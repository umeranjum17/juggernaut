package main

// engine.go - the two long-running bus consumers a home installs as services.
//
//	jg-bus wake-engine   consume this home's wake raises from the JG_WAKE stream and bring the
//	                     read model (state/.wake-queue) up to date for each one, by the
//	                     render bin/jg-wake-bus.sh owns. A wake raised by any producer, on this
//	                     host or another, therefore reaches the files every reader opens
//	                     without a caller having to run a render.
//	jg-bus router        consume captain replies from the CAPTAIN stream and route each by the
//	                     rule `jg-bus reply` already applies (the board's own route).
//	jg-bus probe [part]  print each consumer's stream and consumer counts and its handled
//	                     counter, one line per part, and exit 1 when a named part has no consumer.
//
// Both are pull consumers with a durable name, so an event raised while the service was down
// is delivered when it returns. An event counts as handled only after its handler returned:
// the consumer fetches it without acknowledging (jsclient.go), runs the handler, and then
// acknowledges it. A handler that fails asks the server to deliver the event again after a short
// delay, and an event whose last try failed is written to the part's dead list
// (<runtime>/<part>.dead.jsonl) and terminated, so a failure is kept where an operator can read it
// and never silently dropped. A failure other than "nothing arrived" ends the process with its
// reason, and the unit's Restart=always brings it back.
//
// Both handlers are idempotent (the wake engine's is the render, which is cursor-based; the
// router's is the board's own route), so an event delivered twice after a lost acknowledgement is
// harmless.

import (
	"bytes"
	"cmp"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// running is the client process a part is waiting on. A stop signal ends it with the part, so a
// stopped service never leaves a fetch waiting on the server to take the next event.
var (
	runningMu sync.Mutex
	running   *exec.Cmd
)

func stopOnSignal() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-ch
		runningMu.Lock()
		if running != nil && running.Process != nil {
			_ = running.Process.Kill()
		}
		runningMu.Unlock()
		os.Exit(0)
	}()
}

// tally is a consumer's durable counter, kept beside its pid so a restart continues it.
type tally struct {
	Handled int    `json:"handled"`
	Retried int    `json:"retried"` // handler failures that were sent back for another try
	Failed  int    `json:"failed"`  // events whose last try failed: they are on the dead list
	LastID  string `json:"last_id"`
	LastAt  int64  `json:"last_at"`
	Started int64  `json:"started"`
}

// part is one consumer: where it reads, what it filters, and what it does with an event.
type part struct {
	name   string // service and durable consumer name
	stream string
	filter string
	url    string
	env    []string // NATS_USER and NATS_PASSWORD, so the secret is never in an argument list
	handle func(body []byte) error
	fresh  bool // the part holds no state of its own yet: its consumer replays the stream from the start

	deliver string // where a new consumer starts: "all" (the default) or "new"
}

func (a *app) tallyPath(name string) string { return filepath.Join(a.runtime, name+".counts.json") }

func (a *app) readTally(name string) tally {
	var t tally
	_ = json.Unmarshal([]byte(readFileString(a.tallyPath(name))), &t)
	return t
}

func (a *app) writeTally(name string, t tally) {
	data, _ := json.Marshal(t)
	tmp := a.tallyPath(name) + ".tmp"
	if os.WriteFile(tmp, append(data, '\n'), 0o644) == nil {
		_ = os.Rename(tmp, a.tallyPath(name))
	}
}

// nats runs one client command against a part's server as the home's account.
func (p *part) nats(args ...string) (string, string, error) {
	var out, errb bytes.Buffer
	cmd := exec.Command("nats", append([]string{"-s", p.url}, args...)...)
	cmd.Env = append(os.Environ(), p.env...)
	cmd.Stdout, cmd.Stderr = &out, &errb
	runningMu.Lock()
	err := cmd.Start()
	running = cmd
	runningMu.Unlock()
	if err == nil {
		err = cmd.Wait()
	}
	return out.String(), errb.String(), err
}

// wakeScript runs bin/jg-wake-bus.sh for this home, the one owner of the wake bus' stream, subject and
// server address.
func (a *app) wakeScript(args ...string) (string, error) {
	script := filepath.Join(a.root, "bin", "jg-wake-bus.sh")
	cmd := exec.Command(script, args...)
	cmd.Env = append(os.Environ(), "JG_HOME="+a.home, "JG_STATE_OVERRIDE="+a.state)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("jg-wake-bus.sh %s: %v: %s", args[0], err, strings.TrimSpace(errb.String()))
	}
	return out.String(), nil
}

