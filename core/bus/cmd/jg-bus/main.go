// Command jg-bus is the captain channel's one command: the live tee, the three
// services it talks to, the reply router, and the parity replay.
//
// This header is the one owner of the captain channel's shape. docs/captain-channel.md
// and docs/bus-service.md carry the operator view; nothing else restates it.
//
// WHY THIS EXISTS (migration step 5a, switched live). The fleet reaches the captain
// through files and alerts scattered across the tree. The decided shape is one captain
// channel on a bus: the events that are his to see (a decision waiting, an outcome
// released with its proof link, a blocker, an alert) are published once, delivered to
// his iPad by ntfy, and his replies come back as events routed to the lead that owns
// them. That channel ran in shadow while its parity was proven; `set mode live` is the
// shipped value now, so a change of state reaches the captain by this path.
//
// The stack decision is that new long-running parts are Go. This command owns
// the long-running bus itself (`serve`, `ensure`, `unit`) and the routing every
// captain-facing event takes, so it is written in Go and the shell that held it is
// gone. Its behaviour is unchanged: tests/jg-bus.test.sh drives the same claims it
// drove against the shell, and `parity --corrupt` still proves a green replay is never
// vacuous.
//
// CONTRACT.
//
//	config   defaults/captain-channel, then a home's config/captain-channel, then
//	         JG_CAPTAIN_CHANNEL; the first file carrying a key wins, so an override
//	         may set one key. Nothing here is hard-coded: addresses, subjects,
//	         stream name, the mode, and the relay switch are all in that file.
//	         `config <key>` prints the value in force.
//	mode     `set mode live` is the one switch that decides what this path does, and
//	         live is what ships:
//	           live    record it, publish it, and deliver it to his iPad.
//	           shadow  record and publish only, so the path observes and nothing he
//	                   sees changes. This is the one-step reversal.
//	           off     do nothing at all.
//	record   $STATE/captain-channel.jsonl, one JSON event per line, appended before
//	         anything is published. An event is never lost to an unreachable bus or an
//	         absent service, and it is what a replay and a resend read.
//	publish  Tee one event: record it, publish it to the bus through the Dapr sidecar
//	         (the component file picks the backend; the code does not know NATS from
//	         anything else), and, when the mode is live, deliver it to the captain. It
//	         never breaks its emitter, because the two callers are today's own delivery
//	         paths: every transport failure is logged once to $STATE/captain-channel.log
//	         and the command still exits 0.
//	undelivered  A live delivery that fails is also appended, with its error, to
//	         $STATE/captain-channel-undelivered.jsonl, and `status` counts them. A live
//	         path must not lose an event it was going to deliver without saying so.
//	         Nothing retries on its own: the record holds the event and this file names
//	         the one that did not arrive.
//	parity   Replay every recorded event through the builder the live path sends with
//	         and compare it with the event the record holds: what he would have seen and
//	         what he will get are one diff. The delivery target is the one decision the
//	         switch flips, so parity reports it instead of diffing it. `--corrupt`
//	         tampers with one replayed event on the new side only, which the same diff
//	         must then report, so a green run is never vacuous.
//	ntfy     Delivery to the captain, at the configured topic. `set ntfy-relay off` is
//	         the relay switch: off delivers only to the configured local server, on
//	         sends the same event through ntfy-relay-server. The captain has not
//	         answered the relay question, so the shipped value is off and no code path
//	         needs it on.
//	reply    One captain reply event, JSON {"key","at","answer"[,"label"]}, on stdin or
//	         in a file. Routing is NOT re-decided here: it is the route
//	         bin/jg-board-answers.sh already keeps (state/board-routes/<card-key>) and
//	         the same marked answer line and decision close it sends, so a reply reaching
//	         the bus routes to the lead a board answer routes to. An unrouted card is
//	         refused, exactly as today, and its answer stays with Main.
//	ensure   Start the server when it is not listening and create the stream, then say
//	         one line. What a bootstrap step and docs/bus-service.md run.
//	unit     Print the systemd user service a home installs once, which runs the server
//	         itself and creates the stream after it starts.
//	serve    Start the three services from their files, every one of them read as config
//	         and none re-implemented here: nats-server (core/bus/nats.conf), the
//	         JetStream stream it carries (core/bus/stream.json), the slim Dapr runtime
//	         over NATS (core/bus/dapr/components/pubsub.yaml) and ntfy
//	         (core/bus/ntfy.yml). A home may override any of them under config/bus/.
//	         Pids and logs live in $STATE/bus/, so `stop` and `status` are per home. A
//	         service whose binary is missing is named and not started; the others still
//	         run, because the record never depends on them.
//
// Usage:
//
//	jg-bus config [<key>]
//	jg-bus publish <kind> <key> <text> [--link <url>]
//	jg-bus parity [--record <file>] [--corrupt]
//	jg-bus reply [<event.json>]
//	jg-bus serve | ensure | unit | stop | status | bootstrap
//
// Env: JG_BUS_ROOT (this checkout, set by bin/jg-bus.sh), JG_HOME, JG_STATE_OVERRIDE,
// JG_CAPTAIN_CHANNEL.
package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

