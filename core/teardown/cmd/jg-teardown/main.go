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
// There is no --force here and no override: whether to run this test at all is the caller's
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
	case "default-branch":
		os.Exit(runDefaultBranch(os.Args[2:]))
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: jg-teardown landed --worktree W --branch B --project P [flags] | default-branch --project P")
}
