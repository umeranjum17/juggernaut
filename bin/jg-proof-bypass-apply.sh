#!/usr/bin/env bash
# jg-proof-bypass-apply.sh - the tick's use of the owner's bypass: a lane that reported done inside a standing bypass is not proved.
#
# Usage: jg-proof-bypass-apply.sh <jg-home>
#
# For each local-trunk lane of the home whose last status line is a done line (the lane is a Ship; a Recon has its own gate), in the
# scope of a standing bypass (bin/jg-proof-bypass.sh find):
#   - a done-done run of the lane that is still under way is ended with `done-done abort`, and none is started;
#   - the first time for this done line, in this order: the ticket makes the move `bypass` (bin/jg-move.sh, checked against the
#     ticket table), `bypassed_at` is written on the ticket's row, the use is counted, and then the bypass record for that exact
#     commit is written (bin/jg-bypass-record-lib.sh). The record comes last, so a step that failed is tried again by the next tick;
#   - when the lane's head changed with no new done line (a rebase), only the record is written again, for the new commit.
# The landing takes the record where it takes a completion receipt (jg_dod_trunk_proof_gaps). Lint, the rebase check, yolo and the
# line's verify are not touched: delivering runs as for any change. A lane with a record for its head is left alone.
# Prints one line for each lane it changed. Exit 0; a lane that could not be handled prints a reason on stderr and the pass goes on.
# Env: JG_PROOF_BYPASS_DONE_DONE names another done-done binary (tests).
set -u
export LC_ALL=C
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: jg-proof-bypass-apply.sh <jg-home>  (a home with a state directory)" >&2; exit 2; }
H=$(cd "$1" && pwd -P)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export JG_HOME=$H JG_STATE_OVERRIDE=${JG_STATE_OVERRIDE:-$H/state} JG_CONFIG_OVERRIDE=${JG_CONFIG_OVERRIDE:-$H/config} JG_DATA_OVERRIDE=${JG_DATA_OVERRIDE:-$H/data}
STATE=$JG_STATE_OVERRIDE
[ -s "$JG_CONFIG_OVERRIDE/proof-bypass" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-bypass-record-lib.sh
. "$SCRIPT_DIR/jg-bypass-record-lib.sh"
PB=$SCRIPT_DIR/jg-proof-bypass.sh
DONE_DONE=${JG_PROOF_BYPASS_DONE_DONE:-done-done}

# The epoch of the lane's done line, when the last status line is one.
done_epoch() {
  local line; line=$(tail -n 1 "$STATE/$1.status" 2>/dev/null || true)
  case $line in done\ *|done:*) printf '%s\n' "$line" | sed -n 's/^done[^[]*\[at=\([0-9]*\)\].*/\1/p' | grep . || echo 0 ;; *) return 1 ;; esac
}

# End a done-done run of the lane that is still under way (`done-done status` exits 4 while a run is running).
abort_run() {  # <worktree>
  [ -d "$1" ] || return 0
  local rc=0
  (cd "$1" && "$DONE_DONE" status >/dev/null 2>&1) || rc=$?
  [ "$rc" -eq 4 ] || return 0
  (cd "$1" && "$DONE_DONE" abort >/dev/null 2>&1) && echo "proof bypass: ended the done-done run under way in $1" \
    || echo "jg-proof-bypass-apply: could not end the done-done run under way in $1" >&2
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  mode=$(jg_dod_meta_value "$meta" mode); proj=$(jg_dod_meta_value "$meta" project)
  [ "$(jg_dod_meta_value "$meta" kind)" != scout ] || continue
  jg_dod_trunk_lane "$mode" "$proj" || continue
  at=$(done_epoch "$id") || continue
  branch=$(jg_dod_meta_value "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || continue
  jg_bypass_record_holds "$H" "$STATE" "$id" "$head" && continue
  bp=$(jg_bypass_standing "$H" "$id" "$(basename "$proj")") || continue
  IFS=$'\t' read -r scope _ word < <(bash "$PB" show "$bp") || continue
  abort_run "$(jg_dod_meta_value "$meta" worktree)"
  record=$(jg_bypass_record_file "$STATE" "$id")
  # The same done line as the record on file: the head moved by a rebase, so only the record is written again.
  if [ -f "$record" ] && [ "$(jq -r '.done_at // empty' "$record" 2>/dev/null)" = "$at" ]; then
    jg_bypass_record_write "$STATE" "$id" "$id" "$head" "$bp" "$scope" "$word" "$at" \
      && echo "proof bypass $bp: $id rebased to ${head:0:12}, the record is written again" \
      || echo "jg-proof-bypass-apply: could not write the bypass record of $id" >&2
    continue
  fi
  # The first time for this done line.
  bash "$SCRIPT_DIR/jg-move.sh" "$id" bypass || { echo "jg-proof-bypass-apply: $id: the move bypass was refused, so nothing else was written" >&2; continue; }
  bash "$SCRIPT_DIR/jg-backlog.sh" moment "$id" bypassed_at >/dev/null || { echo "jg-proof-bypass-apply: could not write bypassed_at on $id; the next tick tries again" >&2; continue; }
  bash "$PB" use "$bp" || { echo "jg-proof-bypass-apply: could not count the use of $bp for $id" >&2; continue; }
  jg_bypass_record_write "$STATE" "$id" "$id" "$head" "$bp" "$scope" "$word" "$at" \
    && echo "proof bypass $bp: $id passed over proving at ${head:0:12} (no proof ran)" \
    || echo "jg-proof-bypass-apply: could not write the bypass record of $id" >&2
done
exit 0
