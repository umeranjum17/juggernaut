// repo-guard, in Go: no lane creates, comments on, reviews, or pushes to a repository
// outside allowed-repos, the one list next to this command.
//
// `jg-guard-host gh-axi <args...>` (or `gh`) is the shim in front of that tool: a write
// command's target is resolved explicitly - --repo, then GH_REPO, then this clone's own
// origin - and never from another remote, so a fork clone can never fall back to its
// parent; an on-list target reaches the real tool with --repo made explicit, and an
// off-list one is refused. `jg-guard-host pre-push <remote> <url>` is the git pre-push
// extension: it refuses a push to a remote outside allowed-repos, while a local path or
// file:// remote publishes nothing. A refusal is final - no bypass flag, no environment
// skip - and it names the refused repository and the allow-listed alternative on stderr
// with a non-zero exit status.
//
// This is the Go port of core/repo-guard/repo-guard, whose installed shims exec it. Its
// decisions are unchanged: core/repo-guard/tests/repo-guard.test.sh drives the same
// fixture fork clone, the same stubs and the same pre-push chain it drove before.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

var (
	repoSchemeRe = regexp.MustCompile(`^[^/]*/`)
	repoPathRe   = regexp.MustCompile(`^(/|\./|\.\./|file://|~)`)
	repoGitRe    = regexp.MustCompile(`\.git$`)
)

// guardData is the per-user install dir holding <tool>.real and the allowed-repos list.
func guardData() string {
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		return filepath.Join(xdg, "jg-repo-guard")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "jg-repo-guard")
}

// allowPath is the allow list in force: REPO_GUARD_ALLOW, else the installed copy.
func allowPath() string {
	if p := os.Getenv("REPO_GUARD_ALLOW"); p != "" {
		return p
	}
	return filepath.Join(guardData(), "allowed-repos")
}

// entries is the allow list, one repository or owner/* per line, comments and blanks dropped.
func entries() []string {
	body, err := os.ReadFile(allowPath())
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimRight(line, " \t\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		out = append(out, trimmed)
	}
	return out
}

// writeCommand is the set of commands that write: anything else is a read and passes.
func writeCommand(group, verb string) bool {
	switch group {
	case "pr", "issue", "release", "repo":
	default:
		return false
	}
	switch verb {
	case "create", "comment", "review", "edit", "merge", "close", "reopen", "delete",
		"ready", "update-branch", "revert", "lock", "unlock", "archive", "rename", "transfer":
		return true
	}
	return false
}

// allowed reports whether owner/repo matches the list: owner/repo exactly, owner/* for
// that owner, both case-insensitively.
func allowed(repo string) bool {
	lower := strings.ToLower(repo)
	list := entries()
	for _, entry := range list {
		e := strings.ToLower(entry)
		if owner, ok := strings.CutSuffix(e, "/*"); ok {
			if owner != "" && strings.HasPrefix(lower, owner) {
				return true
			}
			continue
		}
		if e == lower {
			return true
		}
	}
	return false
}

// exampleTarget is the allow-list entry a caller can retry against.
func exampleTarget() string {
	list := entries()
	if len(list) == 0 {
		return ""
	}
	if owner, ok := strings.CutSuffix(list[0], "/*"); ok {
		return owner + "/name"
	}
	return list[0]
}

// refuse reports a final refusal on stderr and exits 1. With two arguments the second is
// what the call would do and the first is the refused repository.
func refuse(args ...string) {
	path := allowPath()
	var b strings.Builder
	if len(args) == 2 {
		fmt.Fprintf(&b, "repo-guard: refused: %s targets %s, which is not an allowed repository.\n", args[1], args[0])
	} else {
		fmt.Fprintf(&b, "repo-guard: refused: %s.\n", args[0])
	}
	fmt.Fprintf(&b, "repo-guard: allowed (%s): %s\n", path, strings.Join(entries(), " "))
	fmt.Fprintf(&b, "repo-guard: retry against one of those (for example --repo %s) or add it to that list. This refusal is final.\n", exampleTarget())
	os.Stderr.WriteString(b.String())
	os.Exit(1)
}

