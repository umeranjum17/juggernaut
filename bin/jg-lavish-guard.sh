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
# This file is the one core owner of both refusals. bin/jg-squad-lead-report.sh
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
  command -v jq >/dev/null 2>&1 || { _unchecked 'jq is not installed'; return 0; }
  mode=$(jg_dod_meta_value "$meta" mode)
  JG_HOME=$home jg_dod_trunk_lane "$mode" "$(jg_dod_meta_value "$meta" project)" \
    || { _unchecked "it is a ${mode:-no-mode} lane, not a local-trunk one"; return 0; }
  wt=$(jg_dod_meta_value "$meta" worktree)
  head=$(git -C "${wt:-/nonexistent}" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) \
    || { _unchecked "no head in its isolated copy ${wt:-(none recorded)}"; return 0; }
  gaps=$(JG_HOME=$home jg_dod_trunk_proof_gaps "$home" "$state" "$id" "$meta" "$head") && return 0
  {
    printf 'done refused: the landing would refuse head %s of %s for missing proof, so nothing was written to %s:\n' "${head:0:12}" "$id" "$file"
    printf '%s\n' "$gaps" | sed 's/^/  - /'
    echo 'Complete the proof at this head and append done again; if it cannot be finished, append a blocked: line that says why.'
  } >&2
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
      done_proof_gate "$APPEND" "$text" || exit 1
      ;;
  esac
  printf '%s\n' "$text" >> "$APPEND" || exit 1
fi
exit 0
