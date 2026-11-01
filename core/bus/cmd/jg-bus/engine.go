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
// is delivered when it returns, and an event is handled once per delivery. The consumer is the
// `nats` client's `consumer next`, the same client the rest of this command uses, because the
// shipped Go module carries no NATS library. A failure other than "nothing arrived" ends the
// process with its reason, and the unit's Restart=always brings it back.
//
// The wake engine's handler is the render, which is idempotent and cursor-based, so an event
// acknowledged by the fetch and then failing to render is applied by the next render. That is
// why a failed handle is counted and reported rather than retried here.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
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
	Failed  int    `json:"failed"`
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

func (a *app) routerPart() *part {
	var env []string
	if user, pass := a.login(); pass != "" {
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
		return nil
	}
	_, errText, err := p.nats("consumer", "add", p.stream, p.name, "--pull", "--filter", p.filter,
		"--ack", "explicit", "--wait", "10s", "--deliver", "all", "--replay", "instant", "--defaults")
	if err != nil {
		return fmt.Errorf("cannot create consumer %s on %s: %s", p.name, p.stream, strings.TrimSpace(errText))
	}
	return nil
}

// serveConsumer runs one part until it fails. Waiting for an event is the fetch's own blocking
// wait, not a sleep.
func (a *app) serveConsumer(p *part) int {
	if err := os.MkdirAll(a.runtime, 0o755); err != nil {
		return die("cannot create %s", a.runtime)
	}
	stopOnSignal()
	pidPath := filepath.Join(a.runtime, p.name+".pid")
	_ = os.WriteFile(pidPath, []byte(fmt.Sprintf("%d\n", os.Getpid())), 0o644)
	if err := p.ensureConsumer(); err != nil {
		return die("%s: %v", p.name, err)
	}
	t := a.readTally(p.name)
	t.Started = time.Now().Unix()
	a.writeTally(p.name, t)
	say("%s: consuming %s on %s as %s", p.name, p.filter, p.stream, p.name)
	for {
		body, errText, err := p.nats("consumer", "next", p.stream, p.name, "--count", "1", "--wait", "30s", "--raw")
		if err != nil {
			// An expired fetch ends as "timeout" or, when the server's expiry notice arrives
			// first, as a message with no reply to acknowledge. Neither is an event.
			if strings.Contains(errText, "timeout") || strings.Contains(errText, "does not have a reply") {
				continue
			}
			return die("%s: fetch failed: %s", p.name, strings.TrimSpace(errText))
		}
		var ev struct {
			ID string `json:"id"`
		}
		_ = json.Unmarshal([]byte(body), &ev)
		if herr := p.handle([]byte(body)); herr != nil {
			t.Failed++
			say("%s: event %s: %v", p.name, ev.ID, herr)
		} else {
			t.Handled++
		}
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
		names = []string{"wake-engine", "router"}
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
		case "router":
			p = a.routerPart()
		default:
			return die("probe: unknown part %q (wake-engine, router)", name)
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
		fmt.Printf("%-11s pid=%d stream=%s messages=%d last_seq=%d consumer=%s delivered=%d acked=%d pending=%d handled=%d failed=%d\n",
			name, pid, p.stream, stream.State.Messages, stream.State.LastSeq, p.name,
			consumer.Delivered.Stream, consumer.AckFloor.Stream, consumer.Pending, t.Handled, t.Failed)
		if cerr != nil {
			status = 1
		}
	}
	return status
}
