// jg-teardown is the Go half of task teardown. This slice owns the landed-work test: the one
// question teardown must answer before it may discard a worktree, "has this work landed?".
//
// bin/jg-teardown.sh gathers a task's recorded facts (its worktree, branch, project, recorded PR
// and base branch, and the forge identity bin/jg-pr-lib.sh parses from the PR URL), runs
//
//	jg-teardown landed --worktree W --branch B --project P [--pr-url U] [--base-branch N]
//	                   [--pr-outside-origin] [--forgejo-host H --forgejo-path R --forgejo-number N
//	                    --forgejo-login L]
//
// and refuses unless it exits 0. The answer is the exit code plus key=value lines on stdout:
//
//	exit 0  landed=yes   the forge proves a merged PR holding this copy's work, or the default
//	                     branch already holds it
//	exit 1  landed=no    gap=<why no landing was proved>, the sentence the refusal prints
//	exit 2               the request itself was invalid; the caller must treat it as a refusal
//
// pr_url=<url> is printed when a merged PR was resolved from the forge, so the caller can record
// the completion link it did not have. `default-branch --project P` prints the project's default
// branch and exits 1 when none can be determined.
//
// `safety` is the next question, asked before the worktree is returned: is anything uncommitted or
// unpushed that nobody has absorbed? It takes the landed flags plus --local and --cached-branch,
// exits 0 to proceed, 1 for a refusal whose sentences it prints on stderr, 3 when a git index lock
// stopped a read (the caller waits, proves the lock stale, and asks again), and 2 for an invalid
// request. branch= and pr_url= on stdout are facts for the caller to keep. The landed question is
// answered in-process, not through `landed`.
//
// There is no --force here and no override: whether to run these tests at all is the caller's
// policy, and this command only ever answers it. It never changes a repository except for
// fetching the refs it compares against.
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "landed":
		os.Exit(runLanded(os.Args[2:]))
	case "reap":
		os.Exit(runReap(os.Args[2:]))
	case "validate-removal":
		os.Exit(runValidateRemoval(os.Args[2:]))
	case "validate-child":
		os.Exit(runValidateChild(os.Args[2:]))
	case "validate-home":
		os.Exit(runValidateHome(os.Args[2:]))
	case "worktree-registered":
		os.Exit(runWorktreeRegistered(os.Args[2:]))
	case "default-branch":
		os.Exit(runDefaultBranch(os.Args[2:]))
	case "safety":
		os.Exit(runSafety(os.Args[2:]))
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: jg-teardown safety --worktree W --project P [--local] [flags] | landed --worktree W --branch B --project P [flags] | default-branch --project P | reap --label L --task-id ID --backend B --target T --caller-pid N DIR... | validate-removal|validate-child|validate-home|worktree-registered [flags] -- TARGET")
}
