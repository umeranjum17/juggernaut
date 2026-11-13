package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Exit codes of `safety`. 3 means a git index lock stopped a read, so the caller may wait, prove
// the lock stale, and ask again; every other refusal is final.
const (
	safetyOK         = 0
	safetyRefused    = 1
	safetyInvalid    = 2
	safetyLockedExit = 3
)

// exemptDirt are the untracked paths the fleet's own hooks leave in a worktree; they never block a
// return.
var exemptDirt = regexp.MustCompile(`^\?\? (\.claude/|\.jg-(grok|kimi)-turnend$)`)

// The closed list of reasons a cleanup is refused. Each refusal prints exactly one as `reason=<value>`
// on stdout; core/machines/cleanup-reason.states holds the same words, and tests/jg-teardown-core.test.sh
// fails when the two differ. A new refusal needs a new word in both, never free text.
const (
	reasonUnreadable  = "unreadable-copy"   // git cannot read the copy's index or history
	reasonUncommitted = "uncommitted"       // the copy holds uncommitted changes
	reasonUnmerged    = "unmerged-local"    // a local-only lane holds commits no branch of the project has
	reasonNoDefault   = "no-default-branch" // the project's default branch cannot be determined
	reasonNotOnTrunk  = "not-on-trunk"      // a local-trunk lane's head is not on the local trunk
	reasonNoProof     = "no-merge-proof"    // the forge does not prove the merge
	reasonEmptyLane   = "empty-lane"        // the copy never left its starting commit and its ticket is still open
)

type safety struct {
	landing
	cachedBranch string
	// local is the delivery-style fact "a known mode that does not publish", read from the table by the caller.
	local bool
	// ticketClosed is the caller's fact that the lane's ticket is closed, dropped or moved to another home.
	ticketClosed bool
}

// runSafety answers whether a worktree may be returned to the pool: nothing uncommitted, nothing
// unpushed that the forge or the default branch has not absorbed. It prints the refusal sentences
// on stderr and `branch=` / `pr_url=` facts on stdout for the caller to keep.
//
//	jg-teardown safety --worktree W --project P [--local] [--ticket-closed] [--cached-branch B]
//	                   [landed flags]
//
// A refusal prints `reason=<value>` on stdout (the closed list above). A clean copy still on the
// commit its lane started on, whose ticket is closed, has nothing to land and nothing to lose: it
// passes with `resolution=dropped`, and the caller must not mark the ticket landed.
func runSafety(args []string) int {
	fs := flag.NewFlagSet("safety", flag.ContinueOnError)
	s := &safety{}
	fs.BoolVar(&s.local, "local", false, "the task's delivery style does not publish (the delivery-style table's local fact)")
	fs.BoolVar(&s.ticketClosed, "ticket-closed", false, "the lane's ticket is closed, dropped or moved; an empty lane is then cleaned as dropped")
	fs.StringVar(&s.cachedBranch, "cached-branch", "", "the branch an earlier check read from this worktree")
	build := landedFlags(fs, &s.landing)
	fs.SetOutput(os.Stderr)
	if fs.Parse(args) != nil {
		return safetyInvalid
	}
	build()
	return s.check()
}

// refuse prints the reason word, then the sentences, and returns the refusal exit code.
func refuse(reason string, lines ...string) int {
	fmt.Println("reason=" + reason)
	for _, l := range lines {
		fmt.Fprintln(os.Stderr, l)
	}
	return safetyRefused
}

