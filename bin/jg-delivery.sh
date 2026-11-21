#!/usr/bin/env bash
# jg-delivery.sh - the delivery record of a steer: five words, each with its own proof.
#
# Usage: jg-delivery.sh handled <task> <seq> --evidence <kind>:<pointer> [--action <lane> <text>]...
#        jg-delivery.sh failed  <task> <seq> --reason <text>
#        jg-delivery.sh show    <task> [<seq>]
#        jg-delivery.sh overdue <task> [--after <seconds>] [--read] [--since <epoch>] [--until <epoch>]
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
# arrives when a worker never acts. The age runs from the FIRST ring (else the first store), so a
# re-ring never resets it. --read lists only records the worker has moved to handled/ and has
# given no word on; --since and --until keep the records whose first sign falls in that window.
# The ledger is read in one jq pass. `show` prints one line per record with the five words.
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
inbox_home=${JG_HOME:-$(dirname "$STATE")}
launch_inbox=${JG_TASK_INBOX:-}
# A local Squad Lead reads the inbox Main opened for it, but its action records belong to its own home.
if [ "${launch_inbox##*/}" = "$task.inbox" ] && [ -d "$launch_inbox" ]; then
  if [ "$launch_inbox" != "$dir" ]; then inbox_home=$(dirname "$(dirname "$launch_inbox")"); fi
  dir=$launch_inbox
fi
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
  JG_HOME=$inbox_home JG_STATE_OVERRIDE=${dir%/*} \
    timeout "${JG_DELIVERY_BUS_TIMEOUT:-5}" "$SCRIPT_DIR/jg-wake-bus.sh" inbox-handled "$task" "$((10#$1))" "$4" "$3" \
    >/dev/null 2>&1 || printf 'jg-delivery.sh: the bus event was not sent; the record holds the claim\n' >&2
  printf '%s %s %s\n' "$task" "$(printf '%03d' "$((10#$1))")" "$2"
}

# Save one replay-safe action per named lane, in the lead's own state. The
# evidence pointer remains present even when the claim adds a plain description.
record_swarm_actions() { # <steer path> <sequence> <evidence> [--action <lane> <text>]...
  local home=${JG_HOME:-} record=$1 seq=$2 evidence=$3 arm body lanes lane folder saved tmp actions='{}' action
  shift 3
  [ -n "$home" ] || return 0
  local arms=()
  for arm in "$home"/data/swarm/*/arm.json; do
    [ ! -f "$arm" ] || arms+=("$arm")
  done
  [ "${#arms[@]}" -gt 0 ] || { [ "$#" -eq 0 ] || die "this home has no swarm lanes"; return 0; }
  body=$(jg_task_inbox_body "$record") || return 1
  lanes=$(jq -rs --arg body "$body" '
    [$body | scan("[A-Za-z0-9_]+(?:[.-]+[A-Za-z0-9_]+)*")] as $words
    | [.[].rows[] | . as $lane | select($words | index($lane))] | unique[]' "${arms[@]}") || return 1
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 3 ] && [ "$1" = --action ] && [ -n "$3" ] || die "handled accepts --action <lane> <text> after the evidence"
    grep -Fxq -- "$2" <<< "$lanes" || die "steer $seq does not name an owned swarm lane $2"
    actions=$(jq -c --arg lane "$2" --arg action "$3" '.[$lane] = $action' <<< "$actions") || return 1
    shift 3
  done
  [ -n "$lanes" ] || return 0
  case "$task" in *[!A-Za-z0-9._-]*) die "invalid lead task id $task" ;; esac
  while IFS= read -r lane; do
    folder="$home/state/swarm-actions/$lane"
    saved="$folder/$task-$((10#$seq)).json"
    action=$(jq -r --arg lane "$lane" '.[$lane] // empty' <<< "$actions") || return 1
    [ -n "$action" ] || [ ! -f "$saved" ] || continue
    mkdir -p -- "$folder" || return 1
    tmp=$(mktemp "$folder/.action.XXXXXX") || return 1
    if ! jq -nc --arg lane "$lane" --arg task "$task" --argjson seq "$((10#$seq))" \
      --arg evidence "$evidence" --arg action "${action:-$evidence}" \
      '{lane:$lane, steer:{task:$task, seq:$seq}, action:$action, evidence:$evidence}' > "$tmp" ||
      ! mv -- "$tmp" "$saved"; then
      rm -f -- "$tmp"
      return 1
    fi
  done <<< "$lanes"
}

# jg_delivery_close_steer <task> <seq> <evidence>: jg-item close steer:<home id>/<task>/<seq> done handled:<evidence>.
jg_delivery_close_steer() {
  local home=$inbox_home root key
  root=$(cd "$SCRIPT_DIR/.." && pwd)
  [ -e "$home/config/item-store" ] && [ -x "$root/core/item-store/jg-item" ] || return 0
  key=$(JG_HOME=$home "$root/core/item-store/jg-item" key steer --task "$1" --n "$((10#$2))" 2>/dev/null | cut -f1) || return 0
  [ -n "$key" ] || return 0
  JG_HOME=$home python3 -I "$root/core/item-store/adapters/lane.py" has-open "$key" || return 0
  JG_HOME=$home JG_ITEM_OR_INTAKE=1 "$root/core/item-store/jg-item" close "$key" "done" "handled:$3" --source "handled:$1/$((10#$2))" >/dev/null 2>&1
}

