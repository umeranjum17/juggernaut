package main

// watcher.go - the watcher's view of this home's own wake queue, built from the home's own files.
//
//	jg-bus watcher oldest [--urgent] [--after <seq>]
//	                               the oldest eligible unsettled row, tab separated: epoch, seq,
//	                               kind, key, payload, idle seconds. Nothing when the queue is empty.
//	                               --urgent excludes producer-classed batch/silent rows, without
//	                               changing the default view or consuming anything.
//	jg-bus watcher resurfaced <epoch>-<seq>
//	                               the watcher delivered that row's reason: restart its idle clock.
//	jg-bus watcher latest <kind> <key>
//	                               the newest unsettled row of that kind and key: epoch, seq, kind,
//	                               key, payload. Nothing when there is none.
//	jg-bus watcher rows            every unsettled row, in the order the read model lists them
//	                               (state/.wake-queue); the parity replay compares this.
//	jg-bus watcher replay <events.jsonl> --home <key>
//	                               fold recorded raise and acknowledgement events one by one and
//	                               print, after each, the rows, the oldest row and the newest
//	                               host-memory row as one JSON line.
//
// WHAT THIS REPLACES. bin/jg-watch.sh's own_queue_resurface and host_memory_surface_queued each
// opened the read model every poll (an awk over state/.wake-queue) and kept their own progress file
// (state/.own-wake-progress). They now ask this command, so the watcher no longer polls the queue
// file. The fold is the jq reduce bin/jg-wake-bus.sh's render applies, row for row: an
// acknowledgement removes its raise, a raise with a repeated id replaces the earlier one, and only
// `where == "queue"` events are queue rows.
//
// THE VIEW. A query answers from the render's own inputs: the replica state/.wake-bus.events.jsonl,
// then the events this home still owes (state/.wake-bus.outbox.jsonl), applied in that order, which
// is the model the render builds.
//
// The idle clock is the command's: it restarts when the oldest eligible row changes, or when its
// stamp is in the future, and is removed when the queue is empty - the rule own_queue_resurface kept
// in state/.own-wake-progress (state/bus/wake-watcher.progress).
//
// A row's sequence is its `rseq`, which every producer sets before queueing; an event without
// one is ordered by its own `at`, so it sorts with the rest instead of being dropped.