// wakePart is the wake engine: it reads the endpoint from the script, and its handler is the script's render.
func (a *app) wakePart() (*part, error) {
	out, err := a.wakeScript("endpoint")
	if err != nil {
		return nil, err
	}
	f := strings.Split(strings.TrimRight(out, "\n"), "\t")
	if len(f) != 5 {
		return nil, fmt.Errorf("jg-wake-bus.sh endpoint printed %q, want url, stream, subject, user and password file", out)
	}
	var env []string
	if f[3] != "" {
		env = []string{"NATS_USER=" + f[3], "NATS_PASSWORD=" + strings.TrimSpace(readFileString(f[4]))}
	}
	return &part{name: "wake-engine", url: f[0], stream: f[1], filter: f[2], env: env,
		handle: func([]byte) error { _, err := a.wakeScript("render"); return err }}, nil
}

// eventBody is the event a stream message carries. The Dapr sidecar publishes every event inside a
// CloudEvent envelope ({"specversion":"1.0","data":{the event},...}), so what the owner's chat and the
// reply router read is the envelope's data. A body that is no envelope (the bus' own CLI, a test) is
// the event itself.
func eventBody(body []byte) []byte {
	var env struct {
		SpecVersion string          `json:"specversion"`
		Data        json.RawMessage `json:"data"`
	}
	if json.Unmarshal(body, &env) != nil || env.SpecVersion == "" || len(env.Data) == 0 {
		return body
	}
	var text string // a sender may carry the event as a JSON string
	if json.Unmarshal(env.Data, &text) == nil {
		return []byte(text)
	}
	return env.Data
}

func (a *app) routerPart() *part {
	var env []string
	if user, pass, ok := a.credentials(); ok {
		env = []string{"NATS_USER=" + user, "NATS_PASSWORD=" + pass}
	}
	return &part{name: "router", url: a.cfgOr("nats-url", ""), stream: a.streamName(),
		filter: a.cfgOr("subject-prefix", "") + ".reply", env: env,
		handle: func(body []byte) error {
			if code := a.routeReply(body); code != 0 {
				return fmt.Errorf("the reply was not routed (exit %d)", code)
			}
			return nil
		}}
}

// ensureConsumer creates the durable pull consumer when it is not there.
func (p *part) ensureConsumer() error {
	if _, _, err := p.nats("consumer", "info", p.stream, p.name); err == nil {
		if !p.fresh {
			return nil
		}
		// A consumer that has already acknowledged events no longer holds the state it kept, so a
		// part that lost that state replays the stream from the start on a consumer of its own.
		if _, errText, err := p.nats("consumer", "rm", "-f", p.stream, p.name); err != nil {
			return fmt.Errorf("cannot reset consumer %s on %s: %s", p.name, p.stream, strings.TrimSpace(errText))
		}
	}
	from := cmp.Or(p.deliver, "all")
	_, errText, err := p.nats("consumer", "add", p.stream, p.name, "--pull", "--filter", p.filter,
		"--ack", "explicit", "--wait", ackWait.String(), "--deliver", from, "--replay", "instant", "--defaults")
	if err != nil {
		return fmt.Errorf("cannot create consumer %s on %s: %s", p.name, p.stream, strings.TrimSpace(errText))
	}
	return nil
}

// fetchWait is how long one fetch waits for an event: 30s, or JG_BUS_FETCH_WAIT (a Go duration)
// for a test that must cross many fetch cycles quickly.
func fetchWait() time.Duration {
	if d, err := time.ParseDuration(os.Getenv("JG_BUS_FETCH_WAIT")); err == nil && d > 0 {
		return d
	}
	return 30 * time.Second
}

// maxTries is how many times a failing event is tried before it goes to the dead list: 3, or
// JG_BUS_MAX_TRIES. retryDelay is the wait before the server delivers it again, scaled by the try
// number: 5s, or JG_BUS_RETRY_DELAY (a Go duration).
func maxTries() int {
	if n, err := strconv.Atoi(os.Getenv("JG_BUS_MAX_TRIES")); err == nil && n > 0 {
		return n
	}
	return 3
}

func retryDelay(tries int) time.Duration {
	d := 5 * time.Second
	if v, err := time.ParseDuration(os.Getenv("JG_BUS_RETRY_DELAY")); err == nil && v >= 0 {
		d = v
	}
	return d * time.Duration(tries)
}

// ackWait is how long the server waits for an acknowledgement before it delivers an event again.
// ensureConsumer sets it; the keep-alive runs at a third of it.
const ackWait = 10 * time.Second

func envValue(env []string, key string) string {
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, key+"="); ok {
			return v
		}
	}
	return ""
}

