// Fleet delete guard: the one rule every runtime adapter calls (pi, opencode, and this
// command's delete mode for the Claude hook). A block is final: no allow-once, flag or
// env override. Each block appends one JSON line to <home>/state/delete-guard.log for the
// delete-guard check; a repeat by the same task within repeatSecs also queues an immediate
// wake for that home.
//
// This is the Go port of the JavaScript decider that held this rule. Its decisions are
// unchanged: core/delete-guard/tests/delete-guard.test.sh drives the same block and allow
// corpus it drove before, and the OPA shadow replay still scores the Rego rule against this
// decider.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const repeatSecs = 600

var (
	bareVarRe  = regexp.MustCompile(`^(\$\w+|\$\{[^}]+\})(/+[.]?\*|/+\.|/+)?$`)
	shellVarRe = regexp.MustCompile(`^(HOME|PWD|OLDPWD|TMPDIR|TMP|TEMP|USER|LOGNAME|SHELL|PATH|IFS|BASH\w*|(XDG|FM|CLAUDE|CODEX|HERDR|PI|OPENCODE|NO_MISTAKES)_\w*)$`)
	// decl is an optional declaration keyword before an assignment, with only the plain
	// flags -r -x -g: -n (a nameref such as declare -n T=HOME) and any other flag change
	// what the value means, so such a statement never counts as a plain one.
	decl = `(?:(?:export|local|readonly|typeset|declare)(?:\s+-[rxg]+)*\s+)?`

	deleteWordRe = regexp.MustCompile(`(?:"[^"]*"|'[^']*'|[^\s"'])+`)
	quoteInWord  = regexp.MustCompile(`"([^"]*)"|'([^']*)'`)
	quotedSpanRe = regexp.MustCompile(`'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"`)
	varArgRe     = regexp.MustCompile(`^\$(\w+)$|^\$\{(\w+)\}$`)
	mktempAltRe  = regexp.MustCompile("^\\s*mktemp(\\s([^`;$&|()]|\\$\\w+|\\$\\{\\w+\\})*)?$")
	blockStartRe = regexp.MustCompile(`^(if|for|while|until|case)\b`)
	blockEndRe   = regexp.MustCompile(`^(fi|done|esac)\b`)
	literalRe    = regexp.MustCompile(`^[~/\p{L}\p{N}.@%+=:,+-]+$`)
	dotdotRe     = regexp.MustCompile(`(^|/)\.\.(/|$)`)
	homeStartRe  = regexp.MustCompile(`^(\$HOME|\$\{HOME\}|~)(/|$)`)
	trailingGlob = regexp.MustCompile(`/\.?\*$`)
	shellCmdRe   = regexp.MustCompile(`(^|[\s;&|(/])(ba|z|da)?sh(\s|$)`)
	rmWordRe     = regexp.MustCompile(`(^|/|\\)(rm|rimraf)$`)
	findWordRe   = regexp.MustCompile(`(^|/)find$`)
	rimrafWordRe = regexp.MustCompile(`rimraf$`)
	recursiveRe  = regexp.MustCompile(`^-[a-zA-Z]*[rR]`)
	findFlagRe   = regexp.MustCompile(`^[-(!]`)
	cleanDotsRe  = regexp.MustCompile(`^(\.\.?|(\.\./)*\.\.)$`)
	oneInHomeRe  = regexp.MustCompile(`^/home/[^/]+$`)
	heredocHead  = regexp.MustCompile(`<<-?\s*(['"]?)(\w+)`)
)

// homes is the home folder list the guard judges a target against.
func homes() []string {
	seen := map[string]bool{}
	var out []string
	add := func(h string) {
		h = strings.TrimRight(h, "/")
		if h != "" && !seen[h] {
			seen[h] = true
			out = append(out, h)
		}
	}
	if u, err := user.Current(); err == nil {
		add(u.HomeDir)
	}
	if h, err := os.UserHomeDir(); err == nil {
		add(h)
	}
	return out
}

// words splits one simple command into words, dropping the quotes it finds anywhere in a
// word so `"$HOME"` yields `$HOME`.
func words(segment string) []string {
	found := deleteWordRe.FindAllString(segment, -1)
	for i, w := range found {
		found[i] = quoteInWord.ReplaceAllString(w, "${1}${2}")
	}
	return found
}

