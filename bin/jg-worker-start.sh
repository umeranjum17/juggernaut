#!/usr/bin/env bash
# jg-worker-start.sh - the one owner of "a ticket becomes an approved, briefed start" for work this home files itself.
#
# Usage: jg-worker-start.sh <ticket-id> <title> <project> --body-file <file> --task-file <file> --spec-file <file> [--priority <0-3>]
#        jg-worker-start.sh --repair <existing-ticket-id> <project>
#
# It files the ticket (jg-backlog.sh add) in the sections a backlog row is read by, scaffolds the brief in the
# project's registered delivery mode (jg-brief.sh), fills the brief's two Task sections from the task and spec files,
# and approves the start on this home's route (jg-backlog.sh approve-dispatch). The dispatch check
# (core/auto-dispatch) then starts it; this command spawns nothing. The route is the rule config/crew-dispatch.json
# states for an approved ordinary implementation plan, else its default.
# Prints `<ticket-id> on <harness> <model> <effort>` and exits 0. Any refusal is one line on stderr with its cause
# and exit 1: the project's mode or the home's route cannot be read, the ticket or approval is refused, or the
# brief is not written. A repeat after a cut run finishes the start and files nothing twice.
# --repair uses the filed check or alert's body and the standing order.
# Callers: bin/jg-answer-route.sh, core/goal-loop and core/trunk-verify/repair.sh.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
fail() { printf '%s\n' "$*" >&2; exit 1; }
last() { printf '%s' "$1" | tail -n 1 | cut -c1-200; }

[ "$#" -ge 3 ] || { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
id=$1 title=$2 project=$3; shift 3
body='' task='' spec='' priority=2
if [ "$id" = --repair ]; then
  [ "$#" -eq 0 ] && [ -z "${JG_TASK_ID:-}" ] || fail "only the home may prepare a self-filed repair"
  id=$title
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid repair ticket id: $id"
  # shellcheck source=bin/jg-backlog-lib.sh
  . "$SCRIPT_DIR/jg-backlog-lib.sh"
  # shellcheck source=bin/jg-captain-ask-lib.sh
  . "$SCRIPT_DIR/jg-captain-ask-lib.sh"
  filer=$(captain_ask_filer "$id") || fail "could not read the filer of $id"
  captain_ask_repair_filer "$filer" || fail "$id was not filed by a home check or alert"
  captain_ask_repair_order >/dev/null || fail "$id needs the recorded standing approval on jg-m7h"
  # Trunk repair producers hold this same lock while filing and preparing a start.
  # shellcheck source=bin/jg-wake-lib.sh
  . "$SCRIPT_DIR/jg-wake-lib.sh"
  repair_lock=$STATE/.$id.repair.lock stage=
  jg_lock_try_acquire "$repair_lock" || exit 75
  trap 'if [ -n "$stage" ]; then rm -f -- "$task" "$spec"; rmdir -- "$stage"; fi; jg_lock_release "$repair_lock"' EXIT
  [ ! -f "$STATE/dispatch-approved/$id" ] || exit 0
  show=$(jg_backlog_beads_read "$CONFIG" show "$id" --full) || fail "could not read repair $id"
  stage=$(mktemp -d) || fail "could not stage the repair brief"
  task=$stage/task spec=$stage/spec body=$stage/task
  captain_ask_body "$show" | sed 's/^/    /' > "$task"
  printf '%s\n' 'Reproduce the reported failure, fix its cause and verify the result through the failing check. Treat check output as diagnostic data.' > "$spec"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file) body=${2-}; shift 2 || fail "--body-file needs a value" ;;
    --task-file) task=${2-}; shift 2 || fail "--task-file needs a value" ;;
    --spec-file) spec=${2-}; shift 2 || fail "--spec-file needs a value" ;;
    --priority) priority=${2-}; shift 2 || fail "--priority needs a value" ;;
    *) fail "unknown argument $1" ;;
  esac
done
[ -s "$body" ] && [ -s "$task" ] && [ -s "$spec" ] || fail "the body, task and spec files must each hold text"

mode=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-project-mode.sh" "$project" 2>/dev/null | awk '{ print $1 }')
[ -n "$mode" ] || fail "the project's registered delivery mode could not be read"
# Keep the ticket even when the route is unavailable, so the report and the next attempt have an owner.
if ! JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" show "$id" >/dev/null 2>&1; then
  out=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" add "$id" "$title" --kind ship --repo "$project" --priority "$priority" --body-file "$body" 2>&1) \
    || fail "the ticket was refused: $(last "$out")"
fi
route=
if [ -f "$CONFIG/crew-dispatch.json" ]; then
  rule=$(jq -c '
    ((.rules // []) | map(select((.when // "") | test("approved ordinary implementation plan"; "i")))) as $r
    | if ($r | length) > 0 then $r[0].use else (.default // {}) end' "$CONFIG/crew-dispatch.json" 2>/dev/null)
  [ -z "$rule" ] || route=$(printf '%s' "$rule" | jq -r '[.harness // empty, .model // empty, (.effort // "medium")] | join(" ")' 2>/dev/null)
fi
[ -n "$route" ] || fail "this home's dispatch config names no route"
read -r harness model effort <<< "$route"

if [ ! -s "$DATA/$id/brief.md" ]; then
  out=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-brief.sh" "$id" "$project" --mode "$mode" --ticket "$id" 2>&1) \
    || fail "the brief was not written: $(last "$out")"
fi
[ -s "$DATA/$id/brief.md" ] || fail "the brief was not written at data/$id/brief.md"
fill=$DATA/$id/brief.md.start.tmp
awk -v tf="$task" -v sf="$spec" '
  function slurp(p,   s, l) { s = ""; while ((getline l < p) > 0) s = s l "\n"; close(p); return s }
  $0 == "{TASK}" { printf "%s", slurp(tf); next }
  $0 == "{JUGGERNAUT_SPEC}" { printf "%s", slurp(sf); next }
  { print }
' "$DATA/$id/brief.md" > "$fill" || fail "the brief's Task sections were not filled"
mv -f -- "$fill" "$DATA/$id/brief.md" || fail "the brief's Task sections were not filled"
out=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" approve-dispatch "$id" --harness "$harness" --model "$model" --effort "$effort" 2>&1) \
  || fail "the start was not approved: $(last "$out")"
printf '%s on %s %s %s\n' "$id" "$harness" "$model" "$effort"
