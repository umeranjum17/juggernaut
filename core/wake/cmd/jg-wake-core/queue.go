// queue.go - the read model of the wake queue, read the way bin/jg-wake-lib.sh read it.
//
// A row is one tab-separated line: epoch, sequence, kind, key, payload. The queue is rendered from
// the bus (bin/jg-wake-bus.sh render) and every reader here answers from that render, never from
// the server. The line shapes are the ones the shell awk held, including the parts that look like
// an accident: a line with fewer than five fields is not a row, a repeated key is one row that the
// newest line replaces, and a sequence number is a row's number only when it is all digits.
package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
)

// row is one queue line split on tabs. Fields past the fifth are payload, which is why the payload
// is joined back together instead of dropped.
type row struct {
	seq     string
	kind    string
	key     string
	payload string
	fields  int
}

// parseRow splits one line the way `awk -F '\t'` does: a trailing empty field counts, so a payload
// with a tab in it is still one field more than the five a row has.
func parseRow(line string) row {
	f := strings.Split(line, "\t")
	r := row{fields: len(f)}
	if len(f) > 1 {
		r.seq = f[1]
	}
	if len(f) > 2 {
		r.kind = f[2]
	}
	if len(f) > 3 {
		r.key = f[3]
	}
	if len(f) > 4 {
		r.payload = strings.Join(f[4:], "\t")
	}
	return r
}

// isRow reports whether the line is a well-formed queue row; a short line never is.
func isRow(r row) bool { return r.fields >= 5 && isNumber(r.seq) }

// isNumber reports whether s is one all-digit field, the test awk applied with /^[0-9]+$/.
func isNumber(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// lines reads path as awk read it: a final newline ends a record rather than starting an empty one,
// and a blank line in the middle is a record of its own.
func lines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// queueRows reads the rendered queue. A queue that does not exist is no rows: a home that has never
// raised an event has nothing to present, and the file behaviour answered the same way.
func (e env) queueRows() ([]row, error) {
	if _, err := os.Stat(e.queue); err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	ls, err := lines(e.queue)
	if err != nil {
		return nil, err
	}
	rows := make([]row, 0, len(ls))
	for _, line := range ls {
		rows = append(rows, parseRow(line))
	}
	return rows, nil
}

// dedupe prints the rows file as one row per event, in the order the events first appeared.
func (e env) dedupe(path string, out, errw io.Writer) int {
	ls, err := lines(path)
	if err != nil {
		fmt.Fprintf(errw, "jg-wake-core: %v\n", err)
		return 2
	}
	var order []string
	newest := map[string]string{}
	for _, line := range ls {
		r := parseRow(line)
		if r.fields < 5 {
			continue
		}
		// Every heartbeat is one event however its key or payload moved, so its row is keyed by
		// the kind alone; a repeated kind and key is the same fact delivered again.
		id := r.kind + "\x00" + r.key
		if r.kind == "heartbeat" {
			id = "heartbeat"
		}
		if _, seen := newest[id]; !seen {
			order = append(order, id)
		}
		newest[id] = line
	}
	for _, id := range order {
		fmt.Fprintln(out, newest[id])
	}
	return 0
}

// keys prints the distinct keys queued for kind, oldest first.
func (e env) keys(kind string, out, errw io.Writer) int {
	rows, err := e.queueRows()
	if err != nil {
		fmt.Fprintf(errw, "jg-wake-core: %v\n", err)
		return 2
	}
	seen := map[string]bool{}
	for _, r := range rows {
		// A row's number is not part of the question here: a queued line whose sequence is
		// unreadable still names a key somebody queued, so it is listed like any other.
		if r.fields < 5 || r.kind != kind || seen[r.key] {
			continue
		}
		seen[r.key] = true
		fmt.Fprintln(out, r.key)
	}
	return 0
}

// queued prints which of the given sequence numbers the queue still holds.
func (e env) queued(seqs []string, out, errw io.Writer) int {
	rows, err := e.queueRows()
	if err != nil {
		fmt.Fprintf(errw, "jg-wake-core: %v\n", err)
		return 2
	}
	want := make(map[string]bool, len(seqs))
	for _, s := range seqs {
		want[s] = true
	}
	for _, r := range rows {
		if isRow(r) && want[r.seq] {
			fmt.Fprintln(out, r.seq)
		}
	}
	return 0
}

// count prints how many queued rows the actor could act on. A grant file that cannot be read
// reserves nothing, which is what awk's getline did.
func (e env) count(out, errw io.Writer) int {
	rows, err := e.queueRows()
	if err != nil {
		fmt.Fprintf(errw, "jg-wake-core: %v\n", err)
		return 2
	}
	reserved := map[string]bool{}
	if e.actor == "branch" && e.grant == "" {
		fmt.Fprintln(out, 0)
		return 0
	}
	if e.grant != "" {
		if ls, err := lines(e.grant); err == nil {
			for _, line := range ls {
				reserved[line] = true
			}
		}
	}
	n := 0
	for _, r := range rows {
		// A row nobody can retire is Main's, so a malformed row counts for Main and never for
		// the branch, whose grant names sequence numbers only.
		if !isRow(r) {
			if e.actor != "branch" {
				n++
			}
			continue
		}
		if e.actor == "branch" {
			if reserved[r.seq] {
				n++
			}
			continue
		}
		if !reserved[r.seq] {
			n++
		}
	}
	fmt.Fprintln(out, n)
	return 0
}

// grantValid reports whether the file is a non-empty list of distinct sequence numbers.
func (e env) grantValid(path string) int {
	st, err := os.Stat(path)
	if err != nil || st.Size() == 0 {
		return 1
	}
	ls, err := lines(path)
	if err != nil {
		return 1
	}
	seen := map[string]bool{}
	for _, line := range ls {
		if !isNumber(line) || seen[line] {
			return 1
		}
		seen[line] = true
	}
	return 0
}
