package main

// watcher.go - the watcher's view of this home's own wake queue, fed by the bus.
//
//	jg-bus wake-watcher            the service: a durable pull consumer (wake-watcher) on this
//	                               home's `jg.<account>.wake.>` subjects. Each raise and each
//	                               acknowledgement is folded into the set of unsettled queue rows
//	                               the moment it arrives, so the question "what is the oldest wake
//	                               nobody handled, and for how long?" is answered from events and
//	                               never by reading state/.wake-queue.
//	jg-bus watcher oldest [--after <seq>]
//	                               the oldest eligible unsettled row, tab separated: epoch, seq,
//	                               kind, key, payload, idle seconds. Nothing when the queue is empty.
//	jg-bus watcher resurfaced <epoch>-<seq>
//	                               the watcher delivered that row's reason: restart its idle clock.
//	jg-bus watcher latest <kind> <key>
//	                               the newest unsettled row of that kind and key: epoch, seq, kind,
//	                               key, payload. Nothing when there is none.
//	jg-bus watcher rows            every unsettled row, in the order the read model lists them
//	                               (state/.wake-queue); the parity replay compares this.
//	jg-bus watcher replay <events.jsonl> [--home <key>]
//	                               fold recorded raise and acknowledgement events one by one and
//	                               print, after each, the rows, the oldest row and the newest
//	                               host-memory row as one JSON line; no server is read.
//
// WHAT THIS REPLACES. bin/jg-watch.sh's own_queue_resurface and host_memory_surface_queued each
// opened the read model every poll (an awk over state/.wake-queue) and kept their own progress file
// (state/.own-wake-progress). They now ask this command, so the watcher no longer polls the queue
// file. The fold is the jq reduce bin/jg-wake-bus.sh's render applies, row for row: an
// acknowledgement removes its raise, a raise with a repeated id replaces the earlier one, and only
// `where == "queue"` events are queue rows. The service's fold lives in
// state/bus/wake-watcher.fold.json and its idle clock in state/bus/wake-watcher.progress.
//
// THE VIEW. A query answers from the service's fold plus the events this home still owes the bus
// (state/.wake-bus.outbox.jsonl, the spool bin/jg-wake-bus.sh keeps for a publish the server
// refused), applied in that order, which is the model the render builds. A home whose bus is off, or
// whose server is down, therefore keeps resurfacing what it queued. When the service is not running
// its fold is not trusted (it would hold rows nobody settles for it), so the view is built from the
// render's own inputs instead - the replica state/.wake-bus.events.jsonl, then the owed events - and
// the command says so on stderr; that is a degraded path, named in the triage log, not a second one.
//
// The idle clock is the command's: it restarts when the oldest eligible row changes, or when its
// stamp is in the future, and is removed when the queue is empty - the rule own_queue_resurface kept
// in state/.own-wake-progress.
//
// A row's sequence is its `rseq`, which every producer sets before publishing; an event without
// one is ordered by its own `at`, so it sorts with the rest instead of being dropped. The consumer
// acknowledges each message as it fetches it (the `nats` client's `consumer next`), so an event
// received and lost before the fold reached disk is absent; `jg-bus watcher rebuild` deletes the
// fold and the consumer, and the service then replays the stream from the start.

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
	f.Rows[ev.ID] = wrow{ID: ev.ID, At: ev.At, Seq: seq, Kind: ev.Kind, Key: ev.Key, Payload: ev.Payload}
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

func (a *app) foldPath() string     { return filepath.Join(a.runtime, "wake-watcher.fold.json") }
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

func (a *app) saveFold(f *watchFold) error {
	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	return a.writeAtomic(a.foldPath(), data)
}

func (a *app) loadFold() (*watchFold, bool) {
	data, err := os.ReadFile(a.foldPath())
	if err != nil {
		return nil, false
	}
	f := newFold(homeKey(filepath.Dir(a.state)))
	if json.Unmarshal(data, f) != nil || f.Rows == nil {
		return nil, false
	}
	return f, true
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

// wakeWatcherPart is the service's consumer: this home's whole wake subject, so it sees raises,
// acknowledgements and record-only events in order.
func (a *app) wakeWatcherPart() (*part, error) {
	out, err := a.wakeScript("endpoint")
	if err != nil {
		return nil, err
	}
	f := strings.Split(strings.TrimRight(out, "\n"), "\t")
	if len(f) != 5 || !strings.HasSuffix(f[2], ".wake.raise") {
		return nil, fmt.Errorf("jg-wake-bus.sh endpoint printed %q, want url, stream, raise subject, user and password file", out)
	}
	var env []string
	if f[3] != "" {
		env = []string{"NATS_USER=" + f[3], "NATS_PASSWORD=" + strings.TrimSpace(readFileString(f[4]))}
	}
	fold, ok := a.loadFold()
	if !ok {
		fold = newFold(homeKey(filepath.Dir(a.state)))
	}
	p := &part{name: "wake-watcher", url: f[0], stream: f[1], env: env,
		filter: strings.TrimSuffix(f[2], ".raise") + ".>"}
	p.handle = func(body []byte) error {
		fold.apply(body)
		if err := a.saveFold(fold); err != nil {
			return err
		}
		return nil
	}
	p.fresh = !ok
	return p, nil
}

func (a *app) wakeWatcher() int {
	p, err := a.wakeWatcherPart()
	if err != nil {
		return die("wake-watcher: %v", err)
	}
	if _, err := a.wakeScript("render"); err != nil {
		// The render also creates the streams the consumer is made on.
		return die("wake-watcher: %v", err)
	}
	return a.serveConsumer(p)
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
	case "rebuild":
		return a.watcherRebuild()
	}
	fold := a.view()
	switch verb {
	case "oldest":
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

// view is the service's fold with the owed events applied. With the service not running, its fold is
// not trusted, so the view is the inputs the render builds the read model from - the replica of this
// home's unsettled events, then the owed events - and the command says so on stderr.
func (a *app) view() *watchFold {
	fold := newFold(homeKey(filepath.Dir(a.state)))
	var sources []string
	if _, running := a.runningPid("wake-watcher"); running {
		if loaded, ok := a.loadFold(); ok {
			fold = loaded
		} else {
			fmt.Fprintf(os.Stderr, "watcher: the wake-watcher service has not written its fold yet (%s)\n", a.foldPath())
			sources = append(sources, ".wake-bus.events.jsonl")
		}
	} else {
		fmt.Fprintf(os.Stderr, "watcher: the wake-watcher service is not running (see %s); observing the replica and the events still owed to the bus\n",
			filepath.Join(a.runtime, "wake-watcher.log"))
		sources = append(sources, ".wake-bus.events.jsonl")
	}
	sources = append(sources, ".wake-bus.outbox.jsonl")
	for _, name := range sources {
		for _, line := range strings.Split(readFileString(filepath.Join(a.state, name)), "\n") {
			if strings.TrimSpace(line) != "" {
				fold.apply([]byte(line))
			}
		}
	}
	return fold
}

// watcherRebuild forgets the fold, the clock and the consumer, so the service replays the stream.
func (a *app) watcherRebuild() int {
	p, err := a.wakeWatcherPart()
	if err != nil {
		return die("watcher rebuild: %v", err)
	}
	_ = os.Remove(a.foldPath())
	_ = os.Remove(a.progressPath())
	if _, errText, err := p.nats("consumer", "rm", "-f", p.stream, p.name); err != nil && !strings.Contains(errText, "not found") {
		return die("watcher rebuild: %s", strings.TrimSpace(errText))
	}
	say("watcher: fold and consumer removed; restart the wake-watcher service to replay the stream")
	return 0
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
