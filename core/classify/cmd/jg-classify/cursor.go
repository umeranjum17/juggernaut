package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// The bounded-cost open-decisions fold and the file facts it rests on. This file is the one
// statement of the cursor contract; bin/jg-classify-lib.sh forwards each function name to it.
//
// openDecisions re-reads and re-folds a status file's whole lifetime on every call, so its cost
// grows with total log size. A per-drain fleet-wide scan using it would pay that cost for every
// task on every wake. openDecisionsIncremental is the bounded-cost sibling: it reads only the
// bytes appended since its own last call (a persisted per-file byte cursor) and folds just those
// new lines into a persisted running open-set, through the same foldLine rule openDecisions
// uses, so the two strategies can never disagree on what is open. Cost is bounded by new appends
// since the last drain, not by the log's lifetime size.
//
// Correctness invariant: cursor advancement, age, and being buried under later appends never
// drop an open decision - the persisted open-set carries every still-open key forward across
// calls regardless of how much new unrelated log content has since been folded in. Only a line
// the shared fold rule retires removes one.
//
// The cursor file (state/.<task>.open-decisions-cursor) holds `version`, `offset`, `ident`, then
// the folded open set:
//
//	version=<JG_OPEN_DECISIONS_FOLD_VERSION>:<kind>
//	offset=<bytes consumed>
//	ident=<file identity: strong:<dev>:<ino>:<birth> or weak:<dev>:<ino>>
//	<key>\t<verb>\t<note>
//
// The version must be bumped whenever foldLine semantics change, so persisted state from an
// older interpretation is discarded and rebuilt from byte 0; the kind suffix does the same when
// a task kind changes, because kind changes the fold.
//
// Cursor invalidation is deliberately minimal, matching how status files are actually used in
// this repo: every one is created once (`>`) and only ever appended to (`>>`) - never replaced,
// renamed or rewritten in place. So the ways a cursor can go stale are a fold-version mismatch, a
// shrink (truncated), or the file at this path being a different file than before
// (replaced/rotated/recreated), which a changed device+inode makes an O(1) check via one stat -
// no content hashing, no re-reading the consumed prefix. Any signal falls back to a full re-fold
// from byte 0 - byte for byte what openDecisions itself would compute - and rewrites the cursor
// from that clean baseline. A same-inode, same-size, in-place byte edit is NOT detected; that is a
// deliberately accepted gap because no code path in this repo does that to a status file.
//
// The other real failure mode is our own read failing, not a malformed writer: every read here is
// checked, and on failure it reports the already-trusted persisted set unchanged rather than
// risking a silent invalidation that would wipe it - never a bare "empty" as if nothing were open.
//
// The write is atomic (temp file + rename), so a crash between calls leaves either the prior
// cursor or the new one, never a partial one. bin/jg-wake-drain.sh calls this only after
// releasing the wake-queue lock, so a hypothetical race between two overlapping drains can at
// worst redo a little folding work twice - never drop an open decision - because a losing
// writer's offset can only ever be equal to or behind an already-recorded byte position, and the
// next call re-derives from whatever offset actually landed on disk.

// Fold versions, newest last. 4: verb parsing ends at the first "[name=value]" tag rather than
// only at a "[key=...]" one, so lines carrying another bracketed tag first became opens and
// closes. 5: lineVerb also reads through an unbracketed correlation token, so lines that
// previously folded as ordinary status become opens and closes. 6: a done/failed line on a ship
// or scout closes every open decision, and the persisted version now carries the task kind, so
// cursors folded without that terminal rule are discarded. 7: that terminal rule now fires only
// for a line carrying a colon, so a cursor folded when bare prose could close every open decision
// is discarded. 8: a colonless line without a complete "[key=...]" token is no longer a
// transition at all, so a cursor holding a phantom decision that bare prose opened is discarded.
// 9: the two colon tests read the line with its time tag stripped, so a malformed worker stamp
// whose colons used to pose as the head/note separator no longer opens or closes anything.
// 10: a done or failed line carrying an explicit key closes that key on every kind of lane, not
// only through the ship/scout terminal rule, so a cursor holding a squad_lead decision its own
// `done` had answered is discarded.
const openDecisionsFoldVersion = "11"

