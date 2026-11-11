package main

import (
	"bytes"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// env is the home a decision is made for: the facts the shell library resolved once and passes down.
type env struct {
	state       string // the home's state directory
	home        string // JG_HOME
	defaultRoot string // the checkout holding defaults/wake-routing
	queue       string // the read model, state/.wake-queue
	actor       string // who is asking: main or branch
	grant       string // the branch grant's row snapshot, when one is live
	routing     string // JG_WAKE_ROUTING, an override rule file
	configDir   string // JG_CONFIG_OVERRIDE, else <home>/config
	libDir      string // JG_WAKE_LIB_DIR, the bin/ holding jg-watch.sh
	procRoot    string // JG_PROC_ROOT_OVERRIDE, else /proc
	now         func() int64
}

func (e env) epoch() int64 {
	if e.now != nil {
		return e.now()
	}
	return time.Now().Unix()
}

// isFile is `[ -f path ]`: a regular file, a symlink to one included.
func isFile(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Mode().IsRegular()
}

func isLink(path string) bool {
	st, err := os.Lstat(path)
	return err == nil && st.Mode()&os.ModeSymlink != 0
}

// readLines returns the lines `while read -r` runs its body for: every newline-terminated line. A
// final line with no newline is dropped, as read reports it with a failing status.
func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return completeLines(string(data))
}

func completeLines(s string) []string {
	var out []string
	for {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			return out
		}
		out = append(out, s[:i])
		s = s[i+1:]
	}
}

const ifsWhite = " \t\n"

// splitFields is `read -r a b c ... last` under the default IFS: leading blanks dropped, one token
// per variable but the last, which holds the rest of the line without its trailing blanks.
func splitFields(line string, n int) []string {
	out := make([]string, n)
	rest := strings.TrimLeft(line, ifsWhite)
	for i := 0; i < n; i++ {
		if i == n-1 {
			out[i] = strings.TrimRight(rest, ifsWhite)
			break
		}
		j := strings.IndexAny(rest, ifsWhite)
		if j < 0 {
			out[i] = rest
			break
		}
		out[i] = rest[:j]
		rest = strings.TrimLeft(rest[j:], ifsWhite)
	}
	return out
}

// routingFiles is jg_wake_routing_files: the rule files in force, in priority order. A JG_WAKE_ROUTING
// override replaces both; otherwise the home's own config/wake-routing comes first and the checkout's
// defaults/wake-routing falls through behind it, so what the home does not name is the shared file's.
func (e env) routingFiles() []string {
	if e.routing != "" {
		if isFile(e.routing) {
			return []string{e.routing}
		}
		return nil
	}
	def := filepath.Join(e.defaultRoot, "defaults", "wake-routing")
	var out []string
	if home := filepath.Join(e.homeOrRoot(), "config", "wake-routing"); isFile(home) && !sameFile(home, def) {
		out = append(out, home)
	}
	if isFile(def) {
		out = append(out, def)
	}
	return out
}

// sameFile is `[ a -ef b ]`: both paths name one inode.
func sameFile(a, b string) bool {
	x, err := os.Stat(a)
	if err != nil {
		return false
	}
	y, err := os.Stat(b)
	if err != nil {
		return false
	}
	return os.SameFile(x, y)
}

// ruleLines is _jg_wake_rules: every rule line of every file, in priority order, so the first
// match wins across the files and a home rule layers over the shared one. The shell cats each file
// and adds a newline, so a rule file whose last line has no newline still contributes that line.
func (e env) ruleLines() []string {
	var out []string
	for _, f := range e.routingFiles() {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		out = append(out, completeLines(string(data)+"\n")...)
	}
	return out
}

func (e env) homeOrRoot() string {
	if e.home != "" {
		return e.home
	}
	return e.defaultRoot
}

// ruleSet is _jg_wake_rule_set: the first `set <name> <digits>` in priority order, else def, so a
// home's value overrides the shared one.
func (e env) ruleSet(name string, def int64) int64 {
	for _, line := range e.ruleLines() {
		f := splitFields(line, 4)
		if f[0] != "set" || f[1] != name || f[2] == "" || strings.Trim(f[2], "0123456789") != "" {
			continue
		}
		if n, err := strconv.ParseInt(f[2], 10, 64); err == nil {
			return n
		}
	}
	return def
}

