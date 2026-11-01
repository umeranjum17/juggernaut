#!/usr/bin/env bash
# jg-reply-engine.sh - one pending reply as a durable workflow instance, decided
# from the event log: the fold, the decision, the shadow tick and the replay.
#
# WHY THIS EXISTS (migration step 5d, the decision half). A pending reply is
# still a wait run by hand inside bin/jg-pending-reply-lib.sh over a per-waiter
# record file. The decided shape is a durable workflow:
# core/bus/workflows/pending-reply.json owns the instance key, the four events,
# the two stages with the anchor each timer measures from, the activity each
# timeout runs and its retries, and the terminal states. This script is that
# definition's engine: it folds the event log into one state per waiter, decides
# what the definition says that waiter's stage should do, and - in this step -
# only records the decision. NOTHING ACTS YET: no repost is sent, no escalation
# is opened, no record is written, and bin/jg-pending-reply-lib.sh stays the live
# path. A later slice turns the decision into the actor and deletes the code it
# replaces; docs/reply-shadow.md owns what is still shadow.
#
# CONTRACT (this header is the one owner of the engine's shape).
#   store    $STATE/reply-bus.jsonl, the event log, one line per event as
#            <key>\t<digest>\t<json>. It is append-only, and the fold keeps the
#            last event per key, so a changed fact supersedes an earlier one and
#            a repeat with the same digest is a no-op. The format is transport
#            neutral on purpose: bin/jg-reply-bus.sh mirrors the same lines onto
#            JetStream when a bus answers, so a bus-backed transport can feed
#            this engine later without changing the model or this file.
#   events   waiter  the instance exists: task, grace, delivery state
#                     (sent | attempted | confirmed | unknown) and its epochs
#            timer   one stage's timeout: stage, anchor (or none), and whether
#                     that stage's turn was seen busy
#            fire    one stage's timeout fired, and what its activity returned
#            answer  the reply that settled the waiter: epoch and how it came
#   fold     one TSV state line per waiter, in the field order docs_jq prints.
#   decide   the definition's rule, as one row per decision:
#              arm      <id> <stage> <deadline>   the stage's timeout is bound
#              repost   <id> <deadline>           the request stage's activity
#              escalate <id> <reason> <deadline|->
#              answer   <id> <epoch> <via>        the reply settled the waiter
#            A decision is bound to the deadline its timer derives, never to the
#            instant a poll happened to notice it.
#   tick     the watcher's poll slot: fold, decide every waiter at one instant,
#            and append what it would do to $STATE/reply-bus-decisions.jsonl. It
#            acts on nothing and always exits 0.
#   replay   the same decision, walked over a recorded log: every instant the
#            recorded facts imply is replayed, the decision at each instant is
#            compared with the decision the record path took from those same
#            facts, and a difference names both rows. `--corrupt` shifts the
#            replayed grace, which must produce differences, so a green replay is
#            never vacuous.
#
# Usage:
#   jg-reply-engine.sh tick
#   jg-reply-engine.sh docs [<log>]
#   jg-reply-engine.sh decide <log> <epoch>
#   jg-reply-engine.sh replay [<log>] [--corrupt]
set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
LOG_FILE=${JG_REPLY_BUS_LOG:-$STATE/reply-bus.jsonl}
DECISIONS=${JG_REPLY_ENGINE_DECISIONS:-$STATE/reply-bus-decisions.jsonl}
NOW_OVERRIDE=${JG_REPLY_ENGINE_NOW:-}
# The watcher's poll interval bounds how late the record path can notice a
# deadline. A recorded activity later than this is a difference, not lateness.
POLL_CEILING=${JG_REPLY_ENGINE_POLL_CEILING:-900}
GRACE_DEFAULT=120
REPLAY_INSTANTS=0
# A replay may shift every grace the model derives, which must change its
# decisions; that is how the replay proves it is not vacuous.
GRACE_BUMP=0

die() { printf 'jg-reply-engine: %s\n' "$*" >&2; exit 2; }
now_epoch() { if [ -n "$NOW_OVERRIDE" ]; then printf '%s' "$NOW_OVERRIDE"; else date +%s; fi; }
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }

# --- the fold ---------------------------------------------------------------
docs_jq() {
  cat <<'JQ'
def keyof: .kind + "/" + .id + (if .stage then "/" + .stage else "" end);
(reduce .[] as $e ({}; .[$e | keyof] = $e)) as $f
| ([$f[] | select(.kind == "waiter") | .id] | unique) as $ids
| $ids[] as $id
| [ $id,
    ($f["waiter/" + $id].task // "-"),
    ($f["waiter/" + $id].grace // 120),
    ($f["waiter/" + $id].at // "-"),
    ($f["waiter/" + $id].state // "sent"),
    ($f["waiter/" + $id].delivered // "-"),
    ($f["waiter/" + $id].attempted // "-"),
    ($f["timer/" + $id + "/request"].anchor // "-"),
    ($f["timer/" + $id + "/request"].seen // 0),
    ($f["fire/" + $id + "/request"].epoch // "-"),
    ($f["fire/" + $id + "/request"].outcome // "-"),
    ($f["timer/" + $id + "/recovery"].anchor // "-"),
    ($f["timer/" + $id + "/recovery"].seen // 0),
    ($f["fire/" + $id + "/recovery"].epoch // "-"),
    ($f["fire/" + $id + "/recovery"].reason // "-"),
    ($f["answer/" + $id].epoch // "-"),
    ($f["answer/" + $id].via // "-") ]
| @tsv
JQ
}

# cmd_docs [<log>]: one TSV state line per waiter the log holds.
cmd_docs() {
  local log=${1:-$LOG_FILE} tmp
  [ -s "$log" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/jg-reply-docs.XXXXXX") || return 1
  cut -f3 "$log" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  jq -r -s "$(docs_jq)" "$tmp" 2>/dev/null || true
  rm -f -- "$tmp"
}

# --- one waiter's state -----------------------------------------------------
_DOC_FIELDS=(id task grace at state delivered attempted anchor_request
  seen_request fire_request outcome_request anchor_recovery seen_recovery
  fire_recovery reason_recovery answer via)
_DOC=()

docs_read() { # <doc-line>
  local -a v=()
  IFS=$'\t' read -r -a v <<<"$1"
  _DOC=("${v[@]}")
}

doc_get() { # <field-name> [default]
  local want=$1 i
  for i in "${!_DOC_FIELDS[@]}"; do
    [ "${_DOC_FIELDS[$i]}" = "$want" ] || continue
    if [ -n "${_DOC[$i]:-}" ]; then printf '%s' "${_DOC[$i]}"; else printf '%s' "${2:-}"; fi
    return 0
  done
  printf '%s' "${2:-}"
}

# doc_grace: the waiter's grace, bounded to the definition's default.
doc_grace() {
  local grace
  grace=$(doc_get grace "$GRACE_DEFAULT")
  is_num "$grace" || grace=$GRACE_DEFAULT
  printf '%s' "$((grace + GRACE_BUMP))"
}

# --- the decision -----------------------------------------------------------
# decide_one <doc-line> <epoch>: print the rows the definition says this waiter's
# stage should decide at that instant. It reads no file and takes no action.
decide_one() { # <doc-line> <epoch>
  local now=$2 id grace state attempted delivered anchor_request fire_request outcome
  local anchor_recovery fire_recovery reason answer via deadline
  docs_read "$1"
  id=$(doc_get id)
  [ -n "$id" ] || return 0
  grace=$(doc_grace)
  answer=$(doc_get answer -)
  via=$(doc_get via -)
  # The reply that settled the waiter is the definition's terminal answer.
  if is_num "$answer"; then
    printf 'answer\t%s\t%s\t%s\n' "$id" "$answer" "$via"
    return 0
  fi
  state=$(doc_get state sent)
  attempted=$(doc_get attempted -)
  delivered=$(doc_get delivered -)
  fire_recovery=$(doc_get fire_recovery -)
  # Delivery: an attempted delivery that outlived its grace is unknown, and an
  # unknown one is the delivery-unknown escalation, exactly as the record path
  # reconciles its confirmation sidecar.
  case "$state" in
    attempted)
      if is_num "$attempted" && [ "$now" -ge "$((attempted + grace))" ]; then
        printf 'delivery-unknown\t%s\t%s\n' "$id" "$((attempted + grace))"
      fi
      return 0
      ;;
    unknown)
      is_num "$fire_recovery" || printf 'escalate\t%s\tdelivery-unknown\t-\n' "$id"
      return 0
      ;;
    confirmed) ;;
    *) return 0 ;;
  esac
  is_num "$delivered" || return 0
  # The request stage: one timer from the turn's completion, then one repost.
  anchor_request=$(doc_get anchor_request -)
  fire_request=$(doc_get fire_request -)
  if ! is_num "$fire_request"; then
    is_num "$anchor_request" || return 0
    deadline=$((anchor_request + grace))
    if [ "$now" -ge "$deadline" ]; then
      printf 'repost\t%s\t%s\n' "$id" "$deadline"
    else
      printf 'arm\t%s\trequest\t%s\n' "$id" "$deadline"
    fi
    return 0
  fi
  # The recovery stage: a repost that could not be delivered escalates at once;
  # a delivered one waits for the recovery turn and then its own grace.
  outcome=$(doc_get outcome_request -)
  case "$outcome" in
    failed|unknown)
      is_num "$fire_recovery" || printf 'escalate\t%s\trecovery-delivery\t-\n' "$id"
      return 0
      ;;
    confirmed) ;;
    *) return 0 ;;
  esac
  is_num "$fire_recovery" && return 0
  anchor_recovery=$(doc_get anchor_recovery -)
  is_num "$anchor_recovery" || return 0
  # The recovery stage's timeout activity is the missed-report escalation; a
  # delivery failure is decided from the repost's outcome above, never here.
  reason=missed
  deadline=$((anchor_recovery + grace))
  if [ "$now" -ge "$deadline" ]; then
    printf 'escalate\t%s\t%s\t%s\n' "$id" "$reason" "$deadline"
  else
    printf 'arm\t%s\trecovery\t%s\n' "$id" "$deadline"
  fi
  return 0
}

cmd_decide_log() { # <log> <epoch>
  local log=$1 at=$2 doc
  [ -s "$log" ] || return 0
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    decide_one "$doc" "$at"
  done < <(cmd_docs "$log")
}

# --- the shadow tick --------------------------------------------------------
# Fold, decide every waiter at one instant, and record what the engine would do.
# Nothing here sends, escalates, closes or writes a record.
cmd_tick() {
  local at waiters=0 decisions=0 row doc
  at=$(now_epoch)
  if [ ! -s "$LOG_FILE" ]; then
    printf 'reply engine shadow: no event log at %s, nothing to decide\n' "$LOG_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$DECISIONS")" 2>/dev/null || return 1
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    waiters=$((waiters + 1))
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      printf '%s\t%s\n' "$at" "$row" >> "$DECISIONS"
      decisions=$((decisions + 1))
    done < <(decide_one "$doc" "$at")
  done < <(cmd_docs "$LOG_FILE")
  printf 'reply engine shadow: waiters=%s decisions=%s at=%s\n' "$waiters" "$decisions" "$at"
  return 0
}

# --- the replay -------------------------------------------------------------
# A replay walks thousands of instants, so rows are deduplicated in memory: a
# fork per row would dominate the run.
ROWS=()
rows_reset() { ROWS=(); }
rows_add() { # <row>
  local i
  for i in ${ROWS[@]+"${!ROWS[@]}"}; do
    [ "${ROWS[$i]}" = "$1" ] && return 0
  done
  ROWS+=("$1")
}
rows_flush() { # <file>
  [ "${#ROWS[@]}" -eq 0 ] || printf '%s\n' "${ROWS[@]}" >> "$1"
}

# sort_ints: ascending unique ints, without a fork. Prints one per line.
sort_ints() {
  local -a sorted=()
  local v i placed
  for v in "$@"; do
    is_num "$v" || continue
    placed=0
    for i in "${!sorted[@]}"; do
      if [ "$v" -lt "${sorted[$i]}" ]; then
        sorted=("${sorted[@]:0:$i}" "$v" "${sorted[@]:$i}")
        placed=1
        break
      elif [ "$v" -eq "${sorted[$i]}" ]; then
        placed=1
        break
      fi
    done
    [ "$placed" = 1 ] || sorted+=("$v")
  done
  [ "${#sorted[@]}" -eq 0 ] || printf '%s\n' "${sorted[@]}"
}

# reveal_doc <doc-line> <epoch>: the same waiter, with only the facts visible at
# that instant. A delivery, a turn completion, a fire or an answer whose epoch is
# still ahead is not yet visible; the repost's outcome is visible from the repost.
reveal_doc() { # <doc-line> <epoch>
  local at=$2 i out=() field
  for i in "${!_DOC_FIELDS[@]}"; do
    field=${_DOC_FIELDS[$i]}
    case "$field" in
      delivered|attempted|anchor_request|anchor_recovery|answer)
        if is_num "${_DOC[$i]:-}" && [ "${_DOC[$i]}" -gt "$at" ]; then
          out+=("-")
          continue
        fi
        ;;
      # A fired timeout is invisible at the instant it is decided at: the
      # decision is bound to the deadline, and the fire is its consequence.
      fire_request|fire_recovery)
        if is_num "${_DOC[$i]:-}" && [ "${_DOC[$i]}" -ge "$at" ]; then
          out+=("-")
          continue
        fi
        ;;
    esac
    out+=("${_DOC[$i]:-}")
  done
  ( IFS=$'\t'; printf '%s' "${out[*]}" )
}

# record_rows <doc-line> <want-file> <late-file>: the decisions the record path
# took, as the same rows decide prints, derived from the facts the log recorded.
record_rows() { # <doc-line> <want-file> <late-file>
  local id grace anchor_request fire_request anchor_recovery fire_recovery reason
  local answer via deadline
  docs_read "$1"
  id=$(doc_get id)
  [ -n "$id" ] || return 0
  grace=$(doc_grace)
  anchor_request=$(doc_get anchor_request -)
  fire_request=$(doc_get fire_request -)
  anchor_recovery=$(doc_get anchor_recovery -)
  fire_recovery=$(doc_get fire_recovery -)
  reason=$(doc_get reason_recovery -)
  answer=$(doc_get answer -)
  via=$(doc_get via -)
  if is_num "$anchor_request"; then
    deadline=$((anchor_request + grace))
    rows_add "arm	$id	request	$deadline"
  fi
  if is_num "$fire_request"; then
    is_num "$anchor_request" || deadline=$fire_request
    rows_add "repost	$id	$deadline"
    printf 'repost\t%s\n' "$((fire_request - deadline))" >> "$3"
  fi
  if is_num "$anchor_recovery"; then
    rows_add "arm	$id	recovery	$((anchor_recovery + grace))"
  fi
  if is_num "$fire_recovery"; then
    if is_num "$anchor_recovery"; then
      deadline=$((anchor_recovery + grace))
      rows_add "escalate	$id	${reason:--}	$deadline"
      printf 'escalate\t%s\n' "$((fire_recovery - deadline))" >> "$3"
    else
      # No turn completion bounds this escalation: the definition models it as a
      # repost whose delivery failed firing an activity, not as a timeout.
      rows_add "escalate	$id	${reason:--}	-"
    fi
  fi
  if is_num "$answer"; then
    rows_add "answer	$id	$answer	$via"
  fi
  rows_flush "$2"
  return 0
}

# model_rows <doc-line> <got-file> <corrupt>: the decisions the definition takes,
# one replayed instant at a time, from the facts visible at each instant.
model_rows() { # <doc-line> <got-file> <corrupt>
  local grace t doc row
  local -a instants=()
  docs_read "$1"
  grace=$(doc_grace)
  instants=("$(doc_get delivered)" "$(doc_get attempted)" "$(doc_get anchor_request)"
    "$(doc_get fire_request)" "$(doc_get anchor_recovery)" "$(doc_get fire_recovery)"
    "$(doc_get answer)")
  is_num "$(doc_get anchor_request)" && instants+=($(( $(doc_get anchor_request) + grace )))
  is_num "$(doc_get anchor_recovery)" && instants+=($(( $(doc_get anchor_recovery) + grace )))
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    REPLAY_INSTANTS=$((REPLAY_INSTANTS + 1))
    doc=$(reveal_doc "$1" "$t")
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      rows_add "$row"
    done < <(decide_one "$doc" "$t")
  done < <(sort_ints "${instants[@]}")
  rows_flush "$2"
  return 0
}

cmd_replay() {
  local log=$1 corrupt=$2 doc tmp
  [ -s "$log" ] || die "no event log at $log"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-reply-replay.XXXXXX") || return 1
  GRACE_BUMP=0
  : > "$tmp/want"; : > "$tmp/got"; : > "$tmp/late"
  local recorded_events waiters=0 compared diffs held=0 late_min late_max over unbounded
  recorded_events=$(awk 'END { print NR + 0 }' "$log")
  while IFS= read -r doc; do
    [ -n "$doc" ] || continue
    waiters=$((waiters + 1))
    # The record side always reads the grace it recorded; --corrupt moves only
    # the deadlines the model derives.
    GRACE_BUMP=0
    rows_reset
    record_rows "$doc" "$tmp/want" "$tmp/late"
    rows_reset
    GRACE_BUMP=$corrupt
    model_rows "$doc" "$tmp/got"
  done < <(cmd_docs "$log")
  LC_ALL=C sort -o "$tmp/want" "$tmp/want"
  LC_ALL=C sort -o "$tmp/got" "$tmp/got"
  comm -23 "$tmp/want" "$tmp/got" > "$tmp/only_want"
  comm -13 "$tmp/want" "$tmp/got" > "$tmp/only_got"
  # A decision only the model takes is classified, not excused: when the reply
  # was already in the parent log by the instant the activity was due, the record
  # path resolved on its next poll instead of firing, and the workflow would have
  # fired and been settled by the answer event. Anything else is unexplained.
  awk -F'\t' '$1 == "answer" { print $2 "\t" $3 }' "$tmp/want" > "$tmp/answers"
  awk -F'\t' 'NR == FNR { answer[$1] = $2; next }
    { deadline = ($4 == "-" ? "" : $4)
      if (($2 in answer) && (deadline == "" || answer[$2] + 0 >= deadline + 0)) held++; else print }
    END { printf "%d\n", held + 0 }' "$tmp/answers" "$tmp/only_got" > "$tmp/unexplained_got"
  held=$(tail -n 1 "$tmp/unexplained_got")
  sed -i '$d' "$tmp/unexplained_got"
  awk '{ print "- " $0 "\n+ (the model takes no such decision)" }' "$tmp/only_want" > "$tmp/diff"
  awk '{ print "- (the record path takes no such decision)\n+ " $0 }' "$tmp/unexplained_got" >> "$tmp/diff"
  compared=$(awk 'END { print NR + 0 }' "$tmp/want")
  diffs=$(( $(awk 'END { print NR + 0 }' "$tmp/only_want") + $(awk 'END { print NR + 0 }' "$tmp/unexplained_got") ))
  read -r late_min late_max over < <(awk -F'\t' -v ceiling="$POLL_CEILING" '
    { v = $2 + 0; n++; if (n == 1 || v < min) min = v
      if (n == 1 || v > max) max = v; if (v < 0 || v > ceiling) over++ }
    END { printf "%d %d %d\n", min + 0, max + 0, over + 0 }' "$tmp/late" 2>/dev/null || printf '0 0 0\n')
  unbounded=$(awk -F'\t' '$1 == "escalate" && $4 == "-"' "$tmp/want" | awk 'END { print NR + 0 }')
  printf 'reply engine replay: log=%s recorded_events=%s waiters=%s replayed_instants=%s decisions_compared=%s differences=%s held_by_a_reply=%s activity_lateness_s=%s..%s activities_over_poll_ceiling=%s escalations_without_a_timeout=%s\n' \
    "$log" "$recorded_events" "$waiters" "$REPLAY_INSTANTS" "$compared" "$diffs" "${held:-0}" \
    "${late_min:-0}" "${late_max:-0}" "${over:-0}" "${unbounded:-0}"
  head -n 40 "$tmp/diff" 2>/dev/null || true
  if [ "$diffs" -gt 40 ]; then printf '... and %s more difference line(s)\n' "$((diffs - 40))"; fi
  rm -rf -- "$tmp"
  [ "$diffs" -eq 0 ]
}

# --- arguments ---------------------------------------------------------------
CMD=
LOG_ARG=
NUM_ARG=
CORRUPT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    tick|docs|replay) CMD=$1; shift ;;
    decide) CMD=decide; shift ;;
    --corrupt) CORRUPT=1; shift ;;
    -h|--help) sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      if [ -z "$LOG_ARG" ]; then LOG_ARG=$1; elif [ -z "$NUM_ARG" ]; then NUM_ARG=$1; else die "unexpected argument: $1"; fi
      shift
      ;;
  esac
done
[ -n "$CMD" ] || die "usage: jg-reply-engine.sh tick | docs [<log>] | decide <log> <epoch> | replay [<log>] [--corrupt]"
case "$CMD" in
  tick) cmd_tick ;;
  docs) cmd_docs "$LOG_ARG" ;;
  decide) cmd_decide_log "${LOG_ARG:-$LOG_FILE}" "${NUM_ARG:-$(now_epoch)}" ;;
  replay) cmd_replay "${LOG_ARG:-$LOG_FILE}" "$CORRUPT" ;;
esac
