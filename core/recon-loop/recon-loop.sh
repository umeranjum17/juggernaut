#!/usr/bin/env bash
# recon-loop.sh - a deep Recon's writer/critic loop advances by itself: each move that used to wait for an Overwatch turn is taken here, with no model awake.
# Usage: recon-loop.sh tick <jg-home>   one pass over every deep Recon of the home: take the one move its record and its lanes owe, if any
# The delivery tick runs this pass (bin/jg-delivery-tick.sh), and every done line of a worker kicks that tick, so a researcher's "draft ready for the
# separate critic" starts the critic within seconds and a critic's round reaches the researcher as fast.
#
# The loop keeps no state of the Recon's own. Its state is the handoff record (bin/jg-recon-handoff.sh, machine core/machines/tables/recon.tsv); the
# depth gate (bin/jg-recon-gate.sh --step) says whether the loop may go on; bin/jg-facts-lib.sh jg_fact_next_step names the step each finished lane
# owes. This script only takes those steps, once each. Its marks are in data/<recon>/recon-loop/: sent-<what>-<draft hash> for each message
# sent, tries-<move> for each move that failed, and `stopped` (the epoch, then the reason).
#
# One Recon, one pass. The phase is the last line of its handoff record. For a done line in the same second as a move, use the files' write order.
#   phase      what the loop finds                                      the move
#   none       the researcher's last line is done                       draft: record the draft (jg-recon-handoff.sh draft)
#   critiqued  the researcher's done line is newer than the critique    revise: record the revision (done over an unchanged report is a stop)
#   drafted    a draft, and no critic holds it                          assign: the Recon's own earlier critic, else a new critic lane
#                                                                       (jg-recon-critic.sh start), named to the handoff
#   assigned   the critic was not told this draft                       send the critic the round: the draft's sha256, the closure rule, rounds spent
#   assigned   the critic's done line is newer than the assignment      verdict: record the round the critic wrote in its own critic.md; with no
#                                                                       round for this draft, remind the critic once for each done line (a second is a stop)
#   critiqued  the critic found gaps; the researcher was not told       send the researcher the open findings and what to do
#   accepted   the critic found nothing new                             none: the gate decides, and core/recon-ready announces the report once
# A message goes to a live agent by bin/jg-send.sh (a durable steer) and to an agent that is gone by `bin/jg-control.sh relaunch --note-file` (the
# message is the note), so it is never typed at a dead terminal. A war room's lane gets every move but its first critic (bin/jg-war-room.sh starts those).
#
# The gate decides whether the loop may go on, so no copy of its rules lives here. It is asked before a move, unless the researcher is editing (it was
# sent its gaps and has not said done since):
#   STEP critic               the loop is open: take the move above
#   PASS, BYPASSED or exempt  the loop is closed: nothing to do, and a stop from earlier is cleared
#   a refusal                 the loop cannot go on by itself, and that includes a deep Recon past its 3 rounds with new gaps (the cap): stop
# A stop is one `check` wake for Main naming the Recon and the reason, once for each distinct reason, and the Recon is left as it is. So is a move that
# failed three passes running (a message that can neither reach its lane nor relaunch it, a critic that would not start). Every pass looks again: the
# moment the cause is gone the stop is cleared and the loop goes on. Main is woken for a stop and for the final outcome only, and the final outcome is not
# made here: core/recon-ready announces a report when the gate passes, so "no relay before the gate" has one owner.
#
# Seams (tests point them at stand-ins): JG_RECON_LOOP_SEND, JG_RECON_LOOP_CONTROL, JG_RECON_LOOP_CRITIC and JG_RECON_LOOP_AGENT (<id> -> alive, dead,
# missing or unknown). The state directory is JG_STATE_OVERRIDE, else <home>/state; the data directory is JG_DATA_OVERRIDE, else <home>/data.
# Exit 0, or 2 for a usage error.
set -u
export LC_ALL=C
{ [ "$#" -eq 2 ] && [ "$1" = tick ] && [ -d "${JG_STATE_OVERRIDE:-$2/state}" ]; } || { echo "usage: recon-loop.sh tick <jg-home>" >&2; exit 2; }
H=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$H/state}
DATA=${JG_DATA_OVERRIDE:-$H/data}
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
export JG_HOME=$H JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$DATA JG_CONFIG_OVERRIDE=${JG_CONFIG_OVERRIDE:-$H/config}
HANDOFF=$ROOT/bin/jg-recon-handoff.sh
GATE=$ROOT/bin/jg-recon-gate.sh
SEND=${JG_RECON_LOOP_SEND:-$ROOT/bin/jg-send.sh}
CONTROL=${JG_RECON_LOOP_CONTROL:-$ROOT/bin/jg-control.sh}
CRITIC=${JG_RECON_LOOP_CRITIC:-$ROOT/bin/jg-recon-critic.sh}
# shellcheck source=bin/jg-facts-lib.sh
. "$ROOT/bin/jg-facts-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"
umask 077

