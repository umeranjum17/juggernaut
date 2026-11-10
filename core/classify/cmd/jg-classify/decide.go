package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// The decision grammar and fold: the note, key and time-stamp readers, and the fold that turns an
// append-only status stream into the set of keyed decisions still open. It is the one statement
// of this contract; bin/jg-classify-lib.sh forwards each function name to it.
//
// Time stamp. A writer may add "[at=<epoch>]" before the first colon, beside key and corr tags
// in any order: UTC Unix seconds, canonical unsigned decimal, at most 12 digits. A missing,
// malformed or duplicate stamp means the time is unknown, and time never decides current state
// or decision closure. Head-boundary readers (note, key, fold) read the line with every
// stamp-shaped run removed (unstamped), so a worker-written stamp whose colons pose as the
// head/note separator can neither move the separator nor open or close a decision.
//
// Decision key. An optional "[key=<slug>]" names a decision, before the colon or, as an
// equivalent position, at the head of the note (the before-colon token wins when both are
// present; a token deeper in the note is prose). A line with no token uses the key "default". A
// stated slug outside A-Za-z0-9._- is rejected, never rewritten to "default".
//
// Verb. The leading word is cut at the first tag, and whole-word "corr=<16 hex>" tokens after
// the first word are dropped, so "needs-decision corr=... [key=k]: x" reads as needs-decision
// in both directions (open and close). Any other "name=value" word stays, so prose cannot
// impersonate a transition.
//
// Fold. needs-decision or blocked opens a keyed decision; the resolve verb or the verified
// captain-held transfer verb for that key closes it; a done or failed line carrying a colon on
// a ship or scout closes every open decision (a ship's terminal event ends its work). On any
// other kind a done or failed line closes exactly the key it names, and a keyless one says
// nothing: a squad_lead's terminal event describes that lead's own work, not a child's wait.
// A line with neither a colon nor a complete key token is prose and never moves the set.
// A key in a reserved namespace (JG_CLASSIFY_RESERVED_KEY_PREFIXES) moves only on a note that
// begins with that namespace's own "<namespace>...:" vocabulary, so a writer cannot take over
// or clear a decision a supervisor library owns.
const defaultReservedPrefixes = "pending-reply- waiting-timer-"

// keyBeforeColon: a complete "[key=...]" token sits before the first colon, or anywhere on a
// line with no colon.
func keyBeforeColon(line string) bool {
	head := line
	if i := strings.IndexByte(line, ':'); i >= 0 {
		head = line[:i]
	}
	return hasTag(head, "[key=")
}

// keyAtNoteHead is the raw slug of a complete "[key=...]" token at the head of the note.
func keyAtNoteHead(line string) (string, bool) {
	i := strings.IndexByte(line, ':')
	if i < 0 {
		return "", false
	}
	rest := trimLeftSpace(line[i+1:])
	if !strings.HasPrefix(rest, "[key=") || !strings.Contains(rest, "]") {
		return "", false
	}
	rest = rest[5:]
	return rest[:strings.IndexByte(rest, ']')], true
}

// lineNote is the text after the first colon, trimmed, read from the unstamped line. A note-head
// token that states this line's key is key metadata and is stripped.
func lineNote(line string) string {
	u := unstamped(line)
	i := strings.IndexByte(u, ':')
	if i < 0 {
		return u
	}
	n := trimLeftSpace(u[i+1:])
	if !keyBeforeColon(u) {
		if k, ok := keyAtNoteHead(u); ok && slugOK(k) {
			n = trimLeftSpace(strings.TrimPrefix(n, "[key="+k+"]"))
		}
	}
	return n
}

// atEpoch is the one well-formed "[at=<epoch>]" tag before the first colon: canonical unsigned
// decimal, at most 12 digits, and no second tag.
func atEpoch(line string) (string, bool) {
	i := strings.IndexByte(line, ':')
	if i < 0 || !hasTag(line[:i], "[at=") {
		return "", false
	}
	head := line[:i]
	rest := head[strings.Index(head, "[at=")+4:]
	value := rest[:strings.IndexByte(rest, ']')]
	if strings.Contains(rest[strings.IndexByte(rest, ']')+1:], "[at=") || value == "" || len(value) > 12 {
		return "", false
	}
	for _, c := range []byte(value) {
		if c < '0' || c > '9' {
			return "", false
		}
	}
	if value[0] == '0' && len(value) > 1 {
		return "", false
	}
	return value, true
}

