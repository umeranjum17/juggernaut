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
	// Media is set by the chat gateway's inbound event only; old events do not have it.
	Media []mediaFile `json:"media,omitempty"`
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
func (a *app) eventJSON(at int64, kind, key, text, link string, media ...mediaFile) string {
	return toJSON(event{At: at, Kind: kind, Key: key,
		Subject: a.cfgOr("subject-prefix", "") + "." + kind, Text: text, Link: link, Media: media})
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

// post sends one body to one URL and returns the HTTP status and the response body. A
// transport failure is the error; an HTTP status is the caller's to judge. It is the same
// curl call this path has always made (timeout 5s), and the body goes in on stdin, so a
// long event never reaches an argument list.
func post(target, body string, headers map[string]string) (int, string, error) {
	args := []string{"-sS", "--max-time", "5", "-X", "POST", "--data-binary", "@-", "-w", "\n%{http_code}"}
	for k, v := range headers {
		args = append(args, "-H", k+": "+v)
	}
	args = append(args, target)
	cmd := exec.Command("curl", args...)
	cmd.Stdin = strings.NewReader(body)
	out, err := cmd.CombinedOutput()
	text := strings.TrimRight(string(out), "\n")
	if err != nil {
		return 0, strings.TrimSpace(text), err
	}
	i := strings.LastIndexByte(text, '\n')
	status := 0
	fmt.Sscanf(text[i+1:], "%d", &status)
	if i < 0 {
		return status, "", nil
	}
	return status, text[:i], nil
}

// ok2xx reports an accepted HTTP status.
func ok2xx(status int) bool { return status >= 200 && status < 300 }

// busTarget is the sidecar's publish address, which the subject follows.
func (a *app) busTarget() string {
	return strings.TrimRight(a.cfgOr("dapr-http-url", ""), "/") + "/v1.0/publish/" + a.cfgOr("dapr-pubsub", "")
}

// noteUndelivered names a delivery that did not arrive, with its error.
func (a *app) noteUndelivered(target, why, doc string) {
	appendQuiet(a.undelivered, fmt.Sprintf(`{"at":%d,"target":%s,"error":%s,"event":%s}`,
		time.Now().Unix(), toJSON(target), toJSON(detail(why)), doc))
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
	return a.emit(kind, key, text, link, nil)
}

// emit is publish for a caller that holds the event's parts, such as the chat gateway's inbound
// event with its stored files.
func (a *app) emit(kind, key, text, link string, media []mediaFile) int {
	mode := a.channelMode()
	if mode == "off" {
		return 0
	}
	doc := a.eventJSON(time.Now().Unix(), kind, key, text, link, media...)
	subject := a.cfgOr("subject-prefix", "") + "." + kind
	if err := os.MkdirAll(a.state, 0o755); err != nil {
		a.noteFailure("record", err.Error())
	} else if err := appendLine(a.record, doc); err != nil {
		a.noteFailure("record", err.Error())
	}
	target := a.busTarget() + "/" + subject
	status, out, err := post(target, doc, map[string]string{"Content-Type": "application/json"})
	accepted := err == nil && ok2xx(status)
	if !accepted {
		if err == nil {
			out = fmt.Sprintf("HTTP %d %s", status, out)
		}
		a.noteFailure("bus "+subject, out)
	}
	if mode == "live" && !accepted && !isChatEvent(subject) {
		// The bus did not take the event, so the stream never holds it: name it, with the
		// event itself, so a reader of the undelivered record can send it again.
		a.noteUndelivered(target, out, doc)
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
	return a.routeReply(data)
}

// routeReply routes one reply event's JSON; the CLI and the router service both end here.
func (a *app) routeReply(data []byte) int {
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
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
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
		target = a.busTarget()
	}
	fmt.Printf("mode %s, delivery %s\n", a.channelMode(), target)
	fmt.Printf("record %s: %d event(s), %d undelivered\n", a.record, countLines(a.record), countLines(a.undelivered))
	for _, name := range []string{"nats", "dapr"} {
		fmt.Printf("%s: %s\n", name, a.serviceState(name))
	}
	return 0
}

// serviceState says whether one service runs. A detached service this home started is
// read from its pid, and every other one from the unit the service manager runs it as,
// because the manager is the one owner of that truth: a proxy beside it (a listening
// port, a pid nobody wrote) can disagree with it and send a reader after a fault that
// is not there. A state this probe could not read is unknown, never down.
func (a *app) serviceState(name string) string {
	if pid, ok := a.runningPid(name); ok {
		return fmt.Sprintf("up (pid %d)", pid)
	}
	// The server's unit is the one install-service installs, which a lab names itself;
	// every other part is named by the prefix bin/jg-stack.sh writes its unit under.
	unit := stackUnit(name)
	if name == "nats" {
		unit = unitName()
	}
	load, active, ok := unitState(unit)
	answering := name == "nats" && busListening(a.cfgOr("nats-url", ""))
	if !ok {
		// A server that answers is up whoever started it, whatever the manager can say.
		if answering {
			return "up (the server answers on " + a.cfgOr("nats-url", "") + ", no unit state read)"
		}
		return "unknown (cannot read the service manager for " + unit + ")"
	}
	if load == "not-found" {
		if answering {
			return "up (the server answers on " + a.cfgOr("nats-url", "") + ", no unit " + unit + ")"
		}
		return "down (no unit " + unit + " is installed)"
	}
	if load != "loaded" {
		return "down (unit " + unit + " " + load + ")"
	}
	switch active {
	case "active":
		return "up (unit " + unit + ")"
	case "inactive", "failed":
		return "down (unit " + unit + " " + active + ")"
	}
	// activating, deactivating, reloading and anything else the manager reports: say
	// the state as it is rather than calling a moving service either up or down.
	return active + " (unit " + unit + ")"
}

// unitState reads one unit's LoadState and ActiveState from the service manager. ok is
// false when the manager cannot be asked at all or answers without both, which the
// caller reports as unknown.
func unitState(unit string) (load, active string, ok bool) {
	out, err := exec.Command("systemctl", "--user", "show", "--no-pager",
		"-p", "LoadState", "-p", "ActiveState", unit).Output()
	if err != nil {
		return "", "", false
	}
	for _, line := range strings.Split(string(out), "\n") {
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch key {
		case "LoadState":
			load = value
		case "ActiveState":
			active = value
		}
	}
	if load == "" || active == "" {
		return "", "", false
	}
	return load, active, true
}

// unit prints the systemd user service for one part of the stack a home installs once,
// so it is up after every boot and restart without anyone typing a command: `nats`
// (the default) runs the server itself, not `serve`, which only starts services and
// exits, and creates the stream right after it starts; `dapr` runs its
// own binary in the foreground, the same argv `serve` starts it with.
func (a *app) unit(args []string) int {
	part := "nats"
	if len(args) > 0 {
		part = args[0]
	}
	// A home that does not own the machine's unit gets the installed unit back, byte for
	// byte, so a caller that writes what it is given (bin/jg-stack.sh up) changes nothing;
	// its account is added to the owner's shared accounts file on the way.
	if owner, foreign := a.foreignOwner(); foreign && part == "nats" {
		a.joinMachine(owner, say)
		path, _ := unitPath(unitName())
		fmt.Print(readFileString(path))
		return 0
	}
	text, err := a.buildUnit(part)
	if err != nil {
		return die("%v", err)
	}
	fmt.Print(text)
	return 0
}

// buildUnit returns the unit text for one part. For nats it first writes the machine's
// server config and accounts: the config is ONE file with no `include` lines, because
// nats-server resolves an include path against the config's own directory, so an
// absolute one becomes state/bus/home/... and the server refuses to start. One merged
// file is also what lets the JetStream budget be sized for the number of accounts
// instead of staying below what those accounts reserve.
func (a *app) buildUnit(part string) (string, error) {
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return "", fmt.Errorf("cannot create %s", a.runtime)
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
	switch part {
	case "nats":
		natsServer := "nats-server"
		if path, err := exec.LookPath("nats-server"); err == nil {
			natsServer = path
		}
		// One server per machine: the config carries this machine's per-home accounts, so
		// every home on the machine shares one JetStream and no account can reach another
		// home's subjects.
		var err error
		accounts := filepath.Join(a.runtime, "accounts.conf")
		if a.accountsChanged, err = a.writeAccounts(a.machineHomes()); err != nil {
			return "", fmt.Errorf("cannot write %s: %v", accounts, err)
		}
		conf := filepath.Join(a.runtime, "bus.conf")
		text, err := a.machineConfig()
		if err != nil {
			return "", err
		}
		if a.confChanged, err = writeIfChanged(conf, text); err != nil {
			return "", fmt.Errorf("cannot write %s: %v", conf, err)
		}
		fmt.Fprintf(&b, "Description=Juggernaut message bus for this machine (NATS JetStream, one account per home)\n")
		fmt.Fprintf(&b, "After=network.target\n\n")
		a.unitService(&b, quote, percent, fmt.Sprintf("%s -c %s", quote(natsServer), quote(conf)))
		fmt.Fprintf(&b, "ExecStartPost=%s bootstrap\n", quote(filepath.Join(a.root, "bin", "jg-bus.sh")))
	case "wake-engine", "wake-watcher", "router":
		self, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("cannot find this command: %v", err)
		}
		what := "wake engine (consumes this home's wakes and renders the read model)"
		switch part {
		case "router":
			what = "reply router (routes captain replies by the board's own route)"
		case "wake-watcher":
			what = "wake watcher (folds this home's wake events for the watcher's own-queue observation)"
		}
		fmt.Fprintf(&b, "Description=Juggernaut %s\n", what)
		fmt.Fprintf(&b, "After=network.target %s\nRequires=%s\n\n", natsUnit(), natsUnit())
		a.unitService(&b, quote, percent, quoteAll(quote, []string{self, part}))
		fmt.Fprintf(&b, "Environment=%s\nEnvironment=%s\n", quote("JG_BUS_ROOT="+a.root), quote("JG_STATE_OVERRIDE="+a.state))
	case "dapr":
		path, err := exec.LookPath("daprd")
		if err != nil {
			return "", fmt.Errorf("no daprd on PATH")
		}
		fmt.Fprintf(&b, "Description=Juggernaut message bus sidecar (Dapr over NATS)\n")
		fmt.Fprintf(&b, "After=network.target %s\nRequires=%s\n\n", natsUnit(), natsUnit())
		a.unitService(&b, quote, percent, quoteAll(quote, a.daprArgv(path)))
	case "gateway":
		self, err := os.Executable()
		if err != nil {
			return "", fmt.Errorf("cannot find the jg-bus binary: %v", err)
		}
		fmt.Fprintf(&b, "Description=Juggernaut captain chat gateway (Telegram text in and out)\n")
		fmt.Fprintf(&b, "After=network.target %s\nRequires=%s\n\n", natsUnit(), natsUnit())
		a.unitService(&b, quote, percent, quoteAll(quote, []string{self, "gateway", "serve"}))
		fmt.Fprintf(&b, "Environment=%s\n", quote("JG_BUS_ROOT="+a.root))
		fmt.Fprintf(&b, "Environment=%s\n", quote("JG_STATE_OVERRIDE="+a.state))
	default:
		return "", fmt.Errorf("unit: unknown part %q (nats, wake-engine, wake-watcher, router, dapr, gateway)", part)
	}
	fmt.Fprintf(&b, "Restart=always\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n")
	return b.String(), nil
}