// repoFromURL names owner/repo for a remote url; false for a path that publishes nothing.
func repoFromRepoURL(url string) (string, bool) {
	u := url
	if loc := repoGitRe.FindStringIndex(u); loc != nil {
		u = u[:loc[0]] + u[loc[1]:]
	}
	if u == "" || repoPathRe.MatchString(u) {
		return "", false
	}
	switch {
	case strings.Contains(u, "://"):
		u = u[strings.Index(u, "://")+3:]
		if loc := repoSchemeRe.FindStringIndex(u); loc != nil {
			u = u[loc[1]:]
		}
	case strings.Contains(u, ":"):
		u = u[strings.Index(u, ":")+1:]
	default:
		return "", false
	}
	parts := strings.Split(strings.TrimSuffix(u, "/"), "/")
	if len(parts) < 2 {
		return "", false
	}
	return parts[len(parts)-2] + "/" + parts[len(parts)-1], true
}

// flagRepo is the repository the caller already passed, if any.
func flagRepo(args []string) (string, bool) {
	prev := ""
	for _, a := range args {
		switch prev {
		case "-R", "--repo":
			return a, true
		}
		switch {
		case strings.HasPrefix(a, "--repo="):
			return strings.TrimPrefix(a, "--repo="), true
		case a == "-R":
			prev = a
			continue
		case strings.HasPrefix(a, "-R"):
			return strings.TrimPrefix(strings.TrimPrefix(a, "-R"), "="), true
		}
		prev = a
	}
	return "", false
}

// originRepo is this clone's own origin, never another remote.
func originRepo() (string, bool) {
	out, err := exec.Command("git", "remote", "get-url", "origin").Output()
	if err != nil {
		return "", false
	}
	return repoFromRepoURL(strings.TrimSpace(string(out)))
}

// execReal replaces this process with the real tool, exactly as the shim did.
func execReal(real string, args []string) {
	argv := append([]string{real}, args...)
	if err := syscall.Exec(real, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "repo-guard: refused: cannot run %s: %s\n", real, err)
		os.Exit(1)
	}
}

// ghMode guards one gh or gh-axi call.
func ghMode(tool string, args []string) {
	realPath := filepath.Join(guardData(), tool+".real")
	if b, err := os.ReadFile(realPath); err == nil {
		realPath = strings.TrimSpace(string(b))
	} else {
		realPath = ""
	}
	if realPath == "" || !isExecutable(realPath) {
		fmt.Fprintf(os.Stderr, "repo-guard: refused: no real %s recorded in %s/%s.real; reinstall repo-guard. This refusal is final.\n",
			tool, guardData(), tool)
		os.Exit(1)
	}
	group, verb := "", ""
	if len(args) > 0 {
		group = args[0]
	}
	if len(args) > 1 {
		verb = args[1]
	}
	if !writeCommand(group, verb) {
		execReal(realPath, args)
	}
	explicit, hasExplicit := flagRepo(args)
	target := explicit
	if target == "" {
		target = os.Getenv("GH_REPO")
	}
	if target == "" {
		repo, ok := originRepo()
		if !ok {
			refuse(fmt.Sprintf("this %s %s names no repository this clone can resolve; pass --repo", group, verb))
		}
		target = repo
	}
	if !allowed(target) {
		refuse(target, "this "+group+" "+verb)
	}
	if hasExplicit && explicit != "" {
		execReal(realPath, args)
	}
	execReal(realPath, append(append([]string{}, args...), "--repo", target))
}

// pushMode is the git pre-push extension.
func pushMode(args []string) {
	io.Copy(io.Discard, os.Stdin) // drain git's ref lines so the chained hooks never see EPIPE
	url := ""
	if len(args) > 1 {
		url = args[1]
	}
	if url == "" {
		refuse("the pre-push hook reported no remote url")
	}
	repo, ok := repoFromRepoURL(url)
	if !ok {
		if repoPathRe.MatchString(url) {
			os.Exit(0) // a local remote publishes nothing
		}
		refuse("a push to " + url + ", which names no repository")
	}
	if !allowed(repo) {
		refuse(repo, "a push")
	}
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode().Perm()&0o111 != 0
}
