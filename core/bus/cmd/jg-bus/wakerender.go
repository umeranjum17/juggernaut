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
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

func (w wakeBusEnv) render() int {
	if os.MkdirAll(w.state, 0o777) != nil {
		return 1
	}
	var model bytes.Buffer
	if data, err := os.ReadFile(filepath.Join(w.state, ".wake-bus.events.jsonl")); err == nil {
		model.Write(data)
	}
	// An owed event is part of the read model: it carries its own number as its sequence.
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
	path := fmt.Sprintf("%s/.wake-bus.fold.%d", w.state, os.Getpid())
	if os.WriteFile(path, model.Bytes(), 0o666) != nil {
		os.Remove(path)
		return 1
	}
	defer os.Remove(path)
	if wakeRender(w.state, path) != 0 {
		return 1
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
