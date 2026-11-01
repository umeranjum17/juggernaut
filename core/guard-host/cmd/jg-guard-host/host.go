// Guard host facts and the OPA call: the one place a guard rule plugs into.
//
// This is the Go port of the host that gathered the frozen fact document for the Rego
// packages under policy/guard/ and let them decide. The rules and their _test.rego files
// are unchanged, so `opa test policy/guard` still proves the same decisions; this file
// only produces the same input document and the same refusal list. A rule is one .rego
// file under policy/guard/ and nothing here changes for it.
package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// call is one gh or gh-axi invocation in the command, with the repository it would
// write to: what the caller named, else GH_REPO, else this clone's origin.
type call struct {
	Group string `json:"group"`
	Verb  string `json:"verb"`
	Repo  string `json:"repo"`
}

// facts is the frozen input document every rule reads.
type facts struct {
	Tool    string `json:"tool"`
	Command string `json:"command"`
	Cwd     string `json:"cwd"`
	Home    string `json:"home"`
	Calls   []call `json:"calls"`
}

var (
	wordRe    = regexp.MustCompile(`"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\S+`)
	unquoteRe = regexp.MustCompile(`^("([\s\S]*)"|'([\s\S]*)')$`)
	assignRe  = regexp.MustCompile(`^\w+=`)
	ghCallRe  = regexp.MustCompile(`(^|/)(gh-axi|gh)$`)
	schemeRe  = regexp.MustCompile(`^[^/]*/`)
	pathURLRe = regexp.MustCompile(`^(/|\./|\.\./|~|file://)`)
	gitURLRE  = regexp.MustCompile(`\.git$`)
)

// commandWords splits the command into simple commands on ; | & and newlines outside
// quotes, then unshell-quotes each into words. The split is byte-wise, so a multi-byte
// character can never be mistaken for one of the ASCII separators or quotes.
func commandWords(command string) [][]string {
	segments := []string{""}
	var quote byte
	for i := 0; i < len(command); i++ {
		c := command[i]
		if quote == 0 && (c == ';' || c == '|' || c == '&' || c == '\n') {
			if strings.TrimSpace(segments[len(segments)-1]) != "" {
				segments = append(segments, "")
			}
			continue
		}
		if c == '\\' && quote != '\'' {
			segments[len(segments)-1] += string(c)
			if i+1 < len(command) {
				i++
				segments[len(segments)-1] += string(command[i])
			}
			continue
		}
		segments[len(segments)-1] += string(c)
		switch {
		case c == quote:
			quote = 0
		case quote == 0 && (c == '"' || c == '\''):
			quote = c
		}
	}
	out := make([][]string, 0, len(segments))
	for _, segment := range segments {
		if strings.TrimSpace(segment) == "" {
			continue
		}
		words := wordRe.FindAllString(segment, -1)
		for i, word := range words {
			words[i] = unquoteWord(word)
		}
		out = append(out, words)
	}
	return out
}

// unquoteWord drops the outer quotes of a word that is entirely quoted.
func unquoteWord(word string) string {
	m := unquoteRe.FindStringSubmatch(word)
	if m == nil {
		return word
	}
	if m[2] != "" || strings.HasPrefix(word, `"`) {
		return m[2]
	}
	return m[3]
}

// repoFromURL names owner/repo for a remote url; a path or file:// url publishes nothing.
func repoFromURL(url string) string {
	rest := url
	if loc := gitURLRE.FindStringIndex(rest); loc != nil {
		rest = rest[:loc[0]] + rest[loc[1]:]
	}
	if rest == "" || pathURLRe.MatchString(rest) {
		return ""
	}
	switch {
	case strings.Contains(rest, "://"):
		rest = rest[strings.Index(rest, "://")+3:]
		if loc := schemeRe.FindStringIndex(rest); loc != nil {
			rest = rest[loc[1]:]
		}
	case strings.Contains(rest, ":"):
		rest = rest[strings.Index(rest, ":")+1:]
	default:
		return ""
	}
	rest = strings.TrimSuffix(rest, "/")
	parts := strings.Split(rest, "/")
	if len(parts) < 2 {
		return ""
	}
	return strings.Join(parts[len(parts)-2:], "/")
}

// originOf is this clone's own origin, never another remote: a fork clone must not
// fall back to its parent.
func originOf(cwd string) string {
	out, err := exec.Command("git", "-C", cwd, "remote", "get-url", "origin").Output()
	if err != nil {
		return ""
	}
	return repoFromURL(strings.TrimSpace(string(out)))
}

