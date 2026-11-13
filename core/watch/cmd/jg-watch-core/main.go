// Command jg-watch-core is the supervisor watcher's window inventory, in Go.
//
// The watcher used to derive that inventory in shell on every cycle: recorded_windows
// walked every state/<id>.meta and emitted one target per record, window_kind,
// window_backend and window_harness each re-walked the whole record set for one answer,
// and each walk forked grep, cut and a subshell. That walk is the watcher's hot path, and
// it read the same records ten times over. bin/jg-watch-core.sh builds this command and
// bin/jg-watch.sh reads it once per cycle; the shell those function bodies held is
// deleted, so this file is the one owner of the watcher's window-inventory rules.
//
// CONTRACT - the rules every caller of `inventory` gets, and the reason they are here
// rather than in the shell accessors:
//
//	record   A meta record is a state/<id>.meta file. Its fields are read the way
//	         bin/jg-backend.sh's jg_meta_get reads them: the LAST `key=value` line wins,
//	         a value is everything after the first `=`, and a missing or unreadable record
//	         reads as no value at all. Records are given on the command line in the order
//	         the shell's `"$STATE"/*.meta` glob produced them, so the ordering and the
//	         rows stay the glob's own.
//	target   <id>'s target is its terminal= value when backend= is exactly `orca` and
//	         that value is non-empty, else its window= value when non-empty, else none.
//	         A record with no target is never watched (jg_backend_target_of_meta).
//	recorded A record whose task was stopped by a verified `jg-control.sh exit` is not
//	         watched: state/<id>.exit's first line is an epoch greater than the record's
//	         spawn_gen (a leading `s` and anything from the first `.` are dropped, a
//	         non-numeric value reads as 0). Its fields stay answerable below
//	         (jg_meta_exited_on_purpose).
//	answer   A window's kind, backend, harness and task come from the FIRST record - in
//	         the given order - whose window= or terminal= equals that window, whether or
//	         not it is recorded. kind defaults to `ship`, backend to `tmux` (the P1
//	         compatibility contract: an absent backend= means tmux), harness to empty;
//	         a window no record names has kind `unknown`, backend `tmux` and empty
//	         harness, which is exactly what the deleted shell answered.
//
// Output is one record per line, fields separated by a unit separator so an empty
// harness keeps its column:
//
//	r<US><target>                                  watched, in the glob's order
//	w<US><window><US><kind><US><backend><US><harness>   every named window's answers
//
// The `interval` and `cost` commands are owned by interval.go.
//
// Usage: jg-watch-core inventory <meta>...
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const fieldSep = "\x1f"

// metaRecord is one state/<id>.meta with its fields read the way jg_meta_get reads them.
type metaRecord struct {
	path     string
	id       string
	window   string
	terminal string
	kind     string
	backend  string
	harness  string
	spawnGen int64
	exited   bool
}

// inventory is the whole answer for one cycle: the watched targets in order, and the
// field answers for every window a record names.
type inventory struct {
	order   []string            // watched targets, glob order, deduped
	answers map[string][]string // window -> kind, backend, harness
	named   []string            // windows in first-appearance order
}

func main() {
	if len(os.Args) >= 2 {
		switch os.Args[1] {
		case "interval":
			os.Exit(runInterval(os.Args[2:]))
		case "cost":
			os.Exit(runCost(os.Args[2:]))
		}
	}
	if len(os.Args) < 2 || os.Args[1] != "inventory" {
		fmt.Fprintln(os.Stderr, "usage: jg-watch-core inventory <meta>... | interval <poll> <idle> <meta>... | cost <state> <key> <before> <after> [budget]")
		os.Exit(2)
	}
	records := make([]*metaRecord, 0, len(os.Args)-2)
	for _, path := range os.Args[2:] {
		records = append(records, readMeta(path))
	}
	inv := build(records)
	out := bufio.NewWriter(os.Stdout)
	for _, target := range inv.order {
		fmt.Fprintf(out, "r%s%s\n", fieldSep, target)
	}
	for _, window := range inv.named {
		answer := inv.answers[window]
		fmt.Fprintf(out, "w%s%s%s%s%s%s%s%s\n", fieldSep, window,
			fieldSep, answer[0], fieldSep, answer[1], fieldSep, answer[2])
	}
	if err := out.Flush(); err != nil {
		os.Exit(1)
	}
}

// readMeta reads one record, keeping only the last value of each key. A path that names
// no regular file - an unmatched glob, a removed record, a directory - reads as empty,
// which is what jg_meta_get answers.
func readMeta(path string) *metaRecord {
	id := strings.TrimSuffix(filepath.Base(path), ".meta")
	rec := &metaRecord{path: path, id: id}
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return rec
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return rec
	}
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch key {
		case "window":
			rec.window = value
		case "terminal":
			rec.terminal = value
		case "kind":
			rec.kind = value
		case "backend":
			rec.backend = value
		case "harness":
			rec.harness = value
		case "spawn_gen":
			rec.spawnGen = spawnGenEpoch(value)
		}
	}
	rec.exited = exitedOnPurpose(path, rec.spawnGen)
	return rec
}

// spawnGenEpoch reads a spawn_gen value: one leading `s` and anything from the first `.`
// dropped, then digits only, else 0. It mirrors jg_meta_exited_on_purpose's own parse.
func spawnGenEpoch(value string) int64 {
	value = strings.TrimPrefix(value, "s")
	if i := strings.IndexByte(value, '.'); i >= 0 {
		value = value[:i]
	}
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// exitedOnPurpose reports whether the task has a `jg-control.sh exit` epoch newer than
// its spawn generation. The record keeps its window= for relaunch, but a stopped lane's
// endpoint may be dead, so watching it would report stale on every arm.
func exitedOnPurpose(metaPath string, spawnGen int64) bool {
	exited := strings.TrimSuffix(metaPath, ".meta") + ".exit"
	data, err := os.ReadFile(exited)
	if err != nil {
		return false
	}
	line := string(data)
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	epoch, err := strconv.ParseInt(line, 10, 64)
	if err != nil || epoch < 0 {
		return false
	}
	return epoch > spawnGen
}

// target is the window this record is watched under, or empty when it has none.
func (r *metaRecord) target() string {
	if r.backendOrDefault() == "orca" && r.terminal != "" {
		return r.terminal
	}
	return r.window
}

func (r *metaRecord) backendOrDefault() string {
	if r.backend != "" {
		return r.backend
	}
	return "tmux"
}

func (r *metaRecord) kindOrDefault() string {
	if r.kind != "" {
		return r.kind
	}
	return "ship"
}

// build folds the records into the one answer a cycle needs. The watched list keeps the
// glob's order and drops a repeated target, while the field answers come from the first
// record that names the window, the rule jg_backend_meta_for_window applies.
func build(records []*metaRecord) *inventory {
	inv := &inventory{answers: make(map[string][]string, len(records))}
	for _, rec := range records {
		for _, name := range []string{rec.window, rec.terminal} {
			if name == "" {
				continue
			}
			if _, seen := inv.answers[name]; seen {
				continue
			}
			inv.named = append(inv.named, name)
			inv.answers[name] = []string{rec.kindOrDefault(), rec.backendOrDefault(), rec.harness}
		}
	}
	watched := make(map[string]bool, len(records))
	for _, rec := range records {
		if rec.exited {
			continue
		}
		target := rec.target()
		if target == "" || watched[target] {
			continue
		}
		watched[target] = true
		inv.order = append(inv.order, target)
	}
	return inv
}
