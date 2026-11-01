// Command jg-guard-host is the one guard host: every allow/refuse decision a lane's shell
// command meets is made by this command.
//
// It carries four decisions, each with the contract its own file owns:
//
//	hook      policy/guard/*.rego decides (via OPA) whether a gh or gh-axi call writes to
//	          a repository off the allow list. host.go owns the fact document.
//	delete    a recursive delete aimed at the home folder, /, /home, a bare . .. * or an
//	          unknown $VAR is refused. delete.go owns the rule.
//	gh, gh-axi, pre-push
//	          repo-guard's installed shim and git pre-push extension. repoguard.go owns it.
//
// A rule is one .rego file plus its _test.rego under policy/guard/, so a new guard changes
// no file here. `--list` prints the rules this checkout ships, which is how a new rule
// shows it changed no core file.
//
// These decisions are Go by the fleet's stack decision. This guard host is one
// command instead of a JavaScript host, a JavaScript decider and a shell shim, and no
// decision changed: tests/jg-guard-host.test.sh, core/repo-guard/tests/repo-guard.test.sh
// and core/delete-guard/tests/delete-guard.test.sh drive the same claims they drove
// before, and `opa test policy/guard` still proves the rule's own decisions.
//
// Usage: jg-guard-host.sh hook | --list | delete [--runtime <name>] | decide <command> |
// gh <args...> | gh-axi <args...> | pre-push <remote> <url>
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

func usage() {
	fmt.Fprint(os.Stderr, "usage: jg-guard-host.sh hook | --list | delete [--runtime <name>] | decide <command> | gh <args...> | gh-axi <args...> | pre-push <remote> <url>\n")
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
	case "delete":
		deleteMode(args[1:])
	case "decide":
		command := ""
		if len(args) > 1 {
			command = args[1]
		}
		if _, blocked := blockedDelete(command); blocked {
			fmt.Println("block")
			return
		}
		fmt.Println("allow")
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

// deleteMode is the delete guard's hook CLI: a payload on stdin, and exit 2 with the
// reason on stderr blocks the call. --runtime names the runtime for the recorded row.
func deleteMode(args []string) {
	runtime := "unknown"
	for i := 0; i < len(args); i++ {
		if (args[i] == "--runtime" || args[i] == "-runtime") && i+1 < len(args) {
			runtime = args[i+1]
			i++
		}
	}
	p := readPayload()
	cwd := p.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	if reason := guard(p.ToolInput.Command, cwd, runtime); reason != "" {
		fmt.Fprint(os.Stderr, reason+"\n")
		os.Exit(2)
	}
}
