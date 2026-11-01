package main

// The wake engine's fold and read model (docs/bus-live.md), ported from
// bin/jg-wake-bus.sh with identical behaviour. That script still owns the
// transport - every client call, the cursor and the outbox - and the mirror's
// file scan, and hands the events it gathered to these commands:
//
//	wake rows <dump>             the replay's canonical consumer rows, sorted
//	wake render <state> <model>  fold the model into the replica and both read models
//
// One fold serves both: the last raise wins and an acknowledgement marks the raise
// it settles. Key order is kept, so the replica reads as the jq it replaces wrote it.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// wakeEvent is one JSON object, its keys in the order it carried them.
type wakeEvent []struct{ key, val string }

func (e wakeEvent) get(k string) string {
	for _, f := range e {
		if f.key == k {
			return f.val
		}
	}
	return ""
}

// set replaces a key in place, or appends it, as jq's assignment does.
func (e wakeEvent) set(k, v string) wakeEvent {
	out := append(wakeEvent(nil), e...)
	for i := range out {
		if out[i].key == k {
			out[i].val = v
			return out
		}
	}
	return append(out, struct{ key, val string }{k, v})
}

// truthy is jq's truth: absent, null and false are false.
func (e wakeEvent) truthy(k string) bool {
	v := e.get(k)
	return v != "" && v != "null" && v != "false"
}

func (e wakeEvent) is(k, want string) bool {
	var s string
	return json.Unmarshal([]byte(e.get(k)), &s) == nil && s == want
}

// marshal is the event as `jq -c` prints it: its own key order, compact values.
func (e wakeEvent) marshal() string {
	cells := make([]string, len(e))
	for i, f := range e {
		k, _ := json.Marshal(f.key)
		cells[i] = string(k) + ":" + f.val
	}
	return "{" + strings.Join(cells, ",") + "}"
}

// foldFile reads a stream of JSON objects and folds it to one event per id, in
// first-seen order. Like jq, it fails on the first value it cannot read and on an
// event whose id is not a string.
func foldFile(path string) ([]wakeEvent, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	var order []string
	byID := map[string]wakeEvent{}
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			break
		}
		if d, ok := tok.(json.Delim); err != nil || !ok || d != '{' {
			return nil, false
		}
		var e wakeEvent
		for dec.More() {
			var raw json.RawMessage
			var c bytes.Buffer
			key, err := dec.Token()
			if err != nil || dec.Decode(&raw) != nil || json.Compact(&c, raw) != nil {
				return nil, false
			}
			e = e.set(key.(string), c.String())
		}
		var id string
		if _, err := dec.Token(); err != nil || json.Unmarshal([]byte(e.get("id")), &id) != nil {
			return nil, false
		}
		_, seen := byID[id]
		if e.truthy("ack") {
			if seen {
				byID[id] = byID[id].set("ack", "true")
			}
			continue
		}
		if !seen {
			order = append(order, id)
		}
		byID[id] = e
	}
	out := make([]wakeEvent, len(order))
	for i, id := range order {
		out[i] = byID[id]
	}
	return out, true
}

// tsv is jq's @tsv over these keys; a key starting with = is that literal text.
func tsv(e wakeEvent, keys ...string) string {
	cells := make([]string, len(keys))
	for i, k := range keys {
		var s string
		v := e.get(k)
		switch {
		case strings.HasPrefix(k, "="):
			cells[i] = k[1:]
		case json.Unmarshal([]byte(v), &s) == nil:
			cells[i] = strings.NewReplacer(`\`, `\\`, "\t", `\t`, "\n", `\n`, "\r", `\r`).Replace(s)
		case v != "null":
			cells[i] = v
		}
	}
	return strings.Join(cells, "\t")
}

// sortNumeric is `LC_ALL=C sort -t '\t' -kN,Nn`: by the field's leading number,
// then by the whole line, which is sort's own last resort.
func sortNumeric(lines []string, col int) {
	num := func(l string) float64 {
		cells := append(strings.Split(l, "\t"), "")
		c := strings.TrimLeft(cells[min(col, len(cells)-1)], " ")
		end := 0
		for end < len(c) && (c[end] >= '0' && c[end] <= '9' || c[end] == '.' || end == 0 && c[end] == '-') {
			end++
		}
		n, _ := strconv.ParseFloat(c[:end], 64)
		return n
	}
	sort.SliceStable(lines, func(i, j int) bool {
		if a, b := num(lines[i]), num(lines[j]); a != b {
			return a < b
		}
		return lines[i] < lines[j]
	})
}

func joinLines(lines []string) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l + "\n")
	}
	return b.String()
}

// replaceFile writes a read model under the temporary name the render owns, then
// renames it into place.
func replaceFile(tmp, path string, lines []string, mode os.FileMode) error {
	err := os.WriteFile(tmp, []byte(joinLines(lines)), 0o666)
	if err == nil && mode != 0 {
		err = os.Chmod(tmp, mode)
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

func (a *app) wake(args []string) int {
	switch {
	case len(args) == 2 && args[0] == "rows":
		return wakeRows(args[1])
	case len(args) == 3 && args[0] == "render":
		return wakeRender(args[1], args[2])
	}
	return die("wake: usage: wake rows <dump> | wake render <state> <model>")
}

// wakeRows is the replay's side of parity: the bus's canonical consumer rows, in
// the vocabulary the file path's scan prints. An unreadable dump has no rows.
func wakeRows(dump string) int {
	events, ok := foldFile(dump)
	if !ok {
		return 0
	}
	var rows []string
	for _, e := range events {
		switch {
		case e.is("where", "settled"):
			rows = append(rows, tsv(e, "=wake", "id", "=settled", "kind", "key", "payload", "=silent"))
		case e.truthy("task") && e.truthy("ack"):
			rows = append(rows, tsv(e, "=inbox", "id", "=handled", "delivery", "body_sha"))
		case e.truthy("task"):
			rows = append(rows, tsv(e, "=inbox", "id", "=pending", "delivery", "body_sha"))
		case !e.truthy("ack"):
			rows = append(rows, tsv(e, "=wake", "id", "=queue", "kind", "key", "payload", "class"))
		}
	}
	sort.Strings(rows)
	os.Stdout.WriteString(joinLines(rows))
	return 0
}

// wakeRender folds the gathered model into the replica, which keeps only the
// unsettled events, then writes the queue and record read models from it. A
// model the fold cannot read changes nothing.
func wakeRender(state, model string) int {
	events, ok := foldFile(model)
	if !ok {
		return 1
	}
	var replica, queue, settled []string
	for _, e := range events {
		if string(e.get("ack")) == "true" {
			continue
		}
		replica = append(replica, e.marshal())
		if e.is("where", "queue") {
			seq := e.get("rseq") // .seq // .rseq
			if e.truthy("seq") {
				seq = e.get("seq")
			}
			queue = append(queue, tsv(e.set("seq", seq), "at", "seq", "kind", "key", "payload"))
		} else if e.is("where", "settled") {
			settled = append(settled, tsv(e, "at", "=silent", "kind", "key", "payload"))
		}
	}
	sortNumeric(queue, 1)
	sortNumeric(settled, 0)
	if replaceFile(model+".keep", filepath.Join(state, ".wake-bus.events.jsonl"), replica, 0) != nil ||
		replaceFile(model+".queue", filepath.Join(state, ".wake-queue"), queue, 0o600) != nil ||
		replaceFile(model+".settled", filepath.Join(state, ".wake-settled"), settled, 0o600) != nil {
		return 1
	}
	return 0
}
