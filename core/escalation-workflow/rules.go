package main

// The five escalation behaviours the wait workflow applies, read from the shared rule file
// core/bus/workflows/escalation-optimization.json (the shell tick reads the same file, so one
// number has one owner): priority class, budget per target, back-off, coalescing into a digest
// and auto-resolve. Rungs, timers and who is told stay in escalation-wait-timers.json.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/dapr/durabletask-go/workflow"
)

type rules struct {
	Spec struct {
		Classes map[string]struct {
			Wakes        *bool `json:"wakes"`
			Budget       *bool `json:"budget"`
			FlushSeconds int   `json:"flushSeconds"`
		} `json:"classes"`
		Priority []struct{ Class, Kind, Key, Payload string } `json:"priority"`
		Budget   struct {
			PerHour, WindowSeconds int
			Targets                map[string]int
		} `json:"budget"`
		Targets  []struct{ Key, Target string }   `json:"targets"`
		Backoff  struct{ Factor, CapSeconds int } `json:"backoff"`
		Coalesce struct {
			WindowSeconds, MaxEvents int
			Groups                   []struct{ Name, Key string }
		} `json:"coalesce"`
		AutoResolve struct{ Fingerprint string } `json:"autoResolve"`
		Workflow    struct{ HorizonSeconds int } `json:"workflow"`
	} `json:"spec"`
}

func stateDir() string {
	if s := os.Getenv("JG_STATE_OVERRIDE"); s != "" {
		return s
	}
	return filepath.Join(os.Getenv("JG_HOME"), "state")
}

// loadRules reads the rule file in force: JG_ESCALATION_OPT, the home's config copy, else the one
// beside the workflow definition. A home with none gets nil and the ladder runs without the five.
func loadRules() (*rules, error) {
	home := os.Getenv("JG_CONFIG_OVERRIDE")
	if home == "" {
		home = filepath.Join(os.Getenv("JG_HOME"), "config")
	}
	for _, p := range []string{os.Getenv("JG_ESCALATION_OPT"), filepath.Join(home, "escalation-optimization.json"),
		filepath.Join(filepath.Dir(os.Getenv("JG_ESCALATION_WORKFLOW")), "escalation-optimization.json")} {
		raw, err := os.ReadFile(p)
		if p == "" || errors.Is(err, os.ErrNotExist) {
			continue
		}
		var r rules
		if err == nil {
			err = json.Unmarshal(raw, &r)
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		return &r, nil
	}
	return nil, nil
}

// glob matches the rule file's shell-style patterns (* and ?), as the shell reader does.
func glob(pat, s string) bool {
	re := regexp.QuoteMeta(pat)
	re = strings.NewReplacer(`\*`, ".*", `\?`, ".").Replace(re)
	ok, _ := regexp.MatchString("(?s)^"+re+"$", s)
	return ok
}

// fingerprint is the state an escalation was raised about: the last line of the lane's status
// file, or "absent". A change in it auto-resolves the episode.
func (r *rules) fingerprint(task string) string {
	tpl := r.Spec.AutoResolve.Fingerprint
	if tpl == "" {
		return ""
	}
	p := strings.NewReplacer("{state}", stateDir(), "{task}", task).Replace(tpl)
	raw, err := os.ReadFile(p)
	if err != nil {
		return "absent"
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	return lines[len(lines)-1]
}

func (r *rules) class(kind, key, payload string) string {
	c := "now"
	for _, p := range r.Spec.Priority {
		if glob(p.Kind, kind) && glob(p.Key, key) && glob(p.Payload, payload) {
			c = p.Class
			break
		}
	}
	if k, ok := r.Spec.Classes[c]; !ok || k.Wakes == nil {
		return "now"
	}
	return c
}

func (r *rules) group(key string) string {
	for _, g := range r.Spec.Coalesce.Groups {
		if glob(g.Key, key) {
			return g.Name
		}
	}
	return "other"
}

func (r *rules) target(key string) string {
	for _, t := range r.Spec.Targets {
		if glob(t.Key, key) {
			return t.Target
		}
	}
	return "main"
}

// Admission asks whether a due rung may wake someone now.
type Admission struct {
	Rung, Task, Key, Payload, Fingerprint string
}

// Verdict is the answer: deliver, drop (silent), resolve (state changed) or defer into a group
// that flushes as one digest after WaitSecs.
type Verdict struct {
	Action   string `json:"action"`
	Group    string `json:"group"`
	WaitSecs int    `json:"waitSecs"`
}

// withLock serialises the budget and pending files across the activities of every episode.
func withLock(dir string, f func() error) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	return f()
}

func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintln(f, line)
	return err
}

func readRows(path string) []string {
	raw, _ := os.ReadFile(path)
	if len(raw) == 0 {
		return nil
	}
	return strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
}

