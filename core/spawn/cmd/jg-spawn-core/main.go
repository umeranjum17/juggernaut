// jg-spawn-core is the spawn path's pure decision core: the launch flags a harness receives and
// the checks that keep a ship brief and the spawn's own flags in agreement. bin/jg-spawn.sh
// reaches it through bin/jg-spawn-core.sh and keeps everything with a side effect (worktrees,
// endpoints, locks, records); this command reads files and prints text, nothing else.
//
// Usage:
//
//	jg-spawn-core model-flag <harness> <model>
//	jg-spawn-core effort-flag [--harness-script <path>] <harness> <effort> <model>
//	jg-spawn-core delivery-agree [flags]   brief, mode, branch, consent, forge and yolo agreement
//	jg-spawn-core delivery-notices [flags] the two "less than the standing posture" notices
//	jg-spawn-core intake <spawn arguments> the argument grammar and the refusals that need only the arguments
//	jg-spawn-core admit --project <name> --repo <dir> --ticket <json> --lanes <json>  the ticket belongs here and may start
//	jg-spawn-core rovo-override <effort> <data-dir> <state-dir> <id>
//	jg-spawn-core claude-add-dirs <kind> <state-dir> <data-dir> <code-root> <id>
//	jg-spawn-core opencode-lead-grant <lead-home> <state-dir> <id> <code-root>
//	jg-spawn-core launch-home-token <home>
//	jg-spawn-core opencode-db <home-token> <id> <model>
//	jg-spawn-core launch-env-names <file>  the allow-list's names, or exit 1 when the file is invalid
//	jg-spawn-core launch-template <harness> [kind]  the verified launch command, or exit 1 for an unverified adapter
//	jg-spawn-core home-validate <id> <home> <active-home> <repo-root> <marker>  the squad_lead home checks
//	jg-spawn-core worktree-isolated <path> <project-physical-path> <project-path>  the isolation check
//	jg-spawn-core launch-env-strip <allowed-names>
//	jg-spawn-core launch-env-wrap <allowed-names> <traceparent 0|1>   the launch command on stdin
//
// Exit codes: 0 answered, 1 the spawn must stop (the reason is on stderr), 2 the command itself
// was misused. The text each subcommand prints is byte for byte what the shell function it
// replaced printed; core/spawn/README.md records the parity replay that holds it to that. The
// usage line names every command, and tests/jg-go-entries.test.sh holds each name to a caller.
package main

import (
	"fmt"
	"os"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		return usage()
	}
	switch args[0] {
	case "model-flag":
		if len(args) != 3 {
			return usage()
		}
		fmt.Print(modelFlag(args[1], args[2]))
		return 0
	case "effort-flag":
		return effortFlagCmd(args[1:])
	case "delivery-agree":
		return deliveryAgreeCmd(args[1:])
	case "delivery-notices":
		return deliveryNoticesCmd(args[1:])
	case "launch-template":
		return launchTemplateCmd(args[1:])
	case "intake":
		return intakeCmd(args[1:])
	case "admit":
		return admitCmd(args[1:])
	}
	if code, ok := builderCmd(args[0], args[1:]); ok {
		return code
	}
	if code, ok := validatorCmd(args[0], args[1:]); ok {
		return code
	}
	return usage()
}

func usage() int {
	fmt.Fprintln(os.Stderr, "usage: jg-spawn-core model-flag|effort-flag|delivery-agree|delivery-notices|intake|admit|launch-template|home-validate|worktree-isolated|rovo-override|claude-add-dirs|opencode-lead-grant|launch-home-token|opencode-db|launch-env-names|launch-env-strip|launch-env-wrap ... (see the file header)")
	return 2
}
