package main

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// spanEvents classifies one captured span without a process per line. The caller owns
// the size/identity snapshot and commits it only after presenting these events.
// Output is <needs-decision flag>\t<events>; exit 1 means no actionable event.
func spanEvents(kind string, in, out *os.File) int {
	data, err := io.ReadAll(in)
	if err != nil {
		fmt.Fprintf(os.Stderr, "jg-classify: cannot read captured span: %v\n", err)
		return 2
	}
	lines := splitLines(data)
	origins := map[string]int{}
	open := ""
	for i, line := range lines {
		after := foldLine(open, line, kind)
		if after == "" {
			clear(origins)
		}
		key, ok := decisionKey(line, "default")
		verb := lineVerb(line)
		if ok {
			switch verb {
			case "needs-decision", "blocked":
				for _, record := range setRecords(after) {
					if record == key+"\t"+verb+"\t"+lineNote(line) {
						origins[key] = i
					}
				}
			case resolveVerb(), captainHeldVerb():
				if !setHas(after, key) {
					delete(origins, key)
				}
			}
		}
		open = after
	}
	needs := 0
	var events []string
	for i, line := range lines {
		if blank(line) {
			continue
		}
		if isCaptainHeld(line) {
			needs = 1
			continue
		}
		if !isCaptainRelevant(line) {
			continue
		}
		verb := lineVerb(line)
		if verb == "needs-decision" || verb == "blocked" {
			key, ok := decisionKey(line, "default")
			if ok && !transitionAllowed(key, lineNote(line)) {
				line = "reconciliation-required: " + line
			} else if ok {
				if origin, found := origins[key]; !found || origin != i {
					continue
				}
			}
			if verb == "needs-decision" || (ok && pendingReplyEscalation(key, lineNote(line))) {
				needs = 1
			}
		}
		events = append(events, line)
	}
	fmt.Fprint(out, strconv.Itoa(needs)+"\t"+strings.Join(events, " ; "))
	if len(events) == 0 {
		return 1
	}
	return 0
}
