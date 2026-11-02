// jg-escalation-worker runs the stuck-worker escalation ladder as a Dapr workflow.
//
// One workflow instance is one wait episode. It sleeps on durable timers, one per rung of
// the ladder core/bus/workflows/escalation-wait-timers.json declares, delivers each rung
// through an activity when its timer fires, and stops the moment the owner raises the
// `cleared` event (auto-resolve). The timers live in the Dapr scheduler, so a restart of the
// worker or the sidecar loses none of them.
//
//	jg-escalation-worker serve                                    run the worker (needs the sidecar)
//	jg-escalation-worker start <class> <task> <key> [payload]   schedule an episode; the key is its id, the payload feeds the priority rules
//	jg-escalation-worker clear <key>                              the owner cleared the wait
//	jg-escalation-worker status <key>                             runtime status and the rungs fired
//
// Environment: DAPR_GRPC_PORT (the sidecar), JG_ESCALATION_WORKFLOW (the definition; default is
// the repository's), JG_WORKFLOW_DELIVER (the command, with any fixed leading words, an activity runs to
// deliver a rung, called as `<cmd> <rung> <task> <key> <class> <actor>`), and each timer's own override variable named
// in the definition (JG_WAIT_ALERT_SECS and so on), so one number has one owner.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/dapr/durabletask-go/workflow"
	dapr "github.com/dapr/go-sdk/client"
)

// Rung is one step of the ladder: when it fires (seconds from the episode's start) and
// who it tells.
type Rung struct {
	Rung  string `json:"rung"`
	Secs  int    `json:"secs"`
	Actor string `json:"actor"`
}

// Episode is the workflow's input: the lane, its key and the whole ladder, resolved from the
// definition once at start so a replay never reads a file.
type Episode struct {
	Class       string `json:"class"`
	Task        string `json:"task"`
	Key         string `json:"key"`
	Rungs       []Rung `json:"rungs"`
	RealertSecs int    `json:"realertSecs"`
	// The behaviours of the rule file, resolved at start: re-alerts back off by BackoffFactor up
	// to BackoffCap and stop at Horizon; Payload feeds the priority rules; Fingerprint is the state
	// the wait was raised about.
	BackoffFactor int    `json:"backoffFactor"`
	BackoffCap    int    `json:"backoffCap"`
	Horizon       int    `json:"horizon"`
	Payload       string `json:"payload"`
	Fingerprint   string `json:"fingerprint"`
}

// Result is the workflow's output: whether the owner cleared it, whether its state changed under
// it (auto-resolve), the rungs that woke someone and the rungs held back or dropped.
type Result struct {
	Cleared  bool     `json:"cleared"`
	Resolved bool     `json:"resolved"`
	Fired    []string `json:"fired"`
	Held     []string `json:"held"`
}

const (
	workflowName   = "Escalation"
	deliverTimeout = 30 * time.Second
)

