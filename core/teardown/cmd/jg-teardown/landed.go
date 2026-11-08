package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

type forgejoRef struct{ host, path, number, login string }

// landing is one landed-work question. gap always names the most recent reason no landing was
// proved; it is the sentence the refusal prints, so every non-zero path sets it first.
type landing struct {
	wt, branch, project, prURL, baseBranch string
	trunkBranch, trunkGap                  string
	outsideOrigin                          bool
	forgejo                                *forgejoRef
	gap                                    string
	contentGap                             string
}

func runDefaultBranch(args []string) int {
	fs := flag.NewFlagSet("default-branch", flag.ContinueOnError)
	project := fs.String("project", "", "project clone")
	if fs.Parse(args) != nil || *project == "" {
		return 2
	}
	b, ok := defaultBranch(*project)
	if !ok {
		return 1
	}
	fmt.Println(b)
	return 0
}

// landedFlags registers the flags that describe one landed-work question, shared by `landed` and
// `safety` so both read the task's recorded facts the same way. build must run after Parse.
func landedFlags(fs *flag.FlagSet, l *landing) (build func()) {
	fs.StringVar(&l.wt, "worktree", "", "the task's worktree")
	fs.StringVar(&l.project, "project", "", "the project clone")
	fs.StringVar(&l.prURL, "pr-url", "", "the PR recorded for the task")
	fs.StringVar(&l.trunkBranch, "trunk-branch", "", "the project's local trunk branch, when the project is in local-trunk mode")
	fs.StringVar(&l.baseBranch, "base-branch", "", "the task's recorded base branch")
	fs.BoolVar(&l.outsideOrigin, "pr-outside-origin", false, "the recorded PR lives outside this copy's origin repository")
	fHost := fs.String("forgejo-host", "", "Forgejo host of the recorded PR")
	fPath := fs.String("forgejo-path", "", "Forgejo owner/repository of the recorded PR")
	fNum := fs.String("forgejo-number", "", "Forgejo pull number of the recorded PR")
	fLogin := fs.String("forgejo-login", "", "tea login for the Forgejo host")
	return func() {
		if *fHost != "" {
			l.forgejo = &forgejoRef{*fHost, *fPath, *fNum, *fLogin}
		}
	}
}

func runLanded(args []string) int {
	fs := flag.NewFlagSet("landed", flag.ContinueOnError)
	l := &landing{}
	fs.StringVar(&l.branch, "branch", "", "the worktree's branch")
	build := landedFlags(fs, l)
	fs.SetOutput(os.Stderr)
	if fs.Parse(args) != nil || l.wt == "" || l.project == "" {
		return 2
	}
	build()
	landed := l.workIsLanded()
	if landed {
		fmt.Println("landed=yes")
	} else {
		fmt.Println("landed=no")
		fmt.Println("gap=" + oneLine(l.gap))
	}
	if l.prURL != "" {
		fmt.Println("pr_url=" + oneLine(l.prURL))
	}
	if landed {
		return 0
	}
	return 1
}

func oneLine(s string) string { return strings.ReplaceAll(s, "\n", " ") }

// workIsLanded: true when a merged PR proves the current local work is contained in the PR head,
// or - unless the forge reports the PR open or closed - a branch that carries the merge already
// holds it: this exact HEAD when GitHub cannot be read, else its content (the no-PR and non-GitHub
// fallback). That branch is the pull request's own base branch when the forge names it, so a merge
// into a release branch lands here before the default branch holds it. False leaves the reason in gap.
func (l *landing) workIsLanded() bool {
	if l.trunkBranch != "" {
		if l.landedOnTrunk() {
			return true
		}
		l.trunkGap = l.gap
	}
	rc := l.prIsMerged(l.branch)
	exact := false
	switch rc {
	case 0:
		return true
	case 2:
		return false
	case 3:
		exact = true
	}
	if l.contentInDefault(exact) {
		return true
	}
	l.gap = l.gap + "; and " + l.contentGap
	if l.trunkGap != "" {
		l.gap += "; and " + l.trunkGap
	}
	return false
}

