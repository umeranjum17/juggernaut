#!/usr/bin/env bash
# jg-escalation-optimize.sh - decide whether an escalation wakes a model, from the
# rules in core/bus/workflows/escalation-optimization.json. Every number and rule
# lives in that definition (a home overrides it at config/escalation-optimization.json
# or with JG_ESCALATION_OPT); this script only reads facts and applies them.
#
# The six rules, in the order decide applies them:
#   6 envelope       an escalation carries `evidence=[...]` and `action=[...]`
#                    (the proof and the one thing wanted), or it is refused.
#   1 priority       classes urgent/now/soon/batch/digest/silent from spec.priority
#                    (first match wins), falling back to the wake-routing class.
#   4 actionability  a hop that cannot act is never woken: a parked home, a captain
#                    hold, a declared wait or an external wait stops the climb.
#   2 backoff        the same unchanged condition repeats at base*factor^n seconds,
#                    capped; a changed payload resets the count.
#   1 budget         at most N wakes per hour per receiving target; urgent ignores it.
#   3 coalesce       batch/digest events wait in a pending group; flush emits ONE wake
#                    per group with a one-line digest of every event in it, when the
#                    window ends or maxEvents rows are held, whichever comes first.
#   5 auto-resolve   an open escalation records the fingerprint of the state it was
#                    raised about; resolve closes it (and withdraws its queued wake)
#                    when that fingerprint changes.
# Shapes follow Prometheus Alertmanager (Apache-2.0): group_by, repeat_interval and
# inhibit_rules. No Alertmanager code is used.
#
# Usage:
#   jg-escalation-optimize.sh show
#   jg-escalation-optimize.sh wrap <evidence> <action>
#   jg-escalation-optimize.sh classify <kind> <key> <payload>
#   jg-escalation-optimize.sh decide <kind> <key> <payload> [task] [now]
#       prints: deliver <class> | defer <why> | drop <why> | refuse <why>
#   jg-escalation-optimize.sh flush [now] [--force]   one digest line per due group
#   jg-escalation-optimize.sh resolve [now]           closes escalations whose state changed
#   jg-escalation-optimize.sh replay <events-file> [tokens-per-wake]
#       events: <epoch> <seq> <kind> <key> <payload> (the wake queue's own rows)
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
OPT="$STATE/.escalation-opt"

die() { printf 'jg-escalation-optimize: %s\n' "$*" >&2; exit 2; }

definition() {
  local f
  for f in "${JG_ESCALATION_OPT:-}" "$CONFIG/escalation-optimization.json" \
    "$ROOT/core/bus/workflows/escalation-optimization.json"; do
    [ -n "$f" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}
wf() { jq -er "$1" "$DEF"; }
sum() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# glob <pattern> <value>: the definition's patterns are shell globs, as in wake-routing.
# shellcheck disable=SC2254
glob() { case "$2" in $1) return 0 ;; esac; return 1; }

# ---- 1. priority -------------------------------------------------------------
base_class() {  # <kind> <key> <payload> -> the existing wake-routing class
  local file="${JG_WAKE_ROUTING:-}" c k key pay
  [ -f "$file" ] || file="$CONFIG/wake-routing"
  [ -f "$file" ] || file="$ROOT/defaults/wake-routing"
  while read -r c k key pay; do
    case "$c" in '' | '#'* | set) continue ;; esac
    [ "$k" = '*' ] || [ "$k" = "$1" ] || continue
    glob "$key" "$2" || continue
    glob "$pay" "$3" && { printf '%s' "$c"; return 0; }
  done <"$file" 2>/dev/null
  printf now
}
classify() {  # <kind> <key> <payload>
  local c k key pay
  while IFS=$'\t' read -r c k key pay; do
    [ -n "$c" ] || continue
    glob "$k" "$1" && glob "$key" "$2" && glob "$pay" "$3" && { printf '%s' "$c"; return 0; }
  done <<JGOPT_END
$(wf '.spec.priority[]? | [.class, .kind, .key, .payload] | @tsv')
JGOPT_END
  base_class "$1" "$2" "$3"
}
class_field() { wf ".spec.classes[\"$1\"][\"$2\"] | if . == null then empty else tostring end" 2>/dev/null; }

