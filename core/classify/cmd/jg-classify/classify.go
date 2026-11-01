package main

import (
	"os"
	"regexp"
	"strings"
)

// The vocabulary and the line-level tests of the shared wake classifier. Each test reads one
// status line and nothing else; the environment overrides are the ones the shell library
// honoured (JG_CAPTAIN_RE, JG_CLASSIFY_PAUSED_VERB, JG_CLASSIFY_RESOLVE_VERB,
// JG_CLASSIFY_CAPTAIN_HELD_VERB), with the same unset-versus-empty meaning.

const defaultCaptainRE = `done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged`

// envOr is ${NAME:-def}: an unset or empty variable takes the default.
func envOr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func pausedVerb() string      { return envOr("JG_CLASSIFY_PAUSED_VERB", "paused") }
func resolveVerb() string     { return envOr("JG_CLASSIFY_RESOLVE_VERB", "resolved") }
func captainHeldVerb() string { return envOr("JG_CLASSIFY_CAPTAIN_HELD_VERB", "captain-held") }

// keylessPhase is the key a keyless line carries in the wait fold, distinct from any slug.
const keylessPhase = "\x1edefault"

// matches is a case-insensitive search of line for the extended expression pat. An expression
// that does not compile matches nothing, as a bash =~ error did.
func matches(line, pat string) bool {
	re, err := regexp.Compile("(?is)" + pat)
	return err == nil && re.MatchString(line)
}

func legacyRE() string {
	return "^[[:space:]]*(" + envOr("JG_CAPTAIN_RE", defaultCaptainRE) + ")"
}

func verbRecognized(v string) bool {
	switch v {
	case "working", "needs-decision", "blocked", "done", "failed", "note":
		return true
	}
	return v == pausedVerb() || v == resolveVerb() || v == captainHeldVerb()
}

func corrAttempt(w string) bool { return w == "corr" || strings.HasPrefix(w, "corr=") }

// prefixUnrecognized: the line declares a status prefix that did not parse as a recognized
// verb - an unknown lowercase word such as parked:, or a known verb followed only by a
// missing or mismatched correlation token. Continuation prose is not a prefix.
func prefixUnrecognized(line string) bool {
	l := unstamped(line)
	i := strings.IndexByte(l, ':')
	if i < 0 {
		return false
	}
	if after := l[i+1:]; after != "" && !startsWithSpace(after) {
		return false
	}
	verb := lineVerb(l)
	if verb == "" || verbRecognized(verb) {
		return false
	}
	first, rest := firstWord(verb)
	if rest == "" {
		for n, r := range first {
			if n == 0 && !isLowerRune(r) {
				return false
			}
			if !isLowerRune(r) && r != '-' {
				return false
			}
		}
		return true
	}
	if corrAttempt(first) {
		word, after := firstWord(rest)
		if !verbRecognized(word) {
			return false
		}
		rest = after
	} else if !verbRecognized(first) {
		return false
	}
	for rest != "" {
		word, after := firstWord(rest)
		if !corrAttempt(word) {
			return false
		}
		rest = after
	}
	return true
}

// lineIsEvent: a nonblank line is a recognized status event for the scans.
func lineIsEvent(line, legacy string) bool {
	verb := ""
	if strings.IndexByte(line, ':') >= 0 {
		verb = lineVerb(line)
	}
	return verbRecognized(verb) || prefixUnrecognized(line) || matches(unstamped(line), legacy)
}

func isTerminalVerb(line string) bool {
	if line == "" {
		return false
	}
	switch lineVerb(line) {
	case "done", "needs-decision", "blocked", "failed":
		return true
	}
	return false
}

// isCaptainRelevant: terminal verbs always match; nonterminal progress verbs and paused never
// match from prose; an unrecognized prefix surfaces as itself; bare legacy lines may match a
// free-text token.
func isCaptainRelevant(line string) bool {
	if line == "" {
		return false
	}
	verb := lineVerb(line)
	switch verb {
	case "working", "resolved", "captain-held", pausedVerb():
		return false
	}
	if prefixUnrecognized(line) {
		return true
	}
	if _, set := os.LookupEnv("JG_CAPTAIN_RE"); !set {
		switch verb {
		case "done", "needs-decision", "blocked", "failed":
			return true
		}
	}
	return matches(unstamped(line), envOr("JG_CAPTAIN_RE", defaultCaptainRE))
}

func isPaused(line string) bool { return line != "" && lineVerb(line) == pausedVerb() }

func isCaptainHeld(line string) bool { return lineVerb(line) == captainHeldVerb() }

func isPausedOrHeld(line string) bool { return isPaused(line) || isCaptainHeld(line) }