// route is jg_wake_route_class: now, batch or silent. The first matching rule wins and no match
// answers `now`, so a missing rule file can never hide an event. A status-file event is matched
// against the newest line of its status file, so a rule can name the state word.
func (e env) route(kind, key, payload string, depth int) string {
	lines := e.ruleLines()
	if len(lines) == 0 {
		return "now"
	}
	if strings.HasSuffix(key, ".status") {
		if p := filepath.Join(e.state, key); isFile(p) && !isLink(p) {
			if line := lastLine(p); line != "" {
				payload = line
			}
		}
	}
	for _, rule := range lines {
		f := splitFields(rule, 4)
		class, rkind, rkey, rpay := f[0], f[1], f[2], f[3]
		if class == "" || strings.HasPrefix(class, "#") || class == "set" {
			continue
		}
		if rkind != "*" && rkind != kind {
			continue
		}
		if !globMatch(rkey, key) || !globMatch(rpay, payload) {
			continue
		}
		if at := strings.IndexByte(class, '@'); at >= 0 {
			cond := class[at+1:]
			if !e.cond(cond, key, payload, depth) {
				continue
			}
			class = class[:strings.LastIndexByte(class, '@')]
		}
		return class
	}
	return "now"
}

// lastLine is `$(tail -n 1 -- path)`: the final line, empty for an empty file or a blank last line.
func lastLine(path string) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	s := strings.TrimSuffix(string(data), "\n")
	return s[strings.LastIndexByte(s, '\n')+1:]
}

// maxQueueDepth bounds queue-quiet, which routes every queued row and so can reach itself: a rule
// that reads the queue for a row the same rule routes would otherwise recurse without end.
const maxQueueDepth = 8

// cond is _jg_wake_cond: the fact a `class@condition` rule names.
func (e env) cond(cond, key, payload string, depth int) bool {
	switch cond {
	case "parked", "restart-pass":
		base := strings.TrimSuffix(key, ".status")
		prev := ""
		for _, word := range strings.Fields(base + " " + payload) {
			id := ""
			if prev == "squad_lead" || prev == "waiting-state" {
				id = word
				if i := strings.IndexAny(id, ",;:)("); i >= 0 {
					id = id[:i]
				}
			}
			if id == "" && word == base {
				id = word
			}
			prev = word
			if id == "" || strings.Trim(id, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") != "" {
				continue
			}
			if cond == "parked" {
				if e.parkedMeta(filepath.Join(e.state, id+".meta"), id) || e.parkedHome(id) {
					return true
				}
			} else if e.restartPass(id) {
				return true
			}
		}
		return false
	case "queue-quiet":
		if st, err := os.Stat(e.queue); err != nil || st.Size() == 0 {
			return true
		}
		if depth >= maxQueueDepth {
			return false
		}
		for _, row := range readLines(e.queue) {
			f := strings.FieldsFunc(row, func(r rune) bool { return r == '\t' })
			if len(f) < 4 || f[3] == "" {
				continue
			}
			pay := ""
			if len(f) > 4 {
				pay = f[4]
			}
			if e.route(f[2], f[3], pay, depth+1) == "now" {
				return false
			}
		}
		return true
	case "fleet-unchanged":
		return e.fleetUnchanged()
	case "merge-owned":
		return e.mergeOwned(key, payload)
	case "ship-pr":
		return e.shipTask(key)
	case "gap-long":
		return e.gapLong(payload)
	case "lead-restarted":
		return e.leadRestarted(key, payload)
	case "watcher-alive":
		// A live watcher holds this home's watcher lock, so an old beacon is its predecessor's and
		// nothing is left unwatched.
		pid := wholeFile(filepath.Join(e.state, ".watch.lock", "pid"))
		return e.pidAlive(pid) && e.watcherLockMatches(pid)
	}
	return false
}

// metaLast is the last value a task's record gives a key, the rule core/merge-on-green reads it by.
func metaLast(lines []string, key string) string {
	val := ""
	for _, line := range lines {
		if strings.HasPrefix(line, key+"=") {
			val = line[len(key)+1:]
		}
	}
	return val
}

