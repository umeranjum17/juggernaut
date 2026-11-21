#!/usr/bin/env bash
# jg-worker-start.sh - the one owner of "a ticket becomes an approved, briefed start" for work this home files itself.
#
# Usage: jg-worker-start.sh <ticket-id> <title> <project> --body-file <file> --task-file <file> --spec-file <file> [--priority <0-3>]
#
# It files the ticket (jg-backlog.sh add) in the sections a backlog row is read by, scaffolds the brief in the
# project's registered delivery mode (jg-brief.sh), fills the brief's two Task sections from the task and spec files,
# and approves the start on this home's route (jg-backlog.sh approve-dispatch). The dispatch check
# (core/auto-dispatch) then starts it; this command spawns nothing. The route is the rule config/crew-dispatch.json
# states for an approved ordinary implementation plan, else its default.
# Prints `<ticket-id> on <harness> <model> <effort>` and exits 0. Any refusal is one line on stderr with its cause
# and exit 1: the project's mode or the home's route cannot be read, the ticket or approval is refused, or the
# brief is not written. A repeat after a cut run finishes the start and files nothing twice. Callers: bin/jg-answer-route.sh (an answered card), core/goal-loop (a Goal's ship and fix steps).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
fail() { printf '%s\n' "$*" >&2; exit 1; }
last() { printf '%s' "$1" | tail -n 1 | cut -c1-200; }

[ "$#" -ge 3 ] || { sed -n '3,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
id=$1 title=$2 project=$3; shift 3
body='' task='' spec='' priority=2
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
route=
if [ -f "$CONFIG/crew-dispatch.json" ]; then
  rule=$(jq -c '
    ((.rules // []) | map(select((.when // "") | test("approved ordinary implementation plan"; "i")))) as $r
    | if ($r | length) > 0 then $r[0].use else (.default // {}) end' "$CONFIG/crew-dispatch.json" 2>/dev/null)
  [ -z "$rule" ] || route=$(printf '%s' "$rule" | jq -r '[.harness // empty, .model // empty, (.effort // "medium")] | join(" ")' 2>/dev/null)
fi
[ -n "$route" ] || fail "this home's dispatch config names no route"
read -r harness model effort <<< "$route"

# Each step is skipped when an earlier, cut run already did it, so a repeat finishes the start and never files twice.
if ! JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" show "$id" >/dev/null 2>&1; then
  out=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" add "$id" "$title" --kind ship --repo "$project" --priority "$priority" --body-file "$body" 2>&1) \
    || fail "the ticket was refused: $(last "$out")"
fi
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
