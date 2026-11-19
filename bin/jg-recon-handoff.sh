#!/usr/bin/env bash
# jg-recon-handoff.sh - the one owner of a Recon's draft, critic verdict and revision (machine: core/machines/tables/recon.tsv).
#
# Usage:
#   jg-recon-handoff.sh draft   <task-id>                                        record the draft: the sha256 of data/<task-id>/report.md
#   jg-recon-handoff.sh assign  <task-id> --critic <critic-task-id>              the lead names the critic ticket that holds this draft
#   jg-recon-handoff.sh verdict <task-id> --critic <id> --hash <sha256> --gaps <k>   the critic's answer for the draft it read
#   jg-recon-handoff.sh revise  <task-id>                                        record a revised draft after a verdict with gaps
#   jg-recon-handoff.sh assignee <task-id>                                       print critic, generation and hash of the live assignment, or none
#   jg-recon-handoff.sh phase   <task-id>                                        print drafted, assigned, critiqued, accepted or none
#   jg-recon-handoff.sh show    <task-id>                                        print the record, one line per move
#
# The record is data/<task-id>/handoff.tsv, append-only: epoch, event, state after, report hash, actor, gaps. Its last line is the state.
# Every move is tied to the report hash, so an answer about an older draft cannot close a newer one: a verdict is refused (exit 1,
# nothing written) when the hash it names is not the recorded draft, or when report.md changed after the draft was recorded; a revise is
# refused when report.md still holds the critiqued draft. A verdict also writes the gate's own lines into critic.md (`Critic:` once, then
# `Round <n>: new gaps <k> report <sha>`), the format bin/jg-recon-gate.sh reads, so no one installs that file by hand.
# A critic is a separate ticket of its own (a task directory with its own data): assign records it in this one record, so the assignment
# survives a restart of any worker, writes the pointer data/<critic>/assignment.tsv (parent, generation, hash) and the critic's own
# `Critic:` line, and is a no-op for the same critic. Once assigned, only that critic's verdict counts and the parent record alone says
# whether the draft is accepted: the verdict also writes the critic ticket's own `Round` line, so its gate view follows the parent and
# never decides it. A revise retires the assignment, so a late verdict cannot seal the new draft; a draft that was never assigned still
# takes a verdict from any named critic. A second critic while one holds the draft is refused: with config/item-store the store answers it (an
# open work item whose parent is the Recon's work), `refused: <recon> already has an open critic <id>`.
# With config/item-store, assign also opens the critic's work item as the child of the Recon's (the link a ready draft finds its critic
# by), and draft and revise send the round to that critic (core/item-store: jg-item ready); the store adds no rule of its own.
# Exit: 0 done, 1 refused, 2 usage. Data directory: JG_DATA_OVERRIDE, else <JG_HOME>/data.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME=${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
export JG_HOME

die() { echo "jg-recon-handoff: $*" >&2; exit 2; }
refuse() { echo "jg-recon-handoff: refused: $*" >&2; exit 1; }
usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

task_dir() {  # <task-id> -> the data directory of a plain task id
  case "${1:-}" in ''|*/*|.*) die "task id '${1:-}' is not a plain id" ;; esac
  [ -d "$DATA/$1" ] || die "no task directory at $DATA/$1"
  printf '%s\n' "$DATA/$1"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
last_line() { [ -s "$1/handoff.tsv" ] && tail -n 1 "$1/handoff.tsv" || true; }
field() { printf '%s\n' "$1" | cut -f"$2"; }  # <line> <column>

# The item store (core/item-store), guarded by the home's own switch: silent, and never a reason to change this command's output or
# exit; today's record (handoff.tsv) decides. A refused write becomes one intake item on Main (JG_ITEM_OR_INTAKE=1).
ITEM=$SCRIPT_DIR/../core/item-store/jg-item
item_store_on() { [ -e "$JG_HOME/config/item-store" ] && [ -x "$ITEM" ]; }
item_work_key() {  # <task-id> -> key, subject and project of that task's work item
  JG_HOME=$JG_HOME "$ITEM" key work --task "$1" 2>/dev/null
}
item_assign() {  # <recon> <critic>: the critic's work item, linked to the Recon's by parent (the one place a lead names a critic)
  item_store_on || return 0
  local key subject project hid
  IFS=$'\t' read -r key subject project < <(item_work_key "$2") || return 0
  [ -n "${key:-}" ] && [ -n "${project:-}" ] && [ "$project" != - ] || return 0
  hid=${key#work:}; hid=${hid%%/*}
  JG_HOME=$JG_HOME JG_ITEM_OR_INTAKE=1 "$ITEM" open "$key" --kind work --home "$hid" --subject "$subject" --project "$project" \
    --owes "critique $1" --lane "worker:$hid/$2" --parent "work:$hid/$1" --source "assign:$1@$2" >/dev/null 2>&1 || true
}
item_ready() {  # <recon> <draft hash>: the next round goes to the linked critic, or a dispatch asks for one (Y8)
  item_store_on || return 0
  local key
  key=$(item_work_key "$1" | cut -f1)
  [ -n "$key" ] && JG_HOME=$JG_HOME python3 -I "$SCRIPT_DIR/../core/item-store/adapters/lane.py" has-open "$key" || return 0
  JG_HOME=$JG_HOME JG_ITEM_OR_INTAKE=1 "$ITEM" ready "$key" "$2" --source "ready:$1@$2" >/dev/null 2>&1 || true
}

item_open_critic() {  # <recon> -> the task id of the critic's open work item, empty when none (or no store)
  item_store_on || return 0
  local key out
  key=$(item_work_key "$1" | cut -f1)
  [ -n "$key" ] || return 0
  out=$(JG_HOME=$JG_HOME python3 -I "$SCRIPT_DIR/../core/item-store/adapters/lane.py" open-child "$key" 2>/dev/null) || return 0
  out=${out#work:*/}; printf '%s\n' "${out%%#*}"
}