// assignsRe matches any assignment to name, including read/unset/for and ${name:=x}
// forms: any of these replaces a previous value.
func assignsRe(name string) *regexp.Regexp {
	return regexp.MustCompile(`(^|[\s;({])(export\s+|local\s+|readonly\s+|typeset\s+|declare(\s+-\w+)*\s+)?` +
		regexp.QuoteMeta(name) + `\+?=|\$\{` + regexp.QuoteMeta(name) + `:?=|\b(read|for|unset|mapfile|readarray|printf\s+-v)\b.*\b` +
		regexp.QuoteMeta(name) + `\b`)
}

// unquoted is the segment with quoted spans removed, so a word like "unset" inside a
// string never counts as one.
func unquoted(s string) string { return quotedSpanRe.ReplaceAllString(s, " ") }

// seg is one simple command and the separator that started it ("" for the first), so a
// plain statement can be told from one guarded by && or ||.
type seg struct {
	s   string
	sep string
}

// freshTempVar is the mktemp bare-variable exception: the last assignment to the variable
// before the delete, in the same command, is its own statement d=$(mktemp ...), optionally
// after export, local, declare -r and the like, where the arguments may hold plain $NAME
// or ${NAME} expansions but no command substitution, backticks or ; & | ( ), or
// d=$(mktemp ... || mktemp ...) where every || alternative is a mktemp call.
func freshTempVar(arg string, segments []seg, at int) bool {
	m := varArgRe.FindStringSubmatch(arg)
	if m == nil {
		return false
	}
	name := m[1]
	if name == "" {
		name = m[2]
	}
	if name == "" || shellVarRe.MatchString(name) {
		return false
	}
	assigns := assignsRe(name)
	stmtRe := regexp.MustCompile(`^` + decl + regexp.QuoteMeta(name) + `=(.*)$`)
	fresh := false
	for j := 0; j <= at && j < len(segments); j++ {
		if !assigns.MatchString(unquoted(segments[j].s)) {
			continue
		}
		// An unquoted || inside $( ) split the statement into segments; rejoin them until
		// its parentheses balance.
		s := segments[j].s
		end := j
		for end+1 < at && strings.Count(s, "(") > strings.Count(s, ")") {
			end++
			s += segments[end].sep + segments[end].s
		}
		body := ""
		if j < at {
			if m := stmtRe.FindStringSubmatch(strings.TrimSpace(s)); m != nil {
				if inner, ok := callBody(m[1]); ok {
					body = inner
				}
			}
		}
		fresh = body != ""
		if fresh {
			for _, alt := range strings.Split(body, "||") {
				if !mktempAltRe.MatchString(alt) {
					fresh = false
					break
				}
			}
		}
	}
	return fresh
}

// callBody is the inside of `$(...)`, optionally wrapped in one matching pair of quotes.
func callBody(value string) (string, bool) {
	if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
		value = value[1 : len(value)-1]
	}
	if len(value) < 4 || !strings.HasPrefix(value, "$(") || !strings.HasSuffix(value, ")") {
		return "", false
	}
	return value[2 : len(value)-1], true
}

// nested reports whether the segments before at sit inside a block keyword or an
// unmatched ( or { group.
func nested(segments []seg, at int) bool {
	kw, group := 0, 0
	for i := 0; i < at && i < len(segments); i++ {
		t := strings.TrimSpace(segments[i].s)
		group += strings.Count(t, "(") - strings.Count(t, ")") + strings.Count(t, "{") - strings.Count(t, "}")
		if blockStartRe.MatchString(t) {
			kw++
		}
		if blockEndRe.MatchString(t) {
			kw--
		}
	}
	return kw > 0 || group > 0
}

