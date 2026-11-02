package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// env is the home a decision is made for: the facts the shell library resolved once and passes down.
type env struct {
	state       string // the home's state directory
	home        string // JG_HOME
	defaultRoot string // the checkout holding defaults/wake-routing
	queue       string // the read model, state/.wake-queue
	routing     string // JG_WAKE_ROUTING, an override rule file
	configDir   string // JG_CONFIG_OVERRIDE, else <home>/config
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

// routingFile is jg_wake_routing_file: the first existing of JG_WAKE_ROUTING, the home's own
// config/wake-routing, and the checkout's defaults/wake-routing. Empty when there is none.
func (e env) routingFile() string {
	for _, f := range []string{e.routing, filepath.Join(e.homeOrRoot(), "config", "wake-routing"),
		filepath.Join(e.defaultRoot, "defaults", "wake-routing")} {
		if f != "" && isFile(f) {
			return f
		}
	}
	return ""
}

func (e env) homeOrRoot() string {
	if e.home != "" {
		return e.home
	}
	return e.defaultRoot
}

// ruleSet is _jg_wake_rule_set: the last `set <name> <digits>` of the rule file, else def.
func (e env) ruleSet(name string, def int64) int64 {
	file := e.routingFile()
	if file == "" {
		return def
	}
	out := def
	for _, line := range readLines(file) {
		f := splitFields(line, 4)
		if f[0] != "set" || f[1] != name || f[2] == "" || strings.Trim(f[2], "0123456789") != "" {
			continue
		}
		if n, err := strconv.ParseInt(f[2], 10, 64); err == nil {
			out = n
		}
	}
	return out
}

// route is jg_wake_route_class: now, batch or silent. The first matching rule wins and no match
// answers `now`, so a missing rule file can never hide an event. A status-file event is matched
// against the newest line of its status file, so a rule can name the state word.
func (e env) route(kind, key, payload string, depth int) string {
	file := e.routingFile()
	if file == "" {
		return "now"
	}
	if strings.HasSuffix(key, ".status") {
		if p := filepath.Join(e.state, key); isFile(p) && !isLink(p) {
			if line := lastLine(p); line != "" {
				payload = line
			}
		}
	}
	for _, rule := range readLines(file) {
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

// classify is the class jg_wake_append_locked gives an event before it raises or settles it: the
// rule file's class, then a delivered `now` event repeated inside the re-alert window drops to
// `batch`, and a `silent` event past the hourly cap drops to `batch`. key and payload are already
// cleaned of tabs and newlines.
func (e env) classify(kind, key, payload string) string {
	class := e.route(kind, key, payload, 0)
	if !strings.HasSuffix(key, ".status") && class == "now" {
		if data, err := os.ReadFile(filepath.Join(e.state, ".wake-realert")); err == nil && len(data) > 0 &&
			bytes.Contains(data, []byte("\t"+kind+"\t"+key+"\t"+payload)) {
			class = "batch"
		}
	}
	if class == "silent" && !e.silenceCharge() {
		class = "batch"
	}
	return class
}

// realertRecord is _jg_wake_realert_record: remember a delivered `now` event for the rule file's
// re-alert-minutes only, so the same unchanged event cannot wake again inside that window.
func (e env) realertRecord(kind, key, payload string) {
	window := int64(30)
	if file := e.routingFile(); file != "" {
		for _, line := range readLines(file) {
			f := splitFields(line, 4)
			if f[0] == "set" && f[1] == "re-alert-minutes" && f[2] != "" && strings.Trim(f[2], "0123456789") == "" {
				if n, err := strconv.ParseInt(f[2], 10, 64); err == nil {
					window = n
				}
			}
		}
	}
	if window <= 0 {
		return
	}
	cutoff := e.epoch() - window*60
	rules := filepath.Join(e.state, ".wake-realert")
	f, err := os.OpenFile(rules, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, werr := f.WriteString(strconv.FormatInt(cutoff+window*60, 10) + "\t" + kind + "\t" + key + "\t" + payload + "\n")
	f.Close()
	if werr != nil {
		return
	}
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