command_phase() {
  local dir line; dir=$(task_dir "${1:-}") || exit $?; line=$(last_line "$dir")
  if [ -n "$line" ]; then field "$line" 3; else echo none; fi
}

command_show() {
  local dir; dir=$(task_dir "${1:-}") || exit $?
  [ -s "$dir/handoff.tsv" ] && cat "$dir/handoff.tsv" || echo none
}

record() {  # <dir> <id> <event> <to> <hash> <actor> <gaps>; append one line
  local dir=$1 id=$2 event=$3 to=$4
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$event" "$to" "$5" "$6" "$7" >> "$dir/handoff.tsv"
  echo "recon $id: $event -> $to (report ${5:0:12})"
}

report_hash() {  # <dir>
  [ -s "$1/report.md" ] || refuse "no report.md in $1"
  sha_of "$1/report.md"
}

command_draft() {
  local id=${1:-} dir hash; dir=$(task_dir "$id") || exit $?
  [ -z "$(last_line "$dir")" ] || refuse "a draft is already recorded; a new draft after a verdict with gaps is a revise"
  hash=$(report_hash "$dir") || exit $?
  record "$dir" "$id" draft drafted "$hash" researcher 0 || return $?
  item_ready "$id" "$hash"
}

# The live assignment of a record's last line: critic, generation (the number of assign moves) and hash; empty when none holds.
live_assignment() {  # <dir>
  local line; line=$(last_line "$1")
  [ -n "$line" ] && [ "$(field "$line" 3)" = assigned ] || return 0
  printf '%s\t%s\t%s\n' "$(field "$line" 5)" "$(grep -c "$(printf '^[0-9]*\tassign\t')" "$1/handoff.tsv")" "$(field "$line" 4)"
}

command_assignee() {
  local dir out; dir=$(task_dir "${1:-}") || exit $?
  out=$(live_assignment "$dir"); printf '%s\n' "${out:-none}"
}

command_assign() {
  local id=${1:-} dir critic='' line hash cdir live gen open
  [ "$#" -ge 1 ] || usage; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --critic) [ "$#" -ge 2 ] || usage; critic=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  dir=$(task_dir "$id") || exit $?
  [ -n "$critic" ] || usage
  case "$critic" in *[[:space:]]*) die "--critic takes one ticket id" ;; esac
  [ "$(printf '%s' "$critic" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" ] \
    && [ "$critic" != self ] || refuse "the critic is a separate ticket: $critic is the researcher's own"
  cdir=$(task_dir "$critic") || exit $?
  line=$(last_line "$dir")
  [ -n "$line" ] || refuse "no draft is recorded: the researcher runs draft first"
  live=$(live_assignment "$dir")
  if [ -n "$live" ] && [ "$(printf '%s' "$live" | cut -f1)" = "$critic" ]; then
    echo "recon $id: $critic already holds this draft (generation $(printf '%s' "$live" | cut -f2))"; return 0
  fi
  open=$(item_open_critic "$id")
  [ -z "$open" ] || refuse "$id already has an open critic $open"
  [ "$(field "$line" 3)" = drafted ] || refuse "the last move is $(field "$line" 2) ($(field "$line" 3)); a critic is assigned to a draft waiting for one"
  hash=$(field "$line" 4)
  [ "$(report_hash "$dir")" = "$hash" ] || refuse "report.md changed after the draft was recorded: record the revision first"
  record "$dir" "$id" assign assigned "$hash" "$critic" 0 || exit $?
  gen=$(grep -c "$(printf '^[0-9]*\tassign\t')" "$dir/handoff.tsv")
  printf '%s\t%s\t%s\n' "$id" "$gen" "$hash" > "$cdir/assignment.tsv"
  grep -q '^Critic:' "$cdir/critic.md" 2>/dev/null || printf 'Critic: %s\n' "$critic" >> "$cdir/critic.md"
  item_assign "$id" "$critic"
}