mval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
one_line() { grep -v '^[[:space:]]*$' | head -n 1 | tr '\t\r' '  ' | cut -c1-240; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
loop_dir() { printf '%s\n' "$DATA/$1/recon-loop"; }
phase_of() { "$HANDOFF" phase "$1" 2>/dev/null || echo none; }
last_field() { tail -n 1 "$DATA/$1/handoff.tsv" 2>/dev/null | cut -f"$2"; }   # <recon> <column>: a column of the record's last line
last_move() { local at; at=$(last_field "$1" 1); case $at in '' | *[!0-9]*) echo 0 ;; *) echo "$at" ;; esac; }
done_at() {  # <lane>: the epoch of the lane's done line; fails when its last status line is not one
  local at; at=$(jg_fact_ready_at "$STATE" "$1") || return 1
  [ "$at" != 0 ] || at=$(jg_fact_mtime "$STATE/$1.status")
  printf '%s\n' "$at"
}
done_after() {  # <lane> <recon> <epoch>: the lane's done line followed the move
  local at
  at=$(done_at "$1") || return 1
  [ "$at" -gt "$3" ] || { [ "$at" -eq "$3" ] && [ "$STATE/$1.status" -nt "$DATA/$2/handoff.tsv" ]; }
}
lane_live() { [ -f "$STATE/$1.meta" ] && ! grep -q '^cleanup_recovery=' "$STATE/$1.meta"; }
# shellcheck disable=SC2329 # deliver calls it
agent_state() {  # <lane> -> alive, dead, missing or unknown
  if [ -n "${JG_RECON_LOOP_AGENT:-}" ]; then "$JG_RECON_LOOP_AGENT" "$1"; return; fi
  # shellcheck disable=SC2016  # the single-quoted body is the child shell's own script
  bash -c '. "$1/jg-backend.sh" >/dev/null 2>&1 && jg_backend_agent_state "$(jg_backend_of_meta "$2")" "$(jg_backend_target_of_meta "$2")" "$2" "$3"' _ "$ROOT/bin" "$STATE/$1.meta" "$1" 2>/dev/null || echo unknown
}

# --- stops and tries ----------------------------------------------------------------------------------------------------
# stop <recon> <why>: the loop cannot go on by itself. One wake for Main for each distinct reason; the Recon is left as it is.
stop() {
  local r=$1 why=$2 f line
  mkdir -p "$(loop_dir "$r")"; f=$(loop_dir "$r")/stopped
  [ "$(sed -n 2p "$f" 2>/dev/null)" != "$why" ] || return 0
  printf '%s\n%s\n' "$(date +%s)" "$why" > "$f"
  line="recon loop stopped: $r - $why"
  JG_WAKE_LAST=
  jg_wake_append check "recon-loop-$r" "$line" || echo "recon-loop: could not queue the stop wake for $r" >&2
  case ${JG_WAKE_LAST:-} in now:*) printf '%s\n' "$line" ;; esac
}
unstop() { rm -f "$(loop_dir "$1")/stopped"; }

# try <recon> <key> <command...>: run one move; its output stays in TRY_OUT. A failure is tried again by the next pass, and told to Main after the third.
TRY_OUT=''
try() {
  local r=$1 key=$2 n f
  shift 2
  mkdir -p "$(loop_dir "$r")"; f=$(loop_dir "$r")/tries-$key
  if TRY_OUT=$("$@" 2>&1); then rm -f "$f"; return 0; fi
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$n" > "$f"
  [ "$n" -lt 3 ] || stop "$r" "$key still fails after retries: $(printf '%s\n' "$TRY_OUT" | one_line)"
  return 1
}

