#!/usr/bin/env bash
# The escalation workflow definition is the live owner of the two rungs it
# carries: a declared wait's owner alert at its timer and a declared pause's
# recheck at the pause cadence, delivered as the ladder delivered them (same wake
# line, same <key>-owner queue key, episode owner time stamped so the ladder's
# remaining rungs keep their timing). A lane whose rung is not due, whose episode
# already has its owner time, or whose episode this fact layer cannot read (and
# which is not a runtime-blocked lane) gets nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORKFLOWS="$ROOT/bin/jg-escalation-workflows.sh"
HOME_DIR=$(jg_test_tmproot jg-escalation-workflows)
now=$(date +%s)

# One home per case: one open lane, its metadata, its status log and the episode
# record the ladder writes (<signature> <since> <owner> <parent> <key> <misses>
# <card> <last>). Nothing here starts a service.
new_case() {  # <name> -> sets CASE, STATE_DIR, OUT
  CASE="$HOME_DIR/$1"
  STATE_DIR="$CASE/state"
  OUT="$CASE/out"
  mkdir -p "$STATE_DIR/.wait-sources" "$STATE_DIR/.waiting-timers" "$CASE/config"
}

lane() {  # <task> <window> <status-lines> <since> <key-source> [owner]
  local task=$1 window=$2 status=$3 since=$4 src=$5 owner=${6:-0}
  printf 'kind=ship\nbackend=tmux\nwindow=%s\n' "$window" >"$STATE_DIR/$task.meta"
  printf '%s\n' "$status" >"$STATE_DIR/$task.status"
  printf 'sig\t%s\t%s\t0\twaiting-timer-home-%s-g%s-%s\t0\t0\t0\n' \
    "$since" "$owner" "$task" "$since" "$src" >"$STATE_DIR/.waiting-timers/$task"
}

run() {  # <subcommand>
  JG_HOME="$CASE" JG_STATE_OVERRIDE="$STATE_DIR" JG_CONFIG_OVERRIDE="$CASE/config" \
    "$WORKFLOWS" "$@" >"$OUT" 2>&1
}

new_case show
run show || fail "show failed: $(cat "$OUT")"
grep -q 'ladder wait:' "$OUT" || fail "show does not print the wait ladder: $(cat "$OUT")"
grep -qE 'owner +\+120s' "$OUT" || fail "show does not print the owner rung at its timer: $(cat "$OUT")"
grep -qE 'owner +\+14400s' "$OUT" || fail "show does not print the pause cadence: $(cat "$OUT")"
grep -qE 're-alert +not in this definition' "$OUT" \
  || fail "show does not say the re-alert cadence is not this definition's: $(cat "$OUT")"
pass "show prints the definition in force"

# The ladder reads the two numbers it still measures from, so neither is written
# down a second time in shell code.
run timers || fail "timers failed: $(cat "$OUT")"
grep -qx "$(printf 'owner\t120')" "$OUT" || fail "timers does not print the owner alert: $(cat "$OUT")"
grep -qx "$(printf 'pause\t14400')" "$OUT" || fail "timers does not print the pause cadence: $(cat "$OUT")"
pass "timers prints the numbers the ladder reads"

# A due owner rung on a declared wait fires the line the ladder printed, queues
# its one row, and stamps the episode's owner time.
new_case blocked
lane lane fake:1 "blocked [at=$((now - 900))] [key=wait]: external condition" "$((now - 900))" wait
run tick || fail "tick failed: $(cat "$OUT")"
grep -q 'check: waiting-state lane (blocked key=wait, observed .*s, level=owner; Main must recheck and unblock) id=waiting-timer-home-lane-' \
  "$OUT" || fail "tick did not print the owner wake the ladder printed: $(cat "$OUT")"
grep -q 'source=\[blocked \[key=wait\]: external condition\]' "$OUT" \
  || fail "the owner wake does not name its source: $(cat "$OUT")"
