package main

// health.go is the bus health run: `jg-bus health run` logs in as every account the machine's accounts
// file carries and asks JetStream a question only a working account can answer. It exists because a
// failed reload (error 10028) leaves the server up, its unit "active" and JetStream off for the
// accounts it did not reach, and no other check tests an account from the client side.
//
// It uses no model, no wake path and no watcher: those are the things it tests. A systemd timer
// starts it every 60 seconds.
//
// State machine, after Gatus's thresholds: two failed runs in a row open one outage per service, two
// passing runs close it. One message at the start and one at the end, grouped per service, so 26
// failed accounts send one message. A message the owner did not receive stays queued and is sent by
// the next run; the failure is logged and the run exits 1. The record is $STATE/health.json; each
// closed outage adds one row to $STATE/outage-history.jsonl.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	healthFailsToOpen   = 2
	healthPassesToClose = 2
)

type outage struct {
	Fails     int      `json:"fails"`
	Passes    int      `json:"passes"`
	FirstFail int64    `json:"first_fail,omitempty"`
	Open      bool     `json:"open"`
	Since     int64    `json:"since,omitempty"`
	Members   []string `json:"members,omitempty"`
	Cause     string   `json:"cause,omitempty"`
	Unsent    []string `json:"unsent,omitempty"`
}

type healthRecord struct {
	At       int64              `json:"at"`
	Services map[string]*outage `json:"services"`
}

// finding is one failed test: the member that failed and why.
type finding struct{ member, why string }

var serviceLabels = map[string]string{"bus": "the event system"}

func (a *app) health(args []string) int {
	switch {
	case len(args) == 0 || args[0] == "run":
		return a.healthRun(a.runChecks())
	}
	return die("usage: jg-bus health [run]")
}

// runChecks runs every test once and returns the failures of each service (nil when it passed).
func (a *app) runChecks() map[string][]finding {
	return map[string][]finding{"bus": a.busFindings()}
}

// step feeds one run's failures to a service's counters and says what changed: "open", "close" or "".
func (o *outage) step(failed []finding, now int64) string {
	if len(failed) > 0 {
		if o.Fails == 0 {
			o.FirstFail = now
		}
		o.Fails, o.Passes = o.Fails+1, 0
		o.Cause = failed[0].why
		o.Members = o.Members[:0]
		for _, f := range failed {
			o.Members = append(o.Members, f.member)
			if f.why != o.Cause {
				o.Cause = fmt.Sprintf("%d different faults, the first: %s", len(failed), failed[0].why)
			}
		}
		if !o.Open && o.Fails >= healthFailsToOpen {
			o.Open, o.Since = true, o.FirstFail
			return "open"
		}
		return ""
	}
	o.Fails, o.Passes = 0, o.Passes+1
	if o.Open && o.Passes >= healthPassesToClose {
		o.Open = false
		return "close"
	}
	return ""
}

func (a *app) healthRun(results map[string][]finding) int {
	now := time.Now().Unix()
	if v, err := strconv.ParseInt(os.Getenv("JG_HEALTH_NOW"), 10, 64); err == nil {
		now = v
	}
	path := filepath.Join(a.state, "health.json")
	rec := healthRecord{Services: map[string]*outage{}}
	_ = json.Unmarshal([]byte(readFileString(path)), &rec)
	status := 0
	for name, failed := range results {
		o := rec.Services[name]
		if o == nil {
			o = &outage{}
			rec.Services[name] = o
		}
		label := serviceLabels[name]
		switch o.step(failed, now) {
		case "open":
			o.Unsent = append(o.Unsent, startText(label, o, a.repair(name)))
		case "close":
			o.Unsent = append(o.Unsent, endText(label, o, now))
			row := map[string]any{"service": name, "accounts": o.Members, "start": o.Since, "end": now, "cause": o.Cause}
			if err := appendLine(filepath.Join(a.state, "outage-history.jsonl"), toJSON(row)); err != nil {
				a.noteFailure("outage history", err.Error())
				status = 1
			}
			o.Members, o.Cause = nil, ""
		}
		for len(o.Unsent) > 0 {
			if err := a.pushOwner(o.Unsent[0]); err != nil && !errors.Is(err, errNoChat) {
				a.noteFailure("health alert for "+label, err.Error())
				say("jg-bus: health: the owner did not get the outage message for %s: %v", label, err)
				status = 1
				break
			}
			o.Unsent = o.Unsent[1:]
		}
		fmt.Printf("health: %s: %d failing, open=%v\n", name, len(failed), o.Open)
	}
	rec.At = now
	raw, _ := json.Marshal(rec)
	if err := os.WriteFile(path+".new", raw, 0o644); err == nil {
		err = os.Rename(path+".new", path)
		if err != nil {
			status = 1
		}
	} else {
		say("jg-bus: health: cannot write %s: %v", path, err)
		status = 1
	}
	return status
}

