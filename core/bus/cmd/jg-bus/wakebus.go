package main

// The wake engine's raise and delivery paths (docs/bus-live.md), ported from
// bin/jg-wake-bus.sh with identical behaviour: `wake raise <state> <kind> <key>
// <payload> <class>`, `wake settle <state> <kind> <key> <payload>`, and `wake deliver
// <state> <subject> <msg-id> <json>` (publish, or owe in the outbox). The script passes what it resolved - JG_HOME, the home key, the
// bus address, the nats client it called (empty: none), the subject prefix and the
// stream age - and renders after. The raise-stdin and settle-stdin variants omit
// the payload argument and read its bytes from stdin instead.

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
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
	cmd := exec.Command(w.client, "-s", w.url, "--timeout", "10s", "pub", "--jetstream", "-H", "Nats-Msg-Id:"+id, "--no-templates", subject)
	cmd.Stdin = strings.NewReader(event)
	out, err := cmd.CombinedOutput()
	var seq int64
	if m := regexp.MustCompile(`Sequence: ([0-9]+)`).FindSubmatch(out); err == nil && m != nil {
		fmt.Sscan(string(m[1]), &seq)
	}
	return seq
}

// ensureStream makes the stream and makes sure it carries this home's subject: the machine
// runs one JetStream, so a stream an earlier build made for another home gets this home's
// subject added to its list, keeping its messages.
func (w wakeBusEnv) ensureStream(stream, subject string) {
	out, _ := w.busOut("stream", "info", stream, "--json")
	var info struct {
		Config struct {
			Subjects []string `json:"subjects"`
		} `json:"config"`
	}
	json.Unmarshal(out, &info)
	have := info.Config.Subjects
	if len(have) == 0 {
		w.bus("stream", "add", stream, "--subjects", subject, "--storage", "file", "--retention", "limits",
			"--max-age", w.maxAge, "--dupe-window", "24h", "--defaults")
		return
	}
	for _, s := range have {
		if s == subject {
			return
		}
	}
	w.bus("stream", "edit", stream, "--subjects", strings.Join(append(have, subject), ","), "--force")
}

func (w wakeBusEnv) ensureStreams() {
	w.ensureStream("JG_WAKE", w.prefix+".wake.>")
	w.ensureStream("JG_INBOX", w.prefix+".inbox.>")
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

// nextWakeSequence fixes the row order before publication, including while offline.
// The kernel releases the lock on exit; atomic replacement keeps an interrupted
// write from resetting the high-water mark. It is ordering state, not a queue.
func (a *app) nextWakeSequence(state string) (int64, error) {
	path := filepath.Join(state, "bus", "wake-order")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 0, err
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return 0, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return 0, err
	}
	var previous int64
	data, err := os.ReadFile(path)
	if err == nil {
		previous, err = strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	} else if os.IsNotExist(err) {
		// Legacy producers used a random suffix within the current second.
		// Start beyond that range so their existing rows remain older.
		previous = time.Now().Unix()*1000 + 999
		for _, name := range []string{".wake-bus.events.jsonl", ".wake-bus.outbox.jsonl"} {
			old, readErr := os.ReadFile(filepath.Join(state, name))
			if readErr != nil && !os.IsNotExist(readErr) {
				return 0, readErr
			}
			eachObject(old, func(e wakeEvent) {
				for _, key := range []string{"rseq", "seq"} {
					n, _ := strconv.ParseInt(e.get(key), 10, 64)
					previous = max(previous, n)
				}
			})
		}
		err = nil
	}
	if err != nil {
		return 0, fmt.Errorf("read %s: %w", path, err)
	}
	seq := time.Now().UnixMilli()
	if seq <= previous {
		seq = previous + 1
	}
	// JSON, jq and awk readers must all represent the integer exactly.
	if previous < 0 || previous >= 1<<53-1 || seq <= 0 || seq > 1<<53-1 {
		return 0, fmt.Errorf("%s: sequence exceeds the exact integer range", path)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".wake-order.*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	if _, err = fmt.Fprintln(tmp, seq); err == nil {
		err = tmp.Sync()
	}
	if closeErr := tmp.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		return 0, err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return 0, err
	}
	defer dir.Close()
	return seq, dir.Sync()
}

func (a *app) wakeBus(args []string) int {
	need := map[string]int{"raise": 5, "settle": 4, "raise-stdin": 4, "settle-stdin": 3, "deliver": 4, "render": 1}
	if len(args) == 0 || need[args[0]] == 0 || len(args)-1 < need[args[0]] {
		return die("wake: usage: wake render|raise|settle|deliver (wake.go, wakebus.go, wakerender.go)")
	}
	p := args[1:]
	verb := args[0]
	if verb == "raise-stdin" || verb == "settle-stdin" {
		payload, err := io.ReadAll(os.Stdin)
		if err != nil {
			return die("wake: read payload: %v", err)
		}
		q := []string{p[0], p[1], p[2], string(payload)}
		if verb == "raise-stdin" {
			q = append(q, p[3])
		}
		p, verb = q, strings.TrimSuffix(verb, "-stdin")
	}
	w := wakeBusEnv{p[0], os.Getenv("JG_HOME"), os.Getenv("JG_WAKE_HOME_KEY"), os.Getenv("JG_NATS_BIN"),
		os.Getenv("JG_WAKE_BUS_URL"), os.Getenv("JG_BUS_SUBJECT_PREFIX"), os.Getenv("JG_BUS_MAX_AGE")}
	now := time.Now().Unix()
	at, hk := fmt.Sprint(now), jqString(w.key)
	ok := true
	switch verb {
	case "raise", "settle":
		// The row's number is fixed here, before any publish, so it does not change
		// when an owed event later reaches the stream.
		kind, where, class, subject := "wake", "queue", "", w.prefix+".wake.raise"
		if verb == "settle" {
			kind, where, class, subject = "settled", "settled", "silent", w.prefix+".wake.settled"
		} else {
			class = p[4]
		}
		seq, err := a.nextWakeSequence(w.state)
		if err != nil {
			return die("wake %s: cannot assign row sequence: %v", args[0], err)
		}
		id := fmt.Sprintf("%s/%s/%d-%d", kind, w.key, seq, os.Getpid())
		kv := []string{"v", "1", "id", jqString(id), "home", hk, "where", jqString(where),
			"at", at, "rseq", fmt.Sprint(seq), "kind", jqString(p[1]),
			"key", jqString(p[2]), "payload", jqString(p[3]), "class", jqString(class)}
		if word := os.Getenv("JG_WAKE_WORD"); word != "" { // the status word, kept for routing audits
			kv = append(kv, "word", jqString(word))
		}
		ok = w.deliver(subject, id, object(kv...))
	case "deliver":
		ok = w.deliver(p[1], p[2], p[3])
	case "render":
		return w.render()
	}
	if !ok {
		return 1
	}
	return 0
}
