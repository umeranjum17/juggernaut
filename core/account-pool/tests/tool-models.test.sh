#!/usr/bin/env bash
# Tool-models journey for the pool: config/tool-models.json moves the default route chain (tag route-chain) and the
# Claude model a pick uses when the request names none (tag model-pool) with a file edit alone. Each step prints the
# real jg-model-pool answer before and after the edit; removing the entry restores today's default; a bad entry keeps
# the default and prints one plain TOOL_MODELS line. Fixture home only: no network, no login, no real model CLI.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
addons=$(cd "$here/../.." && pwd) || exit 1
helper=$addons/account-pool/bin/jg-model-pool
pool=$addons/claude-accounts/bin/claude-accounts-pick
w=$(mktemp -d "${TMPDIR:-/tmp}/tool-models-pool-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
mkdir -p "$w/home/state" "$w/home/config" "$w/a" "$w/pool" "$w/bin"
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1: $3"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
for name in claude codex cursor opencode pi kimi; do
  printf '#!/bin/sh\necho blocked:%s >&2; exit 97\n' "$name" >"$w/bin/$name"
  chmod +x "$w/bin/$name"
done
printf '#!/bin/sh\nexec env JG_HOME="%s" JG_CLAUDE_ACCOUNTS_REGISTRY="%s" JG_CLAUDE_ACCOUNTS_FRESH=999999 "%s" "$@"\n' \
  "$w/home" "$w/registry.json" "$pool" >"$w/bin/pool-cmd"
chmod +x "$w/bin/pool-cmd"
printf '{"version":1,"accounts":[{"id":"pa_umer_a","provider":"claude","name":"Umer A","folder":"%s"}]}\n' "$w/a" >"$w/registry.json"
cfg=$w/home/config/account-pool
tm=$w/home/config/tool-models.json
printf 'state=%s\ncommand=%s\n' "$w/pool" "$w/bin/pool-cmd" >"$cfg"

claude_room() { # <left percent>: Umer A's reading
  local now
  now=$(date +%s)
  jq -n --argjson at "$now" --arg f "$w/a" --argjson l "$1" \
    '{schema:1,generated_at:$at,accounts:[{id:"pa_umer_a",name:"Umer A",folder:$f,five_hour:{left:$l},seven_day:{left:$l},read_at:$at,problem:null}]}' \
    >"$w/pool/claude-accounts.json"
  cp "$w/pool/claude-accounts.json" "$w/home/state/claude-accounts.json"
}
pick() { # <extra request json>
  out=$(jq -nc --arg p "$cfg" --argjson x "${1:-{\}}" '{v:1,purpose:"work",pool_config:$p,capabilities:["text"],attempted:[]} + $x' |
    env -i PATH="$w/bin:/usr/bin:/bin" HOME="$w" TMPDIR="$w" JG_HOME="$w/home" JG_ROUTE_CHAIN_STATE="$w/home/state" \
      JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" JG_CLAUSE_NOW=1793538000 JG_MODEL_POOL_FLOOR=15 \
      JG_ACCOUNT_POOL_REST_FLOOR=15 JG_CLAUDE_ACCOUNTS_LOW=5 JG_CLAUDE_ACCOUNTS_FRESH=999999 \
      "$helper" pick --json 2>"$w/err")
}
route_ids() { # the chain in order: pick, then pick past each id already returned
  local seen='[]' ids=''
  while pick "{\"attempted\":$seen}" && [ "$(jq -r .ok <<<"$out")" = true ]; do
    ids="$ids $(jq -r '.id + "(" + .harness + ")"' <<<"$out")"
    seen=$(jq -c --argjson s "$seen" '$s + [.id]' <<<"$out")
  done
  printf '%s' "${ids# }"
}
rules() { printf '{"rules":[{"tool":"%s","when":"fixture","use":%s}]}\n' "$1" "$2"; }
tm_lines() { grep -c "^TOOL_MODELS:.* $1 keeps its default" "$w/err"; } # <tool>: lines naming that tool

echo "== route chain =="
claude_room 0
default_chain=$(route_ids)
echo "before (no file): $default_chain"
is "built-in head" "${default_chain%% *}" "route:ollama-cloud/deepseek-v4.1-flash(opencode)"

rules route-chain '[{"harness":"pi","model":"commandcode/deepseek/deepseek-v4.1-flash"},{"harness":"codex","model":"openai-codex/gpt-6-luna","provider":"codex"}]' >"$tm"
edited=$(route_ids)
echo "after the file names two routes: $edited"
is "the file alone sets the chain" "$edited" "route:commandcode/deepseek/deepseek-v4.1-flash(pi) route:openai-codex/gpt-6-luna(codex)"

rules route-chain '[{"harness":"cursor","model":"auto"}]' >"$tm"
is "the next edit applies at the next call" "$(route_ids)" "route:cursor/auto(cursor)"

rm -f "$tm"
is "removing the file restores today's default" "$(route_ids)" "$default_chain"

rules squad-lead '{"harness":"claude","model":"sonnet"}' >"$tm"
is "a file with no route-chain rule keeps the default" "$(route_ids)" "$default_chain"

rules route-chain '[{"harness":"nonesuch","model":"x/y"}]' >"$tm"
pick
is "a bad entry keeps the default head" "$(jq -r .id <<<"$out")" "route:ollama-cloud/deepseek-v4.1-flash"
is "a bad entry prints one plain TOOL_MODELS line for the chain" "$(tm_lines route-chain)" 1
echo "reason: $(grep 'route-chain keeps' "$w/err")"

printf 'not json\n' >"$tm"
pick
is "text that is not JSON keeps the default head" "$(jq -r .id <<<"$out")" "route:ollama-cloud/deepseek-v4.1-flash"
is "and prints one plain TOOL_MODELS line for the chain" "$(tm_lines route-chain)" 1

printf '{"openai-codex":["gpt-6-sol"]}\n' >"$w/home/config/model-allow-list.json"
rules route-chain '[{"harness":"codex","model":"openai-codex/gpt-6-luna","provider":"codex"},{"harness":"cursor","model":"auto"}]' >"$tm"
is "a model the allow-list refuses is skipped, the rest apply" "$(route_ids)" "route:cursor/auto(cursor)"
rm -f "$w/home/config/model-allow-list.json"

printf 'route={"id":"route:home/own","provider":"cursor","harness":"cursor","model":"auto","billing":"plan"}\n' >>"$cfg"
rules route-chain '[{"harness":"pi","model":"commandcode/deepseek/deepseek-v4.1-flash"}]' >"$tm"
is "a home's own route= lines still win" "$(route_ids)" "route:home/own(cursor)"
rm -f "$tm"
sed -i '/^route=/d' "$cfg"

echo "== pool default Claude model =="
claude_room 90
pick
echo "before (no file): model = $(jq -r .model <<<"$out")"
is "built-in Claude model" "$(jq -r .model <<<"$out")" claude-haiku-5-5
rules model-pool '{"harness":"claude","model":"claude-sonnet-5-5"}' >"$tm"
pick
is "the file alone sets the model" "$(jq -r .model <<<"$out")" claude-sonnet-5-5
rules model-pool '{"harness":"claude","model":"claude-fable-5-1"}' >"$tm"
pick
is "the next edit applies at the next call" "$(jq -r .model <<<"$out")" claude-fable-5-1
pick '{"model":"claude-opus-5-5"}'
is "a model the request names still wins" "$(jq -r .model <<<"$out")" claude-opus-5-5
rm -f "$tm"
pick
is "removing the file restores today's default" "$(jq -r .model <<<"$out")" claude-haiku-5-5
rules model-pool '{"harness":"codex","model":"gpt-6-luna"}' >"$tm"
pick
is "a non-Claude entry keeps the default" "$(jq -r .model <<<"$out")" claude-haiku-5-5

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "tool-models pool: all checks passed"
