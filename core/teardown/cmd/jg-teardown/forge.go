package main

import (
	"encoding/json"
	"os/exec"
	"regexp"
	"strings"
)

// prNumberFromBranch finds the PR for a branch through gh-axi. rc 0 is a single match, 1 is "the
// forge says there is none", and 3 is "the forge could not be read or answered in a shape this
// does not recognise", so the caller can tell no PR from an unreadable forge.
var listRow = regexp.MustCompile(`^[ \t\r\f\v]*([0-9]+),`)

func prNumberFromBranch(wt, branch string) (string, int) {
	if branch == "" || branch == "HEAD" {
		return "", 1
	}
	out, err := run(wt, "gh-axi", "pr", "list", "--state", "all", "--head", branch, "--limit", "1")
	if err != nil {
		return "", 3
	}
	for _, line := range strings.Split(out, "\n") {
		if m := listRow.FindStringSubmatch(line); m != nil {
			return m[1], 0
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "count: 0") {
			return "", 1
		}
	}
	return "", 3
}

// prNumberFromTarget reads the pull number out of a PR URL or a bare number. GitHub and GitLab
// style /pull/<n>, Forgejo style /pulls/<n>, or a leading number; anything else names none.
func prNumberFromTarget(target string) (string, bool) {
	var n string
	switch {
	case target == "":
		return "", false
	case strings.Contains(target, "/pull/"):
		n = target[strings.LastIndex(target, "/pull/")+len("/pull/"):]
	case strings.Contains(target, "/pulls/"):
		n = target[strings.LastIndex(target, "/pulls/")+len("/pulls/"):]
	case target[0] >= '0' && target[0] <= '9':
		n = target
	default:
		return "", false
	}
	end := 0
	for end < len(n) && n[end] >= '0' && n[end] <= '9' {
		end++
	}
	n = n[:end]
	return n, n != ""
}

// ensureCommitObject: the PR head must be a commit this copy can read, fetched from the forge's
// pull ref when the clone does not hold it yet.
func ensureCommitObject(wt, target, commit string) bool {
	if gitOK(wt, "cat-file", "-e", commit+"^{commit}") {
		return true
	}
	n, ok := prNumberFromTarget(target)
	if !ok || !gitOK(wt, "remote", "get-url", "origin") {
		return false
	}
	if !gitOK(wt, "fetch", "--quiet", "origin", "refs/pull/"+n+"/head") {
		return false
	}
	return gitOK(wt, "cat-file", "-e", commit+"^{commit}")
}

var shaRe = regexp.MustCompile(`^([0-9a-f]{40}|[0-9a-f]{64})$`)

// forgeHost is the host part of a PR or git URL, "" for a local path or an unrecognised shape.
func forgeHost(url string) string {
	var host string
	switch {
	case strings.Contains(url, "://"):
		host = url[strings.Index(url, "://")+3:]
		if i := strings.Index(host, "/"); i >= 0 {
			host = host[:i]
		}
	case strings.HasPrefix(url, "/") || strings.HasPrefix(url, "."):
		return ""
	case strings.Contains(url, ":"):
		host = url[:strings.Index(url, ":")]
	default:
		return ""
	}
	if i := strings.LastIndex(host, "@"); i >= 0 {
		host = host[i+1:]
	}
	if i := strings.Index(host, ":"); i >= 0 {
		host = host[:i]
	}
	return host
}

// forgeIsGitHub: must gh be able to read this task's forge? Any host naming github counts, so an
// SSH alias such as github-work does too. Another host, or a local path, falls back to the
// content check.
func (l *landing) forgeIsGitHub() bool {
	host := forgeHost(l.prURL)
	if host == "" {
		origin, _ := git(l.wt, "remote", "get-url", "origin")
		host = forgeHost(origin)
	}
	return strings.Contains(host, "github")
}

// forgejoRecord is a Forgejo pull request read through "tea api", so the credential never leaves
// tea. Only a record whose state, merged and head.sha fields have the expected types is
// accepted; "tea api" exits 0 on an HTTP error and prints the error body, which this refuses.
func (l *landing) forgejoRecord() (state string, merged bool, head string, ok bool) {
	f := l.forgejo
	if f == nil || f.login == "" || f.number == "" {
		return "", false, "", false
	}
	for _, c := range f.number {
		if c < '0' || c > '9' {
			return "", false, "", false
		}
	}
	cmd := exec.Command("tea", "api", "--login", f.login, "--repo", f.path,
		"/repos/{owner}/{repo}/pulls/"+f.number)
	raw, err := cmd.Output()
	if err != nil || len(raw) == 0 {
		return "", false, "", false
	}
	var rec struct {
		State  *string `json:"state"`
		Merged *bool   `json:"merged"`
		Head   *struct {
			Sha *string `json:"sha"`
		} `json:"head"`
	}
	if json.Unmarshal(raw, &rec) != nil || rec.State == nil || *rec.State == "" ||
		rec.Merged == nil || rec.Head == nil || rec.Head.Sha == nil {
		return "", false, "", false
	}
	return *rec.State, *rec.Merged, *rec.Head.Sha, true
}
