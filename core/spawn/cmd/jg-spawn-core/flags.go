package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// shellQuote single-quotes a value for the launch text, closing and reopening the quote around a
// literal single quote.
func shellQuote(v string) string {
	return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
}

// jsonEscape escapes backslash then double quote, the two characters the launch JSON fragment
// needs; it is not a general JSON encoder.
func jsonEscape(v string) string {
	v = strings.ReplaceAll(v, `\`, `\\`)
	return strings.ReplaceAll(v, `"`, `\"`)
}

var modelHarnesses = map[string]bool{
	"claude": true, "codex": true, "opencode": true, "pi": true, "pi-signed": true, "grok": true,
	"kimi": true, "cursor": true, "gemini": true, "muse": true, "rovo": true, "omp": true,
	"agy": true, "devin": true,
}

// modelFlag is the --model argument for a harness whose CLI takes one; a harness outside the
// verified set, an empty model and the literal "default" yield nothing.
func modelFlag(harness, model string) string {
	if model == "" || model == "default" || !modelHarnesses[harness] {
		return ""
	}
	return "--model " + shellQuote(model) + " "
}

func in(v string, set ...string) bool {
	for _, s := range set {
		if v == s {
			return true
		}
	}
	return false
}

// effortFlag maps the shared effort vocabulary onto one harness's launch text. An effort the
// harness cannot take is omitted rather than passed as a known-bad value. pi's native ultra
// level is the one effort that needs an outside check (validate); a nil error is the check passing.
func effortFlag(harness, effort, model string, validate func() error) (string, error) {
	if effort == "" || effort == "default" {
		return "", nil
	}
	switch harness {
	case "claude":
		if in(effort, "low", "medium", "high", "xhigh", "max") {
			return "--effort " + shellQuote(effort) + " ", nil
		}
	case "codex":
		switch {
		case in(effort, "low", "medium", "high", "xhigh"):
			return "-c " + shellQuote(`model_reasoning_effort="`+effort+`"`) + " ", nil
		case effort == "max" && model == "gpt-5.6-luna":
			return "-c " + shellQuote(`model_reasoning_effort="max"`) + " ", nil
		}
	case "grok":
		if in(effort, "low", "medium", "high") {
			return "--reasoning-effort " + shellQuote(effort) + " ", nil
		}
	case "agy":
		if in(effort, "low", "medium", "high") {
			return "--effort " + shellQuote(effort) + " ", nil
		}
	case "pi", "pi-signed":
		if effort == "ultra" {
			if err := validate(); err != nil {
				return "", err
			}
			return "--codex-effort " + shellQuote("ultra") + " ", nil
		}
		if in(effort, "low", "medium", "high", "xhigh", "max") {
			return "--thinking " + shellQuote(effort) + " ", nil
		}
	case "omp":
		if in(effort, "low", "medium", "high", "xhigh", "max") {
			return "--thinking " + shellQuote(effort) + " ", nil
		}
	case "opencode":
		// The effort rides the OPENCODE_CONFIG_CONTENT JSON the launch already writes, keyed to the
		// resolved model, and only where that model's provider exposes the level. The fragment
		// lands inside a single-quoted assignment, so a quote in the model id closes and reopens it.
		if model == "" || model == "default" {
			return "", nil
		}
		provider := model
		if i := strings.Index(model, "/"); i >= 0 {
			provider = model[:i]
		}
		ok := (provider == "anthropic" && in(effort, "high", "max")) ||
			(provider == "openai" && in(effort, "low", "medium", "high", "xhigh"))
		if !ok {
			return "", nil
		}
		modelJSON := strings.TrimRight(jsonEscape(model), "\n")
		modelJSON = strings.ReplaceAll(modelJSON, "'", `'\''`)
		return fmt.Sprintf(`,"agent":{"build":{"model":"%s","variant":"%s"}}`, modelJSON, effort), nil
	case "muse":
		switch {
		case in(effort, "low", "medium", "high", "xhigh"):
			return "--reasoning-effort " + shellQuote(effort) + " ", nil
		case effort == "max":
			return "--reasoning-effort " + shellQuote("ultra") + " ", nil
		}
	}
	return "", nil
}

func effortFlagCmd(args []string) int {
	script := ""
	if len(args) >= 2 && args[0] == "--harness-script" {
		script, args = args[1], args[2:]
	}
	if len(args) != 3 {
		return usage()
	}
	harness, effort, model := args[0], args[1], args[2]
	out, err := effortFlag(harness, effort, model, func() error {
		if script == "" {
			return fmt.Errorf("effort ultra needs --harness-script to validate it")
		}
		cmd := exec.Command(script, "validate-native-effort", harness, model, effort)
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		return cmd.Run()
	})
	if err != nil {
		if _, isExit := err.(*exec.ExitError); !isExit {
			fmt.Fprintln(os.Stderr, "error:", err)
		}
		return 1
	}
	fmt.Print(out)
	return 0
}

// rigorRank orders the delivery modes by rigor: 3 most, 1 least, 0 for a word that is not a task mode.
func rigorRank(mode string) int {
	switch mode {
	case "no-mistakes":
		return 3
	case "direct-PR":
		return 2
	case "local-only":
		return 1
	}
	return 0
}
