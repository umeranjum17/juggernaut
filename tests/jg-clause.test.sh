#!/usr/bin/env bash
# jg-clause.test.sh - the owner-rule clause journeys, on the real jg-model-pool, jg-owner-rules.sh, jg-pref.sh
# and the real config push propagation. No network, no model CLI, no login: the route chain is three fixture routes.
#   1. One command adds a rule and the next route pick obeys it, with no code change.
#   2. The peak-hour DeepSeek rule (first clause) skips DeepSeek in the window and falls to the next route; changing the
#      peak-hours block changes the behaviour; removing the clause makes this journey fail (the regression guard).
#   3. A rule that was code (Sol only for a hard step) is a clause now: same behaviour, and the pool holds no per-rule branch.
#   4. A preference block change reaches a squad_lead home through the existing push, and an absent block mirrors absent.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(cd "$here/.." && pwd) || exit 1
pool=$root/core/account-pool/bin/jg-model-pool
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-clause-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }

home=$w/home
mkdir -p "$home/config" "$home/data" "$home/state" "$w/pool"
printf 'state=%s\ncommand=/bin/true\n' "$w/pool" >"$home/config/account-pool"
cat >>"$home/config/account-pool" <<'R'
route={"id":"route:ollama-cloud/deepseek-v4.1-flash","provider":"ollama-cloud","harness":"opencode","model":"ollama-cloud/deepseek-v4.1-flash","billing":"plan"}
route={"id":"route:kimi-coding/kimi-for-coding","provider":"kimi-coding","harness":"kimi","model":"kimi-coding/kimi-for-coding","billing":"plan"}
route={"id":"route:openai-codex/gpt-6.1-sol","provider":"codex","harness":"codex","model":"openai-codex/gpt-6.1-sol","billing":"plan","only":"hard"}
route={"id":"route:cursor/auto","provider":"cursor","harness":"cursor","model":"auto","billing":"plan"}
R
# Fixed clocks: Monday 14:00 UTC (peak), Monday 20:00 UTC (off peak), Sunday 13:00 UTC (weekend).
MON_PEAK=$(date -u -d 2026-11-02T14:00:00Z +%s)
MON_OFF=$(date -u -d 2026-11-02T20:00:00Z +%s)
SUN=$(date -u -d 2026-11-01T13:00:00Z +%s)

pick() { # <epoch> [hard] -> picked route id
  printf '%s' "{\"v\":1,\"purpose\":\"work\",\"pool_config\":\"$home/config/account-pool\",\"hard\":${2:-false}}" |
    env -i PATH=/usr/bin:/bin HOME="$w" TMPDIR="$w" JG_HOME="$home" JG_CLAUSE_NOW="$1" JG_MODEL_GATE=/nonexistent \
      JG_ROUTE_CHAIN_STATE="$home/state" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/none.json" "$pool" pick --json 2>"$w/err" | jq -r '.id // "none"'
}
prefenv() { env PATH=/usr/bin:/bin HOME="$w" JG_HOME="$home" JG_PREF_NO_PUSH=1 "$@"; }

echo "# journey 1: shipped peak-hour clause, then one command adds a rule"
is "off peak: DeepSeek leads" "$(pick "$MON_OFF")" "route:ollama-cloud/deepseek-v4.1-flash"
is "peak: DeepSeek skipped, next route used" "$(pick "$MON_PEAK")" "route:kimi-coding/kimi-for-coding"
is "weekend at the same hour is not peak" "$(pick "$SUN")" "route:ollama-cloud/deepseek-v4.1-flash"
pick "$MON_PEAK" >/dev/null
case $(cat "$w/err") in *"skip by clause no-deepseek-at-peak"*) ok=yes ;; *) ok=no ;; esac
is "the skip names its clause" "$ok" yes
is "before the new rule: Kimi takes Monday peak" "$(pick "$MON_PEAK")" "route:kimi-coding/kimi-for-coding"
prefenv "$root/bin/jg-owner-rules.sh" add --kind owner --words "no Kimi on Mondays from now on" --scope "all homes" \
  --point route-select --when "provider=kimi-coding weekday=1" --then skip --reason "owner: no Kimi on Mondays" >/dev/null 2>&1
is "one command, no code: the next pick skips Kimi on Monday" "$(pick "$MON_PEAK")" "route:cursor/auto"
is "the rule only bites where it applies (Sunday unchanged)" "$(pick "$SUN")" "route:ollama-cloud/deepseek-v4.1-flash"
is "his words are recorded beside the clause" "$(grep -c "^- Owner's words: \"no Kimi on Mondays from now on\"" "$home/data/owner-rules.md")" 1
bad=$(prefenv "$root/bin/jg-owner-rules.sh" add --kind owner --words "this rule names a fact nobody gathers" --scope x \
  --point route-select --when "colour=red" --then skip 2>&1; echo "rc=$?")
case $bad in *"not gathered"*"rc=2") ok=yes ;; *) ok=no ;; esac
is "a rule needing an ungathered fact is refused, nothing recorded" "$ok$(grep -c 'nobody gathers' "$home/data/owner-rules.md")" yes0