grep -q 'waiting-timer-home-lane-.*-owner' "$STATE_DIR/.wake-queue" \
  || fail "tick queued no wake row: $(cat "$STATE_DIR/.wake-queue" 2>/dev/null)"
IFS=$'\t' read -r _sig _since owner _parent key _misses _card _last <"$STATE_DIR/.waiting-timers/lane"
[ "${owner:-0}" -gt 1 ] || fail "tick did not stamp the episode's owner time"
[ "$key" = "waiting-timer-home-lane-g$((now - 900))-wait" ] || fail "tick rewrote the episode key: $key"
# One wake per poll: the stamped episode fires nothing on the next tick.
run tick || fail "second tick failed: $(cat "$OUT")"
[ -s "$OUT" ] && fail "the stamped episode fired a second owner wake: $(cat "$OUT")"
pass "a due owner rung fires once with the ladder's own line, row and stamp"

# A lane under its timer is silent.
new_case early
lane lane fake:1 "blocked [at=$((now - 5))] [key=wait]: external condition" "$((now - 5))" wait
run tick || fail "tick failed: $(cat "$OUT")"
[ -s "$OUT" ] && fail "a wait below its owner timer alerted: $(cat "$OUT")"
pass "a wait below the owner timer is silent"

# The pause cadence is the definition's, not the owner alert's: a paused lane
# under 14400s is silent, and one past it fires.
new_case pause
lane paused fake:2 "paused [at=$((now - 900))]: waiting on the pipeline run" "$((now - 900))" default
run tick || fail "tick failed: $(cat "$OUT")"
[ -s "$OUT" ] && fail "a paused wait alerted before the pause cadence: $(cat "$OUT")"
lane paused fake:2 "paused [at=$((now - 20000))]: waiting on the pipeline run" "$((now - 20000))" default
run tick || fail "tick failed: $(cat "$OUT")"
grep -q 'check: waiting-state paused (paused, observed .*s, level=owner; Main must recheck' "$OUT" \
  || fail "a paused wait never rechecked at the pause cadence: $(cat "$OUT")"
pass "a declared pause rides the pause cadence and no other"

# A lane the runtime reported blocked has no declaration this fact layer reads;
# its key still names the source, so it keeps its owner alert.
new_case herdr
printf 'kind=ship\nbackend=herdr\nwindow=herdr-1\n' >"$STATE_DIR/blocked.meta"
printf 'working [at=%s]: building\n' "$((now - 900))" >"$STATE_DIR/blocked.status"
printf 'sig\t%s\t0\t0\twaiting-timer-home-blocked-g%s-herdr-blocked\t0\t0\t0\n' \
  "$((now - 900))" "$((now - 900))" >"$STATE_DIR/.waiting-timers/blocked"
run tick || fail "tick failed: $(cat "$OUT")"
grep -q 'check: waiting-state blocked (herdr-blocked, observed .*s, level=owner; Main must recheck' "$OUT" \
  || fail "a runtime-blocked lane lost its owner alert: $(cat "$OUT")"
pass "a runtime-blocked lane still reaches its owner"

# An episode a native wake already handed to the owner keeps its stamp, so the
# definition delivers no duplicate.
new_case stamped
lane lane fake:1 "blocked [at=$((now - 900))] [key=wait]: external condition" "$((now - 900))" wait "$now"
run tick || fail "tick failed: $(cat "$OUT")"
[ -s "$OUT" ] && fail "an already-delivered owner alert fired again: $(cat "$OUT")"
pass "an episode the ladder already stamped is left alone"

# A lead home names the owning lead, not Main, exactly as the ladder did.
new_case lead
: >"$CASE/.jg-squad-lead-home"
lane lane fake:1 "blocked [at=$((now - 900))] [key=wait]: external condition" "$((now - 900))" wait
run tick || fail "tick failed: $(cat "$OUT")"
grep -q 'level=owner; owning lead must recheck and unblock' "$OUT" \
  || fail "a lead home did not name the owning lead: $(cat "$OUT")"
pass "a lead home names the owning lead in the wake"