// stampLine stamps a newly emitted event, keeping any existing tag.
func stampLine(line string) string {
	i := strings.IndexByte(line, ':')
	if i < 0 || strings.Contains(line[:i], "[at=") {
		return line
	}
	return fmt.Sprintf("%s [at=%d]:%s", line[:i], time.Now().Unix(), line[i+1:])
}

// untimed removes the one well-formed time tag atEpoch accepts.
func untimed(line string) string {
	epoch, ok := atEpoch(line)
	if !ok {
		return line
	}
	i := strings.IndexByte(line, ':')
	head, tag := line[:i], "[at="+epoch+"]"
	before := head[:strings.Index(head, tag)]
	return strings.TrimSuffix(before, " ") + head[strings.Index(head, tag)+len(tag):] + ":" + line[i+1:]
}

func reservedPrefixes() []string {
	return strings.Fields(envOr("JG_CLASSIFY_RESERVED_KEY_PREFIXES", defaultReservedPrefixes))
}

// transitionAllowed: a reserved key may only move on a note that speaks its namespace.
func transitionAllowed(key, note string) bool {
	for _, p := range reservedPrefixes() {
		if strings.HasPrefix(key, p) {
			return strings.HasPrefix(note, p) && strings.IndexByte(note[len(p):], ':') >= 0
		}
	}
	return true
}

// waitTimerClose: a resolve line for a waiting-timer key closes it whatever its note says. The
// captain voice file may have rewritten the machine close line's "waiting-timer-cleared:" note
// into prose on its way to the parent channel, and a wait that is over must not stay open for
// that. Only a close is relaxed; opening or reopening still needs the namespace's own note.
func waitTimerClose(verb, key string) bool {
	return verb == resolveVerb() && strings.HasPrefix(key, "waiting-timer-")
}

func pendingReplyEscalation(key, note string) bool {
	if !strings.HasPrefix(key, "pending-reply-") {
		return false
	}
	for _, p := range []string{"pending-reply-missed:", "pending-reply-delivery-unknown:", "pending-reply-recovery-delivery-failed:", "pending-reply-recovery-delivery-unknown:"} {
		if strings.HasPrefix(note, p) {
			return true
		}
	}
	return false
}

