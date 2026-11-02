package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// The pure builders of the launch: the text a harness's launch command gets for the grants and
// settings that depend only on the task's own directories, the home's identity, the model and the
// launch-env allow-list. Each is byte for byte what the shell function it replaced printed.

// physDir is `(cd "$d" && pwd -P)`: the physical path of an existing, enterable directory. Like
// bash's cd it reads the path logically first, collapsing a `..` against the text before it, and
// only when that is not a directory lets the kernel resolve each component and `..` physically. An
// empty argument is an error, as it is for cd.
func physDir(d string) (string, error) {
	if d == "" {
		return "", fmt.Errorf("null directory")
	}
	if !filepath.IsAbs(d) {
		cwd, err := os.Getwd()
		if err != nil {
			return "", err
		}
		d = cwd + "/" + d
	}
	var firstErr error
	for _, cand := range []string{filepath.Clean(d), d} {
		real, err := filepath.EvalSymlinks(cand)
		if err == nil {
			var st os.FileInfo
			if st, err = os.Stat(real); err == nil && !st.IsDir() {
				err = fmt.Errorf("not a directory: %s", cand)
			}
		}
		if err == nil {
			err = syscall.Access(real, 1)
		}
		if err == nil {
			// POSIX leaves a leading double slash implementation-defined, and bash keeps it.
			if strings.HasPrefix(d, "//") && !strings.HasPrefix(d, "///") {
				real = "/" + real
			}
			// The shell captures the path in a command substitution, which drops trailing newlines.
			return strings.TrimRight(real, "\n"), nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return "", firstErr
}

// jsonEscapeLine is the shell's `$(json_escape ...)`: backslash then double quote escaped, and the
// trailing newlines a command substitution drops removed.
func jsonEscapeLine(v string) string {
	return strings.TrimRight(jsonEscape(v), "\n")
}

// rovo confines every file-tool operation (open_files, create_file, grep, ...)
// to its worktree by default; toolPermissions.allowedExternalPaths
// (~/.rovo/config.yml) is the only lift, and it must be granted at launch
// through --config-override since there is no per-session escalation once
// the process is running. rovo's bash tool is NOT covered by this grant and
// stays confined to the worktree regardless (confirmed live) - the standard
// operator flow's literal `echo ... >> status file` bash line therefore still
// fails under rovo, but the worker recovers by falling back to its own file
// tools for the same append (confirmed live), which the grant below does cover.
// --config-override itself is single-value (a second occurrence silently
// discards the first, confirmed live), so this is the ONE place that must
// also fold in agent.efficiencyLevel when a supported effort was requested.
// Granted paths are real (symlink-resolved) directories/files under this
// task's home, matching BRIEF_REAL's own resolution: the brief dir (covers
// brief.md/launch-brief.md/report.md), the steering inbox directory (covers
// every steer and its handled/ acknowledgement), and the status file itself.
func rovoOverride(effort, dataDir, stateDir, id string) (string, error) {
	dataReal, err := physDir(dataDir)
	if err != nil {
		return "", err
	}
	stateReal, err := physDir(stateDir)
	if err != nil {
		return "", err
	}
	agent := ""
	if in(effort, "low", "medium", "high", "max") {
		agent = `"agent":{"efficiencyLevel":"` + jsonEscapeLine(effort) + `"},`
	}
	paths := fmt.Sprintf(`"%s","%s","%s"`,
		jsonEscapeLine(dataReal+"/"+id), jsonEscapeLine(stateReal+"/"+id+".inbox"), jsonEscapeLine(stateReal+"/"+id+".status"))
	cfg := "{" + agent + `"toolPermissions":{"allowedExternalPaths":[` + paths + `]}}`
	return "--config-override " + shellQuote(cfg) + " ", nil
}

// Claude Code path-checks the Read/Glob/Grep file tools (and an Edit's
// mandatory prior Read) against its working directories: the pane cwd plus
// every --add-dir. Since 2.1.257 the first outside read in --permission-mode
// auto parks the pane on a one-time interactive question instead of reading,
// and any "Block" answer on the machine lands
// permissions.blockReadsOutsideWorkingDirectories in user settings, which
// then refuses the same reads under --dangerously-skip-permissions too. A
// Juggernaut worker always reads outside its cwd - a squad_lead's steers live
// in the PARENT home's state/<id>.inbox, and a ship or scout worker's launch
// record, steers, and brief live in this home's state/operational-inbox,
// state/<id>.inbox, and data/<id>, plus the code root's .agents/skills so the
// worker can read the skill file the launch role names as the fallback for a
// session where the skill name does not resolve - so every Claude launch,
// fresh spawn and relaunch, in both permission modes, grants exactly those
// task-channel directories. The skills grant is that directory, not the
// checkout root, so the grant does not open the whole checkout. Paths resolve
// the way rovoOverride resolves them
// (real paths under the task's home). The state channel dirs are created
// lazily by their first record, so they are made here: an --add-dir naming a
// directory that does not exist at launch would leave the channel created
// later outside the grant. The grant never covers the whole state/ (watcher
// internals live there) or anything wider.
func claudeAddDirs(kind, stateDir, dataDir, codeRoot, id string) (string, error) {
	stateReal, err := physDir(stateDir)
	if err != nil {
		return "", err
	}
	var dirs []string
	if kind == "squad_lead" {
		if err := mkdirAll(stateReal+"/"+id+".inbox/handled", stateReal+"/pending-replies"); err != nil {
			return "", err
		}
		dirs = []string{stateReal + "/" + id + ".inbox", stateReal + "/pending-replies"}
	} else {
		dataReal, err := physDir(dataDir)
		if err != nil {
			return "", err
		}
		rootReal, err := physDir(codeRoot)
		if err != nil {
			return "", err
		}
		if st, err := os.Stat(rootReal + "/.agents/skills"); err != nil || !st.IsDir() {
			return "", fmt.Errorf("%s/.agents/skills is not a directory", rootReal)
		}
		if err := mkdirAll(stateReal+"/operational-inbox", stateReal+"/"+id+".inbox/handled", dataReal+"/"+id); err != nil {
			return "", err
		}
		dirs = []string{stateReal + "/operational-inbox", stateReal + "/" + id + ".inbox", dataReal + "/" + id, rootReal + "/.agents/skills"}
	}
	var b strings.Builder
	for _, d := range dirs {
		b.WriteString("--add-dir " + shellQuote(d) + " ")
	}
	return b.String(), nil
}

// mkdirAll is `mkdir -p` over several paths: every one is attempted, and the first failure is the
// result, so a path that cannot be made does not stop the others from being made.
func mkdirAll(paths ...string) error {
	var first error
	for _, p := range paths {
		if err := os.MkdirAll(p, 0o777); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// OpenCode asks before reading outside its cwd, and a squad_lead's steering
// inbox, the parent's pending-replies, and the parent's tracked tooling (the
// bin/ scripts it sources, docs/, .agents/skills/) live in the PARENT home. The
// launch-time OPENCODE_CONFIG_CONTENT grant above is an env var, so a lead
// restarted by hand (OpenCode's exit banner prints a bare `opencode --session`)
// loses it and stalls on "Access external directory". The same access, scoped
// to exactly those directories, is therefore also written where OpenCode
// reads it from the lead's own cwd: <home>/.opencode/opencode.json (verified
// on 1.18.25; the root .gitignore keeps it out of git). The tooling
// directories are read-only for the edit tool: it matches a path relative to
// the lead's cwd (../<root name>/bin/...), so the deny keys on the root's
// basename. A shell command can still write; only the edit tool is blocked.
// OpenCode matches an outside read on its parent directory, so a single file
// cannot be granted: the lead's status file shares state/ with watcher
// internals and the parent's AGENTS.md shares the root with .env, so both are
// left out. Reaching the rest of the parent home (data/, config/, projects/,
// other tasks' state) stays a prompt.
func opencodeLeadGrant(home, stateDir, id, codeRoot string) error {
	stateReal, err := physDir(stateDir)
	if err != nil {
		return err
	}
	rootReal, err := physDir(codeRoot)
	if err != nil {
		return err
	}
	if err := mkdirAll(stateReal+"/"+id+".inbox/handled", stateReal+"/pending-replies", home+"/.opencode"); err != nil {
		return err
	}
	allow := `"` + jsonEscapeLine(stateReal+"/"+id+".inbox/**") + `":"allow","` + jsonEscapeLine(stateReal+"/pending-replies/**") + `":"allow"`
	deny := ""
	base := rootReal[strings.LastIndex(rootReal, "/")+1:]
	for _, d := range []string{"bin", "docs", ".agents/skills"} {
		allow += `,"` + jsonEscapeLine(rootReal+"/"+d+"/**") + `":"allow"`
		if deny != "" {
			deny += ","
		}
		deny += `"` + jsonEscapeLine("*/"+base+"/"+d+"/**") + `":"deny"`
	}
	return os.WriteFile(home+"/.opencode/opencode.json", []byte(`{"permission":{"external_directory":{`+allow+`},"edit":{`+deny+"}}}\n"), 0o666)
}

// Implement the launch-delivery contract in this script's header. The full
// home-identity hash isolates equal task ids across homes, and the spawn token in
// the final filename keeps a buffered source line bound to this incarnation.
//
// launchHomeToken is the hex sha-256 of the home's physical path (its given spelling when it cannot
// be entered).
func launchHomeToken(home string) string {
	root, err := physDir(home)
	if err != nil {
		root = home
	}
	sum := sha256.Sum256([]byte(root))
	return hex.EncodeToString(sum[:])
}

// OpenCode keeps every session in one SQLite store, and OpenCode 1.18.25 fails
// a write after a fixed 5000 ms busy timeout. Workers sharing the default
// ~/.local/share/opencode/opencode.db (20.7 GB on 2026-10-10) lost turns to
// "database is locked": one worker held the WAL write lock for up to 11 s.
// So each launch gets its own store through OpenCode's OPENCODE_DB setting.
// The name is relative, so OpenCode resolves it inside its own data directory
// ($XDG_DATA_HOME/opencode, default ~/.local/share/opencode), next to the shared
// auth.json, snapshots, and log, and this script writes nothing there itself.
// It is keyed by home identity and task id, so a relaunch reopens the same
// store and equal task ids in different homes never share one. Readers of
// OpenCode sessions and usage read <opencode data dir>/opencode.db plus every
// <opencode data dir>/juggernaut-*.db; the stores are kept after teardown.
// The opencode console provider keeps its access and refresh tokens inside the
// shared store, and a fresh store has no account, so an opencode/* launch keeps
// the shared store rather than copying credentials, as does a launch whose
// provider is unknown because no model was given. The opencode-go provider is
// different: its key lives in the data dir's auth.json, not in the store, so a
// fresh store still bills that key (verified live with an opencode-go model). A
// Go model therefore gets its own store whenever that auth.json carries an
// opencode-go entry, which keeps it off the console account the shared store
// bills. Only key presence is tested; the value is never read.
func opencodeGoAuthPresent() bool {
	dir := os.Getenv("XDG_DATA_HOME")
	if dir == "" {
		dir = os.Getenv("HOME") + "/.local/share"
	}
	f, err := os.Open(dir + "/opencode/auth.json")
	if err != nil {
		return false
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		return false
	}
	// jq -e 'has("opencode-go")' answers for every value in the file and succeeds only when it
	// parsed to the end, every value was an object, and the last one has the key.
	// jq skips a leading byte-order mark, so this does too.
	br := bufio.NewReader(f)
	if b, err := br.Peek(3); err == nil && string(b) == "\xef\xbb\xbf" {
		_, _ = br.Discard(3)
	}
	dec := json.NewDecoder(br)
	last := false
	for {
		var v map[string]json.RawMessage
		err := dec.Decode(&v)
		if err == io.EOF {
			return last
		}
		if err != nil || v == nil {
			return false
		}
		_, last = v["opencode-go"]
	}
}

// opencodeDB is the OPENCODE_DB assignment that gives one launch its own session store (see
// opencodeGoAuthPresent for why), or nothing when the launch keeps the shared store: no model, the
// opencode console provider, or an opencode-go model whose key is not in auth.json.
func opencodeDB(token, id, model string) string {
	switch {
	case model == "" || model == "default" || strings.HasPrefix(model, "opencode/"):
		return ""
	case strings.HasPrefix(model, "opencode-go/") && !opencodeGoAuthPresent():
		return ""
	}
	if len(token) > 12 {
		token = token[:12]
	}
	return "OPENCODE_DB='juggernaut-" + token + "-" + id + ".db' "
}

// launchEnvNames is config/launch-env-allowlist: one POSIX environment name per line, blank lines
// and lines beginning with # ignored. Anything else makes the whole file invalid.
func launchEnvNames(data []byte) ([]string, bool) {
	var names []string
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !validEnvName(line) {
			return nil, false
		}
		names = append(names, line)
	}
	return names, true
}

func validEnvName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

var credentialShapes = []string{"_api_key", "_apikey", "_token", "_secret", "_secret_key", "_password", "_passwd",
	"_credential", "_credentials", "_access_key", "_access_key_id", "_private_key"}

// launchEnvStrip is the statement a launch pins in front of everything else: a POSIX sh loop that
// walks the pane's own exported names and unsets every credential-shaped one the allow-list does
// not name. It runs in the destination pane, because the pane inherits from the backend server and
// re-exports from its profile after this process built the launch, so a name list computed here
// would miss exactly the credentials that reach workers. The shapes travel as case patterns, never
// as names, so nothing here reads or carries a value.
func launchEnvStrip(allowed []string) string {
	pattern := make([]string, 0, len(credentialShapes))
	for _, shape := range credentialShapes {
		var b strings.Builder
		b.WriteByte('*')
		for i := 0; i < len(shape); i++ {
			c := shape[i]
			if c >= 'a' && c <= 'z' {
				b.WriteByte('[')
				b.WriteByte(c)
				b.WriteByte(c - 'a' + 'A')
				b.WriteByte(']')
				continue
			}
			b.WriteByte(c)
		}
		pattern = append(pattern, b.String())
	}
	allow := strings.Join(allowed, "|")
	if allow != "" {
		allow += ") ;; "
	}
	return "for jg_n in $(env | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'); do case $jg_n in " +
		allow + strings.Join(pattern, "|") + ") unset \"$jg_n\";; esac; done; unset jg_n; "
}

// allowNames is the `|`-free list form of config/launch-env-allowlist as the spawn passes it: one
// name per line, empty lines dropped.
func allowNames(names string) []string {
	var out []string
	for _, n := range strings.Split(names, "\n") {
		if n != "" {
			out = append(out, n)
		}
	}
	return out
}

// envFloor is the operational floor a filtered launch keeps: identity, locale and temp paths, the
// backend's routing names, and the task marker.
var envFloor = []string{"HOME", "PATH", "USER", "LOGNAME", "SHELL", "TERM", "COLORTERM", "LANG", "LC_ALL", "LC_CTYPE",
	"TMPDIR", "TMP", "TEMP", "GOTMPDIR", "TMUX", "TMUX_PANE", "HERDR_ENV", "HERDR_SESSION", "HERDR_SOCKET_PATH",
	"HERDR_PANE_ID", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
	"CMUX_SOCKET_PATH", "ZELLIJ", "ZELLIJ_SESSION_NAME", "ZELLIJ_PANE_ID", "JG_ZELLIJ_SESSION",
	"JG_TASK_ID", "COMPACT_ADVISER_DISABLE"}

// launchEnvWrap puts a launch command behind `env -i` and a shell, forwarding the floor and the
// allow-listed names by reference so a value is expanded once, in the pane, and never becomes text.
//
// COMPACT_ADVISER_DISABLE is the intentional declarative floor-membership entry; the explicit
// COMPACT_ADVISER_DISABLE=1 assignment after the loop is the authoritative setter. It comes last
// deliberately: `env` applies assignments left to right, so it wins over a forwarded pane value, and
// it still delivers the switch on a pane whose export never landed. Setting it here rather than
// relying on the assignment already carried by the launch is what gives the wrapping `/bin/sh`
// itself the switch, not only the agent command it runs. Unlike the trace carrier it carries no
// gate, so it is appended unconditionally. The carrier is forwarded only when the spawn delivers one.
func launchEnvWrap(launch string, allowed []string, traceparent bool) string {
	var b strings.Builder
	b.WriteString("/usr/bin/env -i")
	for _, n := range append(append([]string{}, envFloor...), allowed...) {
		fmt.Fprintf(&b, ` ${%s+"%s=$%s"}`, n, n, n)
	}
	b.WriteString(" COMPACT_ADVISER_DISABLE=1")
	if traceparent {
		b.WriteString(` ${TRACEPARENT+"TRACEPARENT=$TRACEPARENT"}`)
	}
	b.WriteString(" /bin/sh -c " + shellQuote(launch))
	return b.String()
}

func fail(msg string, err error) int {
	if err != nil {
		fmt.Fprintf(os.Stderr, "jg-spawn-core: %s: %v\n", msg, err)
	}
	return 1
}

// builderCmd dispatches the builder subcommands; ok is false for a name it does not own.
func builderCmd(name string, args []string) (code int, ok bool) {
	switch name {
	case "rovo-override":
		if len(args) != 4 {
			return usage(), true
		}
		out, err := rovoOverride(args[0], args[1], args[2], args[3])
		if err != nil {
			return fail("rovo-override", err), true
		}
		fmt.Print(out)
		return 0, true
	case "claude-add-dirs":
		if len(args) != 5 {
			return usage(), true
		}
		out, err := claudeAddDirs(args[0], args[1], args[2], args[3], args[4])
		if err != nil {
			return fail("claude-add-dirs", err), true
		}
		fmt.Print(out)
		return 0, true
	case "opencode-lead-grant":
		if len(args) != 4 {
			return usage(), true
		}
		if err := opencodeLeadGrant(args[0], args[1], args[2], args[3]); err != nil {
			return fail("opencode-lead-grant", err), true
		}
		return 0, true
	case "launch-home-token":
		if len(args) != 1 {
			return usage(), true
		}
		fmt.Print(launchHomeToken(args[0]))
		return 0, true
	case "opencode-db":
		if len(args) != 3 {
			return usage(), true
		}
		fmt.Print(opencodeDB(args[0], args[1], args[2]))
		return 0, true
	case "launch-env-names":
		if len(args) != 1 {
			return usage(), true
		}
		data, err := os.ReadFile(args[0])
		if err != nil {
			return fail("launch-env-names", err), true
		}
		names, valid := launchEnvNames(data)
		if !valid {
			return 1, true
		}
		for _, n := range names {
			fmt.Println(n)
		}
		return 0, true
	case "launch-env-strip":
		if len(args) != 1 {
			return usage(), true
		}
		fmt.Print(launchEnvStrip(allowNames(args[0])))
		return 0, true
	case "launch-env-wrap":
		// launch-env-wrap <allowed-names> <traceparent 0|1>, the launch command on stdin.
		if len(args) != 2 {
			return usage(), true
		}
		launch, err := io.ReadAll(os.Stdin)
		if err != nil {
			return fail("launch-env-wrap", err), true
		}
		var allowed []string
		for _, n := range strings.Fields(args[0]) {
			allowed = append(allowed, n)
		}
		fmt.Print(launchEnvWrap(string(launch), allowed, args[1] == "1"))
		return 0, true
	}
	return 0, false
}
