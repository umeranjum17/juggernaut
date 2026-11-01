// Command jg-herdr is the herdr backend's decision core.
//
// bin/backends/herdr.sh is the session-provider adapter for the herdr runtime; it keeps the
// function names bin/jg-backend.sh and its callers use and runs the `herdr` client itself. What
// the adapter used to decide with awk, cksum and tr is answered here, in one place. Each
// command prints its answer, not an exit code, because exit 2 belongs to bin/jg-herdr.sh when
// this command cannot run at all; a caller reads an empty answer as "indeterminate".
//
//	version-at-least <candidate> <floor>                  0 at or above, 1 below, 2 unparseable
//	release-floor-verdict <proto> <ver> <min-proto> <min-ver>
//	                                                       0 at or above, 1 below, 2 indeterminate
//	presentation-preference <file>           off, on or default
//	agent-name-for <task-id>                 herdr's agent name (exit 1 for an empty id)
//	agent-name-variant <name> <salt>         <name> cut to 27 characters, plus a checksum
//	submit-confirm-budget <seconds> <minimum>
//
// This is slice one of the adapter port (core/herdr/README.md): the decisions. The readers of
// herdr's JSON answers, the lifecycle, presentation-journal and send paths stay in shell until
// their slices.
package main

import (
	"fmt"
	"os"
)

const usage = "usage: jg-herdr.sh version-at-least|release-floor-verdict|presentation-preference|agent-name-for|agent-name-variant|submit-confirm-budget [args]\n"

func die(code int, format string, a ...any) {
	fmt.Fprintf(os.Stderr, "jg-herdr: "+format+"\n", a...)
	os.Exit(code)
}

func need(args []string, n int, name string) {
	if len(args) < n {
		die(2, "%s needs %d argument(s)", name, n)
	}
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "version-at-least":
		need(rest, 2, cmd)
		fmt.Print(versionAtLeast(rest[0], rest[1]))
	case "release-floor-verdict":
		need(rest, 4, cmd)
		fmt.Print(releaseFloorVerdict(rest[0], rest[1], rest[2], rest[3]))
	case "presentation-preference":
		need(rest, 1, cmd)
		fmt.Println(presentationPreference(rest[0]))
	case "agent-name-for":
		need(rest, 1, cmd)
		if rest[0] == "" {
			os.Exit(1)
		}
		fmt.Print(agentNameFor(rest[0]))
	case "agent-name-variant":
		need(rest, 2, cmd)
		fmt.Print(agentNameVariant(rest[0], rest[1]))
	case "submit-confirm-budget":
		need(rest, 2, cmd)
		fmt.Print(submitConfirmBudget(rest[0], rest[1]))
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
}
