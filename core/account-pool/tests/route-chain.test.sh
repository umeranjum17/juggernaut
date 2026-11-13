#!/usr/bin/env bash
# Route-chain journey: the approved free-route order picks Ollama first, Sol only when the call asked for a hard step;
# the health probe marks a dead route down with one switch line, work continues on the next route, and the down route
# returns on its own after its retry time. A home that names its own route= order gets that order.
# No network, no login copy, no real model CLI: quota-axi, curl and every model binary are fixture stubs.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
helper=$addons/account-pool/bin/jg-model-pool
probe=$addons/account-pool/bin/jg-route-probe
w=$(mktemp -d "${TMPDIR:-/tmp}/route-chain-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/state" "$w/home/config" "$w/pool" "$w/bin" "$w/.config/ollama-cloud"
# The capacity alert goes through the real alert function: the fixture home reaches it by a one-line wrapper.
mkdir -p "$w/home/bin"; printf '#!/usr/bin/env bash\nexec bash %s/bin/jg-alert.sh "$@"\n' "$(cd "$here/../../.." && pwd)" >"$w/home/bin/jg-alert.sh"; chmod +x "$w/home/bin/jg-alert.sh"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

for name in claude codex cursor opencode pi kimi; do
  printf '#!/bin/sh\necho blocked:%s >&2; exit 97\n' "$name" >"$w/bin/$name"
  chmod +x "$w/bin/$name"
done
printf 'fixture-ollama-key\n' >"$w/.config/ollama-cloud/api_key"
# quota-axi stand-in: Command Code usable, Codex usable, Kimi signed out, Cursor out of quota.
cat >"$w/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"providers":[
 {"provider":"commandcode","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"through_reset"}}]}},
 {"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"through_reset"}}]}},
 {"provider":"kimi","state":{"status":"unavailable"}},
 {"provider":"cursor","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","runway":{"status":"exhausted_now"}}]}}]}'
SH
chmod +x "$w/bin/quota-axi"
balance() { # <included balance>
  printf '#!/bin/sh\nprintf %%s %s\n' "'{\"purchased\":{\"balance_usd\":0},\"included\":{\"balance_usd\":$1,\"allowance_usd\":300}}'" >"$w/bin/curl"
  chmod +x "$w/bin/curl"
}
balance 299.95
pool_cfg=$w/home/config/account-pool
printf 'state=%s\ncommand=/bin/true\n' "$w/pool" >"$pool_cfg"

# No Claude account in the pool (registry absent): the chain is the route list.
req() { jq -nc --arg p "$pool_cfg" --argjson a "${1:-[]}" --argjson hard "${2:-false}" \
  '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],hard:$hard,attempted:$a}'; }
pick() { # <attempted-json> [hard]
  out=$(printf '%s' "$(req "${1:-[]}" "${2:-false}")" | env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" \
    JG_HOME="$w/home" JG_ROUTE_CHAIN_STATE="$w/home/state" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/none.json" \
    JG_CLAUSE_NOW="${JG_CLAUSE_NOW:-1793538000}" \
    JG_MODEL_POOL_FLOOR=15 JG_ACCOUNT_POOL_REST_FLOOR=15 "$helper" pick --json 2>"$w/err"); rc=$?
}
probe_run() {
  out=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" JG_HOME="$w/home" \
    JG_ROUTE_CHAIN_STATE="$w/home/state" JG_ROUTE_RETRY_SECONDS=900 \
    bash "$probe" probe --force 2>"$w/perr"); rc=$?
}
log_lines() { if [ -f "$w/home/state/route-chain.log" ]; then wc -l <"$w/home/state/route-chain.log"; else echo 0; fi; }
state_of() { awk -F '\t' -v r="$1" '$1 == r { print $2 }' <<<"$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" \
  JG_HOME="$w/home" JG_ROUTE_CHAIN_STATE="$w/home/state" bash "$probe" status)"; }

# 1. Approved order: Ollama credit first, on the opencode harness.
pick
is "chain head is Ollama" "$(jq -r .id <<<"$out")" "route:ollama-cloud/deepseek-v4.1-flash"
is "Ollama model" "$(jq -r .model <<<"$out")" "ollama-cloud/deepseek-v4.1-flash"
is "Ollama harness" "$(jq -r .harness <<<"$out")" opencode
is "Ollama is a plan route, not credits" "$(jq -r .billing <<<"$out")" plan

