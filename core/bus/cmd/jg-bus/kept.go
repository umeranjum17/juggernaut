package main

// The definitions the kept commands share, copied unchanged from the code slice 11b5 deleted.

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// registryHomeRe anchors on the structured suffix of a data/squad_leads.md line,
// the same one bin/jg-squad-lead-registry-lib.sh parses.
var registryHomeRe = regexp.MustCompile(`^- ([A-Za-z0-9._-]+) - .+ \((?:host:[^;)]*;\s*root:[^;)]*;\s*)?home:\s*([^;)]*);\s*scope:.*;\s*projects:[^;)]*;\s*added\s+\d{4}-\d{2}-\d{2}\)\s*$`)

// resolveHome makes a home path absolute and symlink-free, so one home has one
// name however it was spelled.
func resolveHome(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		path = abs
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	return filepath.Clean(path)
}

// squadLead is one entry of a data directory's Squad Lead registry; remote entries route over SSH.
type squadLead struct {
	id, home string
	remote   bool
}

// squadLeadEntries reads the Squad Lead registry in one data directory.
func squadLeadEntries(data string) []squadLead {
	raw, err := os.ReadFile(filepath.Join(data, "squad_leads.md"))
	if err != nil {
		raw, _ = os.ReadFile(filepath.Join(data, "secondmates.md"))
	}
	var out []squadLead
	for _, line := range strings.Split(string(raw), "\n") {
		if m := registryHomeRe.FindStringSubmatch(line); m != nil && strings.TrimSpace(m[2]) != "" {
			out = append(out, squadLead{m[1], strings.TrimSpace(m[2]), strings.Contains(line, "(host:")})
		}
	}
	return out
}

func readFileString(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}