import (
	"bufio"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// wrow is one unsettled queue row.
type wrow struct {
	ID      string `json:"id"`
	At      int64  `json:"at"`
	Seq     int64  `json:"seq"`
	Kind    string `json:"kind"`
	Key     string `json:"key"`
	Payload string `json:"payload"`
	Class   string `json:"class,omitempty"`
}

// watchFold is the unsettled queue rows by event id.
type watchFold struct {
	Home string          `json:"home"`
	Rows map[string]wrow `json:"rows"`
}

func newFold(home string) *watchFold { return &watchFold{Home: home, Rows: map[string]wrow{}} }

// homeKey is bin/jg-wake-bus.sh's home_key: the home folder's name and the first eight hex digits of
// the sha256 of its path, which every event of that home carries as `home`.
func homeKey(home string) string {
	sum := sha256.Sum256([]byte(home))
	return fmt.Sprintf("%s:%x", filepath.Base(home), sum[:4])
}

// apply folds one event body into the rows, exactly as the render's reduce does.
func (f *watchFold) apply(body []byte) {
	var ev struct {
		ID      string   `json:"id"`
		Home    string   `json:"home"`
		Ack     bool     `json:"ack"`
		Where   string   `json:"where"`
		At      int64    `json:"at"`
		Seq     *float64 `json:"seq"`
		RSeq    *float64 `json:"rseq"`
		Kind    string   `json:"kind"`
		Key     string   `json:"key"`
		Payload string   `json:"payload"`
		Class   string   `json:"class"`
	}
	if json.Unmarshal(body, &ev) != nil || ev.ID == "" || ev.Home != f.Home {
		return
	}
	if ev.Ack {
		delete(f.Rows, ev.ID)
		return
	}
	if strings.HasPrefix(ev.ID, "inbox/") || ev.Where != "queue" {
		// Record-only (`settled`) events and inbox records are not queue rows. They are still
		// folded by id so a later acknowledgement finds nothing to remove, as in the render.
		delete(f.Rows, ev.ID)
		return
	}
	seq := ev.At * 1000
	switch {
	case ev.RSeq != nil:
		seq = int64(*ev.RSeq)
	case ev.Seq != nil:
		seq = int64(*ev.Seq)
	}
	f.Rows[ev.ID] = wrow{ID: ev.ID, At: ev.At, Seq: seq, Kind: ev.Kind, Key: ev.Key, Payload: ev.Payload, Class: ev.Class}
}

// tsvEscape is jq's @tsv for a string: backslash, tab, newline and carriage return.
var tsvEscape = strings.NewReplacer(`\`, `\\`, "\t", `\t`, "\n", `\n`, "\r", `\r`)

func (r wrow) line() string {
	return fmt.Sprintf("%d\t%d\t%s\t%s\t%s", r.At, r.Seq, tsvEscape.Replace(r.Kind), tsvEscape.Replace(r.Key), tsvEscape.Replace(r.Payload))
}

// ordered is the read model's order: `LC_ALL=C sort -t <tab> -k2,2n`, whose last resort is the whole line.
func (f *watchFold) ordered() []wrow {
	rows := make([]wrow, 0, len(f.Rows))
	for _, r := range f.Rows {
		rows = append(rows, r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Seq != rows[j].Seq {
			return rows[i].Seq < rows[j].Seq
		}
		return rows[i].line() < rows[j].line()
	})
	return rows
}

// A declared external pause is a wait the worker named, not an unhandled wake: the same
// test squad_lead_oldest_queue_row applied.
var declaredPause = regexp.MustCompile(`^stale: .*\(paused [0-9]+s, awaiting external - declared (pause,|paused\))`)

// oldest is the first row in file order with the smallest sequence above `after`, skipping
// declared external pauses.
func (f *watchFold) oldest(after int64, haveAfter bool) (wrow, bool) {
	var best wrow
	found := false
	for _, r := range f.ordered() {
		if r.Kind == "stale" && declaredPause.MatchString(tsvEscape.Replace(r.Payload)) {
			continue
		}
		if haveAfter && r.Seq <= after {
			continue
		}
		if !found || r.Seq < best.Seq {
			best, found = r, true
		}
	}
	return best, found
}

// latest is the last row of a kind and key in file order.
func (f *watchFold) latest(kind, key string) (wrow, bool) {
	var best wrow
	found := false
	for _, r := range f.ordered() {
		if r.Kind == kind && r.Key == key {
			best, found = r, true
		}
	}
	return best, found
}

func (a *app) progressPath() string { return filepath.Join(a.runtime, "wake-watcher.progress") }

func (a *app) writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// progress is the idle clock: when the oldest eligible row was first seen as the oldest.
func (a *app) readProgress() (int64, string) {
	parts := strings.SplitN(strings.TrimRight(readFileString(a.progressPath()), "\n"), "\t", 2)
	if len(parts) != 2 {
		return 0, ""
	}
	at, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, ""
	}
	return at, parts[1]
}

func (a *app) writeProgress(at int64, key string) error {
	return a.writeAtomic(a.progressPath(), []byte(fmt.Sprintf("%d\t%s\n", at, key)))
}

func rowKey(r wrow) string { return fmt.Sprintf("%d-%d", r.At, r.Seq) }

// observe keeps the idle clock current: it restarts when the oldest row changes (or the clock
// reads from the future) and is removed when the queue has nothing to resurface. It returns the
// seconds the current oldest row has been the oldest.
func (a *app) observe(f *watchFold, after int64, haveAfter bool, now int64) (wrow, int64, bool, error) {
	r, ok := f.oldest(after, haveAfter)
	if !ok {
		if !haveAfter {
			_ = os.Remove(a.progressPath())
		}
		return wrow{}, 0, false, nil
	}
	since, key := a.readProgress()
	if key != rowKey(r) || now < since {
		return r, 0, true, a.writeProgress(now, rowKey(r))
	}
	return r, now - since, true, nil
}

// watcherCmd is `jg-bus watcher <verb>`.
func (a *app) watcherCmd(args []string) int {
	if len(args) == 0 {
		return die("watcher: oldest | resurfaced | latest | rows | replay | rebuild")
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "replay":
		return a.watcherReplay(rest)
	}
	fold := a.view()
	switch verb {
	case "oldest":
		if len(rest) > 0 && rest[0] == "--urgent" {
			a.urgentRows(fold)
			rest = rest[1:]
		}
		var after int64
		haveAfter := false
		if len(rest) == 2 && rest[0] == "--after" {
			n, err := strconv.ParseInt(rest[1], 10, 64)
			if err != nil {
				return die("watcher oldest: --after wants a sequence number, got %q", rest[1])
			}
			after, haveAfter = n, true
		}
		r, idle, ok, err := a.observe(fold, after, haveAfter, time.Now().Unix())
		if err != nil {
			return die("watcher oldest: cannot record the idle clock: %v", err)
		}
		if ok {
			fmt.Printf("%s\t%d\n", r.line(), idle)
		}
		return 0
	case "resurfaced":
		if len(rest) != 1 {
			return die("watcher resurfaced: want <epoch>-<seq>")
		}
		if err := a.writeProgress(time.Now().Unix(), rest[0]); err != nil {
			return die("watcher resurfaced: cannot record the idle clock: %v", err)
		}
		return 0
	case "latest":
		if len(rest) != 2 {
			return die("watcher latest: want <kind> <key>")
		}
		if r, ok := fold.latest(rest[0], rest[1]); ok {
			fmt.Println(r.line())
		}
		return 0
	case "rows":
		for _, r := range fold.ordered() {
			fmt.Println(r.line())
		}
		return 0
	}
	return die("watcher: unknown verb %q", verb)
}

// urgentRows preserves the producer's effective class, including a repeated urgent
// event held as batch by re-alert throttling. Older running consumers saved no class;
// enrich only their existing rows from the replica/outbox, never replay acknowledgements
// over a newer fold or resurrect a row the service already removed.
func (a *app) urgentRows(fold *watchFold) {
	for _, row := range fold.Rows {
		if row.Class != "" {
			continue
		}
		for _, name := range []string{".wake-bus.events.jsonl", ".wake-bus.outbox.jsonl"} {
			for _, line := range strings.Split(readFileString(filepath.Join(a.state, name)), "\n") {
				var event struct{ ID, Class string }
				if json.Unmarshal([]byte(line), &event) == nil && event.ID == row.ID && event.Class != "" {
					row.Class = event.Class
				}
			}
		}
		fold.Rows[row.ID] = row
	}
	for id, row := range fold.Rows {
		if row.Class == "batch" || row.Class == "silent" {
			delete(fold.Rows, id)
		}
	}
}

// view is the replica of this home's unsettled events, then the events the home still owes: the
// inputs the render builds the read model from.
func (a *app) view() *watchFold {
	fold := newFold(homeKey(filepath.Dir(a.state)))
	for _, name := range []string{".wake-bus.events.jsonl", ".wake-bus.outbox.jsonl"} {
		for _, line := range strings.Split(readFileString(filepath.Join(a.state, name)), "\n") {
			if strings.TrimSpace(line) != "" {
				fold.apply([]byte(line))
			}
		}
	}
	return fold
}

// watcherReplay folds recorded events and prints the answers after each one.
func (a *app) watcherReplay(args []string) int {
	home := ""
	var file string
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--home" && i+1 < len(args):
			home = args[i+1]
			i++
		case file == "":
			file = args[i]
		default:
			return die("watcher replay: <events.jsonl> [--home <key>]")
		}
	}
	if file == "" || home == "" {
		return die("watcher replay: <events.jsonl> --home <key>")
	}
	in, err := os.Open(file)
	if err != nil {
		return die("watcher replay: %v", err)
	}
	defer in.Close()
	fold := newFold(home)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		fold.apply([]byte(line))
		var rows []string
		for _, r := range fold.ordered() {
			rows = append(rows, r.line())
		}
		out := struct {
			Rows    []string `json:"rows"`
			Oldest  string   `json:"oldest"`
			HostMem string   `json:"host_memory"`
		}{Rows: rows}
		if rows == nil {
			out.Rows = []string{}
		}
		if r, ok := fold.oldest(0, false); ok {
			out.Oldest = r.line()
		}
		if r, ok := fold.latest("check", "host-memory"); ok {
			out.HostMem = r.line()
		}
		data, _ := json.Marshal(out)
		fmt.Println(string(data))
	}
	return 0
}
