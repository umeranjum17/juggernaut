package main

// The wake engine's render (docs/bus-live.md), ported from bin/jg-wake-bus.sh's
// live_render with identical behaviour. `wake render <state>` checks the bus; when
// it answers and the home is on, it makes the streams and publishes what the
// outbox owes. It then gathers the model - the replica, every event the outbox
// still owes, and each message the two streams stored for this home since the
// cursor - and folds it into the replica and both read models (wake.go). The cursor
// moves only after the replica holding those messages is durable.

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// busOut is one client call's standard output, its errors discarded.
func (w wakeBusEnv) busOut(args ...string) ([]byte, error) {
	if w.client == "" {
		return nil, os.ErrNotExist
	}
	return exec.Command(w.client, append([]string{"-s", w.url, "--timeout", "10s"}, args...)...).Output()
}

func (w wakeBusEnv) render() int {
	if os.MkdirAll(w.state, 0o777) != nil {
		return 1
	}
	live := w.enabled()
	if live {
		_, err := w.busOut("stream", "ls")
		live = err == nil
	}
	if live {
		w.ensureStreams()
		w.flush()
	}
	var model bytes.Buffer
	if data, err := os.ReadFile(filepath.Join(w.state, ".wake-bus.events.jsonl")); err == nil {
		model.Write(data)
	}
	// An owed event is part of the read model, so a home whose bus is down still
	// queues and drains; it carries its own number as its sequence.
	owed, _ := os.ReadFile(w.outbox())
	eachObject(owed, func(e wakeEvent) {
		seq := "0" // .rseq // .seq // 0
		if e.truthy("rseq") {
			seq = e.get("rseq")
		} else if e.truthy("seq") {
			seq = e.get("seq")
		}
		model.WriteString(e.drop("subject").set("seq", seq).marshal() + "\n")
	})
	var pending []cursorMark
	if live {
		for _, stream := range []string{"JG_WAKE", "JG_INBOX"} {
			if m, ok := w.apply(stream, &model); ok {
				pending = append(pending, m)
			}
		}
	}
	path := fmt.Sprintf("%s/.wake-bus.fold.%d", w.state, os.Getpid())
	if os.WriteFile(path, model.Bytes(), 0o666) != nil {
		os.Remove(path)
		return 1
	}
	defer os.Remove(path)
	if wakeRender(w.state, path) != 0 {
		return 1
	}
	// The replica now holds everything read, so the cursor may pass it. A render killed
	// before this leaves the old cursor, and the next one reads the same messages again.
	for _, m := range pending {
		if !w.setCursor(m) {
			return 1
		}
	}
	return 0
}

// eachObject hands over each object of a JSON stream until the first value that
// is not one, as a jq filter over the stream stops there. A null is skipped.
func eachObject(data []byte, fn func(wakeEvent)) {
	dec := json.NewDecoder(bytes.NewReader(data))
	for {
		tok, err := dec.Token()
		if err != nil || tok != json.Delim('{') {
			if tok == nil && err == nil {
				continue
			}
			return
		}
		e, ok := readObject(dec)
		if !ok {
			return
		}
		fn(e)
	}
}

// cursorMark is where one stream was read to, and the creation time of the stream it was
// read on.
type cursorMark struct {
	stream, made string
	last         int64
}

// renderRetryLimit is how many renders may be refused the same message before the read steps
// over it. One refusal can be a transport hiccup, so the read stops before it and the next
// render asks again; a message the server refuses this many renders running is a message no
// render will ever read, and holding the cursor behind it stops the whole read model, so it is
// kept on the dead list where an operator can read it and the cursor moves past it.
const renderRetryLimit = 3

// refusal is the message the server refused this stream, and how many renders it has refused.
type refusal struct {
	Seq   int64  `json:"seq"`
	Tries int    `json:"tries"`
	Error string `json:"error"`
}

func (w wakeBusEnv) refusalPath() string {
	return filepath.Join(w.state, "bus", "wake-render.stuck.json")
}

