package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// reap ends the processes a finished task leaked, before teardown discards the directories they
// are rooted in. It is the process-reaping half of teardown, ported from the shell
// reap_task_worktree_processes and its helpers.
//
//	jg-teardown reap --label L --task-id ID --backend B --target T --caller-pid N [--lane-groups FILE] DIR...
//
// A process belongs to the task when its working directory is DIR or under it, from one bounded
// system-wide `lsof -a -d cwd` scan (never the recursive +D walk, which lsof documents as slow).
// Each process is tracked by its start time as well as its number, so a number the system reused
// after the process died is never signalled. TERM goes first, KILL after a grace second to what
// still lives, and up to three passes run because a reaped parent can have started a child.
//
//	exit 0  nothing is left under the directories (or the tmux process-group fallback ran)
//	exit 1  REFUSED: the scan failed, a process could not be identified, or processes remain
//	exit 2  the request itself was invalid
//
// --lane-groups names state/<id>.lane-groups, one run token per line (bin/jg-lane-run.sh). Every
// process whose environment carries JG_LANE_TOKEN=<token> for a recorded token is the lane's
// harness or its descendant and is stopped the same way, wherever its cwd or group is. The
// record is the only authority: no name or pattern is read. A host without /proc warns and skips.
//
// Without lsof the command falls back to the tmux pane's process group. --caller-pid is the
// teardown script's own pid: that process is never a leak, and its process group is never signalled.
func runReap(args []string) int {
	var label, id, backend, target, laneGroups string
	callerPid := 0
	var roots []string
	for i := 0; i < len(args); i++ {
		next := func() string {
			i++
			if i >= len(args) {
				return ""
			}
			return args[i]
		}
		switch args[i] {
		case "--label":
			label = next()
		case "--task-id":
			id = next()
		case "--backend":
			backend = next()
		case "--target":
			target = next()
		case "--lane-groups":
			laneGroups = next()
		case "--caller-pid":
			n, err := strconv.Atoi(next())
			if err != nil || n < 0 {
				fmt.Fprintln(os.Stderr, "jg-teardown reap: --caller-pid must be a process number")
				return 2
			}
			callerPid = n
		case "--":
			roots = append(roots, args[i+1:]...)
			i = len(args)
		default:
			fmt.Fprintf(os.Stderr, "jg-teardown reap: unknown argument %s\n", args[i])
			return 2
		}
	}
	r := &reaper{label: label, id: id, backend: backend, target: target, callerPid: callerPid, roots: roots}
	if !r.reapLaneTokens(laneGroups) {
		return 1
	}
	if _, err := exec.LookPath("lsof"); err != nil {
		r.reapBackendProcessGroup()
		return 0
	}
	if r.reapRoots() {
		return 0
	}
	return 1
}

type reaper struct {
	label, id, backend, target string
	callerPid                  int
	roots                      []string
	failedDir                  string
}

// pidsWithCwdUnder lists the processes whose cwd is dir or under it, never the caller. An empty
// or missing dir has none. ok is false when the scan could not establish a safe answer.
func (r *reaper) pidsWithCwdUnder(dir string) ([]int, bool) {
	if dir == "" {
		return nil, true
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return nil, true
	}
	abs, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return nil, false
	}
	if abs, err = filepath.Abs(abs); err != nil {
		return nil, false
	}
	var stdout bytes.Buffer
	cmd := exec.Command("lsof", "-a", "-d", "cwd", "-Fpn")
	cmd.Stdout = &stdout
	if cmd.Run() != nil {
		return nil, false
	}
	out := strings.TrimRight(stdout.String(), "\n")
	if out == "" {
		return nil, true
	}
	var pids []int
	pid := ""
	sc := bufio.NewScanner(strings.NewReader(out + "\n"))
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "p"):
			pid = line[1:]
			if pid == "" || strings.Trim(pid, "0123456789") != "" {
				return nil, false
			}
		case line == "fcwd":
			if pid == "" {
				return nil, false
			}
		case strings.HasPrefix(line, "n"):
			if pid == "" {
				return nil, false
			}
			path := line[1:]
			if path == abs || strings.HasPrefix(path, abs+"/") {
				n, _ := strconv.Atoi(pid)
				if n != r.callerPid {
					pids = append(pids, n)
				}
			}
		case line == "":
		default:
			return nil, false
		}
	}
	return pids, true
}