# --- messages ----------------------------------------------------------------------------------------------------------
# deliver <lane> <message file>: a durable steer to a live agent, a relaunch with the message as its note to one that is gone.
# shellcheck disable=SC2329 # try runs it by name
deliver() {
  case $(agent_state "$1") in
    dead | missing) "$CONTROL" "$1" relaunch --note-file "$2" ;;
    *) "$SEND" "$1" "$(cat "$2")" ;;
  esac
}
# send_once <recon> <lane> <what> <draft hash> <message file>: one message for each draft; its mark is written once the delivery went through.
send_once() {
  local mark; mark=$(loop_dir "$1")/sent-$3-${4:0:12}
  [ ! -e "$mark" ] || return 0
  try "$1" "$3" deliver "$2" "$5" && : > "$mark"
}
rounds_with_gaps() { grep -c '^Round [0-9]*: new gaps [1-9]' "$DATA/$1/critic.md" 2>/dev/null || true; }
gap_lines() { awk '/^Round [0-9]+:/ { gaps = ""; next } /^- / { gaps = gaps $0 "\n" } END { printf "%s", gaps }' "$1" 2>/dev/null | head -n 40; }
round_text() {  # <recon> <critic> <hash>: what the critic is told for a draft
  # shellcheck disable=SC2016  # the backquotes are the message's own text
  printf 'The draft %s of the deep Recon %s is ready for your next round (report sha256 %s).\nRead %s/%s/report.md again. Check that each gap of your last round is closed, and look for new ones with the critic rubric of %s/.agents/skills/deep-recon/SKILL.md.\nWrite the round in %s/%s/critic.md, then record it: `%s/bin/jg-recon-handoff.sh verdict %s --critic %s --hash <sha256 of report.md as you read it> --gaps <k>`.\n<k> is the number of new gaps. 0 means every earlier gap is closed and you found nothing new: that is the closure of the loop. Rounds that found gaps so far: %s of 3.\nThen append your done line.\n' \
    "${3:0:12}" "$1" "$3" "$DATA" "$1" "$ROOT" "$DATA" "$2" "$ROOT" "$1" "$2" "$(rounds_with_gaps "$1")"
}
findings_text() {  # <recon> <critic> <hash>: what the researcher is told when the critic found gaps
  # shellcheck disable=SC2016  # the backquotes are the message's own text
  printf 'The critic %s found new gaps in your draft %s of %s (round %s of at most 3 with gaps).\nClose each one in %s/%s/report.md: a gap you cannot close in one revision moves to section 7 or 10 with its reason. Then run `%s/bin/jg-recon-handoff.sh revise %s` and append `done [at=<epoch>]: draft ready for the separate critic`.\nThe open gaps, as the critic wrote them in %s/%s/critic.md:\n%s\n' \
    "$2" "${3:0:12}" "$1" "$(rounds_with_gaps "$1")" "$DATA" "$1" "$ROOT" "$1" "$DATA" "$2" "$(gap_lines "$DATA/$2/critic.md")"
}

# --- the critic's lane --------------------------------------------------------------------------------------------------
# critic_of <recon> -> "<task> <generation>": the Recon's current critic. The newest critic this loop started (generation 1, 2, ...), else the critic
# a person named in the Recon's critic.md (generation 0); empty when it has none.
critic_of() {
  local d gen task='' named
  for d in "$DATA/$1"/critic-*/; do
    [ -s "$d/task" ] || continue
    gen=${d%/}; gen=${gen##*critic-}
    task=$(cat "$d/task")
  done
  if [ -n "$task" ]; then printf '%s %s\n'  "$task" "$gen"; return 0; fi
  named=$(sed -n 's/^Critic:[[:space:]]*//p' "$DATA/$1/critic.md" 2>/dev/null | head -n 1 | tr -d '[:space:]')
  [ -z "$named" ] || [ "$named" = self ] || [ "$named" = "$1" ] || printf '%s 0\n' "$named"
}
lane_gone() {  # <recon> <critic> <generation>: the critic's lane had a record once and has none now
  lane_live "$2" && return 1
  [ "$3" = 0 ] || [ "$(cat "$DATA/$1/critic-$3/spawn.rc" 2>/dev/null)" = 0 ]
}
critic_start() {  # <recon> <generation>: ask the starter; sets CRITIC_TASK and returns its exit (0 live, 75 starting, 1 refused: a stop)
  local out err rc
  err=$(mktemp "$DATA/$1/.recon-loop-err.XXXXXX") || return 1
  out=$("$CRITIC" start "$1" "$2" 2>"$err"); rc=$?
  CRITIC_TASK=$(printf '%s\n' "$out" | head -n 1)
  [ "$rc" -eq 0 ] || [ "$rc" -eq 75 ] || stop "$1" "the critic did not start: $(grep -v '^[[:space:]]*$' "$err" | tail -n 1 | cut -c1-240)"
  rm -f "$err"
  return "$rc"
}

# --- the moves ---------------------------------------------------------------------------------------------------------
move_assign() {  # <recon>: name the critic that will read this draft
  local r=$1 c gen rc
  read -r c gen < <(critic_of "$r")
  if [ -z "${c:-}" ] || lane_gone "$r" "$c" "$gen"; then
    # A war room's own step starts its lanes' critics: wait for it rather than start a second one.
    [ -z "$("$HANDOFF" council "$r" 2>/dev/null)" ] || return 0
    critic_start "$r" "$(( ${gen:-0} + 1 ))"; rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 75 ] || return 1
    c=$CRITIC_TASK
  fi
  try "$r" assign "$HANDOFF" assign "$r" --critic "$c"
}