// literalValue is the literal-assignment exception: the last assignment to the variable
// before the delete, in the same command, is an unconditional statement (after ; or a
// newline or at the start, not inside an if or loop, a subshell or a {} group, and not
// after && || | &) whose value is a literal path.
func literalValue(arg string, segments []seg, at int) (string, bool) {
	m := varArgRe.FindStringSubmatch(arg)
	if m == nil {
		return "", false
	}
	name := m[1]
	if name == "" {
		name = m[2]
	}
	if name == "" || shellVarRe.MatchString(name) {
		return "", false
	}
	assigns := assignsRe(name)
	stmtRe := regexp.MustCompile(`^` + decl + regexp.QuoteMeta(name) + `=(.+)$`)
	value, known := "", false
	for j := 0; j < at && j < len(segments); j++ {
		if !assigns.MatchString(unquoted(segments[j].s)) {
			continue
		}
		value, known = "", false // the last assignment decides; anything else leaves it unknown
		m := stmtRe.FindStringSubmatch(strings.TrimSpace(segments[j].s))
		if m == nil || (segments[j].sep != "" && segments[j].sep != ";" && segments[j].sep != "\n") || nested(segments, j) {
			continue
		}
		v := m[1]
		if len(v) >= 2 && (v[0] == '"' && v[len(v)-1] == '"' || v[0] == '\'' && v[len(v)-1] == '\'') {
			v = v[1 : len(v)-1]
		}
		if literalRe.MatchString(v) && !dotdotRe.MatchString(v) {
			value, known = v, true
		}
	}
	return value, known
}

// dangerousTarget judges one operand of a recursive delete.
func dangerousTarget(arg string, segments []seg, at int) bool {
	if arg == "" || arg == "--" {
		return false
	}
	if bareVarRe.MatchString(arg) {
		if freshTempVar(arg, segments, at) {
			return false
		}
		lit, known := literalValue(arg, segments, at)
		if !known {
			return true // otherwise blocked whatever the variable holds
		}
		arg = lit // set to a literal path in the same command: judge it like a direct target
	}
	if strings.Contains(arg, "$") && dotdotRe.MatchString(arg) {
		return true // $d/.. and $d/../x
	}
	home := ""
	if hs := homes(); len(hs) > 0 {
		home = hs[0]
	}
	a := arg
	if home != "" {
		a = homeStartRe.ReplaceAllString(a, home+"$2")
	}
	a = path.Clean(trailingGlob.ReplaceAllString(a, ""))
	a = strings.TrimRight(a, "/")
	if a == "" {
		a = "/"
	}
	if cleanDotsRe.MatchString(a) || a == "*" || a == ".*" {
		return true
	}
	if a == "/" || a == "/home" || oneInHomeRe.MatchString(a) {
		return true
	}
	for _, h := range homes() {
		if a == h {
			return true
		}
		if rest, ok := strings.CutPrefix(a, h+"/"); ok && !strings.Contains(rest, "/") {
			return true
		}
	}
	return false
}

// segmentsOf splits the command into simple commands on ; | & and newlines outside
// quotes, keeping the separator that started each. A heredoc body fed to a shell stays
// commands; any other heredoc body is data and is dropped.
func segmentsOf(command string) []seg {
	text := dropDataHeredocs(command)
	out := []seg{{}}
	var quote byte
	for i := 0; i < len(text); i++ {
		c := text[i]
		if quote == 0 && (c == ';' || c == '|' || c == '&' || c == '\n') {
			out = append(out, seg{sep: string(c)})
			continue
		}
		if c == '\\' && quote != '\'' {
			cur := out[len(out)-1].s + string(c)
			if i+1 < len(text) {
				i++
				cur += string(text[i])
			}
			out[len(out)-1].s = cur
			continue
		}
		out[len(out)-1].s += string(c)
		switch {
		case c == quote:
			quote = 0
		case quote == 0 && (c == '"' || c == '\''):
			quote = c
		}
	}
	return out
}

// dropDataHeredocs keeps a heredoc body only when it is fed to a shell; every other body
// is data and is removed with its opening line's tail.
func dropDataHeredocs(text string) string {
	lines := strings.Split(text, "\n")
	var out strings.Builder
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		if start, tag, ok := heredocStart(lines, i); ok {
			j := closingLine(lines, i+1, tag)
			rest := line[:start[0]] + line[start[1]:]
			out.WriteString(rest)
			if shellCmdRe.MatchString(rest) {
				out.WriteString("\n")
				out.WriteString(strings.Join(lines[i+1:j], "\n"))
			}
			out.WriteString("\n")
			i = j
			continue
		}
		out.WriteString(line)
		if i < len(lines)-1 {
			out.WriteString("\n")
		}
	}
	return out.String()
}

