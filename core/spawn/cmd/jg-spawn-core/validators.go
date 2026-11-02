package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// The read-only checks a spawn makes before it creates anything: that a squad_lead's home is a
// seeded home of its own and not the active home or the repository, and that a worker's directory is
// an isolated worktree and not the primary checkout. Each is what the shell function it replaced
// printed and returned.

// pathIsAncestorOf is the shell's `case "$path" in "$ancestor"/*`: a strict, textual ancestor.
func pathIsAncestorOf(ancestor, path string) bool {
	if ancestor == "" || path == "" || ancestor == path {
		return false
	}
	return strings.HasPrefix(path, ancestor+"/")
}

// resolvedExistingDir is `[ -d "$path" ]` and then `cd "$path" && pwd -P`. A directory that is there
// but cannot be entered yields no path and no message of its own, as it did for the shell.
func resolvedExistingDir(path string, stderr *strings.Builder) (string, bool) {
	if st, err := os.Stat(path); err != nil || !st.IsDir() {
		fmt.Fprintf(stderr, "error: juggernaut home does not exist or is not a directory: %s\n", path)
		return "", false
	}
	real, err := physDir(path)
	if err != nil {
		return "", false
	}
	return real, true
}

// validateOperationalDirs checks that each of a squad_lead home's four working directories resolves
// inside that home and outside the active home and the repository.
func validateOperationalDirs(absHome, absActive, absRoot string, stderr *strings.Builder) bool {
	for _, name := range []string{"data", "state", "config", "projects"} {
		dir := absHome + "/" + name
		lst, lerr := os.Lstat(dir)
		_, serr := os.Stat(dir)
		if lerr == nil && lst.Mode()&os.ModeSymlink != 0 && serr != nil {
			fmt.Fprintf(stderr, "error: squad_lead %s directory must resolve inside the squad_lead home: %s\n", name, dir)
			return false
		}
		var absDir string
		switch st, err := os.Stat(dir); {
		case err == nil && st.IsDir():
			absDir, _ = physDir(dir)
		case err == nil:
			fmt.Fprintf(stderr, "error: squad_lead %s path is not a directory: %s\n", name, dir)
			return false
		default:
			absDir = absHome + "/" + name
		}
		if !pathIsAncestorOf(absHome, absDir) {
			fmt.Fprintf(stderr, "error: squad_lead %s directory must resolve inside the squad_lead home: %s\n", name, dir)
			return false
		}
		if absDir == absActive || pathIsAncestorOf(absActive, absDir) {
			fmt.Fprintf(stderr, "error: squad_lead %s directory cannot be inside the active juggernaut home: %s\n", name, dir)
			return false
		}
		if absDir == absRoot || pathIsAncestorOf(absRoot, absDir) {
			fmt.Fprintf(stderr, "error: squad_lead %s directory cannot be inside the juggernaut repo: %s\n", name, dir)
			return false
		}
	}
	return true
}

// validateHomeForSpawn is every refusal of a squad_lead spawn's home: the home exists, is none of
// the filesystem root, the active home or the repository, is neither inside nor an ancestor of
// either, keeps its working directories to itself, and carries this squad_lead's seed marker. On
// success it returns the home's physical path.
func validateHomeForSpawn(id, home, activeHome, root, marker string) (string, string, bool) {
	var stderr strings.Builder
	absHome, ok := resolvedExistingDir(home, &stderr)
	if !ok {
		return "", stderr.String(), false
	}
	// The active home and the repository exist by the time a spawn runs. The shell did not stop on
	// either failing, and neither does this: the path stays empty and the message is kept.
	absActive, _ := resolvedExistingDir(activeHome, &stderr)
	absRoot, _ := resolvedExistingDir(root, &stderr)
	refuse := func(format string, a ...any) (string, string, bool) {
		fmt.Fprintf(&stderr, format+"\n", a...)
		return "", stderr.String(), false
	}
	switch {
	case absHome == "/":
		return refuse("error: squad_lead home cannot be the filesystem root: %s", home)
	case absHome == absActive:
		return refuse("error: squad_lead home cannot be the active juggernaut home: %s", home)
	case absHome == absRoot:
		return refuse("error: squad_lead home cannot be the juggernaut repo: %s", home)
	case pathIsAncestorOf(absActive, absHome):
		return refuse("error: squad_lead home cannot be inside the active juggernaut home: %s", home)
	case pathIsAncestorOf(absRoot, absHome):
		return refuse("error: squad_lead home cannot be inside the juggernaut repo: %s", home)
	case pathIsAncestorOf(absHome, absActive):
		return refuse("error: squad_lead home cannot be an ancestor of the active juggernaut home: %s", home)
	case pathIsAncestorOf(absHome, absRoot):
		return refuse("error: squad_lead home cannot be an ancestor of the juggernaut repo: %s", home)
	}
	if !validateOperationalDirs(absHome, absActive, absRoot, &stderr) {
		return "", stderr.String(), false
	}
	if st, err := os.Stat(absHome + "/" + marker); err != nil || !st.Mode().IsRegular() {
		return refuse("error: juggernaut home %s is not a seeded squad_lead home", home)
	}
	data, _ := os.ReadFile(absHome + "/" + marker)
	markerID := strings.TrimRight(string(data), "\n")
	if markerID != id {
		unknown := markerID
		if unknown == "" {
			unknown = "unknown"
		}
		return refuse("error: juggernaut home %s is marked for squad_lead %s, expected %s", home, unknown, id)
	}
	if st, err := os.Stat(absHome + "/AGENTS.md"); err != nil || !st.Mode().IsRegular() {
		return refuse("error: %s is not a juggernaut home (missing AGENTS.md)", home)
	}
	if st, err := os.Stat(absHome + "/bin"); err != nil || !st.IsDir() {
		return refuse("error: %s is not a juggernaut home (missing bin/)", home)
	}
	return absHome, stderr.String(), true
}

