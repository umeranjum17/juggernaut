package main

import (
	"bytes"
	"os/exec"
	"strings"
)

// run executes a command in dir and returns its stdout with trailing newlines removed, the way a
// shell command substitution reads it. Standard error is discarded: every caller reports its
// own reason, never the tool's.
func run(dir string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return strings.TrimRight(out.String(), "\n"), err
}

func git(wt string, args ...string) (string, error) {
	return run("", "git", append([]string{"-C", wt}, args...)...)
}

func gitOK(wt string, args ...string) bool {
	_, err := git(wt, args...)
	return err == nil
}

// defaultBranch is the project's default branch: origin/HEAD when set, else a local main or
// master. ok is false when none can be determined, and the caller must refuse rather than guess.
func defaultBranch(project string) (string, bool) {
	if ref, err := git(project, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil && ref != "" {
		return strings.TrimPrefix(ref, "origin/"), true
	}
	for _, b := range []string{"main", "master"} {
		if gitOK(project, "show-ref", "--verify", "--quiet", "refs/heads/"+b) {
			return b, true
		}
	}
	return "", false
}

// patchID is the stable patch id of one commit, or "" when it cannot be computed.
func patchID(wt, commit string) string {
	show := exec.Command("git", "-C", wt, "show", "--pretty=medium", "--no-ext-diff", commit)
	pid := exec.Command("git", "patch-id", "--stable")
	pipe, err := show.StdoutPipe()
	if err != nil {
		return ""
	}
	pid.Stdin = pipe
	var out bytes.Buffer
	pid.Stdout = &out
	if show.Start() != nil || pid.Start() != nil {
		return ""
	}
	_ = pid.Wait()
	_ = show.Wait()
	f := strings.Fields(strings.SplitN(out.String(), "\n", 2)[0])
	if len(f) == 0 {
		return ""
	}
	return f[0]
}

// unpushedPatchesInPRHead: every commit this copy has that no remote has carries a patch the
// merged PR head also carries. A squash merge or a pipeline rebase changes commit ids but not
// patch ids, so this is how a rebased copy is told apart from one with extra unlanded work.
func unpushedPatchesInPRHead(wt, prHead string) bool {
	current, err := git(wt, "rev-parse", "--verify", "HEAD")
	if err != nil {
		return false
	}
	base, err := git(wt, "merge-base", current, prHead)
	if err != nil {
		return false
	}
	logOut, _ := git(wt, "log", "--format=%H", base+".."+prHead, "--")
	prIDs := map[string]bool{}
	for _, c := range strings.Split(logOut, "\n") {
		if id := patchID(wt, c); c != "" && id != "" {
			prIDs[id] = true
		}
	}
	if len(prIDs) == 0 {
		return false
	}
	unpushed, err := git(wt, "log", "--format=%H", "HEAD", "--not", "--remotes", "--")
	if err != nil || unpushed == "" {
		return false
	}
	for _, c := range strings.Split(unpushed, "\n") {
		if c == "" {
			continue
		}
		if id := patchID(wt, c); id == "" || !prIDs[id] {
			return false
		}
	}
	return true
}
