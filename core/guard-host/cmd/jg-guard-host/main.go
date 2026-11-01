// Command jg-guard-host is the guard host for the shell commands a lane runs.
//
// It carries two decisions, each with the contract its own file owns:
//
//	hook      policy/guard/*.rego decides (via OPA) whether a gh or gh-axi call writes to
//	          a repository off the allow list. host.go owns the fact document.
//	gh, gh-axi, pre-push
//	          repo-guard's installed shim and git pre-push extension. repoguard.go owns it.
//
// A rule is one .rego file plus its _test.rego under policy/guard/, so a new guard changes
// no file here. `--list` prints the rules this checkout ships, which is how a new rule
// shows it changed no core file.
//
// These decisions are Go by the fleet's stack decision. This guard host is one command
// instead of a JavaScript host and a shell shim, and no decision changed:
// tests/jg-guard-host.test.sh and core/repo-guard/tests/repo-guard.test.sh drive the same
// claims they drove before, and `opa test policy/guard` still proves the rule's own
// decisions.
//
// Usage: jg-guard-host.sh hook | --list | gh <args...> | gh-axi <args...> |
// pre-push <remote> <url>
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

func usage() {
	fmt.Fprint(os.Stderr, "usage: jg-guard-host.sh hook | --list | gh <args...> | gh-axi <args...> | pre-push <remote> <url>\n")
	os.Exit(2)
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
	}
	switch args[0] {
	case "hook":
		hookMode()
	case "--list":
		listRules()
	case "pre-push":
		pushMode(args[1:])
	case "gh", "gh-axi":
		ghMode(args[0], args[1:])
	default:
		usage()
	}
}

// payload is the Claude PreToolUse document this host reads on stdin.
type payload struct {
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		Command string `json:"command"`
	} `json:"tool_input"`
	Cwd string `json:"cwd"`
}

// readPayload never fails a run: an unreadable payload is an empty one, exactly as the
// host read it before.
func readPayload() payload {
	var p payload
	body, err := io.ReadAll(os.Stdin)
	if err != nil {
		return p
	}
	_ = json.Unmarshal(body, &p)
	return p
}

// hookMode is the Claude Code PreToolUse hook: a payload on stdin, and exit 2 with the
// reasons on stderr blocks the call.
func hookMode() {
	p := readPayload()
	cwd := p.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	f := facts{
		Tool:    strings.ToLower(p.ToolName),
		Command: p.ToolInput.Command,
		Cwd:     cwd,
		Home:    os.Getenv("JG_HOME"),
		Calls:   callsIn(p.ToolInput.Command, cwd),
	}
	messages, err := decide(policyDir(policyRoot()), f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "guard-host: %s\n", err)
		return
	}
	if len(messages) > 0 {
		fmt.Fprint(os.Stderr, strings.Join(messages, "\n")+"\n")
		os.Exit(2)
	}
}

// listRules prints the rule files this checkout ships, one per line.
func listRules() {
	fmt.Print(strings.Join(ruleNames(policyRoot()), "\n") + "\n")
}