// mergeOwned is the `@merge-owned` fact: the status line `payload` is a worker's PR-ready report and
// core/merge-on-green will merge that PR with no model turn, so the report asks the lead for nothing
// and the watcher's own merge or alert wakes the lead. It holds only when the task record names the
// PR the line names and its head, a ship (never a Recon or a lead) carries the merge authority the
// watcher honours (yolo=on or merge=approved, never merge=manual), and the watcher has not already
// spent its one attempt on that head. Any missing fact answers false, so the line keeps waking.
func (e env) mergeOwned(key, payload string) bool {
	if !strings.HasSuffix(key, ".status") {
		return false
	}
	task := strings.TrimSuffix(key, ".status")
	if task == "" || strings.ContainsAny(task, "/\\") || strings.HasPrefix(task, ".") {
		return false
	}
	meta := filepath.Join(e.state, task+".meta")
	if !isFile(meta) || isLink(meta) {
		return false
	}
	data, err := os.ReadFile(meta)
	if err != nil {
		return false
	}
	lines := completeLines(string(data))
	if kind := metaLast(lines, "kind"); kind != "" && kind != "ship" {
		return false
	}
	pr, head := metaLast(lines, "pr"), metaLast(lines, "pr_head")
	if pr == "" || head == "" || !strings.Contains(payload, pr) {
		return false
	}
	merge := metaLast(lines, "merge")
	if merge == "manual" || (metaLast(lines, "yolo") != "on" && merge != "approved") {
		return false
	}
	attempted := strings.TrimSpace(wholeFile(filepath.Join(e.homeOrRoot(), "data", "jg-merge-on-green", task+".head")))
	return attempted != head
}

// shipTask is the `@ship-pr` fact: the key is a `<task>.status` whose task record exists and is a ship (the
// kind is absent or `ship`), so its PR-ready report is a merge-ready outcome the merge-ready batch names.
// A Recon, a lead and a task with no record answer false and keep their own routing.
func (e env) shipTask(key string) bool {
	if !strings.HasSuffix(key, ".status") {
		return false
	}
	task := strings.TrimSuffix(key, ".status")
	if task == "" || strings.ContainsAny(task, "/\\") || strings.HasPrefix(task, ".") {
		return false
	}
	meta := filepath.Join(e.state, task+".meta")
	if !isFile(meta) || isLink(meta) {
		return false
	}
	data, err := os.ReadFile(meta)
	if err != nil {
		return false
	}
	kind := metaLast(completeLines(string(data)), "kind")
	return kind == "" || kind == "ship"
}

// wholeFile is `$(cat path)`: the file's text without one trailing newline, empty when unreadable.
func wholeFile(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(string(data), "\n")
}

func numeric(s string) bool { return s != "" && strings.Trim(s, "0123456789") == "" }