target_of() {  # <key>
  local pat t
  while IFS=$'\t' read -r pat t; do
    glob "$pat" "$1" && { printf '%s' "$t"; return 0; }
  done <<JGOPT_END
$(wf '.spec.targets[]? | [.key, .target] | @tsv')
JGOPT_END
  printf main
}

# ---- 4. actionability --------------------------------------------------------
blocker() {  # <task> -> the first fact that stops the climb, else nothing
  local task=$1 name fact path
  [ -n "$task" ] || return 0
  while IFS=$'\t' read -r name fact path; do
    [ -n "$name" ] || continue
    case "$fact" in
      parked-home)
        # shellcheck source=/dev/null
        if [ -r "$ROOT/core/parked-homes/bin/jg-parked-homes-lib.sh" ] \
          && . "$ROOT/core/parked-homes/bin/jg-parked-homes-lib.sh" \
          && jg_parked_home "$task" 2>/dev/null; then printf '%s' "$name"; return 0; fi ;;
      file)
        path=${path//\{state\}/$STATE}
        path=${path//\{task\}/$task}
        [ -e "$path" ] && { printf '%s' "$name"; return 0; } ;;
    esac
  done <<JGOPT_END
$(wf '.spec.actionability.blockers[]? | [.name, .fact, (.path // "-")] | @tsv')
JGOPT_END
  return 0
}

# ---- 5. auto-resolve ---------------------------------------------------------
fingerprint() {  # <task>
  local path
  path=$(wf '.spec.autoResolve.fingerprint // empty') || return 0
  path=${path//\{state\}/$STATE}
  path=${path//\{task\}/$1}
  if [ -f "$path" ]; then tail -n 1 -- "$path" | cksum | cut -d' ' -f1; else printf absent; fi
}

# ---- 3. coalesce -------------------------------------------------------------
group_of() {  # <key>
  local pat name
  while IFS=$'\t' read -r name pat; do
    glob "$pat" "$1" && { printf '%s' "$name"; return 0; }
  done <<JGOPT_END
$(wf '.spec.coalesce.groups[]? | [.name, .key] | @tsv')
JGOPT_END
  printf other
}

# ---- decide ------------------------------------------------------------------
cmd_decide() {  # <kind> <key> <payload> [task] [now]
  local kind=$1 key=$2 payload task=${4:-} now=${5:-} blocked
  local was class target limit req h f count=0 prev_hash='' next=0 base factor cap interval n win used i
  payload=$(clean "$3")
  [ -n "$now" ] || now=$(date +%s)
  mkdir -p "$OPT/backoff" "$OPT/budget" "$OPT/pending" "$OPT/open" || die 'cannot write state'
  # 6. the envelope
  if [ "$(wf '.spec.envelope.enforce // false')" = true ]; then
    for req in $(wf '.spec.envelope.required[]'); do
      case "$payload" in *"$req=["*"]"*) ;; *) printf 'refuse missing-%s\n' "$req"; return 0 ;; esac
    done
  fi
  # 1. priority
  class=$(classify "$kind" "$key" "$payload")
  [ -n "$(class_field "$class" wakes)" ] || class=now
  if [ "$class" = silent ]; then printf 'drop silent\n'; return 0; fi
  # 4. actionability, before anything is remembered, so a held lane costs nothing
  blocked=$(blocker "$task")
  if [ -n "$blocked" ]; then printf 'drop not-actionable:%s\n' "$blocked"; return 0; fi
  was=0
  [ "$(base_class "$kind" "$key" "$payload")" != now ] || was=1
  # 3. non-waking classes join their pending group
  if [ "$(class_field "$class" wakes)" = false ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$class" "$key" "$payload" "$was" >>"$OPT/pending/$(group_of "$key")"
    printf 'defer %s\n' "$class"
    return 0
  fi
  # 2. backoff: the same unchanged condition waits base*factor^(n-1), capped
  h=$(sum "$kind|$key")
  f="$OPT/backoff/$h"
  [ ! -f "$f" ] || IFS=$'\t' read -r count prev_hash next <"$f"
  if [ "$prev_hash" = "$(sum "$payload")" ] && [ "$now" -lt "$next" ]; then
    printf 'defer backoff\n'
    return 0
  fi
  # 1. budget per receiving target (urgent ignores it)
  target=$(target_of "$key")
  if [ "$(class_field "$class" budget)" != false ]; then
    limit=$(wf ".spec.budget.targets[\"$target\"] // .spec.budget.perHour")
    win=$(wf '.spec.budget.windowSeconds')
    used=0
    [ ! -f "$OPT/budget/$target" ] || used=$(awk -v c="$((now - win))" '$1 > c' "$OPT/budget/$target" | wc -l)
    if [ "$used" -ge "$limit" ]; then
      printf 'defer over-budget:%s\n' "$target"
      printf '%s\t%s\t%s\t%s\t%s\n' "$now" batch "$key" "$payload" "$was" >>"$OPT/pending/$(group_of "$key")"
      return 0
    fi
  fi
  # deliver: advance the backoff, charge the budget, open the escalation
  if [ "$prev_hash" = "$(sum "$payload")" ]; then n=$((count + 1)); else n=1; fi
  base=$(wf '.spec.backoff.baseSeconds')
  factor=$(wf '.spec.backoff.factor')
  cap=$(wf '.spec.backoff.capSeconds')
  interval=$base
  i=1
  while [ "$i" -lt "$n" ] && [ "$interval" -lt "$cap" ]; do interval=$((interval * factor)); i=$((i + 1)); done
  [ "$interval" -le "$cap" ] || interval=$cap
  printf '%s\t%s\t%s\n' "$n" "$(sum "$payload")" "$((now + interval))" >"$f"
  printf '%s\n' "$now" >>"$OPT/budget/$target"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$key" "$task" "$(fingerprint "$task")" >"$OPT/open/$h"
  printf 'deliver %s\n' "$class"
}

cmd_flush() {  # [now] [--force]
  local now='' force='' a g oldest class win digest first rows max
  for a in "$@"; do
    case "$a" in --force) force=1 ;; *) now=$a ;; esac
  done
  [ -n "$now" ] || now=$(date +%s)
  [ -d "$OPT/pending" ] || return 0
  for g in "$OPT/pending"/*; do
    [ -s "$g" ] || continue
    IFS=$'\t' read -r oldest class _ <"$g"
    win=$(wf '.spec.coalesce.windowSeconds')
    [ "$class" != digest ] || win=$(class_field digest flushSeconds)
    max=$(wf '.spec.coalesce.maxEvents // 0')
    [ -n "$force" ] || [ "$now" -ge "$((oldest + win))" ] \
      || { [ "$max" -gt 0 ] && [ "$(wc -l <"$g" | tr -d ' ')" -ge "$max" ]; } || continue
    digest=$(awk -F '\t' '{ k = $3; sub(/-[^-]*$/, "", k); n[k]++; t++ } END { s = ""; for (k in n) s = s (s ? ", " : "") n[k] "x " k; print t " events: " s }' "$g")
    first=$(awk -F '\t' 'NR == 1 { print $4 }' "$g" | sed 's/ *evidence=\[.*//' | cut -c1-100)
    rows=$(wc -l <"$g" | tr -d ' ')
    printf 'check: escalation-digest %s (%s) evidence=[%s rows since %s; first: %s] action=[review the batch once; no per-event reply needed]\n' \
      "${g##*/}" "$digest" "$rows" "$oldest" "$first"
    rm -f -- "$g"
  done
}

