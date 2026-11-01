#!/usr/bin/env bash
# jg-merge-on-green.sh - the deterministic merge watcher: no model turn sits
# between a pull request's required checks going green and the merge.
#
# Usage: jg-merge-on-green.sh sweep
#        jg-merge-on-green.sh approve <task-id>
#        jg-merge-on-green.sh latency [<path>]
#        jg-merge-on-green.sh --help
#
# `sweep` is one poll pass over every task in this home that has a recorded
# `pr=` and no merge yet, and bin/jg-watch.sh runs it on its own short cadence
# (JG_MERGE_ON_GREEN_INTERVAL, default 20 seconds) so the wait for a green
# required set is measured in seconds, not in how long a supervisor takes to
# notice. For each such task it asks bin/jg-pr-state.sh what the change is
# waiting on:
#   - a draft, conflicts, a red required check, or a required check that has not
#     reported is an ordinary wait: nothing runs and nothing is raised, because a
#     watcher that alerts on every pending check is noise;
#   - `the merge call` means every required check is green, so the sweep merges,
#     but only under authority it can name: the project's registered `+yolo`
#     posture (bin/jg-project-mode.sh) or a durable approval this home recorded
#     with `approve` when the captain said to land it. Without authority it does
#     nothing at all rather than attempting a merge it would be refused for.
#
# A refused merge raises exactly one alert per task and head, naming the gate's
# own refusal text, and never touches the pull request: bin/jg-pr-merge.sh owns
# every refusal, this script only reports the first one it sees. The marker
# data/jg-merge-on-green/<task>.<head>.refused makes "exactly one" true across
# restarts, and a new head is a new alert because it is a new verdict.
#
# Every merge it lands records the time from the task's `done` line to the
# merge, in whole minutes, in data/merge-latency.tsv: one header line, then one
# `<task> <pr> <done epoch> <merged epoch> <minutes> <path>` row per merge. A
# merge over JG_MERGE_LATENCY_LIMIT_MINUTES (default 5) raises one alert naming
# the number, because a five-minute path that silently takes eleven is the
# failure this whole feature exists to make visible. `latency` prints the rows
# and the worst and median minute count, so a reader never has to trust a
# promise.
#
# `approve` is the durable form of the captain's word: after he says to land a
# specific pull request, the lead records that approval here, and the sweep is
# allowed to merge that task once its required checks are green. The record is
# state/<task-id>.merge-go, a plain one-line record naming the URL it approves
# and the epoch it was recorded, so an approval cannot silently carry over to a
# different change.
#
# Nothing here writes to a project, reverts anything, or answers a gate
# refusal: a red required check is the worker's to fix, and the post-merge alarm
# is bin/jg-post-merge-ci.sh's, which files a fix-forward item and never a
# revert.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
DIR="$DATA/jg-merge-on-green"
LATENCY="$DATA/merge-latency.tsv"
LIMIT_MINUTES=${JG_MERGE_LATENCY_LIMIT_MINUTES:-5}

case "$LIMIT_MINUTES" in ''|*[!0-9]*) LIMIT_MINUTES=5 ;; esac

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'
}

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# One meta value, last occurrence, empty when absent.
meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# The epoch of the task's last `done` status line, empty when it never reported
# one: the clock the five minutes are measured from.
done_epoch() {  # <status-file>
  sed -n 's/^done \[at=\([0-9][0-9]*\)\]:.*/\1/p' "$1" 2>/dev/null | tail -n 1
}

raise() {  # <key> <text>
  # shellcheck source=bin/jg-wake-lib.sh
  if . "$SCRIPT_DIR/jg-wake-lib.sh" 2>/dev/null; then
    jg_wake_append check "$1" "$2" >/dev/null 2>&1 && return 0
  fi
  say "could not queue the wake for $1: $2"
  return 1
}