// app carries the paths one run resolves. Every command works from these, so the
// shell's per-call environment resolution exists once.
type app struct {
	root        string
	home        string
	state       string
	runtime     string
	record      string
	undelivered string
	log         string
	configFiles []string
}

func main() {
	os.Exit(run(os.Args[1:]))
}

// run dispatches one command and returns its exit status.
func run(args []string) int {
	a := resolve()
	if len(args) == 0 {
		return a.status()
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "config":
		return a.config(rest)
	case "publish":
		return a.publish(rest)
	case "parity":
		return a.parity(rest)
	case "reply":
		return a.reply(rest)
	case "serve":
		return a.serve()
	case "unit":
		return a.unit()
	case "ensure":
		return a.ensure()
	case "stop":
		return a.stop()
	case "bootstrap":
		return a.bootstrap()
	case "status":
		return a.status()
	default:
		return die("unknown command: %s", cmd)
	}
}

// resolve reads the paths one run works from. JG_BUS_ROOT is set by the dispatcher,
// so a home's checkout is named even though the binary itself lives in the home's
// state directory.
func resolve() *app {
	root := os.Getenv("JG_BUS_ROOT")
	if root == "" {
		root = os.Getenv("JG_ROOT_OVERRIDE")
	}
	if root == "" {
		if exe, err := os.Executable(); err == nil {
			root = filepath.Dir(filepath.Dir(exe))
		}
	}
	home := os.Getenv("JG_HOME")
	if home == "" {
		home = os.Getenv("JG_ROOT_OVERRIDE")
	}
	if home == "" {
		home = root
	}
	state := os.Getenv("JG_STATE_OVERRIDE")
	if state == "" {
		state = filepath.Join(home, "state")
	}
	a := &app{
		root:        root,
		home:        home,
		state:       state,
		runtime:     filepath.Join(state, "bus"),
		record:      filepath.Join(state, "captain-channel.jsonl"),
		undelivered: filepath.Join(state, "captain-channel-undelivered.jsonl"),
		log:         filepath.Join(state, "captain-channel.log"),
	}
	files := []string{os.Getenv("JG_CAPTAIN_CHANNEL"), filepath.Join(home, "config", "captain-channel"),
		filepath.Join(root, "defaults", "captain-channel")}
	for _, f := range files {
		if f != "" {
			a.configFiles = append(a.configFiles, f)
		}
	}
	return a
}

// die reports a refusal and returns the exit status the shell used.
func die(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "jg-bus: "+format+"\n", args...)
	return 2
}

// say writes one informational line to stderr, as the shell did.
func say(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

// runningPid reads one service's pid when that process is still alive.
func (a *app) runningPid(name string) (int, bool) {
	data, err := os.ReadFile(filepath.Join(a.runtime, name+".pid"))
	if err != nil {
		return 0, false
	}
	var pid int
	if _, err := fmt.Sscanf(strings.TrimSpace(string(data)), "%d", &pid); err != nil {
		return 0, false
	}
	if err := syscall.Kill(pid, 0); err != nil {
		return 0, false
	}
	return pid, true
}

// countLines is `wc -l`: the number of newlines in a file, or zero when absent.
func countLines(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return bytes.Count(data, []byte("\n"))
}

// setLine is one `set <key> <value>` line of a channel config file.
var setLine = regexp.MustCompile(`^[ \t]*set[ \t]+([^ \t]+)[ \t]+(.*)$`)

// fileGet reads one key out of one config file, or nothing.
func fileGet(path, key string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		m := setLine.FindStringSubmatch(sc.Text())
		if m != nil && m[1] == key {
			return strings.TrimRight(m[2], " \t")
		}
	}
	return ""
}

// cfg is the value in force: the first config file carrying that key wins.
func (a *app) cfg(key string) (string, bool) {
	for _, file := range a.configFiles {
		if v := fileGet(file, key); v != "" {
			return v, true
		}
	}
	return "", false
}

// cfgOr is the value in force with the caller's default.
func (a *app) cfgOr(key, fallback string) string {
	if v, ok := a.cfg(key); ok {
		return v
	}
	return fallback
}

// isOn reports whether one switch key is `on`.
func (a *app) isOn(key string) bool {
	return a.cfgOr(key, "") == "on"
}

// channelMode is what this path does: live, shadow or off. Mode is the one switch.
func (a *app) channelMode() string {
	return a.cfgOr("mode", "live")
}

// busFile is the service file in force: a home override first, then the shipped one.
func (a *app) busFile(name string) string {
	override := filepath.Join(a.home, "config", "bus", name)
	if _, err := os.Stat(override); err == nil {
		return override
	}
	return filepath.Join(a.root, "core", "bus", name)
}

// ntfyURL is the one owner of the relay rule: the local server, or the relay when
// the captain turns that switch on.
func (a *app) ntfyURL() string {
	server := a.cfgOr("ntfy-server", "")
	if a.isOn("ntfy-relay") {
		server = a.cfgOr("ntfy-relay-server", "")
	}
	return strings.TrimRight(server, "/") + "/" + a.cfgOr("ntfy-topic", "")
}
