#!/usr/bin/env bash
# jg-check-live-pipeline.sh - refuse while any home still has a no-mistakes pipeline run under way.
#
#   jg-check-live-pipeline.sh [home ...]
#
# The removal of the no-mistakes tool (ticket jg8-j20d) may only go on when no run is in flight:
# deleting the code that reads a run would orphan it. For each home (default: JG_HOME) this reads
# every ship task record (a record with no kind is a ship) in <home>/state, asks the pipeline for the status of that task's worktree
# and reports each run that has no terminal outcome. A task with no worktree, or a worktree that
# the pipeline does not know, has no run.
# Exit 0: no live run in any home (also when no-mistakes is not installed). Exit 1: a live run
# exists; each is printed as `live pipeline run: <home> <task> <status>`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'; exit 0 ;;
esac
# shellcheck source=bin/jg-nm-run-lib.sh
. "$SCRIPT_DIR/jg-nm-run-lib.sh"

[ "$#" -gt 0 ] || set -- "${JG_HOME:-$JG_ROOT}"
command -v no-mistakes >/dev/null 2>&1 || { echo "no live pipeline run: no-mistakes is not installed"; exit 0; }

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

live=0
for home in "$@"; do
  [ -d "$home/state" ] || { echo "jg-check-live-pipeline: no state directory in $home" >&2; exit 2; }
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(meta_value "$meta" kind)
    [ -z "$kind" ] || [ "$kind" = ship ] || continue
    wt=$(meta_value "$meta" worktree)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    out=$(jg_nm_run "$wt" 15 axi status) || out=
    printf '%s\n' "$out" | grep -q '^run:' || continue
    jg_nm_run_is_active "$out" || continue
    echo "live pipeline run: $home $(basename "$meta" .meta) $(jg_nm_strip_quotes "$(jg_nm_field "$out" status)")"
    live=1
  done
done
[ "$live" = 0 ] || exit 1
echo "no live pipeline run"
