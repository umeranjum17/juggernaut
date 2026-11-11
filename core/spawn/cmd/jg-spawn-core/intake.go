package main

import (
	"fmt"
	"os"
	"strings"
)

// intake is bin/jg-spawn.sh's argument grammar and the refusals that need nothing but the
// arguments: which flag takes which value, the empty-value and traceparent checks, the effort
// vocabulary, what a relaunch may not restate, and what a ship, scout or squad_lead may and may
// not carry. It prints shell assignments for the caller to eval.
//
// The spawn runs the account pool's --account check between the stage-one checks and the rest, so
// the rest is not an exit here: it is the INTAKE_REFUSAL assignment, which the spawn raises after
// that check, in the order the checks always ran.

// intake holds every variable the shell parser set, with the shell's own names.
type intake struct {
	kind                                           string
	kindSet                                        bool
	harness, model, effort, backend, mode, yolo    string
	branchPrefix, baseBranch, consent, traceparent string
	redFixOf, offCritical, ticket                  string
	harnessSet, modelSet, effortSet, backendSet    bool
	modeSet, yoloSet, branchPrefixSet              bool
	baseBranchSet, consentSet, traceparentSet      bool
	redFixOfSet, offCriticalSet, ticketSet         bool
	relaunch, herdrResumeLockWait                  bool
	pos                                            []string
}

func b2i(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// valueFlags are the flags that take a value, as `--flag value` or `--flag=value`.
var valueFlags = []string{"harness", "model", "effort", "backend", "mode", "yolo", "branch-prefix", "base-branch", "red-fix-of", "off-critical-path", "ticket", "upstream-consent", "traceparent"}

// set records one value flag, the shell's `case "$want_value"`.
func (t *intake) set(name, v string) {
	switch name {
	case "harness":
		t.harness, t.harnessSet = v, true
	case "model":
		t.model, t.modelSet = v, true
	case "effort":
		t.effort, t.effortSet = v, true
	case "backend":
		t.backend, t.backendSet = v, true
	case "mode":
		t.mode, t.modeSet = v, true
	case "yolo":
		t.yolo, t.yoloSet = v, true
	case "branch-prefix":
		t.branchPrefix, t.branchPrefixSet = v, true
	case "base-branch":
		t.baseBranch, t.baseBranchSet = v, true
	case "red-fix-of":
		t.redFixOf, t.redFixOfSet = v, true
	case "off-critical-path":
		t.offCritical, t.offCriticalSet = v, true
	case "ticket":
		t.ticket, t.ticketSet = v, true
	case "upstream-consent":
		t.consent, t.consentSet = v, true
	case "traceparent":
		t.traceparent, t.traceparentSet = v, true
	}
}

// parseIntake is the shell's `for a in "$@"` loop and the stage-one checks after it. The error is
// the full stderr line; it ends the spawn at once.
func parseIntake(args []string) (*intake, error) {
	t := &intake{kind: "ship", branchPrefix: "fm/"}
	want := ""
	for _, a := range args {
		if want != "" {
			if strings.HasPrefix(a, "--") {
				return nil, fmt.Errorf("error: --%s requires a value", want)
			}
			t.set(want, a)
			want = ""
			continue
		}
		switch a {
		case "--scout":
			t.kind, t.kindSet = "scout", true
			continue
		case "--squad-lead":
			t.kind, t.kindSet = "squad_lead", true
			continue
		case "--relaunch":
			t.relaunch = true
			continue
		case "--herdr-resume-lock-wait":
			t.herdrResumeLockWait = true
			continue
		}
		matched := false
		for _, name := range valueFlags {
			if a == "--"+name {
				want, matched = name, true
				break
			}
			if strings.HasPrefix(a, "--"+name+"=") {
				t.set(name, strings.TrimPrefix(a, "--"+name+"="))
				matched = true
				break
			}
		}
		if !matched {
			t.pos = append(t.pos, a)
		}
	}
	if want != "" {
		return nil, fmt.Errorf("error: --%s requires a value", want)
	}
	// Branch prefix and base branch are not checked for emptiness: the shell never did.
	for _, c := range []struct {
		set  bool
		val  string
		text string
	}{
		{t.harnessSet, t.harness, "error: --harness requires a non-empty value"},
		{t.modelSet, t.model, "error: --model requires a non-empty value"},
		{t.effortSet, t.effort, "error: --effort requires a non-empty value"},
		{t.backendSet, t.backend, "error: --backend requires a non-empty value"},
		{t.modeSet, t.mode, "error: --mode requires a non-empty value"},
		{t.yoloSet, t.yolo, "error: --yolo requires a non-empty value"},
		{t.redFixOfSet, t.redFixOf, "error: --red-fix-of requires a non-empty branch name"},
		{t.offCriticalSet, t.offCritical, "error: --off-critical-path requires the captain's words as a non-empty value"},
		{t.ticketSet, t.ticket, "error: --ticket requires a non-empty ticket id"},
		{t.consentSet, t.consent, "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value"},
		{t.traceparentSet, t.traceparent, "error: --traceparent requires a non-empty value"},
	} {
		if c.set && c.val == "" {
			return nil, fmt.Errorf("%s", c.text)
		}
	}
	// A parent-delivered carrier replaces this home's own resolution, so it is refused unless it is
	// a squad_lead spawn carrying a strictly valid W3C value.
	if t.traceparentSet {
		if t.kind != "squad_lead" {
			return nil, fmt.Errorf("error: --traceparent applies only to --squad-lead spawns; every other spawn resolves its own carrier from this home's frozen trace-context decision")
		}
		if !traceparentValid(t.traceparent) {
			return nil, fmt.Errorf("error: --traceparent is not a valid W3C traceparent")
		}
	}
	if !in(t.effort, "", "low", "medium", "high", "xhigh", "max", "ultra") {
		return nil, fmt.Errorf("error: --effort must be one of low, medium, high, xhigh, max, ultra")
	}
	return t, nil
}

// traceparentValid is bin/jg-trace-context-lib.sh's jg_trace_context_valid: version 00, a 32-hex
// trace id and a 16-hex span id that are not all zero, and two hex flag digits.
func traceparentValid(tp string) bool {
	if len(tp) != 55 || tp[:3] != "00-" || tp[35] != '-' || tp[52] != '-' {
		return false
	}
	hex := func(s string) bool {
		for i := 0; i < len(s); i++ {
			if !(s[i] >= '0' && s[i] <= '9' || s[i] >= 'a' && s[i] <= 'f') {
				return false
			}
		}
		return true
	}
	trace, span, flags := tp[3:35], tp[36:52], tp[53:]
	if !hex(trace) || !hex(span) || !hex(flags) {
		return false
	}
	return strings.Trim(trace, "0") != "" && strings.Trim(span, "0") != ""
}

// scopeValid is bin/jg-role-lib.sh's jg_role_scope_valid: <host>/<owner>/<repo> (deeper paths
// allowed) over a conservative charset.
func scopeValid(s string) bool {
	if strings.Count(s, "/") < 2 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '/' || c == '-') {
			return false
		}
	}
	return !strings.HasPrefix(s, ".") && !strings.HasSuffix(s, "/") && !strings.Contains(s, "//") && !strings.Contains(s, "..")
}

