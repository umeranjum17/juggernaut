package main

// The wake engine's raise and delivery paths (docs/bus-live.md), ported from
// bin/jg-wake-bus.sh with identical behaviour: `wake raise <state> <kind> <key>
// <payload> <class>`, `wake settle <state> <kind> <key> <payload>`, and `wake deliver
// <state> <subject> <msg-id> <json>` (publish, or owe in the outbox). The script passes what it resolved - JG_HOME, the home key, the
// bus address, the nats client it called (empty: none), the subject prefix and the
// stream age - and renders after.

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// jqString is one string as jq prints it: short escapes for \b \f \t \n \r, \u00xx
// for the other control bytes and DEL, everything else raw, a bad byte as U+FFFD.
func jqString(s string) string {
	short := map[rune]string{'"': `\"`, '\\': `\\`, '\b': `\b`, '\f': `\f`, '\t': `\t`, '\n': `\n`, '\r': `\r`}
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s { // ranging a string yields U+FFFD for each invalid byte
		if esc, ok := short[r]; ok {
			b.WriteString(esc)
		} else if r < 0x20 || r == 0x7f {
			fmt.Fprintf(&b, `\u%04x`, r)
		} else {
			b.WriteRune(r)
		}
	}
	return b.String() + `"`
}

type wakeBusEnv struct{ state, home, key, client, url, prefix, maxAge string }

// enabled is the one-step reversal: config/wake-bus carrying the word `off`.
func (w wakeBusEnv) enabled() bool {
	data, err := os.ReadFile(filepath.Join(w.home, "config", "wake-bus"))
	return err != nil || !regexp.MustCompile(`(^|\W)off(\W|$)`).Match(data)
}

func (w wakeBusEnv) bus(args ...string) ([]byte, error) {
	if w.client == "" {
		return nil, os.ErrNotExist
	}
	return exec.Command(w.client, append([]string{"-s", w.url, "--timeout", "10s"}, args...)...).CombinedOutput()
}

// pubSeq publishes and returns the sequence the server stored it at, or 0.
func (w wakeBusEnv) pubSeq(subject, id, event string) int64 {
	out, err := w.bus("pub", "--jetstream", "-H", "Nats-Msg-Id:"+id, subject, event)
	var seq int64
	if m := regexp.MustCompile(`Sequence: ([0-9]+)`).FindSubmatch(out); err == nil && m != nil {
		fmt.Sscan(string(m[1]), &seq)
	}
	return seq
}

func (w wakeBusEnv) ensureStreams() {
	for _, s := range [][2]string{{"JG_WAKE", w.prefix + ".wake.>"}, {"JG_INBOX", w.prefix + ".inbox.>"}} {
		if _, err := w.bus("stream", "info", s[0]); err != nil {
			w.bus("stream", "add", s[0], "--subjects", s[1], "--storage", "file", "--retention", "limits",
				"--max-age", w.maxAge, "--dupe-window", "24h", "--defaults")
		}
	}
}

func (w wakeBusEnv) outbox() string { return filepath.Join(w.state, ".wake-bus.outbox.jsonl") }

// owe appends `{subject: $subject} + $event` to the outbox, as jq builds it: the
// subject leads, and an event carrying its own subject keeps that value.
func (w wakeBusEnv) owe(subject, event string) bool {
	if os.MkdirAll(w.state, 0o777) != nil {
		return false
	}
	f, err := os.OpenFile(w.outbox(), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o666)
	if err != nil {
		return false
	}
	defer f.Close()
	e, ok := parseObject(event)
	if !ok {
		return false
	}
	lead := jqString(subject)
	if own := e.get("subject"); own != "" {
		lead = own
	}
	_, err = f.WriteString(append(wakeEvent{{"subject", lead}}, e.drop("subject")...).marshal() + "\n")
	return err == nil
}

// deliver publishes one event, making the streams and retrying once when the
// first publish is refused, and owes it in the outbox when that fails too. An off
// home only owes it, and says nothing about whether owing it worked.
func (w wakeBusEnv) deliver(subject, id, event string) bool {
	if !w.enabled() {
		w.owe(subject, event)
		return true
	}
	if w.pubSeq(subject, id, event) > 0 {
		return true
	}
	w.ensureStreams()
	return w.pubSeq(subject, id, event) > 0 || w.owe(subject, event)
}

func (e wakeEvent) drop(k string) wakeEvent {
	var out wakeEvent
	for _, f := range e {
		if f.key != k {
			out = append(out, f)
		}
	}
	return out
}

func parseObject(s string) (wakeEvent, bool) {
	dec := json.NewDecoder(strings.NewReader(s))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, false
	}
	return readObject(dec)
}

// object is one event from key and encoded-value pairs, in order.
func object(kv ...string) string {
	var e wakeEvent
	for i := 0; i+1 < len(kv); i += 2 {
		e = e.set(kv[i], kv[i+1])
	}
	return e.marshal()
}

func (a *app) wakeBus(args []string) int {
	need := map[string]int{"raise": 5, "settle": 4, "deliver": 4}
	if len(args) == 0 || need[args[0]] == 0 || len(args)-1 < need[args[0]] {
		return die("wake: usage: wake rows|render|raise|settle|deliver (wake.go, wakebus.go)")
	}
	p := args[1:]
	w := wakeBusEnv{p[0], os.Getenv("JG_HOME"), os.Getenv("JG_WAKE_HOME_KEY"), os.Getenv("JG_NATS_BIN"),
		os.Getenv("JG_WAKE_BUS_URL"), os.Getenv("JG_BUS_SUBJECT_PREFIX"), os.Getenv("JG_BUS_MAX_AGE")}
	now := time.Now().Unix()
	at, hk := fmt.Sprint(now), jqString(w.key)
	ok := true
	switch args[0] {
	case "raise", "settle":
		// The row's number is fixed here, before any publish, so it does not change
		// when an owed event later reaches the stream.
		kind, where, class, subject := "wake", "queue", "", w.prefix+".wake.raise"
		if args[0] == "settle" {
			kind, where, class, subject = "settled", "settled", "silent", w.prefix+".wake.settled"
		} else {
			class = p[4]
		}
		id := fmt.Sprintf("%s/%s/%s-%d-%d", kind, w.key, at, os.Getpid(), rand.Intn(32768))
		ok = w.deliver(subject, id, object("v", "1", "id", jqString(id), "home", hk, "where", jqString(where),
			"at", at, "rseq", fmt.Sprint(now*1000+int64(rand.Intn(32768)%1000)), "kind", jqString(p[1]),
			"key", jqString(p[2]), "payload", jqString(p[3]), "class", jqString(class)))
	case "deliver":
		ok = w.deliver(p[1], p[2], p[3])
	}
	if !ok {
		return 1
	}
	return 0
}
