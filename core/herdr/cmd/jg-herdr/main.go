// Command jg-herdr is the herdr backend's decision and answer-reading core.
//
// bin/backends/herdr.sh is the session-provider adapter for the herdr runtime; it keeps the
// function names bin/jg-backend.sh and its callers use and runs the `herdr` client itself. What
// the adapter used to decide with jq, awk, cksum and tr is answered here, in one place:
//
//	answer readers   stdin is one `herdr` answer (JSON); stdout is what jq printed for it,
//	                 and exit 5 means jq's own failure (a parse error, an index of the wrong type)
//	  field <.a.b.c> [--default <text>]
//	                 `.a.b.c // empty`, or `// <text>` with --default
//	  select <.array.path> <key> <string|--true> <out-key> [--or-empty]
//	                 `.array[]? | select(.key == want) | .out-key`
//	  workspace-ids <label> <legacy-label>     workspaces named either label
//	  live-tabs                                "<tab_id>, a tab, <label>" for every jg- tab
//	  agent-identity                           "<agent>, a tab, <agent_status>"
//	  client-status                            "<running>|<compatible>" from `status --json`
//	  server-running                           running, stopped or unknown
//	  workspace-presence <id>                  dead, present or unknown
//	  pane-presence <pane-id>                  dead, present or unknown
//	decisions        arguments in, an answer out
//	  version-at-least <candidate> <floor>                  0 at or above, 1 below, 2 unparseable
//	  release-floor-verdict <proto> <ver> <min-proto> <min-ver>
//	                                                         0 at or above, 1 below, 2 indeterminate
//	  presentation-preference <file>           off, on or default
//	  agent-name-for <task-id>                 herdr's agent name (exit 1 for an empty id)
//	  agent-name-variant <name> <salt>         <name> cut to 27 characters, plus a checksum
//	  submit-confirm-budget <seconds> <minimum>
//
// A decision prints its answer, not an exit code, because exit 2 belongs to bin/jg-herdr.sh
// when this command cannot run at all; a caller reads an empty answer as "indeterminate".
//
// This is slice one of the adapter port: the answer readers and the decisions above. The
// lifecycle, presentation-journal and send paths stay in shell until their slices.
package main

import (
	"fmt"
	"io"
	"os"
)

const usage = "usage: jg-herdr.sh field|select|workspace-ids|live-tabs|agent-identity|client-status|server-running|workspace-presence|pane-presence|version-at-least|release-floor-verdict|presentation-preference|agent-name-for|agent-name-variant|submit-confirm-budget [args]\n"

func die(code int, format string, a ...any) {
	fmt.Fprintf(os.Stderr, "jg-herdr: "+format+"\n", a...)
	os.Exit(code)
}

// read prints what r answers for every JSON document on stdin. On a jq-style failure the lines
// printed before it stay printed; fallback, when set, is printed in jq's place and the exit is
// 0, for the callers that read `jq ... || printf <fallback>`.
func read(r reader, fallback *string) {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		die(2, "reading stdin: %v", err)
	}
	out, jqErr := run(data, r)
	for _, line := range out {
		fmt.Println(line)
	}
	if jqErr != nil {
		if fallback != nil {
			fmt.Print(*fallback)
			return
		}
		fmt.Fprintf(os.Stderr, "jg-herdr: error: %v\n", jqErr)
		os.Exit(5)
	}
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
	case "field":
		need(rest, 1, cmd)
		var def *string
		if len(rest) >= 3 && rest[1] == "--default" {
			def = &rest[2]
		}
		read(fieldReader(dotted(rest[0]), def), nil)
	case "select":
		need(rest, 4, cmd)
		var want *string
		if rest[2] != "--true" {
			want = &rest[2]
		}
		read(selectReader(dotted(rest[0]), rest[1], want, rest[3], len(rest) > 4 && rest[4] == "--or-empty"), nil)
	case "workspace-ids":
		need(rest, 2, cmd)
		read(workspaceIDs(rest[0], rest[1]), nil)
	case "live-tabs":
		read(liveTabs, nil)
	case "agent-identity":
		read(agentIdentity, nil)
	case "client-status":
		fallback := "|"
		read(clientStatus, &fallback)
	case "server-running":
		fallback := "unknown"
		read(serverRunning, &fallback)
	case "workspace-presence":
		need(rest, 1, cmd)
		data, _ := io.ReadAll(os.Stdin)
		out, err := run(data, workspacePresence(rest[0]))
		if err != nil || len(out) != 1 {
			out = []string{"unknown"}
		}
		fmt.Print(out[0])
	case "pane-presence":
		need(rest, 1, cmd)
		data, _ := io.ReadAll(os.Stdin)
		fmt.Print(panePresence(data, rest[0]))
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