// processIdentity names one incarnation of a process: its kernel start time, or the `ps` start
// string where /proc does not exist. ok is false when it cannot be read.
func processIdentity(pid int) (string, bool) {
	root := os.Getenv("JG_PROC_ROOT_OVERRIDE")
	if root == "" {
		root = "/proc"
	}
	statPath := fmt.Sprintf("%s/%d/stat", root, pid)
	if f, err := os.Open(statPath); err == nil {
		_ = f.Close()
		raw, err := os.ReadFile(statPath)
		if err != nil {
			return "", false
		}
		line := strings.TrimRight(string(raw), "\n")
		if i := strings.LastIndex(line, ")"); i >= 0 {
			line = line[i+1:]
		}
		fields := strings.Fields(line)
		if len(fields) < 20 {
			return "", false
		}
		start := fields[19]
		if start == "" || strings.Trim(start, "0123456789") != "" {
			return "", false
		}
		return "starttime=" + start, true
	}
	cmd := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "lstart=")
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var out bytes.Buffer
	cmd.Stdout = &out
	if cmd.Run() != nil {
		return "", false
	}
	value := strings.TrimRight(out.String(), "\n")
	value = strings.TrimSpace(value)
	if value == "" || strings.ContainsAny(value, "\n\r") {
		return "", false
	}
	return "lstart=" + value, true
}

func identityMatches(pid int, want string) bool {
	cur, ok := processIdentity(pid)
	return ok && cur == want
}