# ---- 5. resolve --------------------------------------------------------------
cmd_resolve() {
  local f kind key task fp cur
  [ -d "$OPT/open" ] || return 0
  for f in "$OPT/open"/*; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r kind key task fp <"$f"
    cur=$(fingerprint "$task")
    [ "$cur" != "$fp" ] || continue
    rm -f -- "$f" "$OPT/backoff/$(sum "$kind|$key")"
    if [ -r "$ROOT/bin/jg-wake-lib.sh" ] && [ -n "${JG_WAKE_QUEUE:-}" ]; then
      # shellcheck source=/dev/null
      ( . "$ROOT/bin/jg-wake-lib.sh" && jg_wake_withdraw "$kind" "$key" ) >/dev/null 2>&1 || true
    fi
    printf 'resolved %s %s (state changed)\n' "$kind" "$key"
  done
}

# ---- replay ------------------------------------------------------------------
# Feed recorded wake rows through decide in a scratch state, then count what would
# have woken a model. Coalesced rows cost one digest wake per group per window;
# the wait those rows add before that digest is the time-to-unblock cost.
cmd_replay() {  # <events-file> [tokens-per-wake]
  local file=$1 tpw=${2:-} before=0 delivered=0 first=0 last=0 e s kind key payload verdict
  local delay=0 deferred=0 digests=0 win g sandbox avoided stats dg dl nn
  [ -f "$file" ] || die "no events file: $file"
  [ -n "$tpw" ] || tpw=$(wf '.spec.replay.tokensPerWake // 4000')
  win=$(wf '.spec.coalesce.windowSeconds')
  sandbox=$(mktemp -d) || die 'no temp dir'
  STATE="$sandbox"
  OPT="$sandbox/.opt"
  while IFS=$'\t' read -r e s kind key payload; do
    case "$e" in '' | *[!0-9]*) continue ;; esac
    case "$payload" in *"evidence=["*) ;; *) payload="$payload evidence=[replayed row] action=[handle it]" ;; esac
    [ "$first" -ne 0 ] || first=$e
    last=$e
    # The baseline is what today's routing wakes a model for; batch and silent rows never did.
    [ "$(base_class "$kind" "$key" "$payload")" != now ] || before=$((before + 1))
    verdict=$(cmd_decide "$kind" "$key" "$payload" "" "$e")
    case "$verdict" in deliver*) delivered=$((delivered + 1)) ;; esac
  done <"$file"
  for g in "$OPT/pending"/*; do
    [ -s "$g" ] || continue
    # d: digest wakes (one per group per window, over every held row); t, n: the wait
    # added to the rows today's routing would have woken a model for.
    stats=$(awk -F '\t' -v w="$win" 'NR == 1 || $1 >= s + w { s = $1; d++ } $5 == 1 { t += (s + w - $1); n++ } END { print d + 0, t + 0, n + 0 }' "$g")
    read -r dg dl nn <<<"$stats"
    digests=$((digests + dg))
    delay=$((delay + dl))
    deferred=$((deferred + nn))
  done
  rm -rf -- "$sandbox"
  avoided=$((before - delivered - digests))
  [ "$avoided" -ge 0 ] || avoided=0
  printf 'span_seconds=%s\n' "$((last - first))"
  printf 'wakes_before counts the rows that today routing wakes a model for\n'
  printf 'wakes_before=%s wakes_after=%s wakes_avoided=%s\n' "$before" "$((delivered + digests))" "$avoided"
  printf 'tokens_per_wake=%s (estimate, unverified) tokens_saved=%s\n' "$tpw" "$((avoided * tpw))"
  printf 'deferred_events=%s added_wait_seconds_total=%s mean_added_wait_seconds=%s\n' \
    "$deferred" "$delay" "$((deferred ? delay / deferred : 0))"
  : "$s"
}

main() {
  local cmd=${1:-}
  shift || true
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  DEF=$(definition) || die 'no escalation optimization definition found'
  case "$cmd" in
    show)
      printf 'definition: %s\n' "$DEF"
      jq -c '.spec | {classes: (.classes | keys), budget: .budget.perHour, backoff, coalesce: .coalesce.windowSeconds, envelope: .envelope.required}' "$DEF"
      ;;
    wrap) printf 'evidence=[%s] action=[%s]\n' "$(clean "${1:?evidence}")" "$(clean "${2:?action}")" ;;
    classify) classify "${1:?kind}" "${2:?key}" "${3:-}"; echo ;;
    decide) cmd_decide "${1:?kind}" "${2:?key}" "${3:-}" "${4:-}" "${5:-}" ;;
    flush) cmd_flush "$@" ;;
    resolve) cmd_resolve "$@" ;;
    replay) cmd_replay "${1:?events file}" "${2:-}" ;;
    *) die 'usage: jg-escalation-optimize.sh show|wrap|classify|decide|flush|resolve|replay' ;;
  esac
}
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