// Escalation is the workflow. Everything it decides is deterministic: it reads time only from
// the workflow context and calls out only through the delivery activity.
func Escalation(ctx *workflow.WorkflowContext) (any, error) {
	var in Episode
	if err := ctx.GetInput(&in); err != nil {
		return nil, err
	}
	start := ctx.CurrentTimeUTC()
	cleared := ctx.WaitForExternalEvent("cleared", -1)
	res := Result{Fired: []string{}, Held: []string{}}

	// publish shows the rungs that woke someone, then those held back, in the runtime status.
	publish := func() { ctx.SetCustomStatus(strings.Join(res.Fired, ",") + " held=" + strings.Join(res.Held, ",")) }

	// at runs <name> at start+secs, or reports the owner cleared the wait first.
	at := func(name, actor string, secs int) (bool, error) {
		if delay := start.Add(time.Duration(secs) * time.Second).Sub(ctx.CurrentTimeUTC()); delay > 0 {
			timer := ctx.CreateTimer(delay, workflow.WithTimerName(name))
			idx, err := ctx.Select(timer, cleared)
			if err != nil {
				return false, err
			}
			if idx == 1 {
				return true, cleared.Await(nil)
			}
		}
		retry := &workflow.RetryPolicy{MaxAttempts: 3, InitialRetryInterval: time.Second, BackoffCoefficient: 2, MaxRetryInterval: 10 * time.Second}
		var v Verdict
		if err := ctx.CallActivity(Admit, workflow.WithActivityInput(Admission{Rung: name, Task: in.Task, Key: in.Key, Payload: in.Payload, Fingerprint: in.Fingerprint})).Await(&v); err != nil {
			return false, fmt.Errorf("admit %s: %w", name, err)
		}
		switch v.Action {
		case "resolve": // the state the wait was raised about changed: close it and withdraw its wakes
			res.Resolved = true
			_ = ctx.CallActivity(Deliver, workflow.WithActivityInput(Delivery{Rung: "withdraw", Task: in.Task, Key: in.Key, Class: in.Class})).Await(nil)
			return true, nil
		case "drop":
			res.Held = append(res.Held, name+":silent")
			publish()
			return false, nil
		case "defer": // coalesce: wait out the group's window, then one digest covers every held row
			res.Held = append(res.Held, name+":"+v.Group)
			publish()
			if v.WaitSecs > 0 {
				timer := ctx.CreateTimer(time.Duration(v.WaitSecs)*time.Second, workflow.WithTimerName("flush-"+v.Group))
				idx, err := ctx.Select(timer, cleared)
				if err != nil {
					return false, err
				}
				if idx == 1 {
					return true, cleared.Await(nil)
				}
			}
			var line string
			if err := ctx.CallActivity(Flush, workflow.WithActivityInput(v.Group), workflow.WithActivityRetryPolicy(retry)).Await(&line); err != nil {
				return false, fmt.Errorf("flush %s: %w", v.Group, err)
			}
			if line != "" {
				res.Fired = append(res.Fired, "digest-"+v.Group)
				publish()
			}
			return false, nil
		}
		err := ctx.CallActivity(Deliver, workflow.WithActivityInput(Delivery{Rung: name, Actor: actor, Task: in.Task, Key: in.Key, Class: in.Class}),
			workflow.WithActivityRetryPolicy(retry)).Await(nil)
		if err != nil {
			return false, fmt.Errorf("deliver %s: %w", name, err)
		}
		res.Fired = append(res.Fired, name)
		publish()
		return false, nil
	}

	last := 0
	for _, r := range in.Rungs {
		done, err := at(r.Rung, r.Actor, r.Secs)
		if err != nil || done {
			res.Cleared = done && !res.Resolved
			return res, err
		}
		last = r.Secs
	}
	// Re-alerts back off: each interval is the last times the factor, up to the cap, until the
	// episode's horizon. Without the rule file the factor is 1 and the cadence is flat.
	gap := in.RealertSecs
	for i := 1; gap > 0 && last+gap <= in.Horizon; i++ {
		last += gap
		done, err := at(fmt.Sprintf("re-alert-%d", i), "", last)
		if err != nil || done || res.Resolved {
			res.Cleared = done && !res.Resolved
			return res, err
		}
		if gap *= max(in.BackoffFactor, 1); in.BackoffCap > 0 && gap > in.BackoffCap {
			gap = max(in.BackoffCap, in.RealertSecs)
		}
	}
	return res, nil
}

// Delivery is the activity's input.
type Delivery struct {
	Rung  string `json:"rung"`
	Actor string `json:"actor"`
	Task  string `json:"task"`
	Key   string `json:"key"`
	Class string `json:"class"`
}

// Deliver runs the configured delivery command for one rung. A failure comes back with the
// command's own output, so a retry and the final failure both show the real cause.
func Deliver(ctx workflow.ActivityContext) (any, error) {
	var d Delivery
	if err := ctx.GetInput(&d); err != nil {
		return nil, err
	}
	return runDeliver(ctx.Context(), d.Rung, d.Task, d.Key, d.Class, d.Actor)
}