// cursorPath is the sibling cursor file for a status file.
func cursorPath(statusFile string) string {
	return filepath.Join(filepath.Dir(statusFile), "."+strings.TrimSuffix(filepath.Base(statusFile), ".status")+".open-decisions-cursor")
}

// runTool runs a reader override from the environment and returns its stdout with the trailing
// newlines a command substitution would strip. ok is false when the program fails.
func runTool(name string, args ...string) (string, bool) {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return "", false
	}
	return strings.TrimRight(string(out), "\n"), true
}

// fileIdent is the portable device:inode identity used by the rotation/recreation check, with
// the file's birth time when the platform reports one. It prints "strong:<dev>:<ino>:<birth>" or
// "weak:<dev>:<ino>", and reports false for a file it cannot identify. The platform stat is the
// one identity reader: device and inode are the same numbers on every filesystem, and only a
// platform that reports a birth time can tell two files with one reused inode apart.
func fileIdent(path string) (string, bool) {
	if name := os.Getenv("JG_STATUS_IDENTITY_READER"); name != "" {
		return runTool(name, path)
	}
	flag, format, cmd := "-c", "%d:%i|%W|%w", "stat"
	if runtime.GOOS == "darwin" {
		flag, format, cmd = "-f", "%d:%i|%B|%FB", "/usr/bin/stat"
	}
	out, ok := runTool(cmd, flag, format, path)
	if !ok {
		return "", false
	}
	fields := strings.SplitN(out, "|", 3)
	ident := fields[0]
	birth := ""
	if len(fields) > 1 && fields[1] != "0" && len(fields) > 2 {
		birth = fields[2]
	}
	if ident == "" || strings.ContainsAny(ident+birth, "\t\n") {
		return "", false
	}
	if birth != "" {
		return "strong:" + ident + ":" + birth, true
	}
	return "weak:" + ident, true
}

// fileSize is a file's size in bytes, from its status, or the size reader override.
func fileSize(path string) (int64, bool) {
	if name := os.Getenv("JG_STATUS_SIZE_READER"); name != "" {
		out, ok := runTool(name, path)
		if !ok {
			return 0, false
		}
		n, err := strconv.ParseInt(strings.TrimSpace(out), 10, 64)
		return n, err == nil
	}
	st, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return st.Size(), true
}

// fileMTime is a file's modification time in epoch seconds.
func fileMTime(path string) (int64, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	return st.ModTime().Unix(), true
}

