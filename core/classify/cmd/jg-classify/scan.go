package main

import (
	"bytes"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// eventWindowLines is how many trailing lines a latest-event read parses before it widens to
// the whole file, so the watcher's per-poll read stays bounded on a long-lived log.
// JG_CLASSIFY_EVENT_WINDOW_LINES overrides the default 200.
func eventWindowLines() int {
	if n, err := strconv.Atoi(os.Getenv("JG_CLASSIFY_EVENT_WINDOW_LINES")); err == nil && n > 0 {
		return n
	}
	return 200
}

// readLines is the lines of a status file as the shell's read loop saw them: split on newline,
// a final unterminated line kept, NUL bytes dropped. ok is false when the file is not a
// readable regular file.
func readLines(path string) (lines []string, ok bool) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	data = bytes.ReplaceAll(data, []byte{0}, nil)
	if len(data) == 0 {
		return nil, true
	}
	lines = strings.Split(string(data), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines, true
}

func blank(s string) bool { return strings.IndexFunc(s, func(r rune) bool { return !isSpace(r) }) < 0 }

// eventScan is the previous and latest recognized status event in lines, and whether any
// event was found. A stream without events keeps its last nonblank line as the latest.
func eventScan(lines []string) (prev, last string, found bool) {
	legacy := legacyRE()
	fallback := ""
	for _, line := range lines {
		if blank(line) {
			continue
		}
		fallback = line
		if lineIsEvent(line, legacy) {
			prev, last, found = last, line, true
		}
	}
	if !found {
		last = fallback
	}
	return prev, last, found
}

func tailLines(lines []string) []string {
	if n := eventWindowLines(); len(lines) > n {
		return lines[len(lines)-n:]
	}
	return lines
}

// lastEvents is the latest status event of a file and the one before it. With wantPrev it reads
// the whole file, since a bounded window cannot bound two events.
func lastEvents(lines []string, wantPrev bool) (prev, last string) {
	if !wantPrev {
		if p, l, found := eventScan(tailLines(lines)); found {
			return p, l
		}
	}
	prev, last, _ = eventScan(lines)
	return prev, last
}

// declaredWaitScan walks the lines back from the newest event past resolved lines to the first
// other event, and returns it when it is a pause none of those resolved lines share a phase
// key with. exhausted is true when every event is a resolved line, so a bounded read widens.
func declaredWaitScan(lines []string) (line string, exhausted bool) {
	legacy := legacyRE()
	resolve := resolveVerb()
	keys := map[string]bool{}
	for i := len(lines) - 1; i >= 0; i-- {
		l := lines[i]
		if blank(l) || !lineIsEvent(l, legacy) {
			continue
		}
		verb := lineVerb(l)
		if verb != resolve && verb != pausedVerb() {
			return "", false
		}
		key, ok := decisionKey(l, keylessPhase)
		if !ok {
			key = ""
		}
		if verb == resolve {
			keys[key] = true
			continue
		}
		if keys[key] {
			return "", false
		}
		return l, false
	}
	return "", true
}

// declaredWaitLine is the status line that holds a task in a declared wait, or "" when it is in
// none. A captain-held or paused line counts while it is the latest event; a resolved latest
// event ends a pause only for the pause's own phase key.
func declaredWaitLine(lines []string) string {
	_, last := lastEvents(lines, false)
	last = strings.TrimRight(last, "\n")
	if isPausedOrHeld(last) {
		return last
	}
	if lineVerb(last) != resolveVerb() {
		return ""
	}
	if l, exhausted := declaredWaitScan(tailLines(lines)); !exhausted {
		return l
	}
	l, _ := declaredWaitScan(lines)
	return l
}

var untilMinute = regexp.MustCompile(`(?s)^.*[[:space:]][Uu][Nn][Tt][Ii][Ll][[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z).*$`)
var untilSecond = regexp.MustCompile(`(?s)^.*[[:space:]][Uu][Nn][Tt][Ii][Ll][[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z).*$`)

// pausedUntil is the epoch a paused line says it expects to clear, from an "until <UTC time>"
// token. It reports false for a line that is not a pause, names no time, or names a malformed one.
func pausedUntil(line string) (int64, bool) {
	if !isPaused(line) {
		return 0, false
	}
	m := untilMinute.FindStringSubmatch(line)
	if m == nil {
		m = untilSecond.FindStringSubmatch(line)
	}
	if m == nil {
		return 0, false
	}
	return utcISOToEpoch(m[1])
}

var daysIn = [...]int{31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

// utcISOToEpoch reads YYYY-MM-DDTHH:MM[:SS]Z as UTC epoch seconds. Any other shape, or a date
// the calendar does not have, is refused rather than read as now.
func utcISOToEpoch(ts string) (int64, bool) {
	if len(ts) == 17 && ts[16] == 'Z' {
		ts = ts[:16] + ":00Z"
	}
	if len(ts) != 20 || ts[4] != '-' || ts[7] != '-' || ts[10] != 'T' || ts[13] != ':' || ts[16] != ':' || ts[19] != 'Z' {
		return 0, false
	}
	num := func(a, b int) int {
		n, err := strconv.Atoi(ts[a:b])
		if err != nil || ts[a] < '0' || ts[a] > '9' {
			return -1
		}
		return n
	}
	y, mo, d, h, mi, s := num(0, 4), num(5, 7), num(8, 10), num(11, 13), num(14, 16), num(17, 19)
	if y < 0 || mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || h > 24 || mi < 0 || mi > 59 || s < 0 || s > 59 {
		return 0, false
	}
	leap := y%4 == 0 && (y%100 != 0 || y%400 == 0)
	if d > daysIn[mo-1] || mo == 2 && d == 29 && !leap {
		return 0, false
	}
	if h == 24 && (mi != 0 || s != 0) {
		return 0, false
	}
	return time.Date(y, time.Month(mo), d, h, mi, s, 0, time.UTC).Unix(), true
}