func setRecords(set string) []string {
	var out []string
	for _, l := range strings.Split(set, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

func setDrop(set, key string) []string {
	var out []string
	for _, l := range setRecords(set) {
		if !strings.HasPrefix(l, key+"\t") {
			out = append(out, l)
		}
	}
	return out
}

func setHas(set, key string) bool { return len(setDrop(set, key)) != len(setRecords(set)) }

// setVerb is the verb stored for key in an open set, empty when it has no record.
func setVerb(set, key string) string {
	for _, l := range setRecords(set) {
		if strings.HasPrefix(l, key+"\t") {
			v := l[len(key)+1:]
			if i := strings.IndexByte(v, '\t'); i >= 0 {
				v = v[:i]
			}
			return v
		}
	}
	return ""
}

// supersedes: a working or paused line that states a [key=] is the newest word on that key, so it
// closes the key's open blocked or needs-decision wait. A keyless working line says nothing about a key.
func supersedes(line string) bool {
	v := lineVerb(line)
	if v != "working" && v != pausedVerb() {
		return false
	}
	k, ok := decisionKey(line, "")
	return ok && k != ""
}

// foldLine folds one status line into an open set: needs-decision or blocked opens a keyed
// decision, a resolve or captain-held line for its key closes it, a done or failed line on a
// ship or scout closes them all, and a done or failed line carrying an explicit key closes that
// key on any other kind of lane.
func foldLine(open, line, kind string) string {
	u := unstamped(line)
	if strings.IndexByte(u, ':') < 0 && !hasTag(u, "[key=") {
		return open
	}
	verb := lineVerb(line)
	terminal := strings.IndexByte(u, ':') >= 0 && (verb == "done" || verb == "failed")
	if terminal && (kind == "ship" || kind == "scout") {
		return ""
	}
	if !terminal && verb != "needs-decision" && verb != "blocked" && verb != resolveVerb() && verb != captainHeldVerb() && !supersedes(line) {
		return open
	}
	// A terminal line closes a decision only when it states the key to close. A keyless
	// squad_lead `done` reports that lead's own work, so it may not clear a child's wait.
	if terminal {
		_, atHead := keyAtNoteHead(u)
		if !keyBeforeColon(u) && !atHead {
			return open
		}
	}
	key, ok := decisionKey(line, "default")
	if !ok {
		return open
	}
	note := lineNote(line)
	if !transitionAllowed(key, note) && !waitTimerClose(verb, key) {
		return open
	}
	recs := setDrop(open, key)
	if verb == "needs-decision" || verb == "blocked" {
		recs = append(recs, key+"\t"+verb+"\t"+note)
	}
	return strings.Join(recs, "\n")
}

// statusKind is the task kind: the given one, else the sibling .meta file's, else ship; anything
// outside ship, scout and squad_lead is unknown.
func statusKind(file, kind string) string {
	if kind == "" {
		meta := strings.TrimSuffix(file, ".status") + ".meta"
		st, err := os.Lstat(meta)
		if err != nil || !st.Mode().IsRegular() {
			return "unknown"
		}
		lines, ok := readLines(meta)
		if !ok {
			return "unknown"
		}
		for _, l := range lines {
			if strings.HasPrefix(l, "kind=") {
				kind = l[5:]
			}
		}
		if kind == "" {
			kind = "ship"
		}
	}
	switch kind {
	case "ship", "scout", "squad_lead":
		return kind
	}
	return "unknown"
}

// plainStatusLines reads a status file the fold may use: a regular file that is not a symlink.
func plainStatusLines(path string) ([]string, bool) {
	if st, err := os.Lstat(path); err != nil || !st.Mode().IsRegular() {
		return nil, false
	}
	return readLines(path)
}

// openDecisions folds a whole status file.
func openDecisions(file, kind string) string {
	lines, ok := plainStatusLines(file)
	if !ok {
		return ""
	}
	kind = statusKind(file, kind)
	open := ""
	for _, l := range lines {
		switch lineVerb(l) {
		case "needs-decision", "blocked", "done", "failed", "working", pausedVerb(), resolveVerb(), captainHeldVerb():
			open = foldLine(open, l, kind)
		}
	}
	return open
}

// currentLine resolves the log's current declaration: the most recently opened decision, else a
// standing declared wait, else the latest event.
func currentLine(file, kind string) string {
	current := ""
	for _, r := range setRecords(openDecisions(file, kind)) {
		f := strings.SplitN(r, "\t", 3)
		note := ""
		if len(f) == 3 {
			note = strings.TrimRight(f[2], "\t")
		}
		if len(f) > 1 && f[1] != "" {
			current = f[1] + " [key=" + f[0] + "]: " + note
		}
	}
	lines, ok := readLines(file)
	if current == "" && ok {
		current = strings.TrimRight(declaredWaitLine(lines), "\n")
	}
	if current == "" && ok {
		_, last := lastEvents(lines, false)
		current = strings.TrimRight(last, "\n")
	}
	return current
}

// ownOpenDecisions is the open set minus the keys a supervisor library or the parent raised.
func ownOpenDecisions(file string) []string {
	prefixes := append(reservedPrefixes(), "remote-reply-continuity-", "captain-hold-")
	var out []string
recs:
	for _, r := range setRecords(openDecisions(file, "")) {
		for _, p := range prefixes {
			if strings.HasPrefix(r, p) {
				continue recs
			}
		}
		out = append(out, r)
	}
	return out
}

// hasOpenNeedsDecision: a needs-decision record is open, and with a run id, one keyed nm-<run>-<step>.
func hasOpenNeedsDecision(file string, run *string) bool {
	if run != nil && *run == "" {
		return false
	}
	for _, r := range setRecords(openDecisions(file, "")) {
		f := strings.SplitN(r, "\t", 3)
		if len(f) < 2 || f[1] != "needs-decision" {
			continue
		}
		if run == nil || len(f[0]) > len("nm-"+*run+"-") && strings.HasPrefix(f[0], "nm-"+*run+"-") {
			return true
		}
	}
	return false
}

// keyClosingVerb is the verb that last moved key: the opening verb while it is open, the closing
// verb once closed, nothing when no line ever stated a transition for it.
func keyClosingVerb(file, want string) string {
	lines, ok := plainStatusLines(file)
	if !ok || want == "" {
		return ""
	}
	kind := statusKind(file, "")
	open, verb := "", ""
	for _, l := range lines {
		event := lineVerb(l)
		named := strings.Contains(l, "[key="+want+"]")
		// The same transitions foldLine applies: a done or failed line is terminal on a ship
		// or scout, and on any other kind only when it names the key it closes.
		terminal := (event == "done" || event == "failed") && ((kind == "ship" || kind == "scout") || named)
		if !terminal {
			if event != "needs-decision" && event != "blocked" && event != resolveVerb() && event != captainHeldVerb() && !supersedes(l) {
				continue
			}
			if want != "default" && !named {
				continue
			}
		}
		was := setHas(open, want)
		open = foldLine(open, l, kind)
		if was && !setHas(open, want) {
			verb = event
		}
	}
	if setHas(open, want) {
		return setVerb(open, want)
	}
	return verb
}

// decideCommand runs the decision-grammar commands; handled is false for any other command.
func decideCommand(cmd string, a []string, out *os.File) (code int, handled bool) {
	arg := func(i int) string {
		if i < len(a) {
			return a[i]
		}
		return ""
	}
	put := func(s string) int { fmt.Fprint(out, s); return 0 }
	line := func(s string) int { fmt.Fprintln(out, s); return 0 }
	switch cmd {
	case "verb":
		return put(lineVerb(arg(0))), true
	case "note":
		return put(lineNote(arg(0))), true
	case "key": // key <keyless> <line>
		if k, ok := decisionKey(arg(1), arg(0)); ok {
			return put(k), true
		}
		return 1, true
	case "key-before-colon":
		return yes(keyBeforeColon(arg(0))), true
	case "key-at-note-head":
		if k, ok := keyAtNoteHead(arg(0)); ok {
			return put(k), true
		}
		return 1, true
	case "at-epoch":
		if e, ok := atEpoch(arg(0)); ok {
			return put(e), true
		}
		return 1, true
	case "stamp-line":
		return put(stampLine(arg(0))), true
	case "stamp-width":
		return put(strconv.Itoa(len(fmt.Sprintf(" [at=%d]", time.Now().Unix())))), true
	case "untimed":
		return put(untimed(arg(0))), true
	case "event-recorded": // event-recorded <file> <line>
		lines, ok := readLines(arg(0))
		if !ok {
			return 1, true
		}
		want := untimed(arg(1))
		for _, l := range lines {
			if untimed(l) == want {
				return 0, true
			}
		}
		return 1, true
	case "transition-allowed":
		return yes(transitionAllowed(arg(0), arg(1))), true
	case "pending-reply-escalation":
		return yes(pendingReplyEscalation(arg(0), arg(1))), true
	case "kind":
		return put(statusKind(arg(0), arg(1))), true
	case "fold-line": // fold-line <open-set> <line> <kind>
		return put(foldLine(arg(0), arg(1), arg(2))), true
	case "drop":
		return put(strings.Join(setDrop(arg(0), arg(1)), "\n")), true
	case "open-set-has":
		return yes(setHas(arg(0), arg(1))), true
	case "open-set-verb":
		return put(setVerb(arg(0), arg(1))), true
	case "open-decisions": // open-decisions <file> [kind]
		return put(openDecisions(arg(0), arg(1))), true
	case "current-line":
		return line(currentLine(arg(0), arg(1))), true
	case "own-open-decisions":
		for _, r := range ownOpenDecisions(arg(0)) {
			fmt.Fprintln(out, r)
		}
		return 0, true
	case "has-open-needs-decision": // has-open-needs-decision <file> [<run-id>]
		var run *string
		if len(a) > 1 {
			run = &a[1]
		}
		return yes(hasOpenNeedsDecision(arg(0), run)), true
	case "key-closing-verb":
		return put(keyClosingVerb(arg(0), arg(1))), true
	}
	return 0, false
}

// foldData folds a block of status bytes into an open set, one line at a time. The cursor-backed
// fold and the whole-file fold both come through foldLine, so the two can never disagree.
func foldData(open, kind string, data []byte) string {
	for _, l := range splitLines(data) {
		open = foldLine(open, l, kind)
	}
	return open
}
