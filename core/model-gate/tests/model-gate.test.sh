#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Journey for model-gate, with a throwaway HOME, XDG paths and juggernaut home, stub curl answering the real usage and
# balance endpoints and a fixture opencode config: the provider whitelist (others untouched, idempotent, removable), the
# dispatch check (allowed, pinned tag, off-list refusal naming provider/model/list), the list edits, the watch and
# jg-model-pool refusing an off-list route. Nothing real is read, spent or called.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
addons=$(cd "$here/.." && pwd -P)
gate=$here/bin/jg-model-gate
w=$(mktemp -d "${TMPDIR:-/tmp}/model-gate-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/config" "$w/home/state" "$w/home/bin" "$w/xdg" "$w/b" "$w/log" "$w/pool" "$w/a"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
# The real Ollama usage and balance endpoints, answered from fixtures. The key file is a fixture too.
printf 'fixture-key-never-print\n' >"$w/fixture-key"
cat >"$w/b/curl" <<SH
#!/usr/bin/env bash
case "\$*" in *api/balance*) cat "$w/balance.json" ;; *api/usage*) cat "$w/usage.json" ;; *) exit 7 ;; esac
SH
{ printf '#!/bin/sh\necho "$*" >> %s\n' "$w/registered.txt"; } >"$w/home/bin/jg-check-register.sh"
chmod +x "$w/b/curl" "$w/home/bin/jg-check-register.sh"
cat >"$w/balance.json" <<'J'
{"included":{"balance_usd":299.99,"allowance_usd":300,"period":{"from":"2026-10-25T12:23:12Z","until":"2026-11-25T12:23:12Z"}},"purchased":{"balance_usd":0}}
J
usage() { local rows='' m; for m in "$@"; do rows+="{\"model\":\"$m\",\"request_count\":4,\"usage_usd\":0.4213},"; done
  printf '{"range":"7d","group_by":"model","totals":{"request_count":4,"usage_usd":0.4213,"groups":[%s]}}\n' "${rows%,}"; }
cat >"$w/oc.json" <<'J'
{"$schema":"https://opencode.ai/config.json","plugin":["keep-me"],
 "provider":{"ollama-cloud":{"npm":"@ai-sdk/openai-compatible","options":{"apiKey":"{file:~/.config/ollama-cloud/api_key}"},
   "models":{"deepseek-v4.1-flash":{"name":"DeepSeek V4.1 Flash"},"glm-5.3-flash":{"name":"GLM"}}},
  "openrouter":{"models":{"deepseek/deepseek-v4.1-flash":{"name":"DeepSeek"}}}}}
J
export HOME=$w/home XDG_DATA_HOME=$w/xdg JG_HOME=$w/home PATH=$w/b:/usr/bin:/bin
export OPENCODE_CONFIG=$w/oc.json OLLAMA_API_KEY_FILE=$w/fixture-key
list=$w/home/config/model-allow-list.json
inst() { env JG_HOME="$w/home" "$here/wiring.sh" "$@" >>"$w/log/install.out" 2>&1; }

inst --dry-run
is "dry run writes no config" "$(jq -c '.provider["ollama-cloud"].whitelist // "absent"' "$w/oc.json")" '"absent"'
inst
is "opencode whitelist is the listed model only" "$(jq -c '.provider["ollama-cloud"].whitelist' "$w/oc.json")" '["deepseek-v4.1-flash"]'
is "listed models, vendor options, other providers and config keys kept" \
  "$(jq -c '[(.provider["ollama-cloud"].models|length), .provider["ollama-cloud"].options.apiKey, (.provider.openrouter.models|length), .plugin[0]]' "$w/oc.json")" \
  '[2,"{file:~/.config/ollama-cloud/api_key}",1,"keep-me"]'