// explicitRepo is the repository the caller named with --repo or -R, if any.
func explicitRepo(args []string) string {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--repo" || a == "-R":
			if i+1 < len(args) {
				return args[i+1]
			}
			return ""
		case strings.HasPrefix(a, "--repo="):
			return a[len("--repo="):]
		case len(a) > 2 && a[0] == '-' && a[1] == 'R':
			return strings.TrimPrefix(a[2:], "=")
		}
	}
	return ""
}

// callsIn finds every gh or gh-axi call in the command, with the repository it would
// write to. The rule decides which calls are writes.
func callsIn(command, cwd string) []call {
	var calls []call
	for _, words := range commandWords(command) {
		at := 0
		for at < len(words) && assignRe.MatchString(words[at]) {
			at++
		}
		if at >= len(words) || !ghCallRe.MatchString(words[at]) {
			continue
		}
		c := call{}
		if at+1 < len(words) {
			c.Group = words[at+1]
		}
		if at+2 < len(words) {
			c.Verb = words[at+2]
		}
		c.Repo = explicitRepo(words[at+1:])
		calls = append(calls, c)
	}
	if len(calls) == 0 {
		return calls
	}
	origin := originOf(cwd)
	for i := range calls {
		repo := strings.TrimSpace(calls[i].Repo)
		if repo == "" {
			repo = strings.TrimSpace(os.Getenv("GH_REPO"))
		}
		if repo == "" {
			repo = origin
		}
		calls[i].Repo = repo
	}
	return calls
}

// evalResult is the slice of `opa eval --format=json` this host reads.
type evalResult struct {
	Result []struct {
		Expressions []struct {
			Value map[string]json.RawMessage `json:"value"`
		} `json:"expressions"`
	} `json:"result"`
}

// decide returns the refusal messages every rule produced, or nil to allow. One OPA
// call reads every rule at once. With no OPA reachable the host says so and allows,
// exactly as before: it never blocks work no rule ever judged.
func decide(policyDir string, f facts) ([]string, error) {
	opa := os.Getenv("OPA")
	if opa == "" {
		opa = "opa"
	}
	input, err := json.Marshal(f)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(opa, "eval", "--format=json", "--data", filepath.Dir(policyDir), "-I", "data.guard")
	cmd.Stdin = strings.NewReader(string(input))
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		var execErr *exec.Error
		if errors.As(err, &execErr) || errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, errors.New("opa eval failed: " + msg)
		}
		return nil, errors.New("opa eval failed: " + strings.TrimSpace(err.Error()))
	}
	var res evalResult
	if err := json.Unmarshal(out, &res); err != nil {
		return nil, errors.New("opa eval failed: " + strings.TrimSpace(err.Error()))
	}
	if len(res.Result) == 0 || len(res.Result[0].Expressions) == 0 {
		return nil, nil
	}
	value := res.Result[0].Expressions[0].Value
	names := make([]string, 0, len(value))
	for rule := range value {
		names = append(names, rule)
	}
	sort.Strings(names)
	var messages []string
	for _, rule := range names {
		var body struct {
			Deny []string `json:"deny"`
		}
		if err := json.Unmarshal(value[rule], &body); err != nil {
			continue
		}
		for _, msg := range body.Deny {
			messages = append(messages, "["+rule+"] "+msg)
		}
	}
	return messages, nil
}

// policyDir is the directory of rules this checkout ships: <root>/policy/guard.
func policyDir(root string) string { return filepath.Join(root, "policy", "guard") }

// policyRoot resolves the checkout holding policy/guard: the dispatcher passes it in,
// else it is found above the executable, else above the working directory.
func policyRoot() string {
	if root := os.Getenv("JG_GUARD_HOST_ROOT"); root != "" {
		return root
	}
	starts := []string{}
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		starts = append(starts, filepath.Dir(exe))
	}
	if cwd, err := os.Getwd(); err == nil {
		starts = append(starts, cwd)
	}
	for _, start := range starts {
		for dir := start; ; dir = filepath.Dir(dir) {
			if stat, err := os.Stat(filepath.Join(dir, "policy", "guard")); err == nil && stat.IsDir() {
				return dir
			}
			if filepath.Dir(dir) == dir {
				break
			}
		}
	}
	return ""
}

// ruleNames lists the rule files this checkout ships, which is how a new rule shows it
// changed no core file.
func ruleNames(root string) []string {
	entries, err := os.ReadDir(policyDir(root))
	if err != nil {
		return nil
	}
	var names []string
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".rego") || strings.HasSuffix(name, "_test.rego") {
			continue
		}
		names = append(names, strings.TrimSuffix(name, ".rego"))
	}
	sort.Strings(names)
	return names
}
