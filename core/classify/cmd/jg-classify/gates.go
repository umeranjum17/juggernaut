package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// The gate overlay. A decision key that is the id of an owner question (a gate in the home's store)
// is read from that gate and from nothing else: it is open exactly while the gate is open, so the
// status log is no second record of an owner call. A worker's own key, one that is no gate id, folds
// as before. JG_CLASSIFY_GATE_STATES names a command that prints "<gate id>\t<open|closed>" per
// question of the home whose path it is given (bin/jg-gate-states.sh); unset or failing, the overlay
// steps aside and the fold is the status log's alone.
var gateHome string // the home of the status file being folded
var gateMemo = map[string]map[string]string{}

// gateStates is the question states of one home, read once per process.
func gateStates(home string) map[string]string {
	if states, ok := gateMemo[home]; ok {
		return states
	}
	states := map[string]string{}
	gateMemo[home] = states
	cmd := os.Getenv("JG_CLASSIFY_GATE_STATES")
	if cmd == "" || home == "" {
		return states
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, cmd, home).Output()
	if err != nil {
		return states
	}
	for _, l := range strings.Split(string(out), "\n") {
		if f := strings.Split(l, "\t"); len(f) == 2 {
			states[f[0]] = f[1]
		}
	}
	return states
}

// gateOf is the state of key when it is a gate id of the folded file's home: "open", "closed" or "".
func gateOf(key string) string { return gateStates(gateHome)[key] }

// inHome names the home of a status file (<home>/state/<task>.status) for the overlay.
func inHome(file string) { gateHome = filepath.Dir(filepath.Dir(file)) }

// gateOverlay drops every record whose key is a gate that has closed.
func gateOverlay(set string) string {
	recs := setRecords(set)
	kept := recs[:0:0]
	for _, r := range recs {
		if gateOf(r[:strings.IndexByte(r+"\t", '\t')]) != "closed" {
			kept = append(kept, r)
		}
	}
	return strings.Join(kept, "\n")
}
