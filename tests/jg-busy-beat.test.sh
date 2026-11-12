#!/usr/bin/env bash
# Codex and Pi agents write the same beat from their busy record (slice H3b).
# The real watcher caller is bin/jg-busy-lib.sh's jg_busy_classify_meta, fed a real task meta and a real
# busy record written by bin/jg-busy-event.sh; the beat lands through the real bin/jg-beat.sh. Only the
# terminal backend probes are stand-ins.
#
# T1 a Pi busy record writes UserPromptSubmit once, then PostToolBatch only after the busy interval.
# T2 the settled record writes one Stop, and a dead agent one SessionEnd; neither repeats.
# T3 Codex (Herdr's native busy reading) beats the same way.
# T4 an unknown verdict writes no beat, and a Claude lane is left to its own hooks.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(jg_test_tmproot jg-busy-beat)
S="$TMP_ROOT/state"; mkdir -p "$S"
# shellcheck source=bin/jg-backend.sh
. "$ROOT/bin/jg-backend.sh"
# shellcheck source=bin/jg-busy-lib.sh
. "$ROOT/bin/jg-busy-lib.sh"
# Backend stand-ins: the pane exists, its agent runs, and Herdr reads the verdict set below.
jg_backend_agent_exited() { [ "${FAKE_EXITED:-0}" = 1 ]; }
jg_backend_busy_state() { printf '%s' "${FAKE_NATIVE:-}"; }

mkmeta() { # <id> <harness> <backend>
  printf 'window=default:w1:p2\nkind=ship\nbackend=%s\nharness=%s\n' "$3" "$2" >"$S/$1.meta"
}
verdict() { jg_busy_classify_meta "$S/$1.meta" "$1" "$S"; }
events() { awk '{print $2}' "$S/beats/$1" 2>/dev/null | paste -sd' '; }
busy_event() { "$ROOT/bin/jg-busy-event.sh" apply "$S" "$1" "$2" --current-gen --source pi-ext --event "$3"; }

# T1
mkmeta pi1 pi herdr
"$ROOT/bin/jg-busy-event.sh" arm "$S" pi1 >/dev/null
busy_event pi1 busy agent-start
[ "$(verdict pi1 | cut -d' ' -f1)" = busy ] || fail "T1 the Pi record does not read busy"
verdict pi1 >/dev/null
[ "$(events pi1)" = "UserPromptSubmit" ] || fail "T1 two quick reads wrote: $(events pi1)"
JG_BEAT_BUSY_SECS=0 verdict pi1 >/dev/null
[ "$(events pi1)" = "UserPromptSubmit PostToolBatch" ] || fail "T1 the busy interval wrote: $(events pi1)"
pass "T1 a Pi busy record writes a turn start, then a tool-batch beat only after the busy interval"

# T2
busy_event pi1 idle agent-settled
verdict pi1 >/dev/null; verdict pi1 >/dev/null
[ "$(events pi1)" = "UserPromptSubmit PostToolBatch Stop" ] || fail "T2 the settle wrote: $(events pi1)"
busy_event pi1 busy agent-start
verdict pi1 >/dev/null
FAKE_EXITED=1 verdict pi1 >/dev/null; FAKE_EXITED=1 verdict pi1 >/dev/null
[ "$(events pi1)" = "UserPromptSubmit PostToolBatch Stop UserPromptSubmit SessionEnd" ] || fail "T2 the exit wrote: $(events pi1)"
pass "T2 a settled turn writes one Stop and an exited agent one SessionEnd"

# T3
mkmeta cx1 codex herdr
FAKE_NATIVE=busy verdict cx1 >/dev/null
[ "$(events cx1)" = "UserPromptSubmit" ] || fail "T3 Codex native busy wrote: $(events cx1)"
pass "T3 a Codex agent that Herdr reads busy writes the same beat"

# T4
FAKE_NATIVE=idle verdict cx1 >/dev/null
[ "$(events cx1)" = "UserPromptSubmit" ] || fail "T4 an unknown Codex reading wrote: $(events cx1)"
mkmeta cl1 claude herdr
"$ROOT/bin/jg-busy-event.sh" arm "$S" cl1 >/dev/null
[ "$(verdict cl1 | cut -d' ' -f1)" = busy ] || fail "T4 the Claude seed does not read busy"
[ ! -e "$S/beats/cl1" ] || fail "T4 a Claude lane got a beat from the watcher"
pass "T4 an unknown reading writes nothing, and a Claude lane keeps its own hooks"

echo "all jg-busy-beat tests passed"