func (a *app) repair(service string) string {
	return "restart the bus with: systemctl --user restart " + natsUnit()
}

func hhmm(at int64) string { return time.Unix(at, 0).Format("15:04") }

func startText(label string, o *outage, repair string) string {
	who := strings.Join(o.Members, ", ")
	if len(o.Members) > 5 {
		who = fmt.Sprintf("%s and %d more", strings.Join(o.Members[:5], ", "), len(o.Members)-5)
	}
	return fmt.Sprintf("Outage started: %s. %s. Affected: %s. Since %s host time. To repair: %s.", label, o.Cause, who, hhmm(o.Since), repair)
}

func endText(label string, o *outage, now int64) string {
	mins := (now - o.Since + 30) / 60
	return fmt.Sprintf("Outage ended: %s works again. It lasted %d min, from %s to %s host time.", label, mins, hhmm(o.Since), hhmm(now))
}

// accountLogin is one JetStream account of the accounts file and the password its user presents.
type accountLogin struct{ name, password string }

var userLine = regexp.MustCompile(`user: ([A-Za-z0-9._-]+), password: "([^"]*)"`)

// jsAccounts lists the accounts that reserve JetStream: the ones a client must be able to use.
func jsAccounts(accounts string) []accountLogin {
	var out []accountLogin
	reserves := false
	for _, line := range strings.Split(accounts, "\n") {
		if accountLine.MatchString(line) {
			reserves = false
		}
		if jsReservation.MatchString(line) {
			reserves = true
		}
		if m := userLine.FindStringSubmatch(line); m != nil && reserves {
			out = append(out, accountLogin{m[1], m[2]})
		}
	}
	return out
}

// busFindings logs in as every account and lists streams. `nats account info` is not the test: it
// exits 0 and prints "JetStream is not supported in this account" when the account is off.
func (a *app) busFindings() []finding {
	file := a.accountsFile()
	logins := jsAccounts(readFileString(file))
	if len(logins) == 0 {
		return []finding{{file, "the accounts file holds no JetStream account"}}
	}
	got := make([]finding, len(logins))
	var wg sync.WaitGroup
	slots := make(chan struct{}, 8)
	for i, l := range logins {
		wg.Add(1)
		slots <- struct{}{}
		go func() {
			defer func() { <-slots; wg.Done() }()
			p := &part{url: a.cfgOr("nats-url", ""), env: []string{"NATS_USER=" + l.name, "NATS_PASSWORD=" + l.password}}
			_, errText, err := p.nats("--timeout", "5s", "stream", "ls", "-n")
			if err != nil {
				got[i] = finding{l.name, accountFault(errText, err)}
			}
		}()
	}
	wg.Wait()
	var failed []finding
	for _, f := range got {
		if f.why != "" {
			failed = append(failed, f)
		}
	}
	return failed
}

// accountFault names what a failed login or JetStream call means, in plain words.
func accountFault(errText string, err error) string {
	switch low := strings.ToLower(errText); {
	case strings.Contains(low, "no responders"):
		return "JetStream is off for the account (the server is up, as after error 10028)"
	case strings.Contains(low, "authorization violation"):
		return "the server refused the account's login"
	case strings.Contains(low, "no servers available"), strings.Contains(low, "connection refused"):
		return "the server is unreachable"
	case strings.Contains(low, "timeout"), strings.Contains(low, "deadline"):
		return "the server did not answer in 5 seconds"
	case strings.TrimSpace(errText) == "":
		return "the nats client failed: " + err.Error()
	}
	return detail(errText)
}
