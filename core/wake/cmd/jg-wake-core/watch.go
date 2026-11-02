// watch.go - the `@watcher-alive` fact: a live watcher holds this home's watcher lock, so an old
// beacon belongs to that watcher's predecessor and nothing is left unwatched. Ported from
// jg_pid_alive, jg_pid_identity and jg_watcher_lock_matches_pid in bin/jg-wake-lib.sh.

package main

import (
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
)

// watcherAlive is jg_pid_alive plus jg_watcher_lock_matches_pid over state/.watch.lock: the locked
// pid is alive, the lock names this home and this bin/jg-watch.sh, and the process's current
// identity is the one the lock recorded, so a reused pid never counts as a watcher.
func (e env) watcherAlive() bool {
	lock := filepath.Join(e.state, ".watch.lock")
	pid := readTrimmed(filepath.Join(lock, "pid"))
	if !pidAlive(pid) {
		return false
	}
	if readTrimmed(filepath.Join(lock, "jg-home")) != e.home {
		return false
	}
	if readTrimmed(filepath.Join(lock, "watcher-path")) != filepath.Join(e.lib, "jg-watch.sh") {
		return false
	}
	recorded := readTrimmed(filepath.Join(lock, "pid-identity"))
	if recorded == "" {
		return false
	}
	current, ok := e.pidIdentity(pid)
	return ok && current == recorded
}

// readTrimmed is `$(cat <path>)`: the file's text without its trailing newlines, empty when it
// cannot be read.
func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(data), "\n")
}

// pidAlive is jg_pid_alive: a numeric pid `kill -0` can signal.
func pidAlive(pid string) bool {
	if pid == "" || strings.Trim(pid, "0123456789") != "" {
		return false
	}
	n, err := strconv.Atoi(pid)
	if err != nil {
		return false
	}
	return syscall.Kill(n, 0) == nil
}

// pidIdentity is jg_pid_identity: a Linux-compatible /proc gives the process start time and its
// full command line, which together make pid reuse a mismatch; elsewhere `ps` supplies the start
// date and command, with a locale- and width-pinned format so the identity written under one locale
// reads back under another.
func (e env) pidIdentity(pid string) (string, bool) {
	statPath := filepath.Join(e.procRoot, pid, "stat")
	cmdPath := filepath.Join(e.procRoot, pid, "cmdline")
	if isFile(statPath) && isFile(cmdPath) {
		stat, err := os.ReadFile(statPath)
		if err != nil {
			return "", false
		}
		s := string(stat)
		end := strings.LastIndexByte(s, ')')
		if end < 0 {
			return "", false
		}
		fields := strings.Fields(s[end+1:])
		if len(fields) < 20 {
			return "", false
		}
		start := fields[19]
		if start == "" || strings.Trim(start, "0123456789") != "" {
			return "", false
		}
		cmdline, err := os.ReadFile(cmdPath)
		if err != nil || len(cmdline) == 0 {
			return "", false
		}
		key := "proc-starttime"
		if runtime.GOOS == "linux" {
			key = "linux-starttime"
		}
		return key + "=" + start + " cmdline-hex=" + hex.EncodeToString(cmdline), true
	}
	cmd := exec.Command("ps", "-p", pid, "-o", "lstart=", "-o", "command=")
	cmd.Env = append(os.Environ(), "COLUMNS=10000", "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil || strings.TrimSpace(string(out)) == "" {
		return "", false
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	for i := range lines {
		lines[i] = strings.TrimLeft(lines[i], " \t")
	}
	return strings.Join(lines, "\n"), true
}