: >"$w/log/install.out"; inst
is "reinstall writes nothing" "$(grep -c '^wrote ' "$w/log/install.out")" 0
is "gate on PATH, fleet check installed and registered" "$([ -x "$w/home/.local/bin/jg-model-gate" ] && [ -e "$w/home/state/model-gate.check.sh" ] && head -1 "$w/registered.txt" 2>/dev/null)" model-gate
grep -q fixture-key-never-print "$w/log"/*.out && is "key never printed" leak leak || is "key never printed" clean clean
ck() { "$gate" check "$@" >"$w/log/ck.out" 2>&1; echo $?; }
is "allowed flash model" "$(ck ollama-cloud deepseek-v4.1-flash)" 0
is "pinned tag of the same model" "$(ck ollama-cloud deepseek-v4.1-flash:1017)" 0
is "off-list ollama model refused" "$(ck ollama-cloud glm-5.3-flash)" 1
is "refusal names provider, model and list" "$(grep -c "^jg-model-gate: ollama-cloud model glm-5.3-flash is not allowed (allowed: deepseek-v4.1-flash); list: $list$" "$w/log/ck.out")" 1
is "a provider the list does not name is not limited" "$(ck openrouter deepseek/deepseek-v4.1-flash)" 0
is "list prints one line per provider" "$("$gate" list)" "ollama-cloud: deepseek-v4.1-flash  (list: $list)"
is "allow edits the list" "$("$gate" allow ollama-cloud deepseek-v4.1-flash:1017 | tail -1)" "ollama-cloud: deepseek-v4.1-flash deepseek-v4.1-flash:1017  (list: $list)"
is "deny edits the list" "$("$gate" deny ollama-cloud deepseek-v4.1-flash:1017 | tail -1)" "ollama-cloud: deepseek-v4.1-flash  (list: $list)"
export JG_MODEL_GATE_MIN_SECONDS=0
usage deepseek-v4.1-flash:1017 >"$w/usage.json"
is "allowed model only: silent" "$("$gate" watch)" ''
usage deepseek-v4.1-flash:1017 glm-5.3-flash >"$w/usage.json"
first=$("$gate" watch)
is "off-list model warns once, with the credit left and the list" "$(printf '%s' "$first" | grep -c "model-gate: ollama-cloud/glm-5.3-flash was used 4 time(s) for .0.4213 in the last 7d but only deepseek-v4.1-flash is allowed (credit left .299.99 of .300 (period ends 2026-11-25T12:23:12Z)); list: $list")" 1
is "same sighting does not warn again" "$("$gate" watch)" ''
usage deepseek-v4.1-flash:1017 glm-5.3-flash kimi-k3 >"$w/usage.json"
is "only the new off-list model warns" "$("$gate" watch | grep -c 'kimi-k3')" 1
JG_MODEL_GATE_MIN_SECONDS=600 "$gate" watch >"$w/log/throttled.out"
is "cadence throttle keeps one read per window" "$(wc -c <"$w/log/throttled.out")" 0
grep -q fixture-key-never-print "$w/log"/*.out && is "key never leaked by the watch" leak leak || is "key never leaked by the watch" clean clean
printf '#!/bin/sh\nexit 1\n' >"$w/b/pool-cmd"
chmod +x "$w/b/pool-cmd"
# The fixture names its own two-route chain, so this proves the gate skipping a refused route for the next one and
# not which order the shipped chain happens to carry.
{
  printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/b/pool-cmd"
  printf 'route={"id":"route:openai-codex/gpt-6.1-sol","provider":"codex","harness":"codex","model":"openai-codex/gpt-6.1-sol","billing":"plan"}\n'
  printf 'route={"id":"route:deepseek/deepseek-goat","provider":"deepseek","harness":"opencode","model":"deepseek/deepseek-goat","billing":"plan"}\n'
} >"$w/home/config/account-pool"
printf '{"codex": []}\n' >"$w/gate-list.json"
printf '{"version":1,"accounts":[{"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"%s"}]}\n' "$w/a" >"$w/registry.json"
jq -n --argjson at "$(date +%s)" '{schema:1,generated_at:$at,accounts:[{id:"pa_umer_a",name:"Umer A",folder:"a",five_hour:{left:9},seven_day:{left:9},read_at:$at,problem:null}]}' >"$w/pool/claude-accounts.json"
out=$(jq -nc --arg p "$w/home/config/account-pool" '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],attempted:[]}' | \
  env PATH="$w/b:/usr/bin:/bin" HOME="$w/home" JG_HOME="$w/home" TMPDIR="$w" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" \
  JG_MODEL_GATE="$gate" JG_MODEL_GATE_LIST="$w/gate-list.json" JG_MODEL_POOL_FLOOR=15 JG_CLAUDE_ACCOUNTS_FRESH=999999 \
  "$addons/account-pool/bin/jg-model-pool" pick --json 2>"$w/log/pool.err")
is "off-list route refused, next route emitted" "$(jq -r .id <<<"$out")" "route:deepseek/deepseek-goat"
is "pool logs the model-gate refusal" "$(grep -c 'model-gate refuse provider=codex model=openai-codex/gpt-6.1-sol' "$w/log/pool.err")" 1

# The launch hook jg-spawn calls, and the repair the fleet check makes when an opencode update drops the whitelist.
G=$gate
spawn() { ( HARNESS_ARG=opencode MODEL="$1" JG_MODEL_GATE="$G" bash -c '. "$1/bin/jg-model-gate-lib.sh"; jg_model_gate_hook spawn-validate || exit 1' _ "$here" ) 2>"$w/log/spawn.err"; echo $?; }
is "an explicit off-list launch is refused" "$(spawn ollama-cloud/glm-5.3)" 1
is "the launch refusal is the gate's one line" "$(grep -c "^jg-model-gate: ollama-cloud model glm-5.3 is not allowed" "$w/log/spawn.err")" 1
is "an allowed model launches" "$(spawn ollama-cloud/deepseek-v4.1-flash)" 0
is "a provider the list does not name still launches" "$(spawn openai-codex/gpt-6-luna)" 0
G=; is "no gate reachable: launch not blocked" "$(spawn ollama-cloud/glm-5.3)" 0; G=$gate
jq 'del(.provider["ollama-cloud"].whitelist)' "$w/oc.json" >"$w/oc.tmp" && mv "$w/oc.tmp" "$w/oc.json"
is "fleet check restores a wiped whitelist, one line" "$(env -u JG_HOME "$w/home/state/model-gate.check.sh" | grep -c 'restored the opencode whitelist for ollama-cloud')" 1
is "the whitelist is back" "$(jq -c '.provider["ollama-cloud"].whitelist' "$w/oc.json")" '["deepseek-v4.1-flash"]'
is "the repair is not repeated" "$("$w/home/state/model-gate.check.sh" 2>/dev/null | grep -c restored)" 0
inst --remove
is "remove takes its whitelist and check away" "$(jq -r '.provider["ollama-cloud"].whitelist // "absent"' "$w/oc.json") $(find "$w/home" -name 'model-gate*' | wc -l)" 'absent 0'
is "remove keeps the models, other providers and the allow-list" "$(jq -r '(.provider["ollama-cloud"].models|length|tostring) + (.provider.openrouter.models|length|tostring)' "$w/oc.json") $([ -e "$list" ] && echo kept)" '21 kept'

# The shared config survives concurrent runs and a truncated write: always valid, non-empty JSON, never replaced by garbage.
jq 'del(.provider["ollama-cloud"].whitelist)' "$w/oc.json" >"$w/oc.tmp" && mv "$w/oc.tmp" "$w/oc.json"
for _ in 1 2 3 4 5 6; do "$gate" opencode >/dev/null 2>&1 & done; wait
is "concurrent runs leave valid JSON with the whitelist" "$(jq -c '.provider["ollama-cloud"].whitelist' "$w/oc.json" 2>&1)" '["deepseek-v4.1-flash"]'
is "concurrent runs leave no lock or temp file" "$(find "$w" -maxdepth 1 \( -name 'oc.json.lock' -o -name 'oc.json.tmp.*' \) | wc -l)" 0
mkdir "$w/trunc"
# shellcheck disable=SC2016 # the stub script body is meant literal
printf '#!/bin/sh\n[ "$1" = --arg ] && { printf "{\\"provi"; exit 0; }\nexec /usr/bin/jq "$@"\n' >"$w/trunc/jq"; chmod +x "$w/trunc/jq"
jq 'del(.provider["ollama-cloud"].whitelist)' "$w/oc.json" >"$w/oc.tmp" && mv "$w/oc.tmp" "$w/oc.json"
before=$(cksum <"$w/oc.json")
PATH=$w/trunc:$PATH "$gate" opencode >/dev/null 2>"$w/log/trunc.err"; rc=$?
is "a truncated write is refused, non-zero" "$rc" 2
is "a truncated write leaves the original byte for byte" "$(cksum <"$w/oc.json")" "$before"
is "the refusal says why" "$(grep -c 'refusing to write' "$w/log/trunc.err")" 1

[ "$fails" -eq 0 ] && echo PASS || { echo "FAIL: $fails"; exit 1; }