move_send_critic() {  # <recon> <hash>: the critic holds this draft: tell it, once.
  local r=$1 hash=$2 c gen msg rc=0
  read -r c _ < <("$HANDOFF" assignee "$r")
  [ -n "${c:-}" ] && [ "$c" != none ] || return 0
  read -r _ gen < <(critic_of "$r")
  if ! lane_live "$c" && [ "${gen:-0}" != 0 ]; then       # started here, and not yet running: its starter knows if it is coming
    critic_start "$r" "$gen"; rc=$?
    [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ]; return; }
  fi
  msg=$(mktemp "$DATA/$r/.recon-loop-msg.XXXXXX") || return 1
  round_text "$r" "$c" "$hash" > "$msg"
  send_once "$r" "$c" round "$hash" "$msg" || rc=1
  rm -f "$msg"
  return "$rc"
}

move_verdict() {  # <recon> <hash> <moved>: the critic's done line is newer than the assignment: record the round it wrote
  local r=$1 hash=$2 moved=$3 c at line named gaps msg mark rc=0
  read -r c _ < <("$HANDOFF" assignee "$r")
  [ -n "${c:-}" ] && [ "$c" != none ] || return 0
  done_after "$c" "$r" "$moved" || { move_send_critic "$r" "$hash"; return; }
  at=$(done_at "$c") || return 0
  # The critic's own last Round line (or its closure line) for exactly this draft.
  line=$(grep -E '^(Round [0-9]+: new gaps [0-9]+|Closure check:)' "$DATA/$c/critic.md" 2>/dev/null | tail -n 1)
  named=$(printf '%s\n' "$line" | sed -n 's/.*report[[:space:]]\{1,\}\([0-9a-f]\{12,64\}\).*/\1/p')
  if [ -n "$named" ] && [ "${hash:0:${#named}}" = "$named" ]; then
    case $line in
      Closure*) gaps=0 ;;
      *) gaps=$(printf '%s\n' "$line" | sed -n 's/^Round [0-9]*: new gaps \([0-9]*\).*/\1/p') ;;
    esac
    try "$r" verdict "$HANDOFF" verdict "$r" --critic "$c" --hash "$hash" --gaps "$gaps"
    return
  fi
  # No round for this draft: remind the critic once for this done line; a second reminder is a stop.
  mark=$(loop_dir "$r")/sent-remind-$at
  if [ -e "$mark" ]; then stop "$r" "the critic $c reported done twice without a round for the draft ${hash:0:12}"; return 1; fi
  msg=$(mktemp "$DATA/$r/.recon-loop-msg.XXXXXX") || return 1
  # shellcheck disable=SC2016  # the backquotes are the message's own text
  printf 'Your done line has no round for the draft %s of %s. Write `Round <n>: new gaps <k> report %s` in %s/%s/critic.md and record it with `%s/bin/jg-recon-handoff.sh verdict %s --critic %s --hash %s --gaps <k>`.\n' \
    "${hash:0:12}" "$r" "$hash" "$DATA" "$c" "$ROOT" "$r" "$c" "$hash" > "$msg"
  mkdir -p "$(loop_dir "$r")"
  { try "$r" remind deliver "$c" "$msg" && : > "$mark"; } || rc=1
  rm -f "$msg"
  return "$rc"
}

