#!/usr/bin/env bash
# jg-lavish-guard.sh - refuse a captain-facing link on the retired Lavish port
# or a Lavish publication command, and name the surface that replaced it; with
# --append on a lane's status file, also refuse a local-trunk `done` whose head
# the landing would refuse for missing proof.
#
# Usage: jg-lavish-guard.sh [--append <file>] [<text>...]
#
# Reads the proposed text from its arguments, or from stdin when it has none,
# and exits 1 for a Lavish publication with one refusal line on stderr:
#
#   owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead
#
# Everything else exits 0. A grep or read error keeps its own diagnostics and
# exit code, so a broken check never passes as clean text. The Lavish check is
# a text guard: it intercepts the words, never the command.
#
# --append <file> writes the accepted text to <file> unchanged and appends
# nothing when it is refused, so a caller can pipe one line through the guard
# without a second, unguarded copy of the text.
#
# The done proof check (--append only). When <file> is a lane's
# <state>/<id>.status, a line of the text opens with the verb `done`, and the
# lane record <state>/<id>.meta names a local-trunk lane (bin/jg-dod-lib.sh
# jg_dod_trunk_lane), the guard asks the landing's own question,
# jg_dod_trunk_proof_gaps, at the HEAD of the lane's isolated copy (the meta's
# worktree=). With any input missing it exits 1, prints every gap on stderr,
# and leaves the status file unchanged, so the worker sees the gap list at
# once, including after a conflict fix gave the lane a new head. A worker that
# cannot finish the proof appends `blocked:` instead. A check that cannot run
# - no lane record, no jq, another delivery mode, no readable head - lets the
# line through with one warning on stderr; the done acceptance in
# bin/jg-crew-state.sh still judges it. The home is JG_HOME, else the status
# file's parent directory, as in jg_dod_accept_ship_done.
#
# The Recon done check (--append only). When the lane record names a Recon
# (kind=scout) and a line of the text opens with `done`, the guard asks the two
# questions the cleanup asks, so a Recon never says done and then cannot be
# cleaned: the depth gate (bin/jg-recon-gate.sh, which judges a critic task on
# its critic.md and honours a waiver by Main) and the owner-call completion gate
# (bin/jg-captain-hold.sh verify). A Recon with no report.md is refused too,
# except a critic task, whose product is critic.md. A refused done writes
# nothing and lists every gap on stderr. Another kind of lane is not judged here.
#
# The hold record check (--append on a .status file). A blocked: or needs-decision: line that names the captain or Main
# as its cause must carry the id of a hold on record (bin/jg-captain-hold.sh open); without one it is refused with
# "no such hold is on record" and nothing is written.
#
# The wait check (--append on a .status file). A paused: line is the one way to wait, and it names who owes the next
# move and why: `paused [at=<epoch>] [wait=<who>] [reason=<word>]: {why}`. The words are the rows of
# core/machines/ticket-wait.states (not `none`) and core/machines/ticket-wait-reason.states. A paused: line with no wait,
# a wait with no reason, a word outside those lists, or the old placeholder date 2026-12-31 is refused with the new form
# in the refusal text, and nothing is written. A parked lane is `reason=parked`; the quiet rule keys on that word.
#
# This file is the one core owner of these refusals. bin/jg-squad-lead-report.sh
# runs it before a parent-channel append, and the status line bin/jg-brief.sh
# generates pipes through it, so no captain-facing status or report note can
# carry a Lavish address even when a worker types one by hand, and no lane's
# status says done for a head the landing would refuse.
set -u

pattern='https?://[^/[:space:]?#]+:4387([/?#[:space:]"<>)]|$)|(^|[;&|(`]|[$][(])[[:space:]]*lavish-axi[[:space:]]+(publish([^[:alnum:]_-]|$)|[^[:space:]]*[.]html?([^[:alnum:]_-]|$))'

