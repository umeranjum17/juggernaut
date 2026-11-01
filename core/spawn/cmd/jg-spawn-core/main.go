// jg-spawn-core is the spawn path's pure decision core: the launch flags a harness receives and
// the checks that keep a ship brief and the spawn's own flags in agreement. bin/jg-spawn.sh
// reaches it through bin/jg-spawn-core.sh and keeps everything with a side effect (worktrees,
// endpoints, locks, records); this command reads files and prints text, nothing else.
//
// Usage:
//
//	jg-spawn-core model-flag <harness> <model>
//	jg-spawn-core effort-flag [--harness-script <path>] <harness> <effort> <model>
//	jg-spawn-core rigor-rank <mode>
//	jg-spawn-core delivery-agree [flags]   brief, mode, branch, consent, forge and yolo agreement
//	jg-spawn-core delivery-notices [flags] the two "less than the standing posture" notices
//
// Exit codes: 0 answered, 1 the spawn must stop (the reason is on stderr), 2 the command itself
// was misused. The text each subcommand prints is byte for byte what the shell function it
// replaced printed; core/spawn/README.md records the parity replay that holds it to that.
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
	case "rigor-rank":
		if len(args) != 2 {
			return usage()
		}
		fmt.Println(rigorRank(args[1]))
		return 0
	case "delivery-agree":
		return deliveryAgreeCmd(args[1:])
	case "delivery-notices":
		return deliveryNoticesCmd(args[1:])
	}
	return usage()
}

func usage() int {
	fmt.Fprintln(os.Stderr, "usage: jg-spawn-core model-flag|effort-flag|rigor-rank|delivery-agree|delivery-notices ... (see the file header)")
	return 2
}
