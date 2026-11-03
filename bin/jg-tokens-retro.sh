#!/usr/bin/env bash
# jg-tokens-retro.sh - the daily fleet token meter: one learn-from-mistakes-axi
# `tokens retro` a day into data/tokens-retro/<YYYY-MM-DD>/, reporting only a
# week-over-week change.
#
# Usage:
#   jg-tokens-retro.sh [check]
#   jg-tokens-retro.sh arm
#   jg-tokens-retro.sh show
#   jg-tokens-retro.sh disarm
#   jg-tokens-retro.sh --help
#
# `arm` writes state/tokens-retro.check.sh and binds its bytes with
# jg-check-register.sh, so the watcher runs `check` on its normal
# JG_CHECK_INTERVAL cadence and turns its one line into a `check:` wake; there
# is no second scheduler. `disarm` removes the shim and its trust binding and
# keeps the reports.
#
# `check` does nothing while config/token-saver-off exists. Otherwise, when
# today's report is missing and no retro is running, it starts one in the
# background, because a retro over a large session store can outlast the
# watcher's per-check bound, and stays silent. When today's report and the one
# from seven days earlier both exist, it prints one line, once, if tokens per
# day moved by JG_TOKENS_RETRO_CHANGE_PCT percent (default 20) or more.
# Each day's report also adds one row to data/tokens-retro/per-call.tsv, read
# with `show`. Bootstrap arms the check on every primary home, so no one has to.
# The retro reads only the session stores and makes no model calls.
# A host whose learn-from-mistakes-axi has no tokens mode (before 0.12.0)
# stays silent; bootstrap already reports the pin.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
OUT="$DATA/tokens-retro"
CHECK_ID=tokens-retro
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
LFM="${JG_TOKENS_RETRO_LFM:-learn-from-mistakes-axi}"
CHANGE_PCT=${JG_TOKENS_RETRO_CHANGE_PCT:-20}
# A retro that has not finished in this long is treated as dead and retried.
STALE_SECS=21600

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  jg-tokens-retro.sh [check]   run today's token retro if due; print one line on a week-over-week change
  jg-tokens-retro.sh show      print data/tokens-retro/per-call.tsv: tokens per call, floor, share over 200k, by day and commit
  jg-tokens-retro.sh arm       write and register state/tokens-retro.check.sh
  jg-tokens-retro.sh disarm    remove the check shim and its trust binding (reports stay)
  jg-tokens-retro.sh --help    print this help

config/token-saver-off turns the check off. See docs/configuration.md "Token saver".
EOF
}

day() { date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F; }

per_day() { jq -r '.metrics.tokens_per_day // empty | floor' "$1" 2>/dev/null; }