# 0 when <text> may be appended to <status-file>: it carries no done line, the
# lane is not a local-trunk lane, the check cannot run (warned), or the head's
# proof is whole. 1 with the gap list on stderr when the landing would refuse it.
done_proof_gate() {  # <status-file> <text>
  local file=$1 text=$2 state id meta home mode wt head gaps line said_done=''
  while IFS= read -r line; do
    [ "$(status_line_verb "$line")" = "done" ] && { said_done=1; break; }
  done <<< "$text"
  [ -n "$said_done" ] || return 0
  state=$(dirname -- "$file"); id=$(basename -- "$file" .status); meta=$state/$id.meta
  home=${JG_HOME:-$(dirname -- "$state")}
  _unchecked() { echo "warning: the proof of $id was not checked before this done: $1" >&2; }
  [ -f "$meta" ] || { _unchecked "no lane record at $meta"; return 0; }
  [ "$(jg_dod_meta_value "$meta" kind)" != scout ] || return 0  # a Recon: recon_done_gate judges it
  command -v jq >/dev/null 2>&1 || { _unchecked 'jq is not installed'; return 0; }
  mode=$(jg_dod_meta_value "$meta" mode)
  JG_HOME=$home jg_dod_trunk_lane "$mode" "$(jg_dod_meta_value "$meta" project)" \
    || { _unchecked "it is a ${mode:-no-mode} lane, not a local-trunk one"; return 0; }
  wt=$(jg_dod_meta_value "$meta" worktree)
  head=$(git -C "${wt:-/nonexistent}" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) \
    || { _unchecked "no head in its isolated copy ${wt:-(none recorded)}"; return 0; }
  gaps=$(JG_HOME=$home jg_dod_trunk_proof_gaps "$home" "$state" "$id" "$meta" "$head" 'done') && return 0
  {
    printf 'done refused: the landing would refuse head %s of %s for missing proof, so nothing was written to %s:\n' "${head:0:12}" "$id" "$file"
    printf '%s\n' "$gaps" | sed 's/^/  - /'
    echo 'Complete the proof at this head and append done again; if it cannot be finished, append a blocked: line that says why.'
  } >&2
  return 1
}

# 0 when <text> may be appended to a Recon's <status-file>: it carries no done line, the lane is not a
# Recon, or the depth gate, the report and the completion gate all pass. 1 with every gap on stderr.
recon_done_gate() {  # <status-file> <text>
  local file=$1 text=$2 state id meta home data gate hold line said_done='' gaps='' out dir
  while IFS= read -r line; do
    [ "$(status_line_verb "$line")" = "done" ] && { said_done=1; break; }
  done <<< "$text"
  [ -n "$said_done" ] || return 0
  state=$(dirname -- "$file"); id=$(basename -- "$file" .status); meta=$state/$id.meta
  [ -f "$meta" ] && [ "$(jg_dod_meta_value "$meta" kind)" = scout ] || return 0
  home=${JG_HOME:-$(dirname -- "$state")}
  data=${JG_DATA_OVERRIDE:-$home/data}; dir=$data/$id
  gate="$(dirname -- "${BASH_SOURCE[0]}")/jg-recon-gate.sh"
  hold="$(dirname -- "${BASH_SOURCE[0]}")/jg-captain-hold.sh"
  if [ -f "$gate" ]; then
    out=$(JG_HOME=$home JG_DATA_OVERRIDE=$data JG_STATE_OVERRIDE=$state bash "$gate" "$id" 2>&1 >/dev/null) && out=''
    [ -z "$out" ] || gaps=$(printf '%s\n' "$out" | sed 's/^jg-recon-gate: refused: /depth gate: /')
  fi
  if [ ! -f "$dir/report.md" ] && ! { [ -f "$gate" ] && JG_HOME=$home JG_DATA_OVERRIDE=$data bash "$gate" "$id" --is-critic >/dev/null 2>&1; }; then
    gaps=${gaps:+$gaps$'\n'}"no report at $dir/report.md; the report is the work product"
  fi
  if [ -f "$hold" ] && ! JG_HOME=$home JG_STATE_OVERRIDE=$state JG_DATA_OVERRIDE=$data bash "$hold" verify "$id" >/dev/null 2>&1; then
    gaps=${gaps:+$gaps$'\n'}"completion gate: the captain-call inventory is not attested; inventory the report's open calls with bin/jg-captain-hold.sh complete $id"
  fi
  [ -n "$gaps" ] || return 0
  {
    printf 'done refused: Recon %s would not be cleanable, so nothing was written to %s:\n' "$id" "$file"
    printf '%s\n' "$gaps" | sed 's/^/  - /'
    echo 'Close the gaps and append done again; if they cannot be closed, append a blocked: line that says why.'
  } >&2
  return 1
}

# 0 when no line of <text> stops for the captain or Main without a hold on record. A blocked: or needs-decision: line
# whose note names the captain or Main as its cause must carry the id of a hold bin/jg-captain-hold.sh open finds;
# otherwise 1 with one refusal on stderr, so a lane never stops for a decision that does not exist.
hold_record_gate() {  # <text>
  local line verb note tok
  while IFS= read -r line; do
    verb=$(status_line_verb "$line")
    { [ "$verb" = blocked ] || [ "$verb" = needs-decision ]; } || continue
    note=$(status_line_note "$line")
    printf '%s\n' "$note" | grep -Eq '(^|[^[:alnum:]_])([Cc]aptain|Main)([^[:alnum:]_]|$)' || continue
    for tok in $(printf '%s\n' "$note" | grep -Eo '[A-Za-z0-9][A-Za-z0-9._]*-[A-Za-z0-9._-]*[A-Za-z0-9]'); do
      "$(dirname -- "${BASH_SOURCE[0]}")/jg-captain-hold.sh" open "$tok" >/dev/null 2>&1 && continue 2
    done
    echo 'hold refused: no such hold is on record; name the id of the captain hold this line waits on (bin/jg-captain-hold.sh hold), or write the real cause' >&2
    return 1
  done <<< "$1"
}

