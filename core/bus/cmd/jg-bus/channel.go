package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// event is one captain-facing event document. The record, the bus and a replay all
// build the event here, so what went out and what a replay rebuilds cannot drift
// apart. Field order is the record's own, so the bytes read the same way the shell
// wrote them.
type event struct {
	At      int64  `json:"at"`
	Kind    string `json:"kind"`
	Key     string `json:"key"`
	Subject string `json:"subject"`
	Text    string `json:"text"`
	Link    string `json:"link,omitempty"`
}

// toJSON renders one value without HTML escaping, so a text with `&` or `<` keeps the
// bytes the shell's builder produced.
func toJSON(v any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return `""`
	}
	return strings.TrimSuffix(buf.String(), "\n")
}

// eventJSON builds the one event document for a fact.
func (a *app) eventJSON(at int64, kind, key, text, link string) string {
	return toJSON(event{At: at, Kind: kind, Key: key,
		Subject: a.cfgOr("subject-prefix", "") + "." + kind, Text: text, Link: link})
}

// appendLine appends one line to a record and reports why when it cannot.
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "%s\n", line)
	return err
}

// appendQuiet appends where a failed write is not the caller's news.
func appendQuiet(path, line string) {
	_ = appendLine(path, line)
}

// detail is a transport failure as one clamped line, which is what the log and the
// undelivered record hold.
func detail(s string) string {
	s = strings.NewReplacer("\n", " ", "\r", " ").Replace(s)
	return clampChars(s, 300)
}

// clampChars keeps at most n characters, by rune as `cut -c` is.
func clampChars(s string, n int) string {
	if n <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// firstLine is the first line of a text, which is what a delivery title holds.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// noteFailure logs one transport failure, once, and never fails its caller.
func (a *app) noteFailure(what, why string) {
	appendQuiet(a.log, fmt.Sprintf("%s failed: %s", what, detail(why)))
}

// post sends one body to one URL and reports a transport failure. It is the same curl
// call this path has always made, so the timeout, the empty response sink and the rule
// that an HTTP status is not a failure (no -f) are unchanged; the body goes in on
// stdin, so a long event never reaches an argument list.
func post(target, body string, headers map[string]string) (string, error) {
	args := []string{"-sS", "-o", "/dev/null", "--max-time", "5", "-X", "POST", "--data-binary", "@-"}
	for k, v := range headers {
		args = append(args, "-H", k+": "+v)
	}
	args = append(args, target)
	cmd := exec.Command("curl", args...)
	cmd.Stdin = strings.NewReader(body)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return strings.TrimSpace(string(out)), err
	}
	return "", nil
}

// publish tees one captain-facing event. It never fails its emitter: both callers are
// the fleet's own delivery paths, so every transport failure is named and the command
// still exits 0.
func (a *app) publish(args []string) int {
	if len(args) < 3 {
		return die("publish needs <kind> <key> <text>")
	}
	kind, key, text := args[0], args[1], args[2]
	link := ""
	rest := args[3:]
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case "--link":
			if i+1 >= len(rest) {
				return die("publish --link needs a url")
			}
			link = rest[i+1]
			i++
		default:
			return die("publish: unknown flag %s", rest[i])
		}
	}
	mode := a.channelMode()
	if mode == "off" {
		return 0
	}
	doc := a.eventJSON(time.Now().Unix(), kind, key, text, link)
	subject := a.cfgOr("subject-prefix", "") + "." + kind
	if err := os.MkdirAll(a.state, 0o755); err != nil {
		a.noteFailure("record", err.Error())
	} else if err := appendLine(a.record, doc); err != nil {
		a.noteFailure("record", err.Error())
	}
	target := strings.TrimRight(a.cfgOr("dapr-http-url", ""), "/") +
		"/v1.0/publish/" + a.cfgOr("dapr-pubsub", "") + "/" + subject
	if out, err := post(target, doc, nil); err != nil {
		a.noteFailure("bus "+subject, out)
	}
	if mode != "live" {
		return 0
	}
	delivery := a.ntfyURL()
	headers := map[string]string{"Title": clampChars(firstLine(text), 120),
		"Tags": a.cfgOr("ntfy-tag", "")}
	if out, err := post(delivery, text, headers); err != nil {
		a.noteFailure("ntfy", out)
		appendQuiet(a.undelivered, fmt.Sprintf(`{"at":%d,"target":%s,"error":%s,"event":%s}`,
			time.Now().Unix(), toJSON(delivery), toJSON(detail(out)), doc))
	}
	return 0
}