# One row a day in data/tokens-retro/per-call.tsv: tokens per model call (the
# number a context-size change moves), the instruction floor, the share of calls
# above 200k, and the commit this home runs, so a cut shows as a before/after pair.
record_per_call() {
  local f="$OUT/per-call.tsv" j="$OUT/$1/tokens.json" row
  [ -f "$j" ] || return 0
  grep -q "^$1	" "$f" 2>/dev/null && return 0
  row=$(jq -r --arg d "$1" --arg c "$(git -C "$JG_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    'select((.requests // 0) > 0) | [$d, $c, (.requests), ((.total / .requests) | floor),
     (.metrics.floor_tokens_median // 0 | floor), ((.metrics.ctx_over_200k_share // 0) * 100 | floor)] | @tsv' "$j" 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  [ -f "$f" ] || printf 'date\tcommit\tcalls\ttokens_per_call\tfloor_median\tpct_calls_over_200k\n' >"$f"
  printf '%s\n' "$row" >>"$f"
}

action_show() {
  [ -f "$OUT/per-call.tsv" ] || { printf 'jg-tokens-retro: no per-call record yet (%s)\n' "$OUT/per-call.tsv" >&2; return 1; }
  column -t -s "$(printf '\t')" "$OUT/per-call.tsv"
}

action_check() {
  local now today week_ago lock started cur old pct
  [ ! -e "$CONFIG/token-saver-off" ] || return 0
  case "$CHANGE_PCT" in ''|*[!0-9]*) printf 'jg-tokens-retro: JG_TOKENS_RETRO_CHANGE_PCT must be a whole number\n' >&2; return 2 ;; esac
  now=$(date +%s)
  today=$(day "$now")
  week_ago=$(day $((now - 7 * 86400)))
  mkdir -p "$OUT" || return 1
  if [ ! -f "$OUT/$today/tokens.json" ]; then
    "$LFM" tokens --help >/dev/null 2>&1 || return 0
    lock="$OUT/.$today.running"
    if ! mkdir "$lock" 2>/dev/null; then
      started=$(cat "$lock/started" 2>/dev/null || echo 0)
      case "$started" in ''|*[!0-9]*) started=0 ;; esac
      [ $((now - started)) -ge "$STALE_SECS" ] || return 0
      rm -rf -- "$lock" && mkdir "$lock" || return 0
    fi
    printf '%s\n' "$now" >"$lock/started"
    # The run writes into the lock directory and is renamed into place only
    # when tokens.json exists, so a killed run leaves no partial report. A
    # failed run (an empty window, an unreadable store) keeps its lock and log
    # until STALE_SECS, so an idle home retries a few times a day, not every poll.
    # shellcheck disable=SC2016  # the child shell expands these
    nohup bash -c 'lfm=$1 out=$2 lock=$3 today=$4
      "$lfm" tokens retro --since 1d --out "$lock/run" >"$lock/log" 2>&1 \
        && [ -f "$lock/run/tokens.json" ] && mv -- "$lock/run" "$out/$today" \
        && rm -rf -- "$lock"' jg-tokens-retro "$LFM" "$OUT" "$lock" "$today" </dev/null >/dev/null 2>&1 &
    return 0
  fi
  record_per_call "$today"
  [ -f "$OUT/$week_ago/tokens.json" ] || return 0
  [ ! -e "$OUT/$today/.reported" ] || return 0
  cur=$(per_day "$OUT/$today/tokens.json")
  old=$(per_day "$OUT/$week_ago/tokens.json")
  : >"$OUT/$today/.reported"
  case "$cur$old" in ''|*[!0-9]*) return 0 ;; esac
  [ "$old" -gt 0 ] || return 0
  pct=$(( (cur - old) * 100 / old ))
  [ "${pct#-}" -ge "$CHANGE_PCT" ] || return 0
  printf 'tokens per day %s vs %s a week earlier (%+d%%); report: %s\n' "$cur" "$old" "$pct" "$OUT/$today/tokens.txt"
}

shim_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by jg-tokens-retro.sh - daily token retro check shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export JG_HOME=$(printf '%q' "$1")" \
    "exec $(printf '%q' "$SCRIPT_DIR/jg-tokens-retro.sh") check"
}

action_arm() {
  local home device tmp
  home=$(CDPATH='' cd -- "$JG_HOME" 2>/dev/null && pwd -P) || {
    printf 'jg-tokens-retro: cannot resolve JG_HOME %s\n' "$JG_HOME" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  [ ! -L "$STATE" ] || return 1
  device=$(jg_pr_file_device "$STATE") || return 1
  jg_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || {
    printf 'jg-tokens-retro: refusing a non-regular %s\n' "$CHECK_SHIM" >&2
    return 1
  }
  # The bytes arrive by rename so the watcher never reads a half-written shim.
  tmp=$(umask 077; mktemp "$STATE/.jg-tokens-retro-check.XXXXXX") || return 1
  if ! shim_content "$home" >"$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! JG_HOME="$home" "$SCRIPT_DIR/jg-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    printf 'jg-tokens-retro: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  show) action_show ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) printf 'jg-tokens-retro: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