// pidsUnderRoots is the sorted, de-duplicated union of the processes under every root. On failure
// failedDir names the root whose scan failed.
func (r *reaper) pidsUnderRoots() ([]int, bool) {
	r.failedDir = ""
	seen := map[int]bool{}
	for _, dir := range r.roots {
		if dir == "" {
			continue
		}
		pids, ok := r.pidsWithCwdUnder(dir)
		if !ok {
			r.failedDir = dir
			return nil, false
		}
		for _, p := range pids {
			seen[p] = true
		}
	}
	out := make([]int, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	sort.Ints(out)
	return out, true
}

func contains(list []int, p int) bool {
	for _, v := range list {
		if v == p {
			return true
		}
	}
	return false
}

func (r *reaper) refuseScan() bool {
	dir := r.failedDir
	if dir == "" {
		dir = "<missing>"
	}
	fmt.Fprintf(os.Stderr, "REFUSED: cannot determine leaked processes under %s for %s (lsof failed); preserving the worktree/tasktmp for manual inspection or retry.\n", dir, r.id)
	return false
}

func joinInts(list []int) string {
	s := make([]string, len(list))
	for i, v := range list {
		s[i] = strconv.Itoa(v)
	}
	return strings.Join(s, " ")
}

// reapRoots is the lsof path. It reports whether the roots are clear.
func (r *reaper) reapRoots() bool {
	const maxPasses = 3
	for pass := 1; pass <= maxPasses; pass++ {
		pids, ok := r.pidsUnderRoots()
		if !ok {
			return r.refuseScan()
		}
		if len(pids) == 0 {
			return true
		}
		var tracked []int
		var identities []string
		for _, pid := range pids {
			identity, ok := processIdentity(pid)
			if !ok {
				now, ok := r.pidsUnderRoots()
				if !ok {
					return r.refuseScan()
				}
				if contains(now, pid) {
					fmt.Fprintf(os.Stderr, "REFUSED: cannot verify leaked process %d identity for %s; preserving the worktree/tasktmp for manual inspection or retry.\n", pid, r.id)
					return false
				}
				continue
			}
			tracked = append(tracked, pid)
			identities = append(identities, identity)
		}
		if len(tracked) == 0 {
			continue
		}
		current, ok := r.pidsUnderRoots()
		if !ok {
			return r.refuseScan()
		}
		fmt.Fprintf(os.Stderr, "teardown: reaping leaked %s process(es) for %s: %s\n", r.label, r.id, joinInts(pids))
		for i, pid := range tracked {
			if contains(current, pid) && identityMatches(pid, identities[i]) {
				_ = syscall.Kill(pid, syscall.SIGTERM)
			}
		}
		time.Sleep(time.Second)
		current, ok = r.pidsUnderRoots()
		if !ok {
			return r.refuseScan()
		}
		var remaining []int
		var remainingIdentities []string
		for i, pid := range tracked {
			if contains(current, pid) && identityMatches(pid, identities[i]) {
				remaining = append(remaining, pid)
				remainingIdentities = append(remainingIdentities, identities[i])
			}
		}
		if len(remaining) > 0 {
			fmt.Fprintf(os.Stderr, "teardown: force-killing leaked %s process(es) for %s: %s\n", r.label, r.id, joinInts(remaining))
			current, ok = r.pidsUnderRoots()
			if !ok {
				return r.refuseScan()
			}
			for i, pid := range remaining {
				if contains(current, pid) && identityMatches(pid, remainingIdentities[i]) {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			}
		}
	}
	left, ok := r.pidsUnderRoots()
	if !ok {
		return r.refuseScan()
	}
	if len(left) == 0 {
		return true
	}
	fmt.Fprintf(os.Stderr, "REFUSED: leaked %s processes for %s remain after %d reap attempts; preserving the worktree/tasktmp for manual inspection or retry.\n", r.label, r.id, maxPasses)
	return false
}

// psPgid reads a process's group the way the fallback always has, through ps.
func psPgid(pid string) string {
	out, err := exec.Command("ps", "-o", "pgid=", "-p", pid).Output()
	if err != nil {
		return ""
	}
	return strings.Join(strings.Fields(string(out)), "")
}

func isPlainNumber(s string) bool { return s != "" && strings.Trim(s, "0123456789") == "" }

// reapBackendProcessGroup is the fallback when lsof is missing: signal the tmux pane's process
// group, but never teardown's own and never a group whose leader changed identity meanwhile.
func (r *reaper) reapBackendProcessGroup() {
	warn := func(format string, a ...any) {
		fmt.Fprintf(os.Stderr, "warning: lsof is unavailable; "+format+"\n", a...)
	}
	if r.backend != "tmux" {
		warn("cannot resolve a process-group fallback for %s task %s", r.backend, r.id)
		return
	}
	leader := ""
	if paneOut, err := exec.Command("tmux", "display-message", "-p", "-t", r.target, "#{pane_pid}").Output(); err == nil {
		leader = strings.TrimRight(string(paneOut), "\n")
	}
	if !isPlainNumber(leader) {
		warn("cannot resolve the tmux pane process group for %s", r.id)
		return
	}
	leaderPid, _ := strconv.Atoi(leader)
	leaderStart, ok := processIdentity(leaderPid)
	if !ok {
		warn("cannot identify the tmux pane process group for %s", r.id)
		return
	}
	pgid := psPgid(leader)
	if !isPlainNumber(pgid) || pgid == "0" || pgid == "1" {
		warn("cannot resolve the tmux pane process group for %s", r.id)
		return
	}
	if pgid == psPgid(strconv.Itoa(r.callerPid)) {
		warn("refusing to signal teardown's own process group for %s", r.id)
		return
	}
	if !identityMatches(leaderPid, leaderStart) || psPgid(leader) != pgid {
		return
	}
	group, _ := strconv.Atoi(pgid)
	fmt.Fprintf(os.Stderr, "teardown: reaping leaked %s process group for %s: %s\n", r.label, r.id, pgid)
	_ = syscall.Kill(-group, syscall.SIGTERM)
	time.Sleep(time.Second)
	if identityMatches(leaderPid, leaderStart) && psPgid(leader) == pgid && syscall.Kill(-group, 0) == nil {
		fmt.Fprintf(os.Stderr, "teardown: force-killing leaked %s process group for %s: %s\n", r.label, r.id, pgid)
		_ = syscall.Kill(-group, syscall.SIGKILL)
	}
}

// laneTokenPids lists the processes (never the caller or this command) whose environment holds one of the tokens.
func (r *reaper) laneTokenPids(tokens []string) []int {
	root := os.Getenv("JG_PROC_ROOT_OVERRIDE")
	if root == "" {
		root = "/proc"
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var pids []int
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == r.callerPid || pid == os.Getpid() {
			continue
		}
		env, err := os.ReadFile(fmt.Sprintf("%s/%d/environ", root, pid))
		if err != nil {
			continue // exited, or not ours to read
		}
		padded := append(append([]byte{0}, env...), 0) // match whole entries only
		for _, t := range tokens {
			if bytes.Contains(padded, []byte("\x00JG_LANE_TOKEN="+t+"\x00")) {
				pids = append(pids, pid)
				break
			}
		}
	}
	sort.Ints(pids)
	return pids
}

// reapLaneTokens stops the harness processes the lane recorded. It reports whether none is left.
func (r *reaper) reapLaneTokens(file string) bool {
	raw, err := os.ReadFile(file)
	if file == "" || err != nil {
		return true // nothing recorded
	}
	var tokens []string
	for _, line := range strings.Split(string(raw), "\n") {
		if t := strings.TrimSpace(line); t != "" && strings.Trim(t, "0123456789abcdefABCDEF-") == "" {
			tokens = append(tokens, t)
		}
	}
	if _, err := os.Stat("/proc/self"); err != nil && os.Getenv("JG_PROC_ROOT_OVERRIDE") == "" {
		fmt.Fprintf(os.Stderr, "warning: no /proc on this host; cannot find lane harness processes for %s\n", r.id)
		return true
	}
	for pass := 1; pass <= 3; pass++ {
		pids := r.laneTokenPids(tokens)
		if len(pids) == 0 {
			return true
		}
		ids := map[int]string{}
		for _, pid := range pids {
			if identity, ok := processIdentity(pid); ok {
				ids[pid] = identity
			}
		}
		fmt.Fprintf(os.Stderr, "teardown: reaping leaked lane harness process(es) for %s: %s\n", r.id, joinInts(pids))
		for pid, identity := range ids {
			if identityMatches(pid, identity) {
				_ = syscall.Kill(pid, syscall.SIGTERM)
			}
		}
		time.Sleep(time.Second)
		for pid, identity := range ids {
			if identityMatches(pid, identity) {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if left := r.laneTokenPids(tokens); len(left) > 0 {
		fmt.Fprintf(os.Stderr, "REFUSED: lane harness processes for %s remain after 3 reap attempts: %s; preserving the worktree/tasktmp for manual inspection or retry.\n", r.id, joinInts(left))
		return false
	}
	return true
}