move_findings() {  # <recon> <hash>: the critic found gaps: the researcher gets them, once
  local r=$1 hash=$2 msg rc=0
  msg=$(mktemp "$DATA/$r/.recon-loop-msg.XXXXXX") || return 1
  findings_text "$r" "$(last_field "$r" 5)" "$hash" > "$msg"
  send_once "$r" "$r" findings "$hash" "$msg" || rc=1
  rm -f "$msg"
  return "$rc"
}

move_revise() {  # <recon> <hash>: the researcher said done: record the revision
  if [ "$(sha_of "$DATA/$1/report.md")" = "$2" ]; then
    stop "$1" "the researcher reported done over the critiqued draft ${2:0:12} without changing report.md"; return 1
  fi
  try "$1" revise "$HANDOFF" revise "$1"
}

# --- one Recon ---------------------------------------------------------------------------------------------------------
gate_word() {  # <recon>: sets GATE_WORD to loop, closed or refused; the gate's lines are left in GATE_TEXT (no subshell, so both survive)
  local rc
  GATE_TEXT=$("$GATE" "$1" --step 2>&1); rc=$?
  case $rc:$GATE_TEXT in
    0:*"STEP critic"*) GATE_WORD=loop ;;
    0:*) GATE_WORD=closed ;;
    *) GATE_WORD=refused ;;
  esac
}

pass_once() {  # <recon>: the moves that are due now, in order; a move that is not due or cannot be taken ends the pass
  local r=$1 phase moved hash
  phase=$(phase_of "$r"); moved=$(last_move "$r"); hash=$(last_field "$r" 4)
  # No done line and no record: the researcher is still drafting. A researcher that was sent its gaps and has not said done since is editing:
  # its report is not a draft, so the gate is not asked either.
  [ "$phase" != none ] || done_at "$r" > /dev/null || return 0
  if [ "$phase" = critiqued ] && [ -e "$(loop_dir "$r")/sent-findings-${hash:0:12}" ] && ! done_after "$r" "$r" "$moved"; then return 0; fi
  gate_word "$r"
  case $GATE_WORD in
    closed) unstop "$r"; return 0 ;;
    refused) stop "$r" "the depth gate refuses: $(printf '%s\n' "$GATE_TEXT" | sed 's/^jg-recon-gate: refused: //' | grep -v '^[[:space:]]*$' | head -n 4 | paste -sd';' | tr '\t\r' '  ' | cut -c1-600)"; return 0 ;;
  esac
  if [ "$phase" = none ]; then
    try "$r" draft "$HANDOFF" draft "$r" || return 0
  elif [ "$phase" = critiqued ] && done_after "$r" "$r" "$moved"; then
    move_revise "$r" "$hash" || return 0
  fi
  [ "$(phase_of "$r")" != drafted ] || move_assign "$r" || return 0
  phase=$(phase_of "$r"); moved=$(last_move "$r"); hash=$(last_field "$r" 4)
  case $phase in
    assigned) move_verdict "$r" "$hash" "$moved" || return 0 ;;
    critiqued) move_findings "$r" "$hash" || return 0 ;;
  esac
  unstop "$r"
}

# pass <recon>: a move that was taken makes the next one due at once (a verdict is followed by the researcher's gaps, a revision by the critic's round),
# so the pass repeats while the handoff record grows, and ends at the first pass that takes no move. Five at most: one round of the loop is four moves.
pass() {
  local r=$1 n=0 before
  while [ "$n" -lt 5 ]; do
    before=$(wc -l 2>/dev/null < "$DATA/$r/handoff.tsv" || echo 0)
    pass_once "$r"
    [ "$(wc -l 2>/dev/null < "$DATA/$r/handoff.tsv" || echo 0)" != "$before" ] || break
    n=$((n + 1))
  done
}

recons() {  # the lanes of this home that are a deep Recon (never its critic) with a task record and data of their own
  local meta r depth
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    r=$(basename "$meta" .meta)
    [ "$(mval "$meta" kind)" = scout ] && lane_live "$r" && [ -d "$DATA/$r" ] || continue
    depth=$(sed -n 's/^Recon depth:[[:space:]]*//p' "$DATA/$r/brief.md" 2>/dev/null | head -n 1 | tr -d '[:space:]')
    [ "$depth" = deep ] || continue
    ! bash "$GATE" "$r" --is-critic 2>/dev/null || continue
    printf '%s\n' "$r"
  done
}

while IFS= read -r recon; do
  pass "$recon"
done < <(recons)
exit 0