echo "# journey 2: change a preference block, behaviour follows"
prefenv "$root/bin/jg-pref.sh" reset rules >/dev/null  # drop the Monday rule so this journey sees the shipped clauses alone
prefenv "$root/bin/jg-pref.sh" set peak-hours.utcHours 18-22 >/dev/null
is "peak window moved: 14:00 is not peak now" "$(pick "$MON_PEAK")" "route:ollama-cloud/deepseek-v4.1-flash"
is "peak window moved: 20:00 is peak now" "$(pick "$MON_OFF")" "route:kimi-coding/kimi-for-coding"
rej=$(prefenv "$root/bin/jg-pref.sh" set peak-hours.utcHours noon 2>&1; echo "rc=$?")
case $rej in *"refused"*"rc=2") ok=yes ;; *) ok=no ;; esac
is "a value of the wrong kind is refused" "$ok" yes
prefenv "$root/bin/jg-pref.sh" reset peak-hours >/dev/null
is "reset restores the shipped window" "$(pick "$MON_PEAK")" "route:kimi-coding/kimi-for-coding"
# The regression guard: swap in a rules block without the DeepSeek clause and this journey must notice.
jq '.clauses |= map(select(.id != "no-deepseek-at-peak"))' "$root/defaults/preferences/rules.json" >"$w/rules-without.json"
prefenv "$root/bin/jg-pref.sh" swap rules "$w/rules-without.json" >/dev/null
is "enforcement removed: DeepSeek leads at peak (the check this test guards)" "$(pick "$MON_PEAK")" "route:ollama-cloud/deepseek-v4.1-flash"
prefenv "$root/bin/jg-pref.sh" reset rules >/dev/null
is "enforcement restored" "$(pick "$MON_PEAK")" "route:kimi-coding/kimi-for-coding"

echo "# journey 3: a rule that was code is a clause"
is "no per-rule branch left in the pool" "$(grep -c 'only // ""' "$pool")" 1
is "the only-for-hard fact is gathered once, not matched in the loop" "$(grep -c '= hard' "$pool")" 0
route_ids() { pick "$MON_OFF" "$1"; }
is "Sol skipped when the step is not hard (clause sol-hard-only)" "$(route_ids false)" "route:ollama-cloud/deepseek-v4.1-flash"
# Mark the first two routes attempted so Sol is the only candidate left.
sol=$(printf '%s' "{\"v\":1,\"purpose\":\"work\",\"pool_config\":\"$home/config/account-pool\",\"hard\":false,\"attempted\":[\"route:ollama-cloud/deepseek-v4.1-flash\",\"route:kimi-coding/kimi-for-coding\"]}" |
  env -i PATH=/usr/bin:/bin HOME="$w" TMPDIR="$w" JG_HOME="$home" JG_CLAUSE_NOW="$MON_OFF" JG_MODEL_GATE=/nonexistent JG_ROUTE_CHAIN_STATE="$home/state" \
    JG_CLAUDE_ACCOUNTS_REGISTRY="$w/none.json" "$pool" pick --json 2>/dev/null | jq -r '.id // "none"')
is "not hard: Sol skipped, Cursor takes it" "$sol" "route:cursor/auto"
sol=$(printf '%s' "{\"v\":1,\"purpose\":\"work\",\"pool_config\":\"$home/config/account-pool\",\"hard\":true,\"attempted\":[\"route:ollama-cloud/deepseek-v4.1-flash\",\"route:kimi-coding/kimi-for-coding\"]}" |
  env -i PATH=/usr/bin:/bin HOME="$w" TMPDIR="$w" JG_HOME="$home" JG_CLAUSE_NOW="$MON_OFF" JG_MODEL_GATE=/nonexistent JG_ROUTE_CHAIN_STATE="$home/state" \
    JG_CLAUDE_ACCOUNTS_REGISTRY="$w/none.json" "$pool" pick --json 2>/dev/null | jq -r '.id // "none"')
is "hard step: Sol is used" "$sol" "route:openai-codex/gpt-6.1-sol"
prefenv "$root/bin/jg-pref.sh" reset rules >/dev/null

echo "# journey 4: the same change reaches a squad_lead home through the existing push"
mkdir -p "$home/config/preferences"
prefenv "$root/bin/jg-pref.sh" set peak-hours.utcHours 9-11 >/dev/null
lead=$w/lead
mkdir -p "$lead/config"
# shellcheck source=bin/jg-config-inherit-lib.sh
. "$root/bin/jg-config-inherit-lib.sh"
propagate_inheritable_config "$home/config" "$lead/config" "$home" >/dev/null 2>&1
is "the block arrives in the lead home" "$(jq -r .values.utcHours "$lead/config/preferences/peak-hours.json" 2>/dev/null)" "9-11"
prefenv "$root/bin/jg-pref.sh" reset peak-hours >/dev/null
propagate_inheritable_config "$home/config" "$lead/config" "$home" >/dev/null 2>&1
is "resetting the primary mirrors absence downstream" "$([ -e "$lead/config/preferences/peak-hours.json" ] && echo present || echo absent)" absent
is "every shipped block is in the inherited set" "$(for b in "$root"/defaults/preferences/*.json; do n=${b##*/}; [ "$n" = schema.json ] && continue; case " $JG_INHERITABLE_CONFIG " in *" preferences/$n "*) ;; *) echo missing;; esac; done | wc -l | tr -d ' ')" 0
is "schema validates every block" "$("$root/bin/jg-clause.sh" validate >/dev/null 2>&1; echo $?)" 0

if [ "$fails" -eq 0 ]; then echo "PASS: clause journeys"; else echo "FAIL: $fails assertions"; exit 1; fi
