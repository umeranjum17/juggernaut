# shellcheck shell=bash
# jg-route-chain-lib.sh - the shared free-route chain: its route list, each route's health marker, and the one switch
# status line. Sourced by jg-model-pool (skips a route the probe marked down) and jg-route-probe (checks them at pulse
# cadence). No credential is read, printed or copied here.
#
# A home names its own order with one `route=<json object>` line per route in config/account-pool, in chain order; a
# home that names none gets the captain's approved free-route order below. Route object:
# {"id","provider","harness","model","billing"} and optionally "only":"hard" (kept for hard steps, e.g. Sol).
# State: state/route-health/<id> markers, state/route-chain.log (one line per switch), state/.route-chain.head.

# The captain's approved order (2026-10-25): Ollama credit, Command Code, Codex Luna, the free tiers we hold (Kimi,
# Cursor auto), Sol for hard steps only. Claude is not a route: jg-model-pool keeps the owner's own subscription
# accounts ahead of this chain and no route spends extra credits.
JG_ROUTE_DEFAULT_CHAIN='[
 {"id":"route:ollama-cloud/deepseek-v4.1-flash","provider":"ollama-cloud","harness":"opencode","model":"ollama-cloud/deepseek-v4.1-flash","billing":"plan"},
 {"id":"route:commandcode/deepseek/deepseek-v4.1-flash","provider":"commandcode","harness":"pi","model":"commandcode/deepseek/deepseek-v4.1-flash","billing":"plan"},
 {"id":"route:openai-codex/gpt-6-luna","provider":"codex","harness":"codex","model":"openai-codex/gpt-6-luna","billing":"plan"},
 {"id":"route:kimi-coding/kimi-for-coding","provider":"kimi-coding","harness":"kimi","model":"kimi-coding/kimi-for-coding","billing":"plan"},
 {"id":"route:cursor/auto","provider":"cursor","harness":"cursor","model":"auto","billing":"plan"},
 {"id":"route:openai-codex/gpt-6.1-sol","provider":"codex","harness":"codex","model":"openai-codex/gpt-6.1-sol","billing":"plan","only":"hard"}
]'

jg_route_state() { printf '%s\n' "${JG_ROUTE_CHAIN_STATE:-${JG_STATE_OVERRIDE:-${JG_HOME:-$HOME/juggernaut}/state}}"; }

# jg_route_chain_json <pool config file>: the home's route= lines in order, else the built-in chain. A route= line that
# is not one JSON object refuses (non-zero, message on stderr) instead of silently shortening the chain.
jg_route_chain_json() {
  local file=${1:-} line out='[]'
  if [ -n "$file" ] && [ -r "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in
      route=*)
        out=$(jq -c --argjson r "${line#route=}" '. + [$r]' <<<"$out" 2>/dev/null) || {
          printf 'error: config/account-pool route= must be one JSON route object: %s\n' "${line#route=}" >&2
          return 1
        }
        ;;
      esac
    done <"$file"
  fi
  [ "$out" != '[]' ] || out=$(jg_route_tool_models_chain "$file") || out=$JG_ROUTE_DEFAULT_CHAIN
  printf '%s\n' "$out"
}

# jg_route_tool_models_chain <pool config file>: the chain an entry tagged route-chain in config/tool-models.json
# (bin/jg-tool-models.sh, docs/configuration.md "Tool models") names, read at every call; it replaces only the built-in
# default above, so a home's own route= lines still win. Non-zero (print nothing) when there is no usable entry, and the
# built-in default stands. Each profile is {harness, model} plus optional provider (else the model's prefix), billing
# (else plan) and only; the route id is route:<model>, or route:<provider>/<model> when the model has no provider prefix.
jg_route_tool_models_chain() {
  local file=${1:-} tm profiles chain
  tm=${BASH_SOURCE[0]%/*}/../../../bin/jg-tool-models.sh
  [ -x "$tm" ] || return 1
  # The tool-models file sits beside the pool config unless the caller names one.
  if [ -n "$file" ] && [ -z "${JG_TOOL_MODELS:-}" ]; then
    profiles=$(JG_TOOL_MODELS=${file%/*}/tool-models.json "$tm" profiles route-chain) || return 1
  else
    profiles=$("$tm" profiles route-chain) || return 1
  fi
  [ -n "$profiles" ] || return 1
  chain=$(jq -c '[.[] | select(.model != null)
    | (.provider // (if (.model | contains("/")) then (.model | split("/")[0]) else .harness end)) as $provider
    | {id: ("route:" + (if (.model | contains("/")) then .model else $provider + "/" + .model end)),
       provider: $provider, harness, model, billing: (.billing // "plan")} + (if .only then {only} else {} end)]' <<<"$profiles") || return 1
  [ "$chain" != '[]' ] || return 1
  printf '%s\n' "$chain"
}

# jg_route_quota_provider <provider>: the provider name quota-axi reports this route's room under, because pi and the
# chain call openai-codex "codex" and kimi-coding "kimi". One owner for the mapping, read by the probe and by any
# tool that asks a route's room before it calls it.
jg_route_quota_provider() {
  case $1 in
  openai-codex | codex) echo codex ;;
  kimi-coding) echo kimi ;;
  *) echo "$1" ;;
  esac
}

jg_route_marker() { printf '%s/route-health/%s\n' "$(jg_route_state)" "${1//\//%}"; }
jg_route_read() { [ -r "$(jg_route_marker "$1")" ] && head -n 1 -- "$(jg_route_marker "$1")" 2>/dev/null; }

# jg_route_down <id>: 0 when the probe marked the route down and its retry time has not come yet, so a down route is
# skipped now and retried later, never dropped.
jg_route_down() {
  local status retry cause
  read -r status retry cause <<<"$(jg_route_read "$1")" || return 1
  [ "$status" = down ] || return 1
  case ${retry:-} in '' | *[!0-9]*) return 0 ;; esac
  [ "$retry" -gt "$(date +%s)" ]
}

jg_route_cause() {
  { read -r _ _ cause <<<"$(jg_route_read "$1")"; } 2>/dev/null
  printf '%s\n' "${cause:-unknown}"
}

jg_route_retry_seconds() { printf '%s\n' "${JG_ROUTE_RETRY_SECONDS:-900}"; }

jg_route_mark() { # <id> <up|down> <cause>: one marker per route; down carries its retry time
  local f retry=0
  f=$(jg_route_marker "$1")
  [ "$2" = up ] || retry=$(($(date +%s) + $(jg_route_retry_seconds)))
  mkdir -p -- "${f%/*}" 2>/dev/null || return 0
  printf '%s %s %s\n' "$2" "$retry" "${3// /_}" >"$f" 2>/dev/null || true
}

# jg_route_switch <from> <to> <why>: ONE status line per switch. The same switch repeated (every pass while a route
# stays down) stays that one line.
jg_route_switch() {
  local state last
  state=$(jg_route_state)
  mkdir -p -- "$state" 2>/dev/null || return 0
  last="$1->$2($3)"
  [ "$(cat -- "$state/.route-chain.last" 2>/dev/null)" = "$last" ] && return 0
  printf '%s' "$last" >"$state/.route-chain.last" 2>/dev/null || true
  printf '%s route-chain: from=%s to=%s why=%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >>"$state/route-chain.log" 2>/dev/null || true
}