// runDeliver runs the delivery command for one rung (or the digest, or the withdraw of a resolved
// episode's wakes).
func runDeliver(parent context.Context, rung, task, key, class, actor string) (any, error) {
	cmdPath := os.Getenv("JG_WORKFLOW_DELIVER")
	if cmdPath == "" {
		return nil, errors.New("JG_WORKFLOW_DELIVER is not set: no command to deliver the rung with")
	}
	// A delivery that hangs would hold the rung forever; the retry policy needs it to fail.
	runCtx, cancel := context.WithTimeout(parent, deliverTimeout)
	defer cancel()
	words := strings.Fields(cmdPath)
	argv := append(words[1:], rung, task, key, class, actor)
	out, err := exec.CommandContext(runCtx, words[0], argv...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w: %s", cmdPath, rung, err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

type definition struct {
	Spec struct {
		Timers map[string]struct {
			Seconds int    `json:"seconds"`
			Env     string `json:"env"`
		} `json:"timers"`
		Ladders map[string]struct {
			Rungs []struct {
				Rung  string `json:"rung"`
				Timer string `json:"timer"`
				Actor string `json:"actor"`
			} `json:"rungs"`
			ReAlert string `json:"re-alert"`
		} `json:"ladders"`
	} `json:"spec"`
}

// defaultHorizon bounds how long an episode lives when nobody clears it: a day is already more
// than the owner chain needs, and the episode ends cleanly. The rule file may set its own.
const defaultHorizon = 86400

// episode resolves the ladder for <class> from the definition, with each timer's override.
func episode(class, task, key, payload string) (Episode, error) {
	path := os.Getenv("JG_ESCALATION_WORKFLOW")
	if path == "" {
		return Episode{}, errors.New("JG_ESCALATION_WORKFLOW is not set: no definition to read the ladder from")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return Episode{}, err
	}
	var def definition
	if err := json.Unmarshal(raw, &def); err != nil {
		return Episode{}, fmt.Errorf("%s: %w", path, err)
	}
	ladder, ok := def.Spec.Ladders[class]
	if !ok {
		return Episode{}, fmt.Errorf("%s has no %q ladder", path, class)
	}
	secs := func(timer string) (int, error) {
		t, ok := def.Spec.Timers[timer]
		if !ok {
			return 0, fmt.Errorf("%s names timer %q but defines none", path, timer)
		}
		n := t.Seconds
		if v := os.Getenv(t.Env); t.Env != "" && v != "" {
			var perr error
			if n, perr = strconv.Atoi(v); perr != nil {
				return 0, fmt.Errorf("%s=%q is not whole seconds", t.Env, v)
			}
		}
		if n <= 0 {
			return 0, fmt.Errorf("timer %q is %d seconds, want a positive number", timer, n)
		}
		return n, nil
	}
	ep := Episode{Class: class, Task: task, Key: key, Payload: payload, Horizon: defaultHorizon}
	r, err := loadRules()
	if err != nil {
		return Episode{}, err
	}
	if r != nil {
		ep.BackoffFactor, ep.BackoffCap, ep.Fingerprint = r.Spec.Backoff.Factor, r.Spec.Backoff.CapSeconds, r.fingerprint(task)
		if h := r.Spec.Workflow.HorizonSeconds; h > 0 {
			ep.Horizon = h
		}
	}
	for _, r := range ladder.Rungs {
		n, err := secs(r.Timer)
		if err != nil {
			return Episode{}, err
		}
		ep.Rungs = append(ep.Rungs, Rung{Rung: r.Rung, Secs: n, Actor: r.Actor})
	}
	if ladder.ReAlert != "" {
		n, err := secs(ladder.ReAlert)
		if err != nil {
			return Episode{}, err
		}
		ep.RealertSecs = n
	}
	return ep, nil
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: jg-escalation-worker serve | start <class> <task> <key> | clear <key> | status <key>")
	}
	client, err := dapr.NewWorkflowClient()
	if err != nil {
		return fmt.Errorf("no sidecar to talk to (DAPR_GRPC_PORT=%q): %w", os.Getenv("DAPR_GRPC_PORT"), err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	switch args[0] {
	case "serve":
		reg := workflow.NewRegistry()
		if err := reg.AddWorkflowN(workflowName, Escalation); err != nil {
			return err
		}
		for _, act := range []workflow.Activity{Deliver, Admit, Flush} {
			if err := reg.AddActivity(act); err != nil {
				return err
			}
		}
		if err := client.StartWorker(ctx, reg); err != nil {
			return fmt.Errorf("worker did not start: %w", err)
		}
		fmt.Println("jg-escalation-worker: serving")
		<-ctx.Done()
		return nil
	case "start":
		if len(args) != 4 && len(args) != 5 {
			return errors.New("usage: jg-escalation-worker start <class> <task> <key> [payload]")
		}
		ep, err := episode(args[1], args[2], args[3], strings.Join(args[4:], " "))
		if err != nil {
			return err
		}
		id, err := client.ScheduleWorkflow(ctx, workflowName, workflow.WithInstanceID(args[3]), workflow.WithInput(ep))
		if err != nil {
			return fmt.Errorf("start %s: %w", args[3], err)
		}
		fmt.Println(id)
		return nil
	case "clear":
		if len(args) != 2 {
			return errors.New("usage: jg-escalation-worker clear <key>")
		}
		return client.RaiseEvent(ctx, args[1], "cleared")
	case "status":
		if len(args) != 2 {
			return errors.New("usage: jg-escalation-worker status <key>")
		}
		md, err := client.FetchWorkflowMetadata(ctx, args[1], workflow.WithFetchPayloads(true))
		if err != nil {
			return err
		}
		fmt.Printf("%s fired=%s output=%s\n", md.String(), md.CustomStatus.GetValue(), md.Output.GetValue())
		return nil
	}
	return fmt.Errorf("unknown command %q", args[0])
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "jg-escalation-worker:", err)
		os.Exit(1)
	}
}