case "$cmd" in
  handled)
    seq=${1:-}; if [ "${2:-}" = --evidence ]; then ev=${3:-}; else die "handled needs <seq> --evidence <kind>:<pointer>"; fi
    case "$seq" in ''|*[!0-9]*) die "the steer number must be digits" ;; esac
    kind=${ev%%:*}; ptr=${ev#*:}
    case "$kind" in status|commit|reply|task|pr) ;; *) die "evidence kind must be status, commit, reply, task or pr" ;; esac
    [ "$ev" != "$kind" ] && [ -n "$ptr" ] || die "evidence needs a pointer after the kind"
    shift 3
    n=$(printf '%03d' "$((10#$seq))")
    place=$(record_place "$seq")
    case "$place" in handled) record="$dir/handled/$n.msg" ;; inbox) record="$dir/$n.msg" ;; *) die "$task has no steer numbered $seq" ;; esac
    record_swarm_actions "$record" "$seq" "$ev" "$@" || die "the swarm lane action records could not be written"
    claim "$seq" handled "$ev" handled
    # The item store closes the steer's item too (guarded by the home's switch; today's record decides, so nothing here changes
    # this command's output or exit). A steer the store never opened is not a refusal: there is nothing to close.
    jg_delivery_close_steer "$task" "$seq" "$ev" || true ;;
  failed)
    seq=${1:-}; if [ "${2:-}" = --reason ]; then why=${3:-}; else die "failed needs <seq> --reason <text>"; fi
    case "$seq" in ''|*[!0-9]*) die "the steer number must be digits" ;; esac
    [ -n "$why" ] || die "failed needs a reason"
    claim "$seq" failed "$why" failed ;;
  overdue)
    after=900; only_read=0; since=0; until=9999999999
    while [ $# -gt 0 ]; do
      case "$1" in
        --read) only_read=1; shift ;;
        --after|--since|--until) [ $# -ge 2 ] || die "$1 needs a value"
          case "$2" in ''|*[!0-9]*) die "$1 needs seconds since the epoch or seconds" ;; esac
          case "$1" in --after) after=$2 ;; --since) since=$2 ;; *) until=$2 ;; esac; shift 2 ;;
        *) die "unknown overdue option $1 (--help)" ;;
      esac
    done
    places=
    for f in "$dir"/*.msg; do [ -e "$f" ] || continue; seq=$(jg_task_inbox_seq_of "${f##*/}") && places="$places$seq inbox"$'\n'; done
    for f in "$dir"/handled/*.msg; do [ -e "$f" ] || continue; seq=$(jg_task_inbox_seq_of "${f##*/}") && places="$places$seq handled"$'\n'; done
    [ -n "$places" ] || exit 0
    # One pass over the ledger: per steer the latest store and ring (shown), the first of either (the age's anchor).
    out=$(jq -nR -r --argjson now "$(date +%s)" --argjson after "$after" --argjson since "$since" --argjson until "$until" \
        --argjson onlyread "$only_read" --arg places "$places" '
      ([inputs | fromjson? | select(type == "object" and (.seq | type) == "number")] | group_by(.seq)
        | map({key: (.[0].seq | tostring), value: .}) | from_entries) as $L
      | ($places | split("\n") | map(select(length > 0) | split(" ")) | map({seq: (.[0] | tonumber), place: .[1]}) | sort_by(.seq))[]
      | . as $p | ($L[($p.seq | tostring)] // []) as $r
      | def at(w; f): [$r[] | select(.word == w) | .at] | if length == 0 then null else f end;
        def show(v): if v == null then "no" else (v | tostring) end;
        (at("stored"; max)) as $st | (at("rung"; max)) as $rg | (at("handled"; max)) as $h | (at("failed"; max)) as $x
      | (at("rung"; min) // at("stored"; min)) as $t0
      | select($h == null and $x == null and $t0 != null and ($onlyread == 0 or $p.place == "handled")
               and $t0 >= $since and $t0 <= $until and ($now - $t0) >= $after)
      | "\("000" + ($p.seq | tostring) | .[-3:]) stored=\(show($st)) rung=\(show($rg)) read=\(if $p.place == "handled" then "yes" else "no" end) handled=no failed=no age=\($now - $t0)s"
    ' "$ledger" 2>/dev/null) || die "the delivery record could not be read"
    [ -z "$out" ] || { printf '%s\n' "$out"; exit 1; }
    exit 0 ;;
  show)
    want=${1:-}
    for f in "$dir"/*.msg "$dir"/handled/*.msg; do
      [ -e "$f" ] || continue
      seq=$(jg_task_inbox_seq_of "${f##*/}") || continue
      [ -z "$want" ] || [ "$seq" = "$((10#$want))" ] || continue
      place=$(record_place "$seq"); out=''
      for w in stored rung; do t=$(word_at "$seq" $w); out="$out $w=${t:-no}"; done
      out="$out read=$([ "$place" = handled ] && echo yes || echo no)"
      h=$(word_at "$seq" handled); x=$(word_at "$seq" failed)
      out="$out handled=${h:-no} failed=${x:-no}"
      printf '%03d%s\n' "$seq" "$out"
      [ -z "$h" ] || printf '    evidence: %s\n' "$(jq -r --argjson s "$seq" 'select(.seq == $s and .word == "handled") | .pointer' "$ledger" | tail -1)"
      [ -z "$x" ] || printf '    reason: %s\n' "$(jq -r --argjson s "$seq" 'select(.seq == $s and .word == "failed") | .pointer' "$ledger" | tail -1)"
    done ;;
  *) die "unknown command $cmd (--help)" ;;
esac