# The words of a machine enum file (first column of its non-comment rows), one per line.
wait_words() {  # <enum-file-name>
  awk -F '\t' '!/^#/ && NF { print $1 }' "$(dirname -- "${BASH_SOURCE[0]}")/../core/machines/$1"
}

# 0 when every paused: line of <text> names a legal wait and reason; otherwise 1 with the new form on stderr.
wait_line_gate() {  # <text>
  local line head who why whos whys problem form
  whos=$(wait_words ticket-wait.states | grep -vx none) || whos=''
  whys=$(wait_words ticket-wait-reason.states) || whys=''
  form='write paused [at=<epoch>] [wait=<who>] [reason=<word>]: {why}'
  while IFS= read -r line; do
    status_is_paused "$line" || continue
    head=${line%%:*}
    who=$(printf '%s\n' "$head" | sed -n 's/.*[[ ]wait=\([A-Za-z0-9_-]*\).*/\1/p' | head -1)
    why=$(printf '%s\n' "$head" | sed -n 's/.*[[ ]reason=\([A-Za-z0-9_-]*\).*/\1/p' | head -1)
    problem=''
    if printf '%s\n' "$line" | grep -q '2026-12-31'; then problem='the placeholder date 2026-12-31 is not a wait; use reason=parked'
    elif [ -z "$who" ] && [ -z "$why" ]; then problem='a paused line names no wait'
    elif [ -z "$who" ]; then problem='a reason needs a wait: who owes the next move?'
    elif [ -z "$why" ]; then problem="a wait on $who needs a reason"
    elif ! printf '%s\n' "$whos" | grep -qx "$who"; then problem="wait=$who is not a who"
    elif ! printf '%s\n' "$whys" | grep -qx "$why"; then problem="reason=$why is not a reason"
    fi
    [ -n "$problem" ] || continue
    {
      printf 'wait refused: %s; nothing was written.\n' "$problem"
      printf '%s.\n' "$form"
      printf 'wait is one of: %s.\n' "$(printf '%s\n' "$whos" | paste -sd' ' -)"
      printf 'reason is one of: %s.\n' "$(printf '%s\n' "$whys" | paste -sd' ' -)"
    } >&2
    return 1
  done <<< "$1"
}

# The ticket move of a done line, in shadow (bin/jg-move.sh --shadow): the worker said done, so the ticket makes
# claim-done from building, or new-head from delivering. Only a line that opens with `done` moves. It runs before the
# line is written: in shadow it never refuses, and once `ticket` is in config/machine-enforce (bin/jg-move.sh) an
# illegal move returns 1 and the line is not written.
done_line_move() {  # <status file> <text>
  local id state event here line said_done=''
  while IFS= read -r line; do
    [ "$(status_line_verb "$line")" = "done" ] && { said_done=1; break; }
  done <<< "$2"
  [ -n "$said_done" ] || return 0
  here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  id=$(basename -- "$1" .status)
  state=$(bash "$here/jg-machine.sh" show ticket "$id" 2>/dev/null | sed -n 's/^state\t//p')
  if [[ "$state" == delivering* ]]; then event='new-head'; else event='claim-done'; fi
  bash "$here/jg-move.sh" --shadow "$id" "$event" >/dev/null 2>&1; [ "$?" -eq 1 ] || return 0  # only exit 1 is a refusal
  echo "owner-rules: done line refused: ticket $id cannot make the move $event from its state; run: bin/jg-machine.sh next ticket $id" >&2
  return 1
}

APPEND=''
if [ "${1-}" = --append ]; then
  [ "$#" -ge 2 ] || { echo 'error: --append needs a file' >&2; exit 2; }
  APPEND=$2
  shift 2
fi
if [ "$#" -gt 0 ]; then
  text=$(printf '%s\n' "$*")
else
  text=$(cat)
fi
grep_rc=0
printf '%s\n' "$text" | grep -Ei "$pattern" >/dev/null || grep_rc=$?
case "$grep_rc" in
  0)
    echo 'owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead' >&2
    exit 1
    ;;
  1) ;;
  *) exit "$grep_rc" ;;
esac
if [ -n "$APPEND" ]; then
  case $APPEND in
    *.status)
      # shellcheck source=bin/jg-dod-lib.sh
      . "$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/jg-dod-lib.sh"
      hold_record_gate "$text" || exit 1
      wait_line_gate "$text" || exit 1
      recon_done_gate "$APPEND" "$text" || exit 1
      done_proof_gate "$APPEND" "$text" || exit 1
      ;;
  esac
  case $APPEND in *.status) done_line_move "$APPEND" "$text" || exit 1 ;; esac
  printf '%s\n' "$text" >> "$APPEND" || exit 1
fi
exit 0
