package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// The removal validators answer one question before teardown deletes a directory: is this path
// safe to remove? They never remove anything. Each prints the canonical path on stdout when the
// answer is yes, prints nothing (and exits 0) when there is nothing to remove, and prints the
// refusal sentence on stderr with exit 1 when the path must stay.
//
//	jg-teardown validate-removal  --jg-home H --jg-root R --label L [--] TARGET
//	jg-teardown validate-child    --jg-home H --jg-root R --project P [--] TARGET
//	jg-teardown validate-home     --jg-home H --jg-root R --label L --registry REG --marker NAME
//	                              [--expected-id ID] [--] HOME
//	jg-teardown worktree-registered --project P [--] TARGET      (exit 0 when listed, 1 when not)
//
// They are ported from the shell validate_removal_target, validate_child_worktree_for_removal,
// validate_juggernaut_home_for_removal and their helpers, sentence for sentence.

// removalFlags are the options the four commands share.
type removalFlags struct {
	jgHome, jgRoot, label, project, registry, marker, expectedID string
	target                                                       string
}

func parseRemovalFlags(name string, args []string) (removalFlags, bool) {
	var f removalFlags
	targets := 0
	for i := 0; i < len(args); i++ {
		next := func() string {
			i++
			if i >= len(args) {
				return ""
			}
			return args[i]
		}
		switch args[i] {
		case "--jg-home":
			f.jgHome = next()
		case "--jg-root":
			f.jgRoot = next()
		case "--label":
			f.label = next()
		case "--project":
			f.project = next()
		case "--registry":
			f.registry = next()
		case "--marker":
			f.marker = next()
		case "--expected-id":
			f.expectedID = next()
		case "--":
			if i+1 < len(args) {
				f.target = args[i+1]
				targets++
			}
			i = len(args)
		default:
			fmt.Fprintf(os.Stderr, "jg-teardown %s: unknown argument %s\n", name, args[i])
			return f, false
		}
	}
	if targets != 1 {
		fmt.Fprintf(os.Stderr, "jg-teardown %s: exactly one target is required after --\n", name)
		return f, false
	}
	return f, true
}

func refusal(format string, a ...any) int {
	fmt.Fprintf(os.Stderr, "REFUSED: "+format+"\n", a...)
	return 1
}

// pathIsAncestorOf is a strict, textual ancestor test on canonical paths. "/" is deliberately not
// an ancestor of anything, as in the shell test it replaces.
func pathIsAncestorOf(ancestor, path string) bool {
	return ancestor != "" && path != "" && ancestor != path && strings.HasPrefix(path, ancestor+"/")
}

// physicalDir is `cd DIR && pwd -P`.
func physicalDir(dir string) (string, bool) {
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		return "", false
	}
	p, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", false
	}
	if p, err = filepath.Abs(p); err != nil {
		return "", false
	}
	return p, true
}

// removalAbsPath is the shell removal_target_abs_path: the physical path of a directory, or the
// physical parent plus the final name of anything else.
func removalAbsPath(target string) (string, bool) {
	if st, err := os.Stat(target); err == nil && st.IsDir() {
		return physicalDir(target)
	}
	parent, ok := physicalDir(filepath.Dir(target))
	if !ok {
		return "", false
	}
	return parent + "/" + shellBasename(target), true
}