// gitOut is `git -C <dir> <args> 2>/dev/null` inside a command substitution: the output with its
// trailing newlines dropped, and whether git succeeded.
func gitOut(dir string, args ...string) (string, bool) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Stderr = nil
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\n"), err == nil
}

// physDirOrEmpty is `$(cd "$d" 2>/dev/null && pwd -P)` with a failure read as empty.
func physDirOrEmpty(d string) string {
	if d == "" {
		return ""
	}
	real, err := physDir(d)
	if err != nil {
		return ""
	}
	return real
}

// worktreeIsolated is true when path is an isolated worktree of the spawning project: a real
// directory that is its own worktree root, is not the project itself, and does not share the
// project repository's common git dir. top is the worktree root git reported, and reason a phrase
// naming why a rejected path failed, both for the refusal messages.
func worktreeIsolated(path, projAbsReal, projAbs string) (ok bool, top, reason string) {
	wtReal := physDirOrEmpty(path)
	if wtReal == "" {
		return false, "", "it is not a readable directory"
	}
	top, _ = gitOut(path, "rev-parse", "--show-toplevel")
	// An empty toplevel must never reach cd: bash before 5.3 treats `cd ""` as a successful no-op.
	wtTopReal := ""
	if top != "" {
		wtTopReal = physDirOrEmpty(top)
	}
	if wtTopReal == "" {
		return false, top, "it is not inside a git worktree"
	}
	if wtReal != wtTopReal {
		return false, top, fmt.Sprintf("it is a subdirectory of worktree root '%s', not a worktree root", wtTopReal)
	}
	if wtReal == projAbsReal {
		return false, top, "it is the spawning project itself"
	}
	// The primary checkout uses the repository's common git dir as its own git dir. A linked
	// spawning home has a different top-level but the same common dir, so comparing only the two
	// working directories cannot protect primary.
	wtGitDir := ""
	if g, gok := gitOut(path, "rev-parse", "--absolute-git-dir"); gok {
		wtGitDir = physDirOrEmpty(g)
	}
	projCommon := ""
	if c, cok := gitOut(projAbs, "rev-parse", "--path-format=absolute", "--git-common-dir"); cok {
		projCommon = physDirOrEmpty(c)
	}
	if wtGitDir == "" || projCommon == "" {
		return false, top, "its git directory could not be resolved"
	}
	if wtGitDir == projCommon {
		return false, top, "it is the repository's primary checkout (its git dir is the spawning project's common git dir)"
	}
	return true, top, ""
}

// validatorCmd dispatches the validator subcommands; ok is false for a name it does not own.
func validatorCmd(name string, args []string) (code int, ok bool) {
	switch name {
	case "home-validate":
		// home-validate <id> <home> <active-home> <repo-root> <seed-marker-name>
		if len(args) != 5 {
			return usage(), true
		}
		abs, stderr, valid := validateHomeForSpawn(args[0], args[1], args[2], args[3], args[4])
		fmt.Fprint(os.Stderr, stderr)
		if !valid {
			return 1, true
		}
		fmt.Println(abs)
		return 0, true
	case "worktree-isolated":
		// worktree-isolated <path> <project-physical-path> <project-path>: shell assignments for the
		// worktree root and the reason, and exit 0 when the path is an isolated worktree.
		if len(args) != 3 {
			return usage(), true
		}
		isolated, top, reason := worktreeIsolated(args[0], args[1], args[2])
		fmt.Printf("SPAWN_WT_TOP=%s\nSPAWN_WT_REASON=%s\n", shellQuote(top), shellQuote(reason))
		if !isolated {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}
