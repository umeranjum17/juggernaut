package main

// Ask sources across homes. A captain ask routed to a Squad Lead finishes in that home's
// backlog while its origin note stays in this home's inbox, so this home's gateway is the only
// one that can answer it. A child home is read only when this home's own data/squad_leads.md
// names it, its seed marker carries that id, and its local parent record names this home: the
// same binding bin/jg-ff-lib.sh and bin/jg-squad-lead-parent-lib.sh check. A home that fails
// any part is listed as one "unreadable" row with the reason and never sends anything.

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// askHome is one home whose terminal asks this gateway delivers; ID is empty for this home.
type askHome struct{ ID, home, state, data string }

// keyTag keeps outcome keys apart across homes. This home's tag is empty, so the receipts it
// saved before child homes were read still match their outcomes.
func (h askHome) keyTag() string {
	if h.ID == "" {
		return ""
	}
	return "home:" + h.ID + "\x00"
}

// env is the environment that reads the home's backlog. A child read drops every inherited
// home override and store pin, so nothing of this home's own store or config reaches it.
func (h askHome) env() []string {
	var env []string
	for _, kv := range os.Environ() {
		name, _, _ := strings.Cut(kv, "=")
		if h.ID != "" && (name == "BEADS_DIR" || name == "JG_BACKLOG_SNAPSHOT" ||
			strings.HasPrefix(name, "JG_") && strings.HasSuffix(name, "_OVERRIDE")) {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "JG_HOME="+h.home, "JG_STATE_OVERRIDE="+h.state, "JG_DATA_OVERRIDE="+h.data)
}

func (a *app) askSources() ([]askOutcome, error) {
	out, err := a.homeAsks(askHome{"", a.home, a.state, a.data})
	if err != nil {
		return nil, err
	}
	for _, e := range squadLeadEntries(a.data) {
		h, err := a.childAskHome(e)
		var rows []askOutcome
		if err == nil {
			rows, err = a.homeAsks(h)
		}
		if err != nil {
			rows = []askOutcome{{Home: e.id, Delivery: "unreadable", Problem: err.Error()}}
		}
		out = append(out, rows...)
	}
	return out, nil
}

// childAskHome is the registered entry as a readable home, or the reason it is not one.
func (a *app) childAskHome(e squadLead) (askHome, error) {
	no := func(why string) (askHome, error) { return askHome{}, fmt.Errorf("Squad Lead home %s: %s", e.id, why) }
	if e.remote {
		return no("it is on another host, and its asks are not delivered from this one")
	}
	home, self := resolveHome(e.home), resolveHome(a.home)
	if !filepath.IsAbs(e.home) || home == self {
		return no("its registered home is not a separate absolute path")
	}
	marker, ok := plainRecord(filepath.Join(home, ".jg-squad-lead-home"))
	if !ok || strings.TrimSpace(marker) != e.id {
		return no("the home is not seeded for this id")
	}
	raw, ok := plainRecord(filepath.Join(home, ".jg-squad-lead-parent"))
	fields, seen := map[string]string{}, 0
	for _, line := range strings.Split(raw, "\n") {
		if k, v, cut := strings.Cut(line, "="); cut && (k == "schema" || k == "route" || k == "parent_home" || k == "parent_host") {
			fields[k], seen = v, seen+1
		}
	}
	parent := fields["parent_home"]
	_, host := fields["parent_host"]
	if !ok || host || seen != len(fields) || fields["schema"] != "jg-squad-lead-parent.v1" || fields["route"] != "local" ||
		!filepath.IsAbs(parent) || resolveHome(parent) != self {
		return no("its parent record does not name this home")
	}
	return askHome{e.id, home, filepath.Join(home, "state"), filepath.Join(home, "data")}, nil
}

// plainRecord reads a small regular file that is not a symlink and holds no NUL byte.
func plainRecord(path string) (string, bool) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "", false
	}
	b, err := os.ReadFile(path)
	return string(b), err == nil && !bytes.Contains(b, []byte{0})
}

// attachmentVetters checks a report against this home's secret paths and, for a child
// home's report, against that home's own as well.
func (a *app) attachmentVetters(h askHome) []*app {
	if h.ID == "" {
		return []*app{a}
	}
	src := *a
	src.home, src.state, src.data = h.home, h.state, h.data
	return []*app{a, &src}
}