# The authority to merge under, or empty: `yolo` from the project's registered
# posture, or `approved` from this home's durable approval record.
merge_authority() {  # <task-id> <meta> <url>
  local id=$1 meta=$2 url=$3 project yolo_record posture approval_url
  approval_url=
  if [ -f "$STATE/$id.merge-go" ]; then
    approval_url=$(sed -n 's/^url=//p' "$STATE/$id.merge-go" | tail -n 1)
  fi
  if [ -n "$approval_url" ] && [ "$approval_url" = "$url" ]; then
    printf 'approved\n'
    return 0
  fi
  project=$(meta_value "$meta" project)
  [ -n "$project" ] || return 0
  yolo_record=$("$SCRIPT_DIR/jg-project-mode.sh" "$project" 2>/dev/null) || return 0
  posture=${yolo_record##* }
  [ "$posture" = on ] || return 0
  printf 'yolo\n'
}

# The forge's merge time for one pull request, epoch seconds, empty when
# unreadable.
merged_epoch() {  # <url>
  local when
  when=$(gh pr view "$1" --json mergedAt -q '.mergedAt // empty' 2>/dev/null) || return 0
  [ -n "$when" ] || return 0
  date -u -d "$when" +%s 2>/dev/null || true
}

record_latency() {  # <task-id> <url> <path>
  local id=$1 url=$2 path=$3 done_at merged_at minutes
  done_at=$(done_epoch "$STATE/$id.status")
  [ -n "$done_at" ] || { say "$id merged, but it has no done line to measure from"; return 0; }
  merged_at=$(merged_epoch "$url")
  [ -n "$merged_at" ] || merged_at=$(date +%s)
  minutes=$(( (merged_at - done_at) / 60 ))
  [ "$minutes" -ge 0 ] || minutes=0
  mkdir -p "$DATA" 2>/dev/null || true
  [ -s "$LATENCY" ] \
    || printf 'task\tpr\tdone_epoch\tmerged_epoch\tminutes\tpath\n' > "$LATENCY" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$url" "$done_at" "$merged_at" "$minutes" "$path" \
    >> "$LATENCY" 2>/dev/null || say "could not record the merge time for $id"
  say "$id merged in ${minutes}m from its done line (limit ${LIMIT_MINUTES}m)"
  if [ "$minutes" -gt "$LIMIT_MINUTES" ]; then
    raise "merge-latency-$id" \
      "check: $id took ${minutes} minutes from its done line to merged on main, over the ${LIMIT_MINUTES}-minute target; the required check set and its wait are named in $LATENCY" \
      || true
  fi
}

sweep_one() {  # <task-id> <meta>
  local id=$1 meta=$2 url kind state_line wait authority head refused out rc
  url=$(meta_value "$meta" pr)
  [ -n "$url" ] || return 0
  kind=$(meta_value "$meta" kind)
  case "$kind" in ship) ;; *) return 0 ;; esac
  wait=$("$SCRIPT_DIR/jg-pr-state.sh" --waiting-for "$url" 2>/dev/null) || return 0
  [ -n "$wait" ] || return 0
  case "$wait" in
    *'the merge call:'*) ;;
    *) return 0 ;;
  esac
  authority=$(merge_authority "$id" "$meta" "$url")
  [ -n "$authority" ] || return 0
  head=$(gh pr view "$url" --json headRefOid -q '.headRefOid // empty' 2>/dev/null) || head=
  [ -n "$head" ] || return 0
  refused="$DIR/$id.$head.refused"
  [ -e "$refused" ] && return 0
  mkdir -p "$DIR" 2>/dev/null || true
  out=$("$SCRIPT_DIR/jg-pr-merge.sh" "$id" "$url" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    if printf '%s %s\n' "$head" "$(date +%s)" > "$refused.tmp.$$" 2>/dev/null; then
      mv -f "$refused.tmp.$$" "$DIR/$id.merged" 2>/dev/null || rm -f "$refused.tmp.$$" 2>/dev/null
    fi
    say "$id merged on $authority authority at head $head"
    record_latency "$id" "$url" "$authority"
    return 0
  fi
  # Exactly one alert per task and head, naming the gate's own refusal text.
  if printf '%s\n' "$out" > "$refused.tmp.$$" 2>/dev/null; then
    mv -f "$refused.tmp.$$" "$refused" 2>/dev/null || rm -f "$refused.tmp.$$" 2>/dev/null
  fi
  state_line=$(printf '%s\n' "$out" | sed -n '/^error:/p;/refus/p' | head -n 3 | tr '\n' ' ')
  [ -n "$state_line" ] || state_line=${out:-no output}
  raise "merge-on-green-$id-$head" \
    "check: merge-on-green could not merge $id ($url) at head $head under $authority authority: $state_line" \
    || true
  say "$id was refused at head $head; one alert was raised"
}

sweep() {
  local meta id
  command -v gh >/dev/null 2>&1 || { say 'gh is unavailable, so no pull request can be read'; return 0; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    sweep_one "$id" "$meta"
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    sweep) sweep ;;
    approve)
      if [ "$#" -ne 2 ] || [ -z "$2" ]; then
        echo "error: approve needs <task-id>" >&2
        exit 2
      fi
      if [ ! -f "$STATE/$2.meta" ]; then
        echo "error: no task record for $2" >&2
        exit 1
      fi
      url=$(meta_value "$STATE/$2.meta" pr)
      if [ -z "$url" ]; then
        echo "error: $2 has no recorded pull request to approve" >&2
        exit 1
      fi
      {
        printf 'schema=jg-merge-go.v1\n'
        printf 'task=%s\n' "$2"
        printf 'url=%s\n' "$url"
        printf 'approved_at=%s\n' "$(date +%s)"
      } > "$STATE/$2.merge-go.tmp.$$" || exit 1
      mv -f "$STATE/$2.merge-go.tmp.$$" "$STATE/$2.merge-go" || exit 1
      chmod 600 "$STATE/$2.merge-go" 2>/dev/null || true
      printf 'approved: %s may merge on its required checks at %s\n' "$2" "$url"
      ;;
    latency)
      path=${2:-$LATENCY}
      [ -s "$path" ] || { echo "no merge has been recorded yet"; exit 0; }
      cat "$path"
      awk -F '\t' 'NR > 1 && $5 ~ /^[0-9]+$/ { print $5 }' "$path" \
        | sort -n \
        | awk '{ v[NR] = $1; total += $1 }
               END {
                 if (NR == 0) { print "count=0"; exit }
                 median = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
                 printf "count=%d worst=%dm median=%sm\n", NR, v[NR], median
               }'
      ;;
    '') usage; exit 2 ;;
    *) echo "error: unknown command $1; run --help" >&2; exit 2 ;;
  esac
}

main "$@"