// deadLetter records an event that failed its last try, one JSON line, before it is terminated.
func (a *app) deadLetter(p *part, m *jsMsg, tries int, herr error) {
	line, _ := json.Marshal(map[string]any{"at": time.Now().Unix(), "stream": p.stream, "consumer": p.name,
		"tries": tries, "error": herr.Error(), "body": string(m.Data)})
	f, err := os.OpenFile(filepath.Join(a.runtime, p.name+".dead.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		say("%s: cannot write the dead list: %v", p.name, err)
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// serveConsumer runs one part until it fails. Waiting for an event is the fetch's own blocking
// wait, not a sleep. Each event is acknowledged only after its handler returned.
func (a *app) serveConsumer(p *part) int {
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	stopOnSignal()
	pidPath := filepath.Join(a.runtime, p.name+".pid")
	_ = writePid(pidPath, os.Getpid())
	if err := p.ensureConsumer(); err != nil {
		return die("%s: %v", p.name, err)
	}
	t := a.readTally(p.name)
	t.Started = time.Now().Unix()
	a.writeTally(p.name, t)
	say("%s: consuming %s on %s as %s", p.name, p.filter, p.stream, p.name)
	for {
		conn, err := dialNATS(p.url, envValue(p.env, "NATS_USER"), envValue(p.env, "NATS_PASSWORD"))
		if err != nil {
			return die("%s: cannot reach the bus: %v", p.name, err)
		}
		m, err := conn.next(p.stream, p.name, fetchWait())
		if err != nil {
			conn.close()
			return die("%s: fetch failed: %v", p.name, err)
		}
		if m == nil { // nothing arrived within the wait
			conn.close()
			continue
		}
		var ev struct {
			ID string `json:"id"`
		}
		_ = json.Unmarshal(m.Data, &ev)
		tries := m.tries()
		stopKeep := conn.keepAlive(m, ackWait/3)
		herr := p.handle(m.Data)
		stopKeep()
		var rerr error
		switch {
		case herr == nil:
			rerr = conn.ack(m)
			t.Handled++
		case tries < maxTries():
			say("%s: event %s: try %d of %d failed, will be delivered again: %v", p.name, ev.ID, tries, maxTries(), herr)
			rerr = conn.nak(m, retryDelay(tries))
			t.Retried++
		default:
			say("%s: event %s: failed on its last try (%d), written to the dead list: %v", p.name, ev.ID, tries, herr)
			a.deadLetter(p, m, tries, herr)
			rerr = conn.term(m)
			t.Failed++
		}
		if rerr != nil {
			// The server will deliver the event again; both handlers are idempotent.
			say("%s: event %s: the answer to the server was not sent: %v", p.name, ev.ID, rerr)
		}
		conn.close()
		t.LastID, t.LastAt = ev.ID, time.Now().Unix()
		a.writeTally(p.name, t)
	}
}

func (a *app) wakeEngine() int {
	p, err := a.wakePart()
	if err != nil {
		return die("wake-engine: %v", err)
	}
	// One render first: it creates the streams the consumer is made on and applies what arrived while down.
	if _, err := a.wakeScript("render"); err != nil {
		return die("wake-engine: %v", err)
	}
	return a.serveConsumer(p)
}

func (a *app) router() int { return a.serveConsumer(a.routerPart()) }

// probe prints each named part's counts (both when none is named). Its exit status is 1 when a
// part's consumer does not exist, which is how the stack waits for a service to be consuming.
func (a *app) probe(args []string) int {
	names := args
	if len(names) == 0 {
		names = []string{"wake-engine", "wake-watcher", "router"}
	}
	status := 0
	for _, name := range names {
		var p *part
		switch name {
		case "wake-engine":
			var err error
			if p, err = a.wakePart(); err != nil {
				return die("probe: %v", err)
			}
		case "wake-watcher":
			var err error
			if p, err = a.wakeWatcherPart(); err != nil {
				return die("probe: %v", err)
			}
		case "router":
			p = a.routerPart()
		default:
			return die("probe: unknown part %q (wake-engine, wake-watcher, router)", name)
		}
		var consumer struct {
			Delivered struct {
				Stream uint64 `json:"stream_seq"`
			} `json:"delivered"`
			AckFloor struct {
				Stream uint64 `json:"stream_seq"`
			} `json:"ack_floor"`
			Pending uint64 `json:"num_pending"`
		}
		var stream struct {
			State struct {
				Messages uint64 `json:"messages"`
				LastSeq  uint64 `json:"last_seq"`
			} `json:"state"`
		}
		out, _, cerr := p.nats("consumer", "info", p.stream, p.name, "--json")
		if cerr == nil {
			_ = json.Unmarshal([]byte(out), &consumer)
		}
		out, _, _ = p.nats("stream", "info", p.stream, "--json")
		_ = json.Unmarshal([]byte(out), &stream)
		pid := 0
		if got, ok := a.runningPid(name); ok {
			pid = got
		}
		t := a.readTally(name)
		fmt.Printf("%-11s pid=%d stream=%s messages=%d last_seq=%d consumer=%s delivered=%d acked=%d pending=%d handled=%d retried=%d failed=%d\n",
			name, pid, p.stream, stream.State.Messages, stream.State.LastSeq, p.name,
			consumer.Delivered.Stream, consumer.AckFloor.Stream, consumer.Pending, t.Handled, t.Retried, t.Failed)
		if cerr != nil {
			status = 1
		}
	}
	return status
}