// pidAlive is jg_pid_alive: a numeric pid the kernel still reports.
func (e env) pidAlive(pid string) bool {
	if !numeric(pid) {
		return false
	}
	if e.procRoot != "" {
		if _, err := os.Stat(filepath.Join(e.procRoot, pid)); err == nil {
			return true
		}
	}
	p, err := os.FindProcess(atoi(pid))
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// identOf is jg_pid_identity: what makes a pid the same process. Linux starttime with the whole
// cmdline keeps PID reuse a mismatch; where /proc is absent the ps line stands in, pinned to one
// locale and a command column that is never cut, because the value is written by one shell and
// re-read by another.
func (e env) identOf(pid string) (string, bool) {
	if !numeric(pid) {
		return "", false
	}
	root := e.procRoot
	if root == "" {
		root = "/proc"
	}
	data, err := os.ReadFile(filepath.Join(root, pid, "stat"))
	if err == nil {
		cmd, cerr := os.ReadFile(filepath.Join(root, pid, "cmdline"))
		if cerr == nil && len(cmd) > 0 {
			// After the final comm delimiter, index 19 is proc stat field 22 (starttime).
			if i := strings.LastIndexByte(string(data), ')'); i >= 0 {
				fields := strings.Fields(string(data)[i+1:])
				if len(fields) >= 20 && numeric(fields[19]) {
					key := "proc-starttime"
					if runtime.GOOS == "linux" {
						key = "linux-starttime"
					}
					return key + "=" + fields[19] + " cmdline-hex=" + hex.EncodeToString(cmd), true
				}
			}
		}
	}
	command := exec.Command("ps", "-p", pid, "-o", "lstart=", "-o", "command=")
	command.Env = append(os.Environ(), "COLUMNS=10000", "LC_ALL=C")
	out, err := command.Output()
	if err != nil {
		return "", false
	}
	line := strings.TrimLeft(strings.TrimRight(string(out), "\n"), " \t")
	if strings.TrimSpace(line) == "" {
		return "", false
	}
	return line, true
}

// watcherLockMatches is jg_watcher_lock_matches_pid: the lock names this home and this checkout's
// watcher, and the pid's recorded identity still describes that process.
func (e env) watcherLockMatches(pid string) bool {
	lock := filepath.Join(e.state, ".watch.lock")
	if wholeFile(filepath.Join(lock, "jg-home")) != e.home || e.libDir == "" {
		return false
	}
	if wholeFile(filepath.Join(lock, "watcher-path")) != filepath.Join(e.libDir, "jg-watch.sh") {
		return false
	}
	recorded := wholeFile(filepath.Join(lock, "pid-identity"))
	if recorded == "" {
		return false
	}
	current, ok := e.identOf(pid)
	return ok && current == recorded
}

// gapLong: a fleet heartbeat line reports a gap open for at least `set gap-wake-seconds` (default
// 3600). A gap just opened is routine, so only one that stayed open past the threshold wakes.
func (e env) gapLong(payload string) bool {
	limit := e.ruleSet("gap-wake-seconds", 3600)
	for rest := payload; ; {
		i := strings.Index(rest, "GAP for ")
		if i < 0 {
			return false
		}
		rest = rest[i+len("GAP for "):]
		n := 0
		for n < len(rest) && rest[n] >= '0' && rest[n] <= '9' {
			n++
		}
		if n > 0 && n < len(rest) && rest[n] == 's' {
			if secs, err := strconv.ParseInt(rest[:n], 10, 64); err == nil && secs >= limit {
				return true
			}
		}
	}
}

// leadRestarted: the lead named in the event was restarted a moment ago, either by Main's own
// restart pass or by the watcher's relaunch (a `relaunched` row in the lead's relaunch ledger within
// `set lead-restart-grace-seconds`, default 300). A lead that stays down past the window is no longer
// covered, so its notice keeps waking.
func (e env) leadRestarted(key, payload string) bool {
	if e.cond("restart-pass", key, payload, 0) {
		return true
	}
	grace := e.ruleSet("lead-restart-grace-seconds", 300)
	now := e.epoch()
	prev := ""
	for _, word := range strings.Fields(payload) {
		id := ""
		if prev == "squad_lead" {
			id = word
		}
		prev = word
		if id == "" || strings.Trim(id, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") != "" {
			continue
		}
		for _, line := range readLines(filepath.Join(e.state, ".squad-lead-relaunch-"+id)) {
			f := splitFields(line, 2)
			if stamp, err := strconv.ParseInt(f[0], 10, 64); err == nil && f[1] == "relaunched" && now-stamp <= grace {
				return true
			}
		}
	}
	return false
}

// restartPass: the lead id was restarted by Main's own pass within restart-pass-seconds.
func (e env) restartPass(id string) bool {
	secs := e.ruleSet("restart-pass-seconds", 600)
	now := e.epoch()
	path := filepath.Join(e.state, ".squad-lead-restart-pass")
	if !isFile(path) {
		return false
	}
	for _, line := range readLines(path) {
		f := splitFields(line, 2)
		stamp, err := strconv.ParseInt(f[0], 10, 64)
		if err == nil && f[1] == id && now-stamp <= secs {
			return true
		}
	}
	return false
}

// parkedHome is jg_parked_home: the id is listed in config/parked-homes.
func (e env) parkedHome(id string) bool {
	if id == "" {
		return false
	}
	dir := e.configDir
	if dir == "" {
		dir = filepath.Join(e.home, "config")
	}
	file := filepath.Join(dir, "parked-homes")
	if !isFile(file) {
		return false
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(data), "\n") {
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		if strings.Trim(line, " \t\n\r\v\f") == id {
			return true
		}
	}
	return false
}

// parkedMeta is jg_parked_meta: the task meta belongs to a squad_lead whose home id is parked.
func (e env) parkedMeta(meta, task string) bool {
	if !isFile(meta) {
		return false
	}
	data, err := os.ReadFile(meta)
	if err != nil {
		return false
	}
	kind, home := "", ""
	for _, line := range completeLines(string(data)) {
		switch {
		case strings.HasPrefix(line, "kind="):
			kind = line[5:]
		case strings.HasPrefix(line, "home="):
			home = line[5:]
		}
	}
	if kind != "squad_lead" {
		return false
	}
	id := ""
	if home != "" {
		marker := filepath.Join(home, ".jg-squad-lead-home")
		if isFile(marker) && !isLink(marker) {
			if b, err := os.ReadFile(marker); err == nil {
				id = strings.Join(strings.Fields(string(b)), "")
			}
		}
	}
	if id == "" {
		id = task
	}
	return e.parkedHome(id)
}

// silenceCharge is _jg_wake_silence_charge: count one settled event against `set
// silence-cap-per-hour`. False once the hour is spent; the caller then sends it to the digest.
func (e env) silenceCharge() bool {
	capN := e.ruleSet("silence-cap-per-hour", 0)
	if capN <= 0 {
		return true
	}
	now := e.epoch()
	log := filepath.Join(e.state, ".wake-silenced")
	used := int64(0)
	if data, err := os.ReadFile(log); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if len(strings.Fields(line)) > 0 && fieldAtLeast(strings.Fields(line)[0], now-3600, false) {
				used++
			}
		}
	}
	if used >= capN {
		return false
	}
	appendLine(log, strconv.FormatInt(now, 10))
	return true
}

