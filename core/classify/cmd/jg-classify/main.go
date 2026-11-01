// jg-classify is the shared wake classifier: the status-line tests and status-file scans the
// watcher, the away-mode daemon and the drain use to decide what is captain-relevant, what is a
// declared wait, and when a wait expects to clear. It replaces the shell reader that lived in
// bin/jg-classify-lib.sh; that library's functions now call this command.
//
// Usage:
//
//	jg-classify last-line [--previous] <status-file>   latest event (or the one before it)
//	jg-classify declared-wait <status-file>            the line holding the task in a wait
//	jg-classify is-terminal|is-relevant|is-paused|is-held|is-paused-or-held <line>
//	jg-classify paused-until <line>                    epoch the pause expects to clear
//	jg-classify utc-epoch <YYYY-MM-DDTHH:MM[:SS]Z>     UTC ISO time to epoch seconds
//	jg-classify facts                                  one tab-separated verdict row per stdin line
//
// The tests answer by exit status: 0 yes, 1 no. Anything else (2) is a usage or read fault, so a
// caller never reads a broken classifier as an answer. Overrides come from the environment:
// JG_CAPTAIN_RE, JG_CLASSIFY_PAUSED_VERB, JG_CLASSIFY_RESOLVE_VERB, JG_CLASSIFY_CAPTAIN_HELD_VERB.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func yes(b bool) int {
	if b {
		return 0
	}
	return 1
}

func run(args []string, in *os.File, out, errw *os.File) int {
	if len(args) == 0 {
		fmt.Fprintln(errw, "jg-classify: command required (last-line, declared-wait, is-*, paused-until, utc-epoch, facts)")
		return 2
	}
	cmd, rest := args[0], args[1:]
	arg := ""
	if len(rest) > 0 {
		arg = rest[len(rest)-1]
	}
	switch cmd {
	case "is-terminal":
		return yes(isTerminalVerb(arg))
	case "is-relevant":
		return yes(isCaptainRelevant(arg))
	case "is-paused":
		return yes(isPaused(arg))
	case "is-held":
		return yes(isCaptainHeld(arg))
	case "is-paused-or-held":
		return yes(isPausedOrHeld(arg))
	case "paused-until":
		if t, ok := pausedUntil(arg); ok {
			fmt.Fprint(out, t)
			return 0
		}
		return 1
	case "utc-epoch":
		if t, ok := utcISOToEpoch(arg); ok {
			fmt.Fprint(out, t)
			return 0
		}
		return 1
	case "last-line":
		lines, ok := readLines(arg)
		if !ok {
			return 0
		}
		prev, last := lastEvents(lines, len(rest) > 1 && rest[0] == "--previous")
		if len(rest) > 1 && rest[0] == "--previous" {
			fmt.Fprint(out, prev)
			return 0
		}
		fmt.Fprintln(out, last)
		return 0
	case "declared-wait":
		lines, ok := readLines(arg)
		if !ok {
			return 0
		}
		if l := declaredWaitLine(lines); l != "" {
			fmt.Fprintln(out, l)
		}
		return 0
	case "facts":
		return facts(in, out)
	}
	fmt.Fprintf(errw, "jg-classify: unknown command %q\n", cmd)
	return 2
}

// facts answers every test for each line on stdin, one row each: terminal, relevant, paused,
// held, paused-or-held, prefix-unrecognized, event, and the paused-until epoch (or "-"). It is
// how a recorded corpus is replayed against another reader without a process per line.
func facts(in, out *os.File) int {
	r := bufio.NewReaderSize(in, 1<<20)
	w := bufio.NewWriterSize(out, 1<<20)
	defer w.Flush()
	legacy := legacyRE()
	b := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	for {
		line, err := r.ReadString('\n')
		if line == "" && err != nil {
			return 0
		}
		line = strings.TrimSuffix(line, "\n")
		until := "-"
		if t, ok := pausedUntil(line); ok {
			until = strconv.FormatInt(t, 10)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", b(isTerminalVerb(line)), b(isCaptainRelevant(line)),
			b(isPaused(line)), b(isCaptainHeld(line)), b(isPausedOrHeld(line)), b(prefixUnrecognized(line)),
			b(!blank(line) && lineIsEvent(line, legacy)), until)
	}
}