// refusals is what each stream's read has been refused so far, empty when nothing has been.
func (w wakeBusEnv) refusals() map[string]refusal {
	var r map[string]refusal
	if json.Unmarshal([]byte(readFileString(w.refusalPath())), &r) != nil || r == nil {
		return map[string]refusal{}
	}
	return r
}

// saveRefusals records the refusals under the temporary name the render owns, then renames.
func (w wakeBusEnv) saveRefusals(r map[string]refusal) error {
	path := w.refusalPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// deadList keeps a message the render stepped over, one JSON line, the shape the bus consumers'
// own dead list uses, so the wake it carried is found by an operator instead of being lost quietly.
func (w wakeBusEnv) deadList(stream string, seq int64, tries int, why string) {
	line, _ := json.Marshal(map[string]any{"at": time.Now().Unix(), "stream": stream, "sequence": seq,
		"tries": tries, "error": why})
	path := filepath.Join(w.state, "bus", "wake-render.dead.jsonl")
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "wake render: cannot write %s: %v\n", path, err)
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// apply appends every message stored since the cursor that belongs to this home, each
// carrying `.rseq // .seq // <stream sequence>` as its seq, and returns the position it
// read to without moving the cursor (render commits it). A stream the server made again
// numbers its messages from 1, so a cursor taken on another stream, or past this one's
// end, starts again at the first message. A message the stream no longer holds is passed
// over; a message the server refuses stops the read before it, until it has refused
// renderRetryLimit renders and the message is kept on the dead list instead, so no cursor
// stays pinned behind one message it can never read.
func (w wakeBusEnv) apply(stream string, model *bytes.Buffer) (cursorMark, bool) {
	var info struct {
		Created string `json:"created"`
		State   struct {
			FirstSeq json.RawMessage `json:"first_seq"`
			LastSeq  json.RawMessage `json:"last_seq"`
		} `json:"state"`
	}
	out, err := w.busOut("stream", "info", stream, "--json")
	if err != nil {
		return cursorMark{}, false
	}
	json.Unmarshal(out, &info)
	count := func(raw json.RawMessage) int64 {
		n, err := strconv.ParseInt(rawText(string(raw)), 10, 64)
		if err != nil || n < 0 {
			return 0
		}
		return n
	}
	first, last, made := count(info.State.FirstSeq), count(info.State.LastSeq), info.Created
	cur, was := w.cursor(stream)
	from, fresh := cur+1, false
	if (was != "" && made != "" && was != made) || from > last+1 {
		from, fresh = 1, true
	}
	if from < first {
		from = first // the stream's age limit dropped the ones before
	}
	if from < 1 {
		from = 1
	}
	// Nothing new: no read and no write, unless the cursor must move onto this stream.
	if last < from && !fresh && (was != "" || made == "") {
		return cursorMark{}, false
	}
	refused := w.refusals()
	for seq := from; seq <= last; seq++ {
		raw, err := w.bus("stream", "get", stream, fmt.Sprint(seq), "--json")
		if err != nil {
			if strings.Contains(string(raw), "no message found") {
				continue
			}
			why := strings.TrimSpace(firstLine(string(raw)))
			r := refused[stream]
			if r.Seq != seq {
				r = refusal{Seq: seq}
			}
			r.Tries, r.Error = r.Tries+1, why
			refused[stream] = r
			if err := w.saveRefusals(refused); err != nil {
				fmt.Fprintf(os.Stderr, "wake render: cannot record the refusal of %s %d: %v\n", stream, seq, err)
			}
			if r.Tries < renderRetryLimit {
				last = seq - 1
				break
			}
			w.deadList(stream, seq, r.Tries, why)
			delete(refused, stream)
			if err := w.saveRefusals(refused); err != nil {
				fmt.Fprintf(os.Stderr, "wake render: cannot clear the refusal of %s %d: %v\n", stream, seq, err)
			}
			fmt.Fprintf(os.Stderr, "wake render: %s %d refused %d times (%s); kept on %s and stepped over\n",
				stream, seq, r.Tries, why, filepath.Join(w.state, "bus", "wake-render.dead.jsonl"))
			continue
		}
		if r, seen := refused[stream]; seen && r.Seq == seq {
			delete(refused, stream)
			_ = w.saveRefusals(refused)
		}
		var msg struct {
			Data json.RawMessage `json:"data"`
		}
		if json.Unmarshal(raw, &msg) != nil {
			continue
		}
		var data string
		json.Unmarshal(msg.Data, &data)
		body, _ := base64.StdEncoding.DecodeString(data)
		eachObject(body, func(e wakeEvent) {
			if !e.is("home", w.key) {
				return
			}
			own := fmt.Sprint(seq)
			if e.truthy("rseq") {
				own = e.get("rseq")
			} else if e.truthy("seq") {
				own = e.get("seq")
			}
			model.WriteString(e.set("seq", own).marshal() + "\n")
		})
	}
	return cursorMark{stream, made, last}, true
}

func (w wakeBusEnv) cursorFile() string { return filepath.Join(w.state, ".wake-bus.cursor") }

// cursor is the last sequence already applied for one stream and the creation time of the
// stream it was taken on, or 0 and empty.
func (w wakeBusEnv) cursor(stream string) (int64, string) {
	data, _ := os.ReadFile(w.cursorFile())
	var n int64
	var made string
	found := false
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 || f[0] != stream {
			continue
		}
		made = ""
		if len(f) > 2 {
			made = f[2]
		}
		if len(f) > 1 && strings.Trim(f[1], "0123456789") == "" && !found {
			n, _ = strconv.ParseInt(f[1], 10, 64)
			found = true
		}
	}
	return n, made
}