// fieldAtLeast is awk's `$1 > c` (orEqual false) or `$1 >= c` against a number: numeric when the
// field looks like a number, a string comparison otherwise.
func fieldAtLeast(field string, c int64, orEqual bool) bool {
	if n, err := strconv.ParseFloat(field, 64); err == nil {
		if orEqual {
			return n >= float64(c)
		}
		return n > float64(c)
	}
	cs := strconv.FormatInt(c, 10)
	if orEqual {
		return field >= cs
	}
	return field > cs
}

func appendLine(path, line string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	f.WriteString(line + "\n")
}

// cleanField is jg_wake_clean_field: the field characters a row cannot carry become spaces.
func cleanField(s string) string {
	return strings.NewReplacer("\t", " ", "\r", " ", "\n", " ").Replace(s)
}

// identity is _jg_wake_identity: what makes an event the same event again. A status row's payload
// lists files only, so its identity is the newest status line: the same line delivered twice is one
// fact, and a new line is a new event.
func (e env) identity(key, payload string) string {
	if strings.HasSuffix(key, ".status") {
		// tail -n 1 keeps the line's newline, and cleaning turns it into a trailing space.
		if p := filepath.Join(e.state, key); isFile(p) && !isLink(p) {
			if data, err := os.ReadFile(p); err == nil && len(data) > 0 {
				if line := lastLine(p); line != "" {
					if strings.HasSuffix(string(data), "\n") {
						return cleanField(line + "\n")
					}
					return cleanField(line)
				}
			}
		}
	}
	return payload
}

// classify is the class jg_wake_append_locked gives an event before it raises or settles it: the rule
// file's class, then a delivered `now` event repeated inside the re-alert window drops to `batch`, and
// a `silent` event past the hourly cap drops to `batch`. key and payload are already cleaned.
func (e env) classify(kind, key, payload string) string {
	class := e.route(kind, key, payload, 0)
	if class == "now" {
		ident := e.identity(key, payload)
		if data, err := os.ReadFile(filepath.Join(e.state, ".wake-realert")); err == nil && len(data) > 0 &&
			bytes.Contains(data, []byte("\t"+kind+"\t"+key+"\t"+ident)) {
			class = "batch"
		}
	}
	if class == "silent" && !e.silenceCharge() {
		class = "batch"
	}
	return class
}

// realertRecord is _jg_wake_realert_record: remember a delivered event for the rule file's
// re-alert-minutes only, so the same unchanged event cannot wake again inside that window.
func (e env) realertRecord(kind, key, payload string) {
	window := e.ruleSet("re-alert-minutes", 30)
	if window <= 0 {
		return
	}
	cutoff := e.epoch() - window*60
	rules := filepath.Join(e.state, ".wake-realert")
	appendLine(rules, strconv.FormatInt(cutoff+window*60, 10)+"\t"+kind+"\t"+key+"\t"+e.identity(key, payload))
	data, err := os.ReadFile(rules)
	if err != nil {
		return
	}
	var keep strings.Builder
	for _, line := range strings.SplitAfter(string(data), "\n") {
		if line == "" {
			continue
		}
		first := line
		if i := strings.IndexByte(first, '\t'); i >= 0 {
			first = first[:i]
		}
		if fieldAtLeast(strings.TrimSuffix(first, "\n"), cutoff, true) {
			keep.WriteString(line)
		}
	}
	tmp := rules + ".tmp." + strconv.Itoa(os.Getpid())
	if os.WriteFile(tmp, []byte(keep.String()), 0o644) == nil {
		os.Rename(tmp, rules)
	}
	os.Remove(tmp)
}