// refusal is the checks the spawn raises after the account pool's --account check; the empty
// string means none. It may normalize the consent scope, which is why the intake is passed by
// pointer.
func (t *intake) refusal() string {
	if r := t.deliveryRefusal(); r != "" || t.relaunch {
		return r
	}
	switch {
	case t.kind == "squad_lead" && t.ticketSet:
		return "error: --ticket applies only to ship and scout spawns; a squad_lead starts a home, not a ticket"
	case t.kind != "squad_lead" && !t.ticketSet && !t.batch():
		return "error: a fresh ship or scout spawn requires --ticket <ticket-id>; the task id is made from the ticket (bin/jg-backlog.sh task <ticket-id> prints it)"
	}
	return ""
}

// batch is an id=repo dispatch: each pair is spawned singly with its own id as its ticket (a flat ticket's id is its task id).
func (t *intake) batch() bool { return len(t.pos) > 0 && strings.Contains(t.pos[0], "=") }

// deliveryRefusal is the checks every spawn kind had before the ticket: what a relaunch may not
// restate and what a ship, scout or squad_lead may and may not carry.
func (t *intake) deliveryRefusal() string {
	if t.relaunch {
		// A relaunch reuses the task's recorded identity, so restating any axis of it is a refusal.
		for _, c := range []struct {
			set  bool
			text string
		}{
			{t.backendSet, "error: --relaunch reuses the task's recorded backend; --backend cannot override it"},
			{t.kindSet, "error: --relaunch reuses the task's recorded kind; --scout/--squad-lead cannot override it"},
			{t.modeSet, "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it"},
			{t.yoloSet, "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it"},
			{t.branchPrefixSet, "error: --relaunch reuses the task's recorded ship branch; --branch-prefix cannot override it"},
			{t.baseBranchSet, "error: --relaunch reuses the task's recorded base branch; --base-branch cannot override it"},
			{t.redFixOfSet, "error: --relaunch reuses the task's recorded red-fix declaration; --red-fix-of cannot override it"},
			{t.offCriticalSet, "error: --relaunch reuses the task's recorded critical-path decision; --off-critical-path cannot override it"},
			{t.consentSet, "error: --relaunch reuses the task's recorded upstream consent; --upstream-consent cannot override it"},
			{t.ticketSet, "error: --relaunch reads the ticket from the task's record; --ticket cannot override it"},
		} {
			if c.set {
				return c.text
			}
		}
		return ""
	}
	if t.kind == "ship" {
		switch {
		case !t.modeSet:
			return "error: ship spawns require --mode <no-mistakes|direct-PR|local>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md"
		case !t.yoloSet:
			return "error: ship spawns require --yolo <on|off>; it is this task's merge authority, not a project lookup"
		}
		switch t.mode {
		case "no-mistakes", "direct-PR", "local", "local-only", "local-trunk": // local-only and local-trunk are read as before (delivery-styles.tsv alias rows)
		case "no-mistakes-prod-only":
			return "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake"
		default:
			return fmt.Sprintf("error: --mode must be one of no-mistakes, direct-PR, local (the old words local-only and local-trunk are read as before; got '%s')", t.mode)
		}
		if t.yolo != "on" && t.yolo != "off" {
			return fmt.Sprintf("error: --yolo must be on or off (got '%s')", t.yolo)
		}
		if t.consentSet {
			if t.mode == "local" || t.mode == "local-only" || t.mode == "local-trunk" {
				return fmt.Sprintf("error: --upstream-consent is meaningless on %s, which publishes nothing; drop it", t.mode)
			}
			if !scopeValid(t.consent) {
				return fmt.Sprintf("error: --upstream-consent must be <host>/<owner>/<repo> (got '%s')", t.consent)
			}
			t.consent = strings.ToLower(t.consent)
		}
		return ""
	}
	switch {
	case t.modeSet:
		return "error: --mode applies only to ship spawns; a scout delivers a report and a squad_lead records its own fixed posture"
	case t.yoloSet:
		return "error: --yolo applies only to ship spawns; a scout delivers a report and a squad_lead records its own fixed posture"
	case t.branchPrefixSet:
		return "error: --branch-prefix applies only to ship spawns; a scout makes no branch and a squad_lead records no ship branch"
	case t.kind == "squad_lead" && t.baseBranchSet:
		return "error: --base-branch applies only to ship and scout spawns; a squad_lead charter has no task base"
	case t.redFixOfSet:
		return "error: --red-fix-of applies only to ship spawns; a scout and a squad_lead land no change on a release branch"
	case t.offCriticalSet:
		return "error: --off-critical-path applies only to ship spawns; a scout and a squad_lead are never held to the migration's critical path"
	case t.consentSet:
		return "error: --upstream-consent applies only to ship spawns; a scout publishes nothing and a squad_lead records no delivery contract"
	}
	return ""
}