# 2. Order after it: Command Code, then Luna, then the free tiers, Sol only for a hard step.
pick '["route:ollama-cloud/deepseek-v4.1-flash"]'
is "second route is Command Code" "$(jq -r .id <<<"$out")" "route:commandcode/deepseek/deepseek-v4.1-flash"
pick '["route:ollama-cloud/deepseek-v4.1-flash","route:commandcode/deepseek/deepseek-v4.1-flash"]'
is "third route is Luna" "$(jq -r .id <<<"$out")" "route:openai-codex/gpt-6-luna"
free='["route:ollama-cloud/deepseek-v4.1-flash","route:commandcode/deepseek/deepseek-v4.1-flash","route:openai-codex/gpt-6-luna"]'
pick "$free"
is "fourth route is Kimi" "$(jq -r .id <<<"$out")" "route:kimi-coding/kimi-for-coding"
free3=$(jq -c '. + ["route:kimi-coding/kimi-for-coding"]' <<<"$free")
pick "$free3"
is "fifth route is Cursor auto" "$(jq -r .id <<<"$out")" "route:cursor/auto"
all=$(jq -c '. + ["route:cursor/auto"]' <<<"$free3")
pick "$all" false
is "ordinary call refuses Sol (hard steps only)" "$rc" 1
is "ordinary refusal is typed" "$(jq -r .ok <<<"$out")" false
pick "$all" true
is "hard call reaches Sol" "$(jq -r .id <<<"$out")" "route:openai-codex/gpt-6.1-sol"

# 3. Probe: one pass, one marker per route, no switch line while the head holds.
probe_run
is "probe exit 0" "$rc" 0
is "Ollama probed up on its credit" "$(state_of route:ollama-cloud/deepseek-v4.1-flash)" up
is "Command Code probed up" "$(state_of route:commandcode/deepseek/deepseek-v4.1-flash)" up
is "Kimi probed down (signed out, pi name mapped to quota-axi kimi)" "$(state_of route:kimi-coding/kimi-for-coding)" down
is "Cursor probed down (quota)" "$(state_of route:cursor/auto)" down
is "no switch line while the head holds" "$(log_lines)" 0
is "first pass records the state and prints nothing" "$out" ""
probe_run
is "an unchanged state prints nothing" "$out" ""

# 4. The kill: Ollama's credit is gone. The probe writes ONE switch line and work continues on Command Code.
balance 0
probe_run
is "Ollama probed down (credit empty)" "$(state_of route:ollama-cloud/deepseek-v4.1-flash)" down
is "one switch line" "$(log_lines)" 1
is "a changed state prints exactly one line" "$(wc -l <<<"$out")" 1
case $out in *route-chain:\ head=route:commandcode/*down=*route:ollama-cloud/deepseek-v4.1-flash\(ollama_credit_empty\)*) ok=yes ;; *) ok=no ;; esac
is "the line names the new head and the dead route" "$ok" yes
is "the line carries no epoch" "$(grep -Ec '[0-9]{10}' <<<"$out")" 0
line=$(cat "$w/home/state/route-chain.log")
case $line in
*"from=route:ollama-cloud/deepseek-v4.1-flash"*"to=route:commandcode/deepseek/deepseek-v4.1-flash"*"why=ollama_credit_empty"*) ok=yes ;;
*) ok=no ;;
esac
is "switch line names from, to and why" "$ok" yes
pick
is "work continues on Command Code" "$(jq -r .id <<<"$out")" "route:commandcode/deepseek/deepseek-v4.1-flash"
is "skipping the down route wrote no second line" "$(log_lines)" 1
probe_run
is "a second pass on the same dead route writes no new line" "$(log_lines)" 1
is "a second pass on the same dead route prints nothing" "$out" ""

# 5. Retried later: once the retry time has passed the route is probed again and the head returns.
balance 299.95
out=$(env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" JG_HOME="$w/home" JG_ROUTE_CHAIN_STATE="$w/home/state" \
  JG_ROUTE_RETRY_SECONDS=0 bash "$probe" probe --force 2>&1); rc=$?
pick
is "retried route leads again" "$(jq -r .id <<<"$out")" "route:ollama-cloud/deepseek-v4.1-flash"
is "the return is its own single line" "$(log_lines)" 2
case "$(tail -n 1 "$w/home/state/route-chain.log")" in
*"from=route:commandcode/deepseek/deepseek-v4.1-flash"*"to=route:ollama-cloud/deepseek-v4.1-flash"*) ok=yes ;;
*) ok=no ;;
esac
is "return line names the way back" "$ok" yes

# 6. A home that names its own order gets that order, and a bad route line refuses instead of shortening the chain.
printf 'state=%s\ncommand=/bin/true\nroute={"id":"route:cursor/auto","provider":"cursor","harness":"cursor","model":"auto","billing":"plan"}\n' \
  "$w/pool" >"$pool_cfg"
pick
is "home order wins" "$(jq -r .id <<<"$out")" "route:cursor/auto"
printf 'state=%s\nroute=not-json\n' "$w/pool" >"$pool_cfg"
pick
is "bad route line refuses" "$rc" 1
is "refusal names the line" "$(grep -c 'route= must be one JSON route object' "$w/err")" 1

# No real model CLI invoked.
is "no model CLI runs" "$(grep -c 'blocked:' "$w/err" "$w/perr" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')" 0

[ "$fails" -eq 0 ] || { echo "FAIL: $fails assertions"; exit 1; }
echo "PASS: route-chain journey"
exit 0
