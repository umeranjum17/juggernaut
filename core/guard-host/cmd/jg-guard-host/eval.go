// The policy evaluator's command line: the one door every non-guard rule is asked through.
//
// A rule that is a yes/no over facts lives in policy/<family>/ as Rego plus its data in
// rules.json, and the code that gathers the facts asks it here: a fact document on stdin,
// the decision on stdout. `eval gate.checks_lint` evaluates data.gate.checks_lint.decision
// over the policy tree of this checkout, so a new rule family changes no file in this
// command. Unlike the guard hook, which allows a command no rule could judge, a gate that
// cannot be evaluated must not look like a pass: a missing OPA, a policy that does not
// compile or an undefined decision exits 2 with the cause on stderr.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var packageRe = regexp.MustCompile(`^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)*$`)

// evalMode prints the decision document of the named package, e.g. gate.checks_lint.
func evalMode(args []string) {
	if len(args) != 1 || !packageRe.MatchString(args[0]) {
		fmt.Fprint(os.Stderr, "usage: jg-guard-host.sh eval <package>   (a fact document on stdin, e.g. gate.checks_lint)\n")
		os.Exit(2)
	}
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail("cannot read the fact document: " + err.Error())
	}
	root := policyRoot()
	if root == "" {
		fail("no policy tree found: set JG_GUARD_HOST_ROOT to a checkout holding policy/")
	}
	opa := os.Getenv("OPA")
	if opa == "" {
		opa = "opa"
	}
	cmd := exec.Command(opa, "eval", "--format=raw", "--stdin-input", "--ignore", "*_test.rego",
		"--data", filepath.Join(root, "policy"), "data."+args[0]+".decision")
	cmd.Stdin = strings.NewReader(string(input))
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		cause := strings.TrimSpace(stderr.String())
		if cause == "" {
			cause = err.Error()
		}
		fail("opa eval failed: " + cause + " (install OPA, or set OPA to its path)")
	}
	if strings.TrimSpace(string(out)) == "" || strings.TrimSpace(string(out)) == "undefined" {
		fail("policy " + args[0] + " produced no decision for this fact document")
	}
	fmt.Print(string(out))
}

func fail(msg string) {
	fmt.Fprintf(os.Stderr, "jg-guard-host eval: %s\n", msg)
	os.Exit(2)
}