// setCursor rewrites the cursor with this stream's line last, keeping the others.
func (w wakeBusEnv) setCursor(m cursorMark) bool {
	data, _ := os.ReadFile(w.cursorFile())
	var keep []string
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if f := strings.Fields(line); len(data) > 0 && (len(f) == 0 || f[0] != m.stream) {
			keep = append(keep, line)
		}
	}
	line := fmt.Sprintf("%s\t%d", m.stream, m.last)
	if m.made != "" {
		line += "\t" + m.made
	}
	tmp := fmt.Sprintf("%s.tmp.%d", w.cursorFile(), os.Getpid())
	if os.WriteFile(tmp, []byte(joinLines(append(keep, line))), 0o666) != nil || os.Rename(tmp, w.cursorFile()) != nil {
		os.Remove(tmp)
		return false
	}
	return true
}

// flush publishes what the outbox owes and keeps only what is refused again.
func (w wakeBusEnv) flush() {
	data, err := os.ReadFile(w.outbox())
	if err != nil || len(data) == 0 {
		return
	}
	var keep strings.Builder
	lines := strings.Split(string(data), "\n")
	for _, line := range lines[:len(lines)-1] { // read(1) never returns a last line with no newline
		if line == "" {
			continue
		}
		e, ok := parseObject(line)
		if !ok || w.pubSeq(rawText(e.get("subject")), messageID(e), e.drop("subject").marshal()) <= 0 {
			keep.WriteString(line + "\n")
		}
	}
	tmp := fmt.Sprintf("%s.tmp.%d", w.outbox(), os.Getpid())
	if os.WriteFile(tmp, []byte(keep.String()), 0o666) != nil || os.Rename(tmp, w.outbox()) != nil {
		os.Remove(tmp)
	}
}

// messageID is the id an owed event goes out under: an acknowledgement carries its own
// message id (`mid`), because under its raise's id the server would drop it as a duplicate.
func messageID(e wakeEvent) string {
	if e.truthy("mid") {
		return rawText(e.get("mid"))
	}
	if e.get("ack") == "true" {
		return rawText(e.get("id")) + "/ack"
	}
	return rawText(e.get("id"))
}

// rawText is one value as `jq -r` prints it.
func rawText(v string) string {
	var s string
	switch {
	case v == "" || v == "null":
		return "null"
	case json.Unmarshal([]byte(v), &s) == nil:
		return s
	}
	return v
}