func shellBasename(p string) string {
	p = strings.TrimRight(p, "/")
	if p == "" {
		return "/"
	}
	return p[strings.LastIndex(p, "/")+1:]
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func existsOrLink(p string) bool { _, err := os.Lstat(p); return err == nil }

// worktreeRegisteredForProject reports whether git lists target as a worktree of project.
func worktreeRegisteredForProject(project, target string) bool {
	if project == "" {
		return false
	}
	if st, err := os.Stat(project); err != nil || !st.IsDir() {
		return false
	}
	if !gitOK(project, "rev-parse", "--git-dir") {
		return false
	}
	abs, _ := removalAbsPath(target)
	listed, err := run("", "git", "-C", project, "-c", "core.quotePath=false", "worktree", "list", "--porcelain")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(listed, "\n") {
		if !strings.HasPrefix(line, "worktree ") {
			continue
		}
		if got, ok := removalAbsPath(strings.TrimPrefix(line, "worktree ")); ok && got == abs {
			return true
		}
	}
	return false
}

func runWorktreeRegistered(args []string) int {
	f, ok := parseRemovalFlags("worktree-registered", args)
	if !ok {
		return 2
	}
	if worktreeRegisteredForProject(f.project, f.target) {
		return 0
	}
	return 1
}

// validateRemovalTarget returns the canonical target, or the refusal exit code.
func validateRemovalTarget(f removalFlags, target, label string) (string, int) {
	if target == "" || !exists(target) {
		return "", 0
	}
	absTarget, _ := removalAbsPath(target)
	absHome, _ := physicalDir(f.jgHome)
	absRoot, ok := physicalDir(f.jgRoot)
	if !ok {
		fmt.Fprintf(os.Stderr, "jg-teardown: the juggernaut repo %s cannot be resolved\n", f.jgRoot)
		return "", 2
	}
	if absTarget == "" || absTarget == "/" {
		return "", refusal("unsafe %s removal target %s", label, target)
	}
	if absHome != "" && absTarget == absHome {
		return "", refusal("unsafe %s removal target %s is the active juggernaut home", label, target)
	}
	if absTarget == absRoot {
		return "", refusal("unsafe %s removal target %s is the juggernaut repo", label, target)
	}
	if absHome != "" && pathIsAncestorOf(absTarget, absHome) {
		return "", refusal("unsafe %s removal target %s is an ancestor of the active juggernaut home", label, target)
	}
	if pathIsAncestorOf(absTarget, absRoot) {
		return "", refusal("unsafe %s removal target %s is an ancestor of the juggernaut repo", label, target)
	}
	if absHome != "" && pathIsAncestorOf(absHome, absTarget) {
		return "", refusal("unsafe %s removal target %s is inside the active juggernaut home", label, target)
	}
	if pathIsAncestorOf(absRoot, absTarget) {
		return "", refusal("unsafe %s removal target %s is inside the juggernaut repo", label, target)
	}
	return absTarget, 0
}

func runValidateRemoval(args []string) int {
	f, ok := parseRemovalFlags("validate-removal", args)
	if !ok {
		return 2
	}
	abs, rc := validateRemovalTarget(f, f.target, f.label)
	if rc == 0 && abs != "" {
		fmt.Println(abs)
	}
	return rc
}

func runValidateChild(args []string) int {
	f, ok := parseRemovalFlags("validate-child", args)
	if !ok {
		return 2
	}
	if f.target == "" || !exists(f.target) {
		return 0
	}
	abs, rc := validateRemovalTarget(f, f.target, "child worktree")
	if rc != 0 {
		return rc
	}
	if absHome, ok := physicalDir(f.jgHome); ok && pathIsAncestorOf(absHome, abs) {
		return refusal("unsafe child worktree removal target %s is inside the active juggernaut home", f.target)
	}
	absRoot, _ := physicalDir(f.jgRoot)
	if pathIsAncestorOf(absRoot, abs) {
		return refusal("unsafe child worktree removal target %s is inside the juggernaut repo", f.target)
	}
	if !worktreeRegisteredForProject(f.project, f.target) {
		p := f.project
		if p == "" {
			p = "the recorded project"
		}
		return refusal("unsafe child worktree removal target %s is not a git worktree for %s", f.target, p)
	}
	fmt.Println(abs)
	return 0
}

// validateOperationalDirs refuses a Squad Lead home whose data, state, config or projects entry
// leaves the home (a symlink out, a dangling link, or a plain file).
func validateOperationalDirs(home, label string) int {
	absHome, _ := removalAbsPath(home)
	for _, name := range []string{"data", "state", "config", "projects"} {
		dir := home + "/" + name
		if !existsOrLink(dir) {
			continue
		}
		if lst, _ := os.Lstat(dir); lst != nil && lst.Mode()&os.ModeSymlink != 0 && !exists(dir) {
			return refusal("unsafe %s %s directory %s resolves outside the squad_lead home", label, name, dir)
		}
		absDir := ""
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			absDir, _ = physicalDir(dir)
		} else if exists(dir) {
			return refusal("unsafe %s %s path %s is not a directory", label, name, dir)
		}
		if absDir == "" || !pathIsAncestorOf(absHome, absDir) {
			return refusal("unsafe %s %s directory %s resolves outside the squad_lead home", label, name, dir)
		}
	}
	return 0
}

// registeredDescendantHome finds a registered Squad Lead home inside target. rc is 0 for a
// conflict, 1 for none, 2 when the registry itself is unusable (its refusal already printed).
func registeredDescendantHome(reg, target string) (id, home string, rc int) {
	if st, err := os.Stat(reg); err != nil || !st.Mode().IsRegular() {
		return "", "", 1
	}
	if _, errText := validateBindings(reg, "", ""); errText != "" {
		refusal("%s", errText)
		return "", "", 2
	}
	data, _ := os.ReadFile(reg)
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "- ") {
			continue
		}
		rec, ok := parseRegistryLine(line)
		if !ok {
			refusal("malformed squad_lead registry entry: %s", line)
			return "", "", 2
		}
		regAbs, ok := removalAbsPath(rec.home)
		if !ok || regAbs == "" || regAbs == target {
			continue
		}
		if pathIsAncestorOf(target, regAbs) {
			return rec.id, regAbs, 0
		}
	}
	return "", "", 1
}