// reply routes one captain reply event by the rule in force: the board's own route.
func (a *app) reply(args []string) int {
	src := "-"
	if len(args) > 0 {
		src = args[0]
	}
	var data []byte
	var err error
	if src == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		if _, err := os.Stat(src); err != nil {
			return die("no such reply event file: %s", src)
		}
		data, err = os.ReadFile(src)
	}
	if err != nil {
		return die("no reply event: %v", err)
	}
	if strings.TrimSpace(string(data)) == "" {
		return die("no reply event on stdin")
	}
	var ev struct {
		Key    string `json:"key"`
		At     string `json:"at"`
		Answer string `json:"answer"`
		Label  string `json:"label"`
	}
	if err := json.Unmarshal(data, &ev); err != nil {
		return die("the reply event is not JSON")
	}
	if ev.Key == "" || ev.Answer == "" {
		return die("a reply event needs a card key and the answer")
	}
	at := ev.At
	if at == "" {
		at = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	cmd := exec.Command(filepath.Join(a.root, "bin", "jg-board-answers.sh"),
		"route-answer", ev.Key, at, ev.Answer, ev.Label)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home, "JG_STATE_OVERRIDE="+a.state)
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			return exit.ExitCode()
		}
		return die("the reply could not be routed: %v", err)
	}
	return 0
}

// config prints one key in force, or every key the shipped file carries.
func (a *app) config(args []string) int {
	if len(args) > 0 && args[0] != "" {
		key := args[0]
		v, ok := a.cfg(key)
		if !ok {
			return die("no '%s' in the channel config", key)
		}
		fmt.Printf("%s\n", v)
		return 0
	}
	fmt.Printf("channel config in force:\n")
	f, err := os.Open(filepath.Join(a.root, "defaults", "captain-channel"))
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 2 || fields[0] != "set" {
			continue
		}
		fmt.Printf("  %-18s %s\n", fields[1], a.cfgOr(fields[1], ""))
	}
	return 0
}

// status reports the mode, the delivery target, what the records hold and which
// services this home started.
func (a *app) status() int {
	target := "none"
	if a.channelMode() == "live" {
		target = a.ntfyURL()
	}
	fmt.Printf("mode %s, relay %s, delivery %s\n", a.channelMode(), a.cfgOr("ntfy-relay", ""), target)
	fmt.Printf("record %s: %d event(s), %d undelivered\n", a.record, countLines(a.record), countLines(a.undelivered))
	for _, name := range []string{"nats", "dapr", "ntfy"} {
		state := "down"
		if pid, ok := a.runningPid(name); ok {
			state = fmt.Sprintf("up (%d)", pid)
		}
		fmt.Printf("%s: %s\n", name, state)
	}
	return 0
}

// unit prints the systemd user service a home installs once, so the server is up
// after every boot and restart without anyone typing a command. It runs the server
// itself (not `serve`, which only starts services and exits) and creates the stream
// right after it starts.
func (a *app) unit() int {
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	natsServer := "nats-server"
	if path, err := exec.LookPath("nats-server"); err == nil {
		natsServer = path
	}
	// One server per machine: the unit runs the base config with this machine's
	// per-home accounts included, so every home on the machine shares one
	// JetStream and no account can reach another home's subjects.
	base := a.busFile("nats.conf")
	conf := filepath.Join(a.runtime, "bus.conf")
	accounts := filepath.Join(a.runtime, "accounts.conf")
	if err := a.unitAccounts(accounts); err != nil {
		return die("cannot write %s: %v", accounts, err)
	}
	include := fmt.Sprintf("include %q\ninclude %q\n", base, accounts)
	if err := os.WriteFile(conf, []byte(include), 0o600); err != nil {
		return die("cannot write %s: %v", conf, err)
	}
	quote := func(value string) string {
		value = strings.ReplaceAll(value, `\`, `\\`)
		value = strings.ReplaceAll(value, `"`, `\"`)
		value = strings.ReplaceAll(value, "%", "%%")
		return `"` + value + `"`
	}
	percent := func(value string) string { return strings.ReplaceAll(value, "%", "%%") }
	var b strings.Builder
	fmt.Fprintf(&b, "[Unit]\n")
	fmt.Fprintf(&b, "Description=Juggernaut message bus for this machine (NATS JetStream, one account per home)\n")
	fmt.Fprintf(&b, "After=network.target\n\n")
	fmt.Fprintf(&b, "[Service]\n")
	fmt.Fprintf(&b, "Type=simple\n")
	fmt.Fprintf(&b, "WorkingDirectory=%s\n", percent(a.runtime))
	fmt.Fprintf(&b, "Environment=%s\n", quote("JG_HOME="+a.home))
	fmt.Fprintf(&b, "Environment=%s\n", quote("PATH="+os.Getenv("PATH")))
	fmt.Fprintf(&b, "ExecStart=%s -c %s\n", quote(natsServer), quote(conf))
	fmt.Fprintf(&b, "ExecStartPost=%s bootstrap\n", quote(filepath.Join(a.root, "bin", "jg-bus.sh")))
	fmt.Fprintf(&b, "Restart=always\n")
	fmt.Fprintf(&b, "RestartSec=5\n\n")
	fmt.Fprintf(&b, "[Install]\n")
	fmt.Fprintf(&b, "WantedBy=default.target\n")
	fmt.Print(b.String())
	return 0
}