// heredocStart finds the first `<<` marker on one line that has a closing line, and
// returns the span of the marker and the tag.
func heredocStart(lines []string, i int) ([2]int, string, bool) {
	for from := 0; from < len(lines[i]); {
		loc := heredocHead.FindStringSubmatchIndex(lines[i][from:])
		if loc == nil {
			return [2]int{}, "", false
		}
		start := from + loc[0]
		end := from + loc[1]
		quote := ""
		if loc[2] >= 0 {
			quote = lines[i][loc[2]+from : loc[3]+from]
		}
		tag := lines[i][loc[4]+from : loc[5]+from]
		if quote == "" || (end+1 <= len(lines[i]) && string(lines[i][end]) == quote) {
			if quote != "" {
				end++
			}
			if closingLine(lines, i+1, tag) > 0 {
				return [2]int{start, end}, tag, true
			}
		}
		from = loc[1] + from
	}
	return [2]int{}, "", false
}

// closingLine is the first line after from whose content, bar spaces and tabs, is the
// tag; 0 when the heredoc never closes.
func closingLine(lines []string, from int, tag string) int {
	for j := from; j < len(lines); j++ {
		if strings.Trim(lines[j], " \t") == tag {
			return j
		}
	}
	return 0
}

// blockedDelete is the target of the first recursive delete the command would make
// against a folder the guard protects, or ok=false to allow.
func blockedDelete(command string) (string, bool) {
	segments := segmentsOf(command)
	for at, segment := range segments {
		w := words(strings.TrimSpace(segment.s))
		shell := -1
		for i, t := range w {
			if rmShellWord(t) && i+1 < len(w) && w[i+1] == "-c" {
				shell = i
				break
			}
		}
		if shell >= 0 && shell+2 < len(w) {
			if inner, ok := blockedDelete(w[shell+2]); ok {
				return inner, true
			}
		}
		i := indexMatch(w, rmWordRe)
		f := indexMatch(w, findWordRe)
		isFind := f >= 0 && contains(w, "-delete")
		if i < 0 && !isFind {
			continue
		}
		var args []string
		if i >= 0 {
			args = w[i+1:]
		} else {
			args = w[f+1:]
			end := 0
			for end < len(args) && !findFlagRe.MatchString(args[end]) {
				end++
			}
			args = args[:end]
		}
		recursive := i < 0 || rimrafWordRe.MatchString(w[i])
		if !recursive {
			for _, t := range args {
				if recursiveRe.MatchString(t) || t == "--recursive" {
					recursive = true
					break
				}
			}
		}
		if !recursive {
			continue
		}
		for _, t := range args {
			if !strings.HasPrefix(t, "-") || i < 0 {
				if dangerousTarget(t, segments, at) {
					return t, true
				}
			}
		}
	}
	return "", false
}

func rmShellWord(t string) bool {
	switch t {
	case "sh", "bash", "zsh", "dash", "/sh", "/bash", "/zsh", "/dash":
		return true
	}
	return false
}

func indexMatch(words []string, re *regexp.Regexp) int {
	for i, w := range words {
		if re.MatchString(w) {
			return i
		}
	}
	return -1
}

func contains(words []string, want string) bool {
	for _, w := range words {
		if w == want {
			return true
		}
	}
	return false
}

// loggedCommand keeps any block replayable: the whole command, or the head plus the part
// around the blocked delete. The cap sits above the longest command the fleet has
// recorded, because a cut row cannot be replayed.
func loggedCommand(command, target string) string {
	if len(command) <= 2000 {
		return command
	}
	at := strings.LastIndex(command, target)
	if at < 0 {
		at = len(command)
	}
	from := at - 250
	if from < 0 {
		from = 0
	}
	to := at + 350
	if to > len(command) {
		to = len(command)
	}
	return fmt.Sprintf("%s …[%d chars total; around the delete: %s]", command[:2000], len(command), command[from:to])
}

// logRow is one recorded block, in the order the check reads it.
type logRow struct {
	At      string `json:"at"`
	Home    string `json:"home"`
	Task    string `json:"task"`
	Cwd     string `json:"cwd"`
	Runtime string `json:"runtime"`
	Target  string `json:"target"`
	Command string `json:"command"`
}