// prIsMerged: 0 proved, 2 the forge reports the PR open or closed (decisive: no fallback can
// stand in for that merge), 3 a GitHub forge cannot be read (only this exact HEAD on origin's
// default branch can stand in), 1 inconclusive. A merged PR also hands its own base branch to
// the content fallback, because a merge into a release branch lands there and not yet on the
// default branch.
func (l *landing) prIsMerged(branch string) int {
	var target string
	// A cross-repo lane's recorded PR lives outside this copy's origin repository, so its head
	// cannot be fetched here; prove this copy against its own branch's same-repo PR instead.
	if l.prURL != "" && !l.outsideOrigin {
		target = l.prURL
	} else {
		n, rc := prNumberFromBranch(l.wt, branch)
		if rc != 0 {
			l.gap = "no PR was found on the forge for branch " + branch
			if rc != 3 {
				return 1
			}
			l.gap = "the forge could not be read to find the PR for branch " + branch
			if l.forgeIsGitHub() {
				return 3
			}
			return 1
		}
		target = n
	}
	if target == "" {
		return 1
	}
	var head, resolved string
	if l.forgejo != nil && target == l.prURL {
		l.gap = "the forge could not be read for PR " + target
		state, merged, h, ok := l.forgejoRecord()
		if !ok {
			return 1
		}
		if !merged {
			l.gap = "the forge reports PR " + target + " as " + state + ", not merged"
			return 2
		}
		head = h
		l.gap = "the forge reports PR " + target + " merged, but its head " + orNone(head) + " is not a usable commit"
		if !shaRe.MatchString(head) {
			return 1
		}
		resolved = target
		l.gap = "the forge reports PR " + orStr(resolved, target) + " merged, but its head " + orNone(head) + " could not be fetched to check it holds this copy's work"
	} else {
		l.gap = "the forge could not be read for PR " + target
		view, err := run(l.wt, "gh", "pr", "view", target, "--json", "state,headRefOid,url,baseRefName",
			"-q", `.state + "\t" + .headRefOid + "\t" + .url + "\t" + (.baseRefName // "")`)
		if err != nil {
			view = ""
		}
		// state, head, url, and, when the forge names one, the base branch the merge landed on.
		fields := strings.Split(view, "\t")
		if view == "" || len(fields) < 3 || fields[0] == "" {
			if l.forgeIsGitHub() {
				return 3
			}
			return 1
		}
		state, h, u := fields[0], fields[1], fields[2]
		head, resolved = h, u
		if state != "MERGED" && state != "merged" {
			l.gap = "the forge reports PR " + orStr(resolved, target) + " as " + state + ", not merged"
			return 2
		}
		// The merge landed on the pull request's own base branch, so that branch is what proves
		// this copy's work landed. A release branch carries the merge before the default branch
		// does, and a recorded base can go stale when the pull request is retargeted, so the live
		// base wins over both the default branch and the task's record.
		if len(fields) >= 4 && fields[3] != "" {
			l.baseBranch = fields[3]
		}
		l.gap = "the forge reports PR " + orStr(resolved, target) + " merged, but its head " + orNone(head) + " could not be fetched to check it holds this copy's work"
	}
	if head == "" {
		return 1
	}
	if !ensureCommitObject(l.wt, target, head) {
		return 1
	}
	current, err := git(l.wt, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return 1
	}
	landed := gitOK(l.wt, "merge-base", "--is-ancestor", current, head) || unpushedPatchesInPRHead(l.wt, head)
	l.gap = "the forge reports PR " + orStr(resolved, target) + " merged at head " + head + ", which does not contain this copy's HEAD " + current
	if !landed {
		return 1
	}
	if l.prURL == "" {
		l.gap = "the forge reported no URL for merged PR " + target
		if resolved == "" {
			return 1
		}
		l.prURL = resolved
	}
	return 0
}

// landedOnTrunk: the local trunk already holds this copy's exact HEAD. Cleanup does not require
// a release push. When it is not proved the gap says why and the ordinary forge proof gets its turn.
func (l *landing) landedOnTrunk() bool {
	trunk := "refs/heads/" + l.trunkBranch
	if !gitOK(l.wt, "merge-base", "--is-ancestor", "HEAD", trunk) {
		l.gap = "this copy's HEAD is not on the local " + l.trunkBranch
		return false
	}
	return true
}

func orStr(s, fallback string) string {
	if s != "" {
		return s
	}
	return fallback
}

func orNone(s string) string { return orStr(s, "<none>") }

// contentInDefault: is the branch's content already present in the up-to-date branch that carries
// the merge? That is the task's recorded base branch, else the base branch a merged pull request
// names, and the default branch when neither names one. Fetches first, then 3-way merges that
// branch with HEAD: when HEAD introduces nothing the branch does not already contain (its change
// landed via squash) the merged tree equals the branch's tree. Inconclusive (no ref, a failed
// fetch, a conflict) is false and names the gap in contentGap, so the caller refuses rather than
// guesses. With exact, only HEAD itself reachable from origin's freshly fetched branch counts.
func (l *landing) contentInDefault(exact bool) bool {
	name := l.baseBranch
	l.contentGap = "the default branch could not be determined"
	if name == "" {
		b, ok := defaultBranch(l.project)
		if !ok {
			return false
		}
		name = b
	}
	var ref string
	if gitOK(l.wt, "remote", "get-url", "origin") {
		l.contentGap = "origin's " + name + " could not be fetched"
		if !gitOK(l.wt, "fetch", "--quiet", "origin", "+refs/heads/"+name+":refs/remotes/origin/"+name) {
			return false
		}
		ref = "refs/remotes/origin/" + name
	} else if !exact && gitOK(l.wt, "rev-parse", "--quiet", "--verify", "refs/heads/"+name) {
		ref = "refs/heads/" + name
	} else {
		l.contentGap = "there is no origin remote to check " + name + " against"
		return false
	}
	if exact {
		l.contentGap = "this copy's HEAD is not on origin/" + name
		return gitOK(l.wt, "merge-base", "--is-ancestor", "HEAD", ref)
	}
	l.contentGap = "this copy's content is not in " + strings.TrimPrefix(ref, "refs/remotes/")
	defaultTree, err := git(l.wt, "rev-parse", "--quiet", "--verify", ref+"^{tree}")
	if err != nil || defaultTree == "" {
		return false
	}
	merged, err := git(l.wt, "merge-tree", "--write-tree", ref, "HEAD")
	if err != nil {
		return false
	}
	first, _, _ := strings.Cut(merged, "\n")
	return first == defaultTree
}