// shellCode renders the assignments the spawn evals.
func (t *intake) shellCode(refusal string) string {
	var b strings.Builder
	line := func(name, val string) { fmt.Fprintf(&b, "%s=%s\n", name, shellQuote(val)) }
	line("KIND", t.kind)
	line("KIND_SET", b2i(t.kindSet))
	line("HARNESS_ARG", t.harness)
	line("HARNESS_SET", b2i(t.harnessSet))
	line("MODEL", t.model)
	line("MODEL_SET", b2i(t.modelSet))
	line("EFFORT", t.effort)
	line("EFFORT_SET", b2i(t.effortSet))
	line("BACKEND_ARG", t.backend)
	line("BACKEND_SET", b2i(t.backendSet))
	line("MODE", t.mode)
	line("MODE_SET", b2i(t.modeSet))
	line("YOLO", t.yolo)
	line("YOLO_SET", b2i(t.yoloSet))
	line("BRANCH_PREFIX", t.branchPrefix)
	line("BRANCH_PREFIX_SET", b2i(t.branchPrefixSet))
	line("BASE_BRANCH", t.baseBranch)
	line("BASE_BRANCH_SET", b2i(t.baseBranchSet))
	line("RED_FIX_OF", t.redFixOf)
	line("RED_FIX_OF_SET", b2i(t.redFixOfSet))
	line("OFF_CRITICAL_PATH", t.offCritical)
	line("OFF_CRITICAL_PATH_SET", b2i(t.offCriticalSet))
	line("TICKET", t.ticket)
	line("TICKET_SET", b2i(t.ticketSet))
	line("UPSTREAM_CONSENT", t.consent)
	line("UPSTREAM_CONSENT_SET", b2i(t.consentSet))
	line("TRACEPARENT_ARG", t.traceparent)
	line("TRACEPARENT_SET", b2i(t.traceparentSet))
	line("RELAUNCH", b2i(t.relaunch))
	line("HERDR_RESUME_LOCK_WAIT", b2i(t.herdrResumeLockWait))
	b.WriteString("POS=(")
	for i, p := range t.pos {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(shellQuote(p))
	}
	b.WriteString(")\n")
	line("INTAKE_REFUSAL", refusal)
	return b.String()
}

// intakeCmd is `jg-spawn-core intake [--] <spawn arguments...>`.
func intakeCmd(args []string) int {
	t, err := parseIntake(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	refusal := t.refusal()
	fmt.Print(t.shellCode(refusal))
	return 0
}