command_verdict() {
  local id=${1:-} dir critic='' hash='' gaps='' line cur rec n to event
  [ "$#" -ge 1 ] || usage; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --critic) [ "$#" -ge 2 ] || usage; critic=$2; shift 2 ;;
      --hash) [ "$#" -ge 2 ] || usage; hash=$2; shift 2 ;;
      --gaps) [ "$#" -ge 2 ] || usage; gaps=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  dir=$(task_dir "$id") || exit $?
  [ -n "$critic" ] && [ -n "$hash" ] || usage
  case "$gaps" in ''|*[!0-9]*) die "--gaps takes a count" ;; esac
  case "$critic" in *[[:space:]]*) die "--critic takes one id" ;; esac
  [[ $hash =~ ^[0-9a-f]{64}$ ]] || die "--hash takes the sha256 of the report the critic read"
  line=$(last_line "$dir")
  [ -n "$line" ] || refuse "no draft is recorded: the researcher runs draft first"
  case "$(field "$line" 3)" in
    drafted|assigned) ;;
    *) refuse "the last move is $(field "$line" 2) ($(field "$line" 3)); a verdict answers a draft waiting for its critic" ;;
  esac
  [ "$(field "$line" 3)" != assigned ] || [ "$critic" = "$(field "$line" 5)" ] \
    || refuse "critic $(field "$line" 5) holds this draft; a verdict from $critic does not count"
  rec=$(field "$line" 4)
  [ "$hash" = "$rec" ] || refuse "stale verdict: it names report ${hash:0:12} and the recorded draft is ${rec:0:12}"
  cur=$(report_hash "$dir") || exit $?
  [ "$cur" = "$rec" ] || refuse "report.md changed after the draft was recorded (${rec:0:12} -> ${cur:0:12}): record the revision first"
  if [ "$gaps" -eq 0 ]; then event=clear; to=accepted; else event=gaps; to=critiqued; fi
  record "$dir" "$id" "$event" "$to" "$hash" "$critic" "$gaps" || exit $?
  write_round "$dir" "$critic" "$gaps" "$hash"
  # The critic ticket's own file follows the parent's verdict: it holds the pointer, never the decision.
  [ "$(cut -f1 "$DATA/$critic/assignment.tsv" 2>/dev/null)" != "$id" ] || write_round "$DATA/$critic" "$critic" "$gaps" "$hash"
}

write_round() {  # <dir> <critic> <gaps> <hash>: the gate's own lines in <dir>/critic.md
  local n
  [ -f "$1/critic.md" ] && grep -q '^Critic:' "$1/critic.md" || printf 'Critic: %s\n' "$2" >> "$1/critic.md"
  n=$(( $(grep -c '^Round [0-9]*:' "$1/critic.md") + 1 ))
  printf 'Round %s: new gaps %s report %s\n' "$n" "$3" "$4" >> "$1/critic.md"
}

command_revise() {
  local id=${1:-} dir line hash; dir=$(task_dir "$id") || exit $?
  line=$(last_line "$dir")
  [ -n "$line" ] || refuse "no draft is recorded: the researcher runs draft first"
  case "$(field "$line" 3)" in
    critiqued|assigned) ;;
    *) refuse "the last move is $(field "$line" 2) ($(field "$line" 3)); a revision follows a verdict with gaps or a changed draft under review" ;;
  esac
  hash=$(report_hash "$dir") || exit $?
  [ "$hash" != "$(field "$line" 4)" ] || refuse "report.md still holds the critiqued draft ${hash:0:12}: change it before recording the revision"
  record "$dir" "$id" revise drafted "$hash" researcher 0 || return $?
  item_ready "$id" "$hash"
}

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  draft) command_draft "$@" ;;
  verdict) command_verdict "$@" ;;
  revise) command_revise "$@" ;;
  assign) command_assign "$@" ;;
  assignee) command_assignee "$@" ;;
  phase) command_phase "$@" ;;
  show) command_show "$@" ;;
  *) usage ;;
esac
