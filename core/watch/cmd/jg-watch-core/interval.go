// interval.go - how often an idle home's watcher runs a cycle, and what each check costs.
//
// A watcher cycle starts a chain of shell processes for every window and every check. A
// home with no working lane has nothing for those to find, yet on 12 Nov 13 of 16 homes
// had none and their 29 watchers still used 2.3 cores at rest. This file owns two answers
// the watcher asks:
//
//	interval <poll> <idle> <meta>...
//	    The seconds the watcher waits before its next cycle: <idle> when no record is
//	    watched (the same rule `inventory` applies: a target, and no verified exit), else
//	    <poll>. <idle> is never shorter than <poll>, so a bad setting cannot make an idle
//	    home check more often than a busy one. A value that is not a whole number of
//	    seconds, or is zero, reads as its default (15 and 300).
//
//	cost <state> <key> <before> <after> [budget]
//	    Records the CPU seconds one check used. <before> and <after> are the output of
//	    bash's `times` taken around the check; the answer is the change in its children's
//	    user plus system time. The cost is added to <state>/.watch-cost, one row per
//	    minute and key: `<minute-epoch> <key> <cpu-seconds>`; rows older than an hour are
//	    dropped. When the minute's total for the key passes [budget] (default 5) seconds,
//	    one line naming the key is printed, so the caller can raise it.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultPoll   = 15
	defaultIdle   = 300
	defaultBudget = 5.0
	costKeep      = time.Hour
)

// seconds reads a whole positive number of seconds, else the fallback.
func seconds(value string, fallback int64) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

// cycleInterval is the wait before the next cycle for the watched set the records name.
func cycleInterval(poll, idle int64, records []*metaRecord) int64 {
	if idle < poll {
		idle = poll
	}
	if len(build(records).order) == 0 {
		return idle
	}
	return poll
}

func runInterval(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: jg-watch-core interval <poll> <idle> <meta>...")
		return 2
	}
	records := make([]*metaRecord, 0, len(args)-2)
	for _, path := range args[2:] {
		records = append(records, readMeta(path))
	}
	fmt.Println(cycleInterval(seconds(args[0], defaultPoll), seconds(args[1], defaultIdle), records))
	return 0
}

// childCPU reads the children's user plus system seconds from `times` output: its second
// line holds the children's times, as `0m0.010s 0m0.020s`.
func childCPU(path string) (float64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) < 2 {
		return 0, fmt.Errorf("%s: no children line in times output", path)
	}
	total := 0.0
	fields := strings.Fields(lines[1])
	if len(fields) != 2 {
		return 0, fmt.Errorf("%s: want user and system times, got %q", path, lines[1])
	}
	for _, field := range fields {
		minutes, rest, ok := strings.Cut(strings.TrimSuffix(field, "s"), "m")
		if !ok {
			return 0, fmt.Errorf("%s: unreadable time %q", path, field)
		}
		m, errM := strconv.ParseFloat(minutes, 64)
		s, errS := strconv.ParseFloat(rest, 64)
		if errM != nil || errS != nil {
			return 0, fmt.Errorf("%s: unreadable time %q", path, field)
		}
		total += m*60 + s
	}
	return total, nil
}

// costRow is one (minute, key) total of the cost record.
type costRow struct {
	minute int64
	key    string
	cpu    float64
}

func readCost(path string) []costRow {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var rows []costRow
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) != 3 {
			continue
		}
		minute, errM := strconv.ParseInt(f[0], 10, 64)
		cpu, errC := strconv.ParseFloat(f[2], 64)
		if errM != nil || errC != nil {
			continue
		}
		rows = append(rows, costRow{minute, f[1], cpu})
	}
	return rows
}

// addCost folds one check's cost into the rows and returns the key's total for its
// minute. Rows older than costKeep are dropped.
func addCost(rows []costRow, now time.Time, key string, cpu float64) ([]costRow, float64) {
	minute := now.Unix() / 60 * 60
	oldest := now.Add(-costKeep).Unix()
	kept := rows[:0]
	total := cpu
	found := false
	for _, row := range rows {
		if row.minute < oldest {
			continue
		}
		if row.minute == minute && row.key == key {
			row.cpu += cpu
			total = row.cpu
			found = true
		}
		kept = append(kept, row)
	}
	if !found {
		kept = append(kept, costRow{minute, key, cpu})
	}
	sort.SliceStable(kept, func(i, j int) bool { return kept[i].minute < kept[j].minute })
	return kept, total
}

func runCost(args []string) int {
	if len(args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: jg-watch-core cost <state> <key> <before> <after> [budget]")
		return 2
	}
	state, key := args[0], args[1]
	if strings.ContainsAny(key, " \t\n") || key == "" {
		fmt.Fprintf(os.Stderr, "jg-watch-core cost: key %q must be one word\n", key)
		return 2
	}
	before, err := childCPU(args[2])
	if err == nil {
		var after float64
		if after, err = childCPU(args[3]); err == nil {
			budget := defaultBudget
			if len(args) > 4 {
				if b, perr := strconv.ParseFloat(args[4], 64); perr == nil && b > 0 {
					budget = b
				}
			}
			cpu := after - before
			if cpu < 0 {
				cpu = 0
			}
			path := filepath.Join(state, ".watch-cost")
			rows, total := addCost(readCost(path), time.Now(), key, cpu)
			var b strings.Builder
			for _, row := range rows {
				fmt.Fprintf(&b, "%d %s %.3f\n", row.minute, row.key, row.cpu)
			}
			tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
			if err = os.WriteFile(tmp, []byte(b.String()), 0o600); err == nil {
				if err = os.Rename(tmp, path); err == nil {
					if total > budget {
						fmt.Printf("check %s used %.1f CPU seconds in one minute (budget %.1f)\n", key, total, budget)
					}
					return 0
				}
				_ = os.Remove(tmp)
			}
		}
	}
	fmt.Fprintf(os.Stderr, "jg-watch-core cost: %v\n", err)
	return 1
}
