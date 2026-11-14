#!/usr/bin/env bash
# jg-recon-handoff.sh - the one owner of a Recon's draft, critic verdict and revision (machine: core/machines/tables/recon.tsv).
#
# Usage:
#   jg-recon-handoff.sh draft   <task-id>                                        record the draft: the sha256 of data/<task-id>/report.md
#   jg-recon-handoff.sh verdict <task-id> --critic <id> --hash <sha256> --gaps <k>   the critic's answer for the draft it read
#   jg-recon-handoff.sh revise  <task-id>                                        record a revised draft after a verdict with gaps
#   jg-recon-handoff.sh phase   <task-id>                                        print drafted, critiqued, accepted or none
#   jg-recon-handoff.sh show    <task-id>                                        print the record, one line per move
#
# The record is data/<task-id>/handoff.tsv, append-only: epoch, event, state after, report hash, actor, gaps. Its last line is the state.
# Every move is tied to the report hash, so an answer about an older draft cannot close a newer one: a verdict is refused (exit 1,
# nothing written) when the hash it names is not the recorded draft, or when report.md changed after the draft was recorded; a revise is
# refused when report.md still holds the critiqued draft. A verdict also writes the gate's own lines into critic.md (`Critic:` once, then
# `Round <n>: new gaps <k> report <sha>`), the format bin/jg-recon-gate.sh reads, so no one installs that file by hand.
# Each move is judged by bin/jg-machine-guard.sh (shadow, or refusal once `recon` is in config/machine-enforce) before it is written.
# Exit: 0 done, 1 refused, 2 usage. Data directory: JG_DATA_OVERRIDE, else <JG_HOME>/data.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME=${JG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
export JG_HOME

die() { echo "jg-recon-handoff: $*" >&2; exit 2; }
refuse() { echo "jg-recon-handoff: refused: $*" >&2; exit 1; }
usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

task_dir() {  # <task-id> -> the data directory of a plain task id
  case "${1:-}" in ''|*/*|.*) die "task id '${1:-}' is not a plain id" ;; esac
  [ -d "$DATA/$1" ] || die "no task directory at $DATA/$1"
  printf '%s\n' "$DATA/$1"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
last_line() { [ -s "$1/handoff.tsv" ] && tail -n 1 "$1/handoff.tsv" || true; }
field() { printf '%s\n' "$1" | cut -f"$2"; }  # <line> <column>

command_phase() {
  local dir line; dir=$(task_dir "${1:-}") || exit $?; line=$(last_line "$dir")
  if [ -n "$line" ]; then field "$line" 3; else echo none; fi
}

command_show() {
  local dir; dir=$(task_dir "${1:-}") || exit $?
  [ -s "$dir/handoff.tsv" ] && cat "$dir/handoff.tsv" || echo none
}

record() {  # <dir> <id> <event> <to> <hash> <actor> <gaps>; judge the move, then append one line
  local dir=$1 id=$2 event=$3 to=$4 from
  from=$(command_phase "$id"); [ "$from" != none ] || from=-
  "$SCRIPT_DIR/jg-machine-guard.sh" edge recon "$from" "$to" "$id" >/dev/null 2>&1 \
    || refuse "the recon table has no move from $from to $to ($event)"
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
  record "$dir" "$id" draft drafted "$hash" researcher 0
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
  [ "$(field "$line" 3)" = drafted ] || refuse "the last move is $(field "$line" 2) ($(field "$line" 3)); a verdict answers a draft waiting for its critic"
  rec=$(field "$line" 4)
  [ "$hash" = "$rec" ] || refuse "stale verdict: it names report ${hash:0:12} and the recorded draft is ${rec:0:12}"
  cur=$(report_hash "$dir") || exit $?
  [ "$cur" = "$rec" ] || refuse "report.md changed after the draft was recorded (${rec:0:12} -> ${cur:0:12}): record the revision first"
  if [ "$gaps" -eq 0 ]; then event=clear; to=accepted; else event=gaps; to=critiqued; fi
  record "$dir" "$id" "$event" "$to" "$hash" "$critic" "$gaps" || exit $?
  [ -f "$dir/critic.md" ] && grep -q '^Critic:' "$dir/critic.md" || printf 'Critic: %s\n' "$critic" >> "$dir/critic.md"
  n=$(( $(grep -c '^Round [0-9]*:' "$dir/critic.md") + 1 ))
  printf 'Round %s: new gaps %s report %s\n' "$n" "$gaps" "$hash" >> "$dir/critic.md"
}

command_revise() {
  local id=${1:-} dir line hash; dir=$(task_dir "$id") || exit $?
  line=$(last_line "$dir")
  [ -n "$line" ] || refuse "no draft is recorded: the researcher runs draft first"
  [ "$(field "$line" 3)" = critiqued ] || refuse "the last move is $(field "$line" 2) ($(field "$line" 3)); a revision follows a verdict with gaps"
  hash=$(report_hash "$dir") || exit $?
  [ "$hash" != "$(field "$line" 4)" ] || refuse "report.md still holds the critiqued draft ${hash:0:12}: change it before recording the revision"
  record "$dir" "$id" revise drafted "$hash" researcher 0
}

cmd=${1:-}; [ "$#" -gt 0 ] && shift
case "$cmd" in
  draft) command_draft "$@" ;;
  verdict) command_verdict "$@" ;;
  revise) command_revise "$@" ;;
  phase) command_phase "$@" ;;
  show) command_show "$@" ;;
  *) usage ;;
esac