// escalate records the block and queues one wake when the same task repeats it.
func escalate(row logRow) error {
	home := ""
	if exe, err := os.Executable(); err == nil {
		if b, err := os.ReadFile(filepath.Join(filepath.Dir(exe), "home")); err == nil {
			home = strings.TrimSpace(string(b))
		}
	}
	if home == "" {
		return nil
	}
	log := filepath.Join(home, "state", "delete-guard.log")
	line, err := json.Marshal(row)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(log, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	at, err := time.Parse(time.RFC3339, row.At)
	if err != nil {
		at = time.Now()
	}
	since := at.Add(-repeatSecs * time.Second)
	key := row.Task
	if key == "" {
		key = row.Cwd
	}
	body, err := os.ReadFile(log)
	if err != nil {
		return err
	}
	recent := 0
	for _, l := range strings.Split(string(body), "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		var r logRow
		if json.Unmarshal([]byte(l), &r) != nil {
			continue
		}
		k := r.Task
		if k == "" {
			k = r.Cwd
		}
		when, err := time.Parse(time.RFC3339, r.At)
		if err != nil || k != key || when.Before(since) {
			continue
		}
		recent++
	}
	if recent < 2 {
		return nil
	}
	task := "an agent in " + row.Cwd
	if row.Task != "" {
		task = "task " + row.Task
	}
	shome := row.Home
	if shome == "" {
		shome = "?"
	}
	reason := fmt.Sprintf("check: delete guard REPEAT: %s tried %d blocked recursive deletes in %d min (home %s, %s); latest: %s - stop that task and check it",
		task, recent, repeatSecs/60, shome, row.Runtime, firstN(row.Command, 200))
	cmd := exec.Command("bash", "-c", `. "$1/bin/jg-wake-lib.sh" && jg_wake_append check delete-guard "$2"`, "_", home, reason)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "JG_HOME=" + home}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("repeat wake failed: %s", strings.TrimSpace(stderr.String()))
	}
	return nil
}

func firstN(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// guard returns the block message, or "" to allow. Logging and waking never turn a block
// into an allow.
func guard(command, cwd, runtime string) string {
	target, blocked := blockedDelete(command)
	if !blocked {
		return ""
	}
	env := compatEnv()
	// The true home: the juggernaut home holding cwd (the lane the command ran in, even
	// when an inbox or JG_HOME from elsewhere is inherited), else the task's inbox, else
	// JG_HOME.
	home := ""
	if abs, err := filepath.Abs(cwd); err == nil {
		cwd = abs
	}
	if cwd != "" {
		for d := cwd; home == "" && d != "/" && d != "."; d = filepath.Dir(d) {
			if exists(filepath.Join(d, "bin", "jg-wake-lib.sh")) && exists(filepath.Join(d, "state")) {
				home = d
			}
			if filepath.Dir(d) == d {
				break
			}
		}
	}
	if home == "" && env["JG_TASK_INBOX"] != "" {
		home = filepath.Dir(filepath.Dir(env["JG_TASK_INBOX"]))
	}
	if home == "" {
		home = env["JG_HOME"]
	}
	row := logRow{
		At:      time.Now().UTC().Format("2006-01-02T15:04:05.000Z"),
		Home:    home,
		Task:    env["JG_TASK_ID"],
		Cwd:     cwd,
		Runtime: runtime,
		Target:  target,
		Command: loggedCommand(command, target),
	}
	note := ""
	if err := escalate(row); err != nil {
		note = fmt.Sprintf(" (the block could not be logged: %s)", err.Error())
	}
	return `BLOCKED by the fleet delete guard: a recursive delete aimed at "` + target + `" (/, /home, a home folder or a folder directly in it, a bare . .. * ` +
		`or a $VAR target). To delete the folder in a later command, write its literal path: rm -rf -- /tmp/tmp.Ab12. A variable may be deleted only when the same command sets it under your own name such as d, never TMP, TMPDIR, TEMP, HOME, PWD or another shell or runtime variable: ` +
		`d=$(mktemp -d); ...; rm -rf -- "$d". A $VAR set in an earlier command is unknown to the guard and is always blocked. This block is final and has been reported to your ` +
		`supervisor: do not retry it, reword it, or work around it. If you truly need this delete, stop and report it as blocked.` + note
}

// compatEnv is the process environment with an old FM_* name still resolved, so an
// unmigrated caller keeps working.
func compatEnv() map[string]string {
	out := map[string]string{}
	for _, kv := range os.Environ() {
		if i := strings.Index(kv, "="); i > 0 {
			out[kv[:i]] = kv[i+1:]
		}
	}
	for k, v := range out {
		if name, ok := strings.CutPrefix(k, "FM_"); ok {
			if _, set := out["JG_"+name]; !set {
				out["JG_"+name] = v
			}
		}
	}
	return out
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}
