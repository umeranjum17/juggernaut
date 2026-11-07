#!/usr/bin/env bash
# The design gate: every rule is a shell check on recorded files; nothing here calls a model.
# Usage: jg-design-gate.sh size <worktree> <base-branch> <head>
#        jg-design-gate.sh handroll <task-id> [--task-home <home>]
#        jg-design-gate.sh board <first-draft-receipt> <options-folder-or-file>...
#
# Size rule: a change is a small tweak, free to be hand-rolled, when its UI files
# (.html .htm .css .scss .sass .less .svg .jsx .tsx .vue .svelte .astro) change at most
# 40 lines, added plus deleted, against the merge base, and it adds no new UI file.
# A UI file that only loses lines adds none, so it counts as no UI line at all: taking
# a page or a stylesheet apart is not design work and needs no design receipt.
# Both halves detect renames, so a file that only moved is neither a changed line nor a
# new file: moving a page or an image is not design work. A file that really is added, or
# really gains lines, still counts and still refuses on its own merits.
# Past that it is design work, as is every task briefed `--design-call yes`.
# `size` prints `design|tweak <ui-lines> <new-ui-files>` and exits 2 when it cannot measure.
#
# bin/jg-merge-gate-lib.sh's jg_dod_design_gate runs the rule on both merge paths:
# design work merges only with a PASS completion receipt for the head that carries
# `first-draft receipt: <ref>`, and a small tweak that touches any UI line merges only
# with a hand-roll approval. A change with no UI line needs neither.
# The receipt is resolved, never taken on its word: its run record must prove a
# first-draft make or refine and list every design option the work presents, so a
# judge-only record (made nothing) and hand-authored option HTML are refused by name.
# `board` is that same check for a board post of design options: it takes the run
# record and the options about to be posted, and refuses before they are shown.
# `handroll` writes that approval: it measures the task's work copy HEAD, refuses past
# the size rule, and writes <task home state>/design-approvals/<task-id>.handroll.json.
# Only the task's own home (its lead) or Main writes it, and it refuses a caller with
# JG_TASK_ID set: the worker that asks never approves its own work. The gate measures
# the size again at merge, so an approval never covers a change that grew past the rule.
# --task-home names the home that owns the task when Main approves a lead's task.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$SCRIPT_DIR/jg-merge-gate-lib.sh"

die() { echo "jg-design-gate: $*" >&2; exit 1; }
cmd=${1:-}; [ "$#" -gt 0 ] && shift
case $cmd in
  size)
    [ "$#" -eq 3 ] || die "usage: size <worktree> <base-branch> <head>"
    jg_design_size "$@"; exit $?
    ;;
  handroll) ;;
  board)
    [ "$#" -ge 2 ] || die "usage: board <first-draft-receipt> <options-folder-or-file>..."
    ref=$1; shift
    args=(--ref "$ref" --root "$PWD"); opts=()
    for a in "$@"; do
      [ -d "$a" ] || { opts+=("$a"); continue; }
      args+=(--root "$a")
      while IFS= read -r f; do opts+=("$f"); done < <(find "$a" -maxdepth 1 -type f -iname '*.html' | LC_ALL=C sort)
    done
    jg_design_fd_check ${args[@]+"${args[@]}"} -- ${opts[@]+"${opts[@]}"} || exit 1
    printf 'board: %s design option(s) made or refined by first-draft (%s)\n' "${#opts[@]}" "$ref"
    exit 0
    ;;
  *) die "usage: size|handroll|board (see the header)" ;;
esac
[ -n "${JG_HOME:-}" ] || die "JG_HOME must name this home"
ID=${1:-}; [ "$#" -gt 0 ] && shift
case $ID in ''|-*|*/*) die "usage: handroll <task-id> [--task-home <home>]" ;; esac
TASK_HOME=$JG_HOME
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ "$1" = --task-home ] || die "unknown or incomplete flag $1"
  TASK_HOME=$2; shift 2
done
[ -z "${JG_TASK_ID:-}" ] || die "handroll refused: the worker that asks (task $JG_TASK_ID) never approves; its lead or Main does"
MAIN=$(jg_design_main_home "$JG_HOME") || die "cannot find the main home from $JG_HOME"
[ "$JG_HOME" = "$TASK_HOME" ] || [ "$MAIN" = "$JG_HOME" ] || die "handroll refused: only $TASK_HOME's lead or Main approves a hand-roll"
if [ "$TASK_HOME" = "$JG_HOME" ]; then TSTATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; else TSTATE=$TASK_HOME/state; fi
wt=$(jg_dod_meta_value "$TSTATE/$ID.meta" worktree)
head=$(git -C "${wt:-/nonexistent}" rev-parse HEAD 2>/dev/null) || die "cannot read the work copy of $ID from $TSTATE/$ID.meta"
size=$(jg_design_size "$wt" "$(jg_dod_meta_value "$TSTATE/$ID.meta" base_branch)" "$head") || die "cannot measure the UI change of $ID"
case $size in design*) die "handroll refused: $ID changes ${size#design } (UI lines, new UI files), past the small-tweak size; it needs first-draft" ;; esac
mkdir -p "$TSTATE/design-approvals" || die "cannot write $TSTATE/design-approvals"
jq -n --arg id "$ID" --arg h "$head" --arg sz "$size" --arg by "$JG_HOME" --argjson now "$(date +%s)" \
  '{schema: 1, task: $id, head: $h, size: $sz, by: $by, at: $now}' > "$TSTATE/design-approvals/$ID.handroll.json" || die "cannot write the hand-roll approval"
echo "hand-roll approved: $ID ($size)"
