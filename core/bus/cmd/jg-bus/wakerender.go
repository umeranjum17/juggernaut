package main

// The wake engine's render (docs/bus-live.md), ported from bin/jg-wake-bus.sh's
// live_render with identical behaviour. `wake render <state>` checks the bus; when
// it answers and the home is on, it makes the streams and publishes what the
// outbox owes. It then gathers the model - the replica, every event the outbox
// still owes, and each message the two streams stored for this home since the
// cursor - and folds it into the replica and both read models (wake.go).

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
		seq := "0"
		if e.truthy("rseq") {
			seq = e.get("rseq")
		}
		model.WriteString(e.drop("subject").set("seq", seq).marshal() + "\n")
	})
	if live {
		w.apply("JG_WAKE", &model)
		w.apply("JG_INBOX", &model)
	}
	path := fmt.Sprintf("%s/.wake-bus.fold.%d", w.state, os.Getpid())
	if os.WriteFile(path, model.Bytes(), 0o666) != nil {
		os.Remove(path)
		return 1
	}
	defer os.Remove(path)
	return wakeRender(w.state, path)
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

// apply appends every message stored since the cursor that belongs to this home,
// each carrying `.rseq // <stream sequence>` as its seq, then moves the cursor.
func (w wakeBusEnv) apply(stream string, model *bytes.Buffer) {
	from := w.cursor(stream) + 1
	var info struct {
		State struct {
			LastSeq json.RawMessage `json:"last_seq"`
		} `json:"state"`
	}
	out, _ := w.busOut("stream", "info", stream, "--json")
	json.Unmarshal(out, &info)
	last, err := strconv.ParseInt(rawText(string(info.State.LastSeq)), 10, 64)
	if err != nil || last < 0 {
		last = 0
	}
	if last < from {
		return
	}
	for seq := from; seq <= last; seq++ {
		raw, err := w.busOut("stream", "get", stream, fmt.Sprint(seq), "--json")
		var msg struct {
			Data json.RawMessage `json:"data"`
		}
		if err != nil || json.Unmarshal(raw, &msg) != nil {
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
			}
			model.WriteString(e.set("seq", own).marshal() + "\n")
		})
	}
	w.setCursor(stream, last)
}

func (w wakeBusEnv) cursorFile() string { return filepath.Join(w.state, ".wake-bus.cursor") }

// cursor is the last sequence already applied for one stream, or 0.
func (w wakeBusEnv) cursor(stream string) int64 {
	data, _ := os.ReadFile(w.cursorFile())
	for _, line := range strings.Split(string(data), "\n") {
		if f := strings.Fields(line); len(f) > 0 && f[0] == stream {
			n, _ := strconv.ParseInt(append(f, "")[1], 10, 64)
			return n
		}
	}
	return 0
}

// setCursor rewrites the cursor with this stream's line last, keeping the others.
func (w wakeBusEnv) setCursor(stream string, last int64) {
	data, _ := os.ReadFile(w.cursorFile())
	var keep []string
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if f := strings.Fields(line); len(data) > 0 && (len(f) == 0 || f[0] != stream) {
			keep = append(keep, line)
		}
	}
	tmp := fmt.Sprintf("%s.tmp.%d", w.cursorFile(), os.Getpid())
	if os.WriteFile(tmp, []byte(joinLines(append(keep, fmt.Sprintf("%s\t%d", stream, last)))), 0o666) != nil ||
		os.Rename(tmp, w.cursorFile()) != nil {
		os.Remove(tmp)
	}
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
		if !ok || w.pubSeq(rawText(e.get("subject")), rawText(e.get("id")), e.drop("subject").marshal()) <= 0 {
			keep.WriteString(line + "\n")
		}
	}
	tmp := fmt.Sprintf("%s.tmp.%d", w.outbox(), os.Getpid())
	if os.WriteFile(tmp, []byte(keep.String()), 0o666) != nil || os.Rename(tmp, w.outbox()) != nil {
		os.Remove(tmp)
	}
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
