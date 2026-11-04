package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The wake schedule: how often a supervisor is woken for events that do not need a person now.
// Every number and every class lives in the rule file (`set digest-minutes`, the `@fleet-unchanged`
// rows); this file only answers the two facts those rows ask about.

// fleetFingerprint is what the fleet looks like to a heartbeat: every task's status log (name and
// size, so any appended line changes it) and every task record that exists. A heartbeat over an
// unchanged fingerprint reports nothing new.
func (e env) fleetFingerprint() string {
	var names []string
	for _, pat := range []string{"*.status", "*.meta", "*.captain-hold"} {
		matches, _ := filepath.Glob(filepath.Join(e.state, pat))
		for _, m := range matches {
			size := int64(-1)
			if st, err := os.Stat(m); err == nil && strings.HasSuffix(m, ".status") {
				size = st.Size()
			}
			names = append(names, filepath.Base(m)+"\t"+strconv.FormatInt(size, 10))
		}
	}
	sort.Strings(names)
	sum := sha256.Sum256([]byte(strings.Join(names, "\n")))
	return hex.EncodeToString(sum[:])
}

func (e env) fleetFingerprintFile() string { return filepath.Join(e.state, ".heartbeat-fleet-fp") }

// fleetUnchanged is the `@fleet-unchanged` condition: the fleet looks the way it did when the last
// heartbeat that woke was recorded. With no record the fleet counts as changed, so the first
// heartbeat is never hidden.
func (e env) fleetUnchanged() bool {
	stored := wholeFile(e.fleetFingerprintFile())
	return stored != "" && stored == e.fleetFingerprint()
}

// digestDue answers the batched digest: how many queued rows are waiting for a turn (rows the rules
// do not wake on). Two triggers release the batch as one wake: `set digest-minutes` has passed since the
// last digest (a window opens with the first routine row and closes when none waits), or `set digest-count`
// routine rows have queued since the last digest, whichever comes first. Zero minutes turns the digest
// off; zero count turns only the count trigger off. mark records this digest so the next one is a full
// window away and the count starts again from zero.
func (e env) digestDue(args []string, out, errw io.Writer) int {
	minutes := e.ruleSet("digest-minutes", 0)
	if minutes <= 0 {
		return 1
	}
	stamp := filepath.Join(e.state, ".wake-digest-at")
	last, lastErr := strconv.ParseInt(strings.TrimSpace(wholeFile(stamp)), 10, 64)
	// The count trigger counts rows queued after the last RELEASE, which is not the window stamp: a
	// window opens with the first routine row, so rows queued in that second are still unreleased.
	released := filepath.Join(e.state, ".wake-digest-released")
	relAt, relErr := strconv.ParseInt(strings.TrimSpace(wholeFile(released)), 10, 64)
	seen := map[string]bool{}
	fresh := map[string]bool{} // routine rows queued after the last digest
	for _, row := range readLines(e.queue) {
		f := strings.Split(row, "\t")
		if len(f) < 4 || f[3] == "" {
			continue
		}
		pay := ""
		if len(f) > 4 {
			pay = f[4]
		}
		if e.route(f[2], f[3], pay, 0) != "now" {
			seen[f[2]+"\t"+f[3]] = true
			if at, err := strconv.ParseInt(f[0], 10, 64); relErr != nil || err != nil || at > relAt {
				fresh[f[2]+"\t"+f[3]] = true
			}
		}
	}
	countHit := false
	if n := e.ruleSet("digest-count", 0); n > 0 && int64(len(fresh)) >= n {
		countHit = true
	}
	marking := len(args) == 1 && args[0] == "mark"
	if marking && len(seen) == 0 {
		// Nothing routine waits, so no window is open; the next routine row opens a new one.
		_ = os.Remove(stamp)
	}
	if lastErr != nil && !countHit {
		// No digest yet: the first routine row opens the first window, so a digest is never sent
		// the moment a single routine event arrives.
		if marking && len(seen) > 0 {
			_ = os.WriteFile(stamp, []byte(strconv.FormatInt(e.epoch(), 10)+"\n"), 0o644)
		}
		return 1
	}
	if !countHit && e.epoch()-last < minutes*60 {
		return 1
	}
	if len(seen) == 0 {
		return 1
	}
	if marking {
		_ = os.WriteFile(released, []byte(strconv.FormatInt(e.epoch(), 10)+"\n"), 0o644)
		if os.WriteFile(stamp, []byte(strconv.FormatInt(e.epoch(), 10)+"\n"), 0o644) != nil {
			fmt.Fprintln(errw, "jg-wake-core: cannot record the digest time")
			return 2
		}
	}
	fmt.Fprintln(out, len(seen))
	return 0
}
