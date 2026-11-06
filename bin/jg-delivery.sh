#!/usr/bin/env bash
# jg-delivery.sh - the delivery record of a steer: five words, each with its own proof.
#
# Usage: jg-delivery.sh handled <task> <seq> --evidence <kind>:<pointer>
#        jg-delivery.sh failed  <task> <seq> --reason <text>
#        jg-delivery.sh show    <task> [<seq>]
#        jg-delivery.sh overdue <task> [--after <seconds>]     (default 900)
#
#   stored   the record was renamed into <task>.inbox          (written by the inbox library)
#   rung     a doorbell was typed for it                       (written by the inbox library)
#   read     the worker moved it to handled/                   (the file's place; says read only)
#   handled  the worker says it acted, and points at the proof (this command)
#   failed   the worker refused it, with the reason            (this command)
#
# `handled` and `failed` are the worker's claim. The evidence pointer is what makes a claim
# checkable, so it is required: <kind> is status, commit, reply, task or pr, and <pointer> is the
# status line, the commit, the reply or note id, the task id or the PR URL that shows the work.
# The claim is kept in the record (<task>.inbox/.delivery.jsonl) and sent once on the bus as its
# own event (jg-wake-bus.sh inbox-handled) under a short timeout: a bus that is down or slow
# never blocks the worker, and the record still holds it. The doorbell and the file stay: this
# adds the answer, it replaces nothing. A transport acknowledgement is never called handled.
#
# `overdue` is the sender's timeout. It lists every record that was read or rung but has no
# handled or failed word after the given age, and exits 1 when it lists any, because no event
# arrives when a worker never acts. `show` prints one line per record with the five words.
#
# Env: JG_HOME (required) or JG_STATE_OVERRIDE; JG_DELIVERY_BUS_TIMEOUT seconds (default 5).
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ "${1:-}" = --help ]; then sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"; exit 0; fi
STATE=${JG_STATE_OVERRIDE:-${JG_HOME:?jg-delivery.sh needs an explicit JG_HOME}/state}
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"

die() { printf 'jg-delivery.sh: %s\n' "$*" >&2; exit 2; }
cmd=${1:-}; task=${2:-}; [ -n "$cmd" ] && [ -n "$task" ] || die "usage: jg-delivery.sh handled|failed|show|overdue <task> ... (--help)"
shift 2
dir=$(jg_task_inbox_dir "$STATE" "$task")
[ -d "$dir" ] || die "no steering inbox for $task"
ledger=$dir/.delivery.jsonl

# record_place <seq>: where the record file is now, or nothing.
record_place() {
  local n; n=$(printf '%03d' "$((10#$1))")
  if [ -e "$dir/handled/$n.msg" ]; then echo handled; elif [ -e "$dir/$n.msg" ]; then echo inbox; fi
}
# word_at <seq> <word>: the latest time that word was recorded, else nothing.
word_at() {
  [ -s "$ledger" ] || return 0
  jq -r --argjson s "$((10#$1))" --arg w "$2" 'select(.seq == $s and .word == $w) | .at' "$ledger" 2>/dev/null | tail -1
}
claim() { # <seq> <word> <pointer> <outcome>
  [ -n "$(record_place "$1")" ] || die "$task has no steer numbered $1"
  jg_task_delivery_note "$dir" "$1" "$2" "$3" || die "the delivery record could not be written"
  # shellcheck disable=SC2154  # JG_HOME may be unset when only JG_STATE_OVERRIDE names the state
  JG_HOME=${JG_HOME:-$(dirname "$STATE")} JG_STATE_OVERRIDE=$STATE \
    timeout "${JG_DELIVERY_BUS_TIMEOUT:-5}" "$SCRIPT_DIR/jg-wake-bus.sh" inbox-handled "$task" "$((10#$1))" "$4" "$3" \
    >/dev/null 2>&1 || printf 'jg-delivery.sh: the bus event was not sent; the record holds the claim\n' >&2
  printf '%s %s %s\n' "$task" "$(printf '%03d' "$((10#$1))")" "$2"
}

case "$cmd" in
  handled)
    seq=${1:-}; if [ "${2:-}" = --evidence ]; then ev=${3:-}; else die "handled needs <seq> --evidence <kind>:<pointer>"; fi
    case "$seq" in ''|*[!0-9]*) die "the steer number must be digits" ;; esac
    kind=${ev%%:*}; ptr=${ev#*:}
    case "$kind" in status|commit|reply|task|pr) ;; *) die "evidence kind must be status, commit, reply, task or pr" ;; esac
    [ "$ev" != "$kind" ] && [ -n "$ptr" ] || die "evidence needs a pointer after the kind"
    claim "$seq" handled "$ev" handled ;;
  failed)
    seq=${1:-}; if [ "${2:-}" = --reason ]; then why=${3:-}; else die "failed needs <seq> --reason <text>"; fi
    case "$seq" in ''|*[!0-9]*) die "the steer number must be digits" ;; esac
    [ -n "$why" ] || die "failed needs a reason"
    claim "$seq" failed "$why" failed ;;
  show|overdue)
    after=900; want=
    if [ "$cmd" = show ]; then want=${1:-}; else
      [ "${1:-}" != --after ] || after=${2:-}
      case "$after" in ''|*[!0-9]*) die "--after needs seconds" ;; esac
    fi
    now=$(date +%s); late=0
    for f in "$dir"/*.msg "$dir"/handled/*.msg; do
      [ -e "$f" ] || continue
      seq=$(jg_task_inbox_seq_of "${f##*/}") || continue
      [ -z "$want" ] || [ "$seq" = "$((10#$want))" ] || continue
      place=$(record_place "$seq"); out=''
      for w in stored rung; do t=$(word_at "$seq" $w); out="$out $w=${t:-no}"; done
      out="$out read=$([ "$place" = handled ] && echo yes || echo no)"
      h=$(word_at "$seq" handled); x=$(word_at "$seq" failed)
      out="$out handled=${h:-no} failed=${x:-no}"
      if [ "$cmd" = show ]; then
        printf '%03d%s\n' "$seq" "$out"
        [ -z "$h" ] || printf '    evidence: %s\n' "$(jq -r --argjson s "$seq" 'select(.seq == $s and .word == "handled") | .pointer' "$ledger" | tail -1)"
        [ -z "$x" ] || printf '    reason: %s\n' "$(jq -r --argjson s "$seq" 'select(.seq == $s and .word == "failed") | .pointer' "$ledger" | tail -1)"
      elif [ -z "$h" ] && [ -z "$x" ]; then
        # Age runs from the first sign the worker had it: the ring, else the store.
        t0=$(word_at "$seq" rung); [ -n "$t0" ] || t0=$(word_at "$seq" stored); [ -n "$t0" ] || continue
        if [ $((now - t0)) -ge "$after" ]; then late=1; printf '%03d%s age=%ss\n' "$seq" "$out" "$((now - t0))"; fi
      fi
    done
    [ "$late" -eq 0 ] ;;
  *) die "unknown command $cmd (--help)" ;;
esac