// stackUnit is the unit that runs one part, named the way bin/jg-stack.sh names it:
// the server is <prefix>-bus.service and every other part is <prefix>-<part>.service.
// JG_STACK_UNIT_PREFIX is how a second stack on one machine stays apart.
func stackUnit(part string) string {
	prefix := os.Getenv("JG_STACK_UNIT_PREFIX")
	if prefix == "" {
		prefix = "jg"
	}
	if part == "nats" {
		return prefix + "-bus.service"
	}
	return prefix + "-" + part + ".service"
}

// natsUnit is the name of the unit that runs the server, which the sidecar's unit
// requires.
func natsUnit() string { return stackUnit("nats") }

// unitService writes the [Service] lines every part shares, ending at its ExecStart.
func (a *app) unitService(b *strings.Builder, quote, percent func(string) string, execStart string) {
	fmt.Fprintf(b, "[Service]\nType=simple\n")
	fmt.Fprintf(b, "WorkingDirectory=%s\n", percent(a.runtime))
	fmt.Fprintf(b, "Environment=%s\n", quote("JG_HOME="+a.home))
	fmt.Fprintf(b, "Environment=%s\n", quote("PATH="+os.Getenv("PATH")))
	fmt.Fprintf(b, "ExecStart=%s\n", execStart)
}

func quoteAll(quote func(string) string, argv []string) string {
	out := make([]string, len(argv))
	for i, v := range argv {
		out[i] = quote(v)
	}
	return strings.Join(out, " ")
}