func runValidateHome(args []string) int {
	f, ok := parseRemovalFlags("validate-home", args)
	if !ok {
		return 2
	}
	if f.target == "" || !exists(f.target) {
		return 0
	}
	abs, rc := validateRemovalTarget(f, f.target, f.label)
	if rc != 0 {
		return rc
	}
	markerPath := abs + "/" + f.marker
	if st, err := os.Stat(markerPath); err != nil || !st.Mode().IsRegular() {
		return refusal("unsafe %s removal target %s is not a seeded squad_lead home", f.label, f.target)
	}
	if f.expectedID != "" {
		raw, _ := os.ReadFile(markerPath)
		markerID := strings.TrimRight(string(raw), "\n")
		if markerID != f.expectedID {
			if markerID == "" {
				markerID = "unknown"
			}
			return refusal("unsafe %s removal target %s is marked for squad_lead %s, expected %s", f.label, f.target, markerID, f.expectedID)
		}
		if existsOrLink(f.registry) {
			if _, errText := validateBindings(f.registry, f.expectedID, abs); errText != "" {
				if strings.HasPrefix(errText, "overlapping squad_lead home assignment:") {
					return refusal("unsafe %s removal target %s contains registered squad_lead home; %s", f.label, f.target, errText)
				}
				return refusal("%s", errText)
			}
		}
	}
	if rc := validateOperationalDirs(abs, f.label); rc != 0 {
		return rc
	}
	childID, childHome, crc := registeredDescendantHome(f.registry, abs)
	if crc == 2 {
		return 1
	}
	if crc == 1 {
		childID, childHome, crc = registeredDescendantHome(abs+"/data/squad_leads.md", abs)
		if crc == 2 {
			return 1
		}
	}
	if crc == 0 {
		return refusal("unsafe %s removal target %s contains registered squad_lead home %s for %s", f.label, f.target, childHome, childID)
	}
	fmt.Println(abs)
	return 0
}

// ---- the Squad Lead registry (bin/jg-squad-lead-registry-lib.sh) ----------------------------

var (
	localRecordRE  = regexp.MustCompilePOSIX(`^- ([A-Za-z0-9._-]+) - (.+) \(home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$`)
	remoteRecordRE = regexp.MustCompilePOSIX(`^- ([A-Za-z0-9._-]+) - (.+) \(host:[[:space:]]*([^;)]*);[[:space:]]*root:[[:space:]]*([^;)]*);[[:space:]]*home:[[:space:]]*([^;)]*);[[:space:]]*scope:[[:space:]]*(.*);[[:space:]]*projects:[[:space:]]*([^;)]*);[[:space:]]*added[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})\)[[:space:]]*$`)
)

type registryRecord struct {
	id, host, root, home, scope, projects string
	remote                                bool
}

// parseRegistryLine reads one "- id - summary (home: ...; scope: ...; projects: ...; added D)"
// record, trying the local form first so summary prose cannot change a route's placement.
func parseRegistryLine(line string) (registryRecord, bool) {
	var r registryRecord
	if m := localRecordRE.FindStringSubmatch(line); m != nil {
		r = registryRecord{id: m[1], home: m[3], scope: m[4], projects: m[5]}
	} else if m := remoteRecordRE.FindStringSubmatch(line); m != nil {
		r = registryRecord{id: m[1], host: m[3], root: m[4], home: m[5], scope: m[6], projects: m[7], remote: true}
	} else {
		return r, false
	}
	if r.home == "" || r.scope == "" {
		return r, false
	}
	if r.remote && (r.host == "" || r.root == "") {
		return r, false
	}
	return r, true
}

// registryPathKey is squad_lead_registry_path_key: the physical form of an absolute path.
func registryPathKey(path string) string {
	if !strings.HasPrefix(path, "/") {
		return ""
	}
	if p, ok := physicalDir(path); ok {
		return p
	}
	parent, ok := physicalDir(filepath.Dir(path))
	if !ok {
		return ""
	}
	return parent + "/" + shellBasename(path)
}

type registryMatch struct {
	host, home, homeKey string
	remote              bool
}