func (s *safety) check() int {
	wt := s.wt
	if st, err := os.Stat(wt); wt == "" || err != nil || !st.IsDir() {
		return safetyOK
	}
	const discard = "Restore the git index state, or get the captain's explicit OK to discard, then --force."
	dirtyRaw, err := git(wt, "status", "--porcelain")
	if err != nil {
		if s.blockedByLock("uncommitted changes") {
			return safetyLockedExit
		}
		return refuse(reasonUnreadable, "REFUSED: cannot inspect worktree "+wt+" for uncommitted changes.", discard)
	}
	var kept []string
	for _, line := range strings.Split(dirtyRaw, "\n") {
		if !exemptDirt.MatchString(line) {
			kept = append(kept, line)
		}
	}
	dirty := strings.TrimRight(strings.Join(kept, "\n"), "\n")

	unpushedRaw, err := git(wt, "log", "--oneline", "HEAD", "--not", "--remotes", "--")
	if err != nil {
		if s.blockedByLock("commits not on a remote") {
			return safetyLockedExit
		}
		return refuse(reasonUnreadable, "REFUSED: cannot inspect worktree "+wt+" for commits not on a remote.", discard)
	}
	unpushed := firstLines(unpushedRaw, 5)

	if dirty == "" && s.ticketClosed && s.laneIsEmpty() {
		fmt.Println("resolution=dropped")
		return safetyOK
	}

	switch {
	case unpushed != "" && s.local && s.trunkBranch == "":
		def, ok := defaultBranch(s.project)
		if !ok {
			return refuse(reasonNoDefault, "REFUSED: cannot determine default branch for "+s.project+"; expected origin/HEAD, main, or master.")
		}
		unmergedRaw, err := git(wt, "log", "--oneline", "HEAD", "--not", def, "--")
		if err != nil {
			if s.blockedByLock("commits not on " + def) {
				return safetyLockedExit
			}
			return refuse(reasonUnreadable, "REFUSED: cannot inspect worktree "+wt+" for commits not on "+def+".", discard)
		}
		unmerged := firstLines(unmergedRaw, 5)
		if dirty != "" || unmerged != "" {
			fmt.Fprintln(os.Stderr, "REFUSED: local worktree "+wt+" has work not yet merged into "+def+" and not on any remote.")
			if dirty != "" {
				reportDirt(dirty)
			}
			if unmerged != "" {
				fmt.Fprintf(os.Stderr, "commits not yet on %s:\n%s\n", def, unmerged)
			}
			return refuse(reasonUnmerged, "Merge the branch into local "+def+" first (bin/jg-merge-local.sh after the captain approves), or push to a fork/remote, or get the captain's explicit OK to discard, then --force.")
		}
	case dirty != "":
		fmt.Fprintln(os.Stderr, "REFUSED: worktree "+wt+" has uncommitted changes.")
		reportDirt(dirty)
		return refuse(reasonUncommitted, "Commit them (or get the captain's explicit OK to discard, then --force).")
	case s.local && s.trunkBranch != "":
		if !s.landedOnTrunk() {
			return refuse(s.gapReason(reasonNotOnTrunk), "REFUSED: "+s.gap+".", "Land this branch on the local "+s.trunkBranch+" before cleanup.")
		}
	case !s.local:
		// A pushed branch is not a landing: the forge must prove the merge.
		branch := s.cachedBranch
		if branch == "" {
			out, err := git(wt, "rev-parse", "--abbrev-ref", "HEAD")
			switch {
			case err == nil:
				branch = out
			case out != "":
				branch = out + "\nHEAD"
			default:
				branch = "HEAD"
			}
		}
		fmt.Println("branch=" + oneLine(branch))
		s.branch = branch
		landed := false
		if s.project == "" {
			// The old landed-work call refused an empty project as an invalid request.
			s.gap = "the landed-work check could not run (exit 2)"
		} else {
			landed = s.workIsLanded()
		}
		if s.prURL != "" {
			fmt.Println("pr_url=" + oneLine(s.prURL))
		}
		if !landed {
			fmt.Fprintln(os.Stderr, "REFUSED: worktree "+wt+" has no merge proved on the forge: "+oneLine(s.gap)+".")
			if unpushed != "" {
				fmt.Fprintf(os.Stderr, "unpushed commits:\n%s\n", unpushed)
			}
			return refuse(s.gapReason(reasonNoProof), "A pushed branch, a done or merged status line, a pipeline state, or a summary is a claim, not proof.",
				"Check the PR on the forge and re-run once it shows merged at a head containing this copy's HEAD, or get the captain's explicit OK to discard, then --force.")
		}
	}
	return safetyOK
}

func firstLines(s string, n int) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// reportDirt prints what blocks the return, with the same split the refusal uses: a tracked edit,
// or only untracked leftovers, then up to ten untracked paths.
func reportDirt(dirty string) {
	untracked, tracked := 0, false
	var paths strings.Builder
	for _, line := range strings.Split(dirty, "\n") {
		switch {
		case strings.HasPrefix(line, "?? "):
			untracked++
			if untracked <= 10 {
				paths.WriteString("  " + line[3:] + "\n")
			}
		case strings.Trim(line, " \t") != "":
			tracked = true
		}
	}
	if tracked {
		fmt.Fprintln(os.Stderr, "uncommitted changes present (includes tracked edits)")
	} else {
		fmt.Fprintln(os.Stderr, "uncommitted changes present (untracked-only leftovers)")
	}
	if untracked > 0 {
		fmt.Fprintln(os.Stderr, "untracked paths (up to 10):")
		fmt.Fprint(os.Stderr, paths.String())
		if untracked > 10 {
			fmt.Fprintln(os.Stderr, "  ... additional untracked paths omitted")
		}
	}
}

// blockedByLock: a failed read while a git index lock exists may be a lock a dying process still
// holds, so the caller is told to wait and prove it stale instead of refusing at once.
func (s *safety) blockedByLock(reason string) bool {
	lock := indexLockPath(s.wt)
	if lock == "" {
		return false
	}
	if _, err := os.Stat(lock); err != nil {
		return false
	}
	fmt.Fprintf(os.Stderr, "teardown: cannot inspect worktree %s for %s while git lock %s is present; checking whether the lock is stale\n", s.wt, reason, lock)
	return true
}

// indexLockPath is the absolute path of the worktree's git index lock, or "" when it cannot be
// resolved.
func indexLockPath(dir string) string {
	if st, err := os.Stat(dir); dir == "" || err != nil || !st.IsDir() {
		return ""
	}
	lock, err := git(dir, "rev-parse", "--git-path", "index.lock")
	if err != nil || lock == "" {
		return ""
	}
	if filepath.IsAbs(lock) {
		return lock
	}
	abs, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return ""
	}
	if abs, err = filepath.Abs(abs); err != nil {
		return ""
	}
	return abs + "/" + lock
}