// readSpan reads length bytes at start from a regular file, refusing a symlink. It reports false
// on a short read rather than returning a partial span.
func readSpan(path string, start, length int64) ([]byte, bool) {
	if name := os.Getenv("JG_STATUS_SPAN_READER"); name != "" {
		// No trailing-newline trim here: this seam supplies file bytes, not a printed value.
		out, err := exec.Command(name, path, strconv.FormatInt(start, 10), strconv.FormatInt(length, 10)).Output()
		return out, err == nil
	}
	if length < 0 || start < 0 {
		return nil, false
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	if _, err := f.Seek(start, 0); err != nil {
		return nil, false
	}
	buf := make([]byte, length)
	if _, err := io.ReadFull(f, buf); err != nil {
		return nil, false
	}
	return buf, true
}

// plainReadableFile reports whether a status file may be folded: a regular file that is not a
// symlink and can be opened for reading.
func plainReadableFile(path string) bool {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return false
	}
	if li, err := os.Lstat(path); err != nil || li.Mode()&os.ModeSymlink != 0 {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// cursorParse splits a persisted cursor. Anything it cannot trust leaves version, ident and the
// trusted open set empty, which the caller reads as "refold from byte 0".
func cursorParse(data, foldVersion string) (version, ident, open, trusted string, offset int64) {
	nl := strings.IndexByte(data, '\n')
	if nl < 0 {
		return "", "", "", "", 0
	}
	if !strings.HasPrefix(data[:nl], "version=") {
		return "", "", "", "", 0
	}
	version = data[len("version="):nl]
	if version != foldVersion {
		version = ""
	}
	rest := data[nl+1:]
	offsetLine := rest
	if i := strings.IndexByte(rest, '\n'); i >= 0 {
		offsetLine = rest[:i]
	}
	if !strings.HasPrefix(offsetLine, "offset=") {
		return "", "", "", "", 0
	}
	offset, ok := parseCount(offsetLine[len("offset="):])
	if !ok {
		return "", "", "", "", 0
	}
	i := strings.IndexByte(rest, '\n')
	if i < 0 {
		return "", "", "", "", 0
	}
	rest = rest[i+1:]
	identLine := rest
	if j := strings.IndexByte(rest, '\n'); j >= 0 {
		identLine = rest[:j]
		open = rest[j+1:]
	}
	if !strings.HasPrefix(identLine, "ident=") {
		return "", "", "", "", 0
	}
	ident = identLine[len("ident="):]
	if version != "" && ident != "" {
		trusted = open
	}
	return version, ident, open, trusted, offset
}

// parseCount reads a canonical unsigned decimal byte count.
func parseCount(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

// openDecisionsIncremental folds the bytes a status file gained since its last call into the
// persisted open set, and rewrites the cursor. code is 1 only when the cursor cannot be written.
func openDecisionsIncremental(file, capturedEnd string) (string, int) {
	if !plainReadableFile(file) {
		return "", 0
	}
	kind := statusKind(file, "")
	foldVersion := openDecisionsFoldVersion + ":" + kind
	cf := cursorPath(file)

	var version, ident, open, trusted string
	var offset int64
	if data, ok := readRegularNoSymlink(cf); ok && data != "" {
		version, ident, open, trusted, offset = cursorParse(data, foldVersion)
	}

	// A read failure here is a genuine I/O error, not "the file is empty": report the
	// already-trusted persisted set unchanged rather than silently invalidating it.
	cur, ok := fileIdent(file)
	if !ok || cur == "" {
		return trusted, 0
	}
	actual, ok := fileSize(file)
	if !ok || actual < 0 {
		return trusted, 0
	}

	size := actual
	if capturedEnd != "" {
		n, ok := parseCount(capturedEnd)
		if !ok || n > actual {
			return trusted, 0
		}
		size = n
	}

	dirty := false
	if version == "" || ident == "" || ident != cur || offset > actual {
		offset, open, trusted, dirty = 0, "", "", true
	}
	if offset < size {
		chunk, ok := readSpan(file, offset, size-offset)
		if !ok {
			return trusted, 0
		}
		// Test-only observability seam (off by default, no production behaviour change):
		// records exactly how many bytes THIS call folded, so a test can assert the
		// incremental path stays bounded by new appends rather than re-reading the file.
		if probe := os.Getenv("JG_OPEN_DECISIONS_READ_PROBE"); probe != "" {
			if f, err := os.OpenFile(probe, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
				fmt.Fprintf(f, "%s\t%d\n", file, len(chunk))
				f.Close()
			}
		}
		open = foldData(open, kind, chunk)
		offset = size
		dirty = true
	}
	if dirty {
		body := "version=" + foldVersion + "\noffset=" + strconv.FormatInt(offset, 10) + "\nident=" + cur + "\n"
		if open != "" {
			body += open
		}
		if !writeFileAtomic(cf, body) {
			return "", 1
		}
	}
	return open, 0
}

// legacyCursorOffset is the presentation offset seeded from the per-task open-decisions cursor
// before the fleet manifest exists. A fold-version mismatch, identity mismatch, or offset past
// the current size reads as 0; malformed or unreadable cursor state is an error, never a 0 that
// would hide a failure. JG_STATUS_CURSOR_SNAPSHOT_FILE names a path to rewrite with the cursor
// the offset came from.
func legacyCursorOffset(file string) (int64, bool) {
	if !plainReadableFile(file) {
		return 0, false
	}
	cf := cursorPath(file)
	var version, ident, open string
	var offset int64
	if _, err := os.Lstat(cf); err == nil {
		data, ok := readRegularNoSymlink(cf)
		if !ok {
			return 0, false
		}
		version, ident, open, _, offset = cursorParse(data, openDecisionsFoldVersion+":"+statusKind(file, ""))
	}
	cur, ok := fileIdent(file)
	if !ok || cur == "" {
		return 0, false
	}
	size, ok := fileSize(file)
	if !ok || size < 0 {
		return 0, false
	}
	if version == "" || ident == "" || ident != cur || offset > size {
		offset, open = 0, ""
	}
	if snap := os.Getenv("JG_STATUS_CURSOR_SNAPSHOT_FILE"); snap != "" {
		body := "version=" + openDecisionsFoldVersion + ":" + statusKind(file, "") +
			"\noffset=" + strconv.FormatInt(offset, 10) + "\nident=" + cur + "\n"
		if open != "" {
			body += open
		}
		if err := os.WriteFile(snap, []byte(body), 0o644); err != nil {
			return 0, false
		}
	}
	return offset, true
}

// readRegularNoSymlink is a whole-file read of a path that is a regular file and not a symlink.
func readRegularNoSymlink(path string) (string, bool) {
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() {
		return "", false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// writeFileAtomic replaces path with body through a temporary file beside it, so a crash leaves
// either the old file or the new one.
func writeFileAtomic(path, body string) bool {
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		os.Remove(tmp)
		return false
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return false
	}
	return true
}

// statusFiles is the status logs under a state directory, in glob order, less this home's
// outbound parent channel when the caller named one.
func statusFiles(state, exclude string) []string {
	matches, _ := filepath.Glob(filepath.Join(state, "*.status"))
	kept := matches[:0]
	for _, f := range matches {
		if _, err := os.Stat(f); err != nil {
			continue
		}
		if exclude != "" && f == exclude {
			continue
		}
		kept = append(kept, f)
	}
	return kept
}

// scanOpenDecisionsIncremental prints one "<task>\t<key>\t<verb>\t<note>" row per open decision,
// in glob (task id) order, from the cursor-backed fold, so a fleet-wide per-drain scan stays
// bounded by new appends rather than total lifetime log size.
func scanOpenDecisionsIncremental(state, exclude string, out *os.File) int {
	w := bufio.NewWriterSize(out, 1<<16)
	for _, f := range statusFiles(state, exclude) {
		task := strings.TrimSuffix(filepath.Base(f), ".status")
		set, _ := openDecisionsIncremental(f, "")
		for _, line := range strings.Split(set, "\n") {
			if line == "" {
				continue
			}
			fmt.Fprintf(w, "%s\t%s\n", task, line)
		}
	}
	w.Flush()
	return 0
}

// cursorCommand answers the cursor and file-fact reads. handled is false for any other verb.
func cursorCommand(cmd string, a []string, out *os.File) (code int, handled bool) {
	arg := func(i int) string {
		if i < len(a) {
			return a[i]
		}
		return ""
	}
	switch cmd {
	case "cursor-path":
		fmt.Fprint(out, cursorPath(arg(0)))
		return 0, true
	case "file-ident":
		if ident, ok := fileIdent(arg(0)); ok {
			fmt.Fprint(out, ident)
			return 0, true
		}
		return 1, true
	case "file-size":
		if n, ok := fileSize(arg(0)); ok {
			fmt.Fprintf(out, "%d", n)
			return 0, true
		}
		return 1, true
	case "file-mtime":
		if n, ok := fileMTime(arg(0)); ok {
			fmt.Fprintf(out, "%d", n)
			return 0, true
		}
		return 1, true
	case "read-span": // read-span <file> <start> <length>
		start, ok1 := parseCount(arg(1))
		length, ok2 := parseCount(arg(2))
		if !ok1 || !ok2 {
			return 2, true
		}
		data, ok := readSpan(arg(0), start, length)
		if !ok {
			return 1, true
		}
		out.Write(data)
		return 0, true
	case "legacy-cursor-offset": // legacy-cursor-offset <file>
		n, ok := legacyCursorOffset(arg(0))
		if !ok {
			return 1, true
		}
		fmt.Fprintf(out, "%d", n)
		return 0, true
	case "open-decisions-incremental": // open-decisions-incremental <file> [<captured-end>]
		open, code := openDecisionsIncremental(arg(0), arg(1))
		fmt.Fprint(out, open)
		return code, true
	case "scan-open-decisions-incremental": // scan-open-decisions-incremental <state> [<exclude-file>]
		return scanOpenDecisionsIncremental(arg(0), arg(1), out), true
	}
	return 0, false
}
