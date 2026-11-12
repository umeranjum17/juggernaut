package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// admit is the spawn's check that a ticket belongs to the repository it is spawned into and may start
// now: its repository label and its file list name this repository, no dependency edge is open, and no
// other live lane holds one of its files. The spawn reads the rows (bd show --json for the ticket,
// bd list --status in_progress --json for the live lanes) and this command only reads those files and
// the repository, so each refusal is a pure function of what it is given.
//
// Usage: jg-spawn-core admit --project <name> --repo <dir> --ticket <ticket.json> --lanes <lanes.json>
//
// A ticket with no `files` field is not judged on its repository, and one with no edge or lane to
// clash with is admitted: a row made by hand carries no file list (bin/jg-plan-file.sh writes the
// label and the list together), and its label is only the name the captain gave the project. Exit 0
// admits; exit 1 prints each refusal on stderr, `wrong-repo` first when the ticket belongs elsewhere.

// row is the part of a bd row that the admission reads.
type row struct {
	ID           string            `json:"id"`
	Status       string            `json:"status"`
	Labels       []string          `json:"labels"`
	Metadata     map[string]any    `json:"metadata"`
	Dependencies []json.RawMessage `json:"dependencies"`
}

type edge struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Type   string `json:"dependency_type"`
}

// readRows reads a bd JSON answer: an array of rows, or one row.
func readRows(path string) ([]row, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows []row
	if err := json.Unmarshal(data, &rows); err == nil {
		return rows, nil
	}
	var one row
	if err := json.Unmarshal(data, &one); err != nil {
		return nil, fmt.Errorf("%s is not a bd row or a list of rows", path)
	}
	return []row{one}, nil
}

// list reads a metadata field that holds a JSON array of strings, which bd stores as text.
func (r row) list(key string) []string {
	var out []string
	switch v := r.Metadata[key].(type) {
	case string:
		_ = json.Unmarshal([]byte(v), &out)
	case []any:
		for _, e := range v {
			if s, ok := e.(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

// repoLabel is the repository a row names with its `project:<name>` label.
func (r row) repoLabel() string {
	for _, l := range r.Labels {
		if name, ok := strings.CutPrefix(l, "project:"); ok {
			return name
		}
	}
	return ""
}

// admission returns every reason the ticket may not start in this repository, in a fixed order.
func admission(project, repo string, ticket row, lanes []row) []string {
	var why []string
	files, made := ticket.list("files"), map[string]bool{}
	if label := ticket.repoLabel(); len(files) > 0 && label != "" && label != project {
		why = append(why, fmt.Sprintf("wrong-repo: ticket %s belongs to %s, not %s", ticket.ID, label, project))
	}
	for _, f := range ticket.list("new_files") {
		made[f] = true
	}
	var missing []string
	for _, f := range files {
		if _, err := os.Stat(filepath.Join(repo, f)); err != nil && !made[f] {
			missing = append(missing, f)
		}
	}
	if len(missing) > 0 {
		why = append(why, fmt.Sprintf("wrong-repo: ticket %s names files that %s does not have: %s", ticket.ID, project, strings.Join(missing, ", ")))
	}
	for _, raw := range ticket.Dependencies {
		var e edge
		if json.Unmarshal(raw, &e) != nil || e.Status == "closed" || (e.Type != "" && e.Type != "blocks") {
			continue
		}
		why = append(why, fmt.Sprintf("open-edge: ticket %s waits for %s, which is %s", ticket.ID, e.ID, e.Status))
	}
	mine := map[string]bool{}
	for _, f := range files {
		mine[f] = true
	}
	for _, lane := range lanes {
		if lane.ID == ticket.ID {
			continue
		}
		for _, f := range lane.list("files") {
			if mine[f] {
				why = append(why, fmt.Sprintf("held-file: %s is held by the live lane %s", f, lane.ID))
			}
		}
	}
	return why
}

func admitCmd(args []string) int {
	var project, repo, ticketPath, lanesPath string
	dest := map[string]*string{"--project": &project, "--repo": &repo, "--ticket": &ticketPath, "--lanes": &lanesPath}
	for i := 0; i < len(args); i += 2 {
		p, ok := dest[args[i]]
		if !ok || i+1 >= len(args) {
			return usage()
		}
		*p = args[i+1]
	}
	if project == "" || repo == "" || ticketPath == "" || lanesPath == "" {
		return usage()
	}
	tickets, err := readRows(ticketPath)
	if err == nil && len(tickets) != 1 {
		err = fmt.Errorf("%s holds %d rows, not the one ticket", ticketPath, len(tickets))
	}
	var lanes []row
	if err == nil {
		lanes, err = readRows(lanesPath)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: could not read the ticket's rows for the admission check: %v\n", err)
		return 1
	}
	why := admission(project, repo, tickets[0], lanes)
	for _, w := range why {
		fmt.Fprintf(os.Stderr, "error: spawn refused: %s\n", w)
	}
	if len(why) > 0 {
		return 1
	}
	return 0
}