// Admit applies priority, auto-resolve, coalescing and the per-target budget to one due rung.
// The files it keeps are the shell optimiser's (state/.escalation-opt), so a budget is spent once
// whichever path woke the receiver.
func Admit(ctx workflow.ActivityContext) (any, error) {
	var a Admission
	if err := ctx.GetInput(&a); err != nil {
		return nil, err
	}
	r, err := loadRules()
	if r == nil || err != nil {
		return Verdict{Action: "deliver"}, err
	}
	if a.Fingerprint != "" && r.fingerprint(a.Task) != a.Fingerprint {
		return Verdict{Action: "resolve"}, nil
	}
	class := r.class("check", a.Key, a.Payload)
	if class == "silent" {
		return Verdict{Action: "drop"}, nil
	}
	dir := filepath.Join(stateDir(), ".escalation-opt")
	now := time.Now().Unix()
	v := Verdict{Action: "deliver"}
	err = withLock(dir, func() error {
		hold := func(held string) error {
			g := r.group(a.Key)
			v = Verdict{Action: "defer", Group: g}
			if err := os.MkdirAll(filepath.Join(dir, "pending"), 0o755); err != nil {
				return err
			}
			p := filepath.Join(dir, "pending", g)
			if err := appendLine(p, fmt.Sprintf("%d\t%s\t%s\t%s\t1", now, held, a.Key, a.Payload)); err != nil {
				return err
			}
			rows := readRows(p)
			var oldest int64
			fmt.Sscanf(rows[0], "%d", &oldest)
			win := r.Spec.Coalesce.WindowSeconds
			if held == "digest" && r.Spec.Classes["digest"].FlushSeconds > 0 {
				win = r.Spec.Classes["digest"].FlushSeconds
			}
			if v.WaitSecs = int(oldest) + win - int(now); v.WaitSecs < 0 || (r.Spec.Coalesce.MaxEvents > 0 && len(rows) >= r.Spec.Coalesce.MaxEvents) {
				v.WaitSecs = 0
			}
			return nil
		}
		if *r.Spec.Classes[class].Wakes == false {
			return hold(class)
		}
		if b := r.Spec.Classes[class].Budget; b == nil || *b {
			target := r.target(a.Key)
			limit, ok := r.Spec.Budget.Targets[target]
			if !ok {
				limit = r.Spec.Budget.PerHour
			}
			used := 0
			for _, row := range readRows(filepath.Join(dir, "budget", target)) {
				var at int64
				if fmt.Sscanf(row, "%d", &at); at > now-int64(r.Spec.Budget.WindowSeconds) {
					used++
				}
			}
			if used >= limit {
				return hold("batch")
			}
			if err := os.MkdirAll(filepath.Join(dir, "budget"), 0o755); err != nil {
				return err
			}
			return appendLine(filepath.Join(dir, "budget", target), fmt.Sprint(now))
		}
		return nil
	})
	return v, err
}

// Flush emits one digest wake for a group whose window has ended (or that holds maxEvents rows)
// and empties it. The episode that finds the group already flushed, or not yet due, does nothing.
func Flush(ctx workflow.ActivityContext) (any, error) {
	var group string
	if err := ctx.GetInput(&group); err != nil {
		return nil, err
	}
	r, err := loadRules()
	if r == nil || err != nil {
		return "", err
	}
	p := filepath.Join(stateDir(), ".escalation-opt", "pending", group)
	var line string
	err = withLock(filepath.Join(stateDir(), ".escalation-opt"), func() error {
		rows := readRows(p)
		if len(rows) == 0 {
			return nil
		}
		f := strings.Split(rows[0], "\t")
		var oldest int64
		fmt.Sscanf(f[0], "%d", &oldest)
		win := r.Spec.Coalesce.WindowSeconds
		if f[1] == "digest" && r.Spec.Classes["digest"].FlushSeconds > 0 {
			win = r.Spec.Classes["digest"].FlushSeconds
		}
		if time.Now().Unix() < oldest+int64(win) && (r.Spec.Coalesce.MaxEvents == 0 || len(rows) < r.Spec.Coalesce.MaxEvents) {
			return nil
		}
		n := map[string]int{}
		for _, row := range rows {
			k := strings.Split(row, "\t")[2]
			if i := strings.LastIndex(k, "-"); i >= 0 {
				k = k[:i]
			}
			n[k]++
		}
		var kinds []string
		for k, c := range n {
			kinds = append(kinds, fmt.Sprintf("%dx %s", c, k))
		}
		sort.Strings(kinds)
		first := strings.Split(rows[0], "\t")[3]
		if i := strings.Index(first, " evidence=["); i >= 0 {
			first = first[:i]
		}
		if len(first) > 100 {
			first = first[:100]
		}
		line = fmt.Sprintf("check: escalation-digest %s (%d events: %s) evidence=[%d rows since %d; first: %s] action=[review the batch once; no per-event reply needed]",
			group, len(rows), strings.Join(kinds, ", "), len(rows), oldest, first)
		// Delivered before the rows go, so a failed delivery retries with the rows still held.
		if _, err := runDeliver(ctx.Context(), "digest", group, "escalation-digest-"+group, "digest", line); err != nil {
			return err
		}
		return os.Remove(p)
	})
	return line, err
}