func isIDChars(s string) bool {
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// validateBindings is squad_lead_registry_validate_bindings with the path-key resolver: every
// entry parses and has a safe route, no two entries share a home or an id, no home contains
// another, and the optional expected id and home match. A non-empty error text is the refusal.
func validateBindings(reg, expectedID, expectedHome string) (registryMatch, string) {
	var match registryMatch
	if !isIDChars(expectedID) {
		return match, "invalid squad_lead id: " + expectedID
	}
	unsafe := "squad_lead registry is unavailable or unsafe: " + reg
	lst, err := os.Lstat(reg)
	if err != nil || !lst.Mode().IsRegular() {
		return match, unsafe
	}
	raw, err := os.ReadFile(reg)
	if err != nil {
		return match, unsafe
	}
	type binding struct{ key, id string }
	var bindings []binding
	for _, line := range strings.Split(string(raw), "\n") {
		if !strings.HasPrefix(line, "- ") {
			continue
		}
		r, ok := parseRegistryLine(line)
		if !ok {
			return match, "malformed squad_lead registry entry: " + line
		}
		if !strings.HasPrefix(r.home, "/") {
			return match, fmt.Sprintf("unsafe non-absolute squad_lead home for %s: %s", r.id, r.home)
		}
		if strings.ContainsAny(r.home+r.host+r.root, "\t\n\r") {
			return match, "unsafe squad_lead route for " + r.id
		}
		var key string
		if r.remote {
			if r.host == "" || strings.HasPrefix(r.host, "-") || !isIDChars(r.host) {
				return match, fmt.Sprintf("unsafe SSH host alias for %s: %s", r.id, r.host)
			}
			if !strings.HasPrefix(r.root, "/") {
				return match, fmt.Sprintf("unsafe non-absolute remote root for %s: %s", r.id, r.root)
			}
			if hasTraversal(r.root) {
				return match, fmt.Sprintf("remote code root contains traversal components for %s: %s", r.id, r.root)
			}
			if hasTraversal(r.home) {
				return match, fmt.Sprintf("remote home contains traversal components for %s: %s", r.id, r.home)
			}
			if strings.Contains(r.root+r.home, "//") {
				return match, "remote route contains an empty path component for " + r.id
			}
			if r.root == r.home {
				return match, fmt.Sprintf("overlapping remote root and home for %s: %s", r.id, r.root)
			}
			if strings.HasPrefix(r.home+"/", r.root+"/") {
				return match, fmt.Sprintf("remote home for %s is inside its code root: %s", r.id, r.home)
			}
			if strings.HasPrefix(r.root+"/", r.home+"/") {
				return match, fmt.Sprintf("remote code root for %s is inside its home: %s", r.id, r.root)
			}
			key = "ssh:" + r.host + ":" + r.home
		} else {
			k := registryPathKey(r.home)
			if k == "" {
				return match, fmt.Sprintf("unresolvable squad_lead home for %s: %s", r.id, r.home)
			}
			key = "local:" + k
		}
		bindings = append(bindings, binding{key, r.id})
		if expectedID != "" && r.id == expectedID {
			match = registryMatch{host: r.host, home: r.home, homeKey: key, remote: r.remote}
		}
	}
	// A home bound twice.
	var dup []string
	owner := map[string]string{}
	for _, b := range bindings {
		if o, seen := owner[b.key]; seen {
			dup = append(dup, b.key+": "+o+", "+b.id)
		} else {
			owner[b.key] = b.id
		}
	}
	if len(dup) > 0 {
		return match, "duplicate squad_lead home assignment: " + strings.Join(dup, "\n")
	}
	// An id bound twice.
	dup = nil
	homeOf := map[string]string{}
	for _, b := range bindings {
		if h, seen := homeOf[b.id]; seen {
			dup = append(dup, b.id+": "+h+", "+b.key)
		} else {
			homeOf[b.id] = b.key
		}
	}
	if len(dup) > 0 {
		return match, "duplicate squad_lead id assignment: " + strings.Join(dup, "\n")
	}
	// One home containing another.
	var overlaps []string
	for i, b := range bindings {
		for _, e := range bindings[:i] {
			if awkAncestor(b.key, e.key) {
				overlaps = append(overlaps, fmt.Sprintf("%s (%s) contains %s (%s)", b.key, b.id, e.key, e.id))
			} else if awkAncestor(e.key, b.key) {
				overlaps = append(overlaps, fmt.Sprintf("%s (%s) contains %s (%s)", e.key, e.id, b.key, b.id))
			}
		}
	}
	if len(overlaps) > 0 {
		return match, "overlapping squad_lead home assignment: " + strings.Join(overlaps, "\n")
	}
	if expectedID != "" && match.home == "" {
		return match, "no registry binding for squad_lead " + expectedID
	}
	if expectedHome != "" {
		expectedKey := ""
		if match.remote {
			expectedKey = "ssh:" + match.host + ":" + expectedHome
		} else if k := registryPathKey(expectedHome); k != "" {
			expectedKey = "local:" + k
		}
		if expectedKey == "" || expectedKey != match.homeKey {
			return match, fmt.Sprintf("squad_lead %s is registered at %s, not %s", expectedID, match.home, expectedHome)
		}
	}
	return match, ""
}

func awkAncestor(a, b string) bool { return a != b && strings.HasPrefix(b, a+"/") }

func hasTraversal(p string) bool {
	return strings.Contains("/"+p+"/", "/../") || strings.Contains("/"+p+"/", "/./")
}
