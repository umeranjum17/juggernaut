// Command jg-bus is the captain channel's one command: the chat in and out, the reply route, the
// parity replay and the home's own wake queue.
//
// This header is the one owner of the captain channel's shape. docs/captain-channel.md
// and docs/bus-service.md carry the operator view; nothing else restates it.
//
// WHY THIS EXISTS. The fleet reaches the captain through files and alerts scattered across the
// tree. The decided shape is one captain channel: the events that are his to see (a decision
// waiting, an outcome released with its proof link, a blocker, an alert) are recorded once and
// sent to his chat, and his replies come back routed to the lead that owns them. No server runs
// for it: the chat is sent in-process and the queue is the home's own files.
//
// CONTRACT.
//
//	config   defaults/captain-channel, then a home's config/captain-channel, then
//	         JG_CAPTAIN_CHANNEL; the first file carrying a key wins, so an override
//	         may set one key. `config <key>` prints the value in force.
//	mode     `set mode direct` is the one switch that decides what this path does:
//	           direct  record it, then send it through the chat in-process. A send that fails
//	                   is named undelivered. This is the shipped value.
//	           off     do nothing at all.
//	record   $STATE/captain-channel.jsonl, one JSON event per line, appended before
//	         anything is sent. An event is never lost to an unreachable chat, and it is what a
//	         replay and a resend read.
//	publish  Tee one event: record it and send it through the chat. It never breaks its
//	         emitter, because the two callers are today's own delivery paths: every transport
//	         failure is logged once to $STATE/captain-channel.log and the command still exits 0.
//	undelivered  A send the chat does not take is also appended, with its error, to
//	         $STATE/captain-channel-undelivered.jsonl, and `status` counts them. Nothing
//	         retries on its own: the record holds the event and this file names the one that
//	         did not arrive.
//	parity   Replay every recorded event through the builder the live path sends with
//	         and compare it with the event the record holds: what he would have seen and
//	         what he will get are one diff. The delivery target is the one decision the
//	         switch flips, so parity reports it instead of diffing it. `--corrupt`
//	         tampers with one replayed event on the new side only, which the same diff
//	         must then report, so a green run is never vacuous.
//	reply    One captain reply event, JSON {"key","at","answer"[,"label"]}, on stdin or
//	         in a file. Routing is NOT re-decided here: it is the route
//	         bin/jg-board-answers.sh already keeps (state/board-routes/<card-key>) and
//	         the same marked answer line and decision close it sends. An unrouted card is
//	         refused, exactly as today, and its answer stays with Main.
//	unit     `unit gateway` prints the systemd user service a home installs once for the chat gateway.
//	wake     The home's own wake queue: raise, settle, deliver and render, in files under the home's state.
//	watcher  The watcher's view of that queue: oldest, resurfaced, latest, rows and replay (watcher.go).
//	status   What the channel holds: the mode, the delivery target and the record counts.
//
// Usage:
//
//	jg-bus config [<key>]
//	jg-bus publish <kind> <key> <text> [--link <url>] [--option <value>=<label>]... [--answer <words>]   (--option on a card makes buttons; kind card-close with --answer closes a card the board answered)
//	jg-bus gateway --once | serve | pair | status | enabled | push <text>   (gateway.go, gateway_pair.go and gateway_push.go own this)
//	jg-bus parity [--record <file>] [--corrupt]
//	jg-bus reply [<event.json>]
//	jg-bus unit gateway | status
//	jg-bus watcher oldest|resurfaced|latest|rows|replay   (watcher.go owns these)
//	jg-bus wake render|raise|settle|deliver <state> ...   (wake.go, wakebus.go, wakerender.go own the wake queue's fold, outbox and replica)
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
	// typing is the chat's "typing…" indicator while a serving gateway has open notes; nil otherwise.
	typing *typer
	// data is the home's data directory, which holds the Squad Lead registry.
	data string
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
	case "gateway":
		return a.gateway(rest)
	case "parity":
		return a.parity(rest)
	case "reply":
		return a.reply(rest)
	case "watcher":
		return a.watcherCmd(rest)
	case "unit":
		return a.unit(rest)
	case "wake":
		return a.wake(rest)
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
	a.configFiles = configFilesFor(home, root)
	a.data = os.Getenv("JG_DATA_OVERRIDE")
	if a.data == "" {
		a.data = filepath.Join(home, "data")
	}
	return a
}

// configFilesFor lists the captain-channel config files in force for one home.
func configFilesFor(home, root string) []string {
	var out []string
	for _, f := range []string{os.Getenv("JG_CAPTAIN_CHANNEL"), filepath.Join(home, "config", "captain-channel"),
		filepath.Join(root, "defaults", "captain-channel")} {
		if f != "" {
			out = append(out, f)
		}
	}
	return out
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

// writePid records a service's pid so a reader sees the old pid or the new one, never an empty
// file: a plain truncating write leaves a gap in which the stack's report reads no pid at all and
// calls a service that is starting "not running". The rename replaces the file in one step.
func writePid(path string, pid int) error {
	tmp := fmt.Sprintf("%s.%d.tmp", path, os.Getpid())
	if err := os.WriteFile(tmp, []byte(fmt.Sprintf("%d\n", pid)), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
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

// channelMode is what this path does: direct, live, shadow or off. Mode is the one switch.
func (a *app) channelMode() string {
	return a.cfgOr("mode", "direct")
}

// chatOn is whether the chat gateway runs: the modes that deliver to the owner's chat.
func (a *app) chatOn() bool {
	m := a.channelMode()
	return m == "direct"
}

// busFile is the service file in force: a home override first, then the shipped one.
func (a *app) busFile(name string) string {
	override := filepath.Join(a.home, "config", "bus", name)
	if _, err := os.Stat(override); err == nil {
		return override
	}
	return filepath.Join(a.root, "core", "bus", name)
}
