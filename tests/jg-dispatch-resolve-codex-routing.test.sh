#!/usr/bin/env bash
# Fast eval of the Codex-credit routing in bin/jg-dispatch-resolve.sh.
#
# One case per difficulty tier, all offline: a fake quota-axi and a fake curl
# stand in for the network, so each case resolves end to end in well under a
# second and no model is called.
#
# The tier map below mirrors the captain's live routing (the local, gitignored
# config/crew-dispatch.json): hard and architecture work -> Sol, medium and
# design-heavy work -> Luna, easy/mechanical work -> DeepSeek, and every
# premium candidate carries a 15% remaining floor so a near-empty window makes
# that candidate ineligible and the resolver steps down to the tier's next
# route. No route names an Opus model.
#
# The four cases are the ones the routing change had to move:
#   hard -> Sol, medium design -> Luna, easy -> DeepSeek, and a hard task whose
#   first route is nearly empty -> the tier's next route.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RESOLVE="$ROOT/bin/jg-dispatch-resolve.sh"
TMP_ROOT=$(jg_test_tmproot jg-dispatch-resolve-codex-routing)
trap jg_test_cleanup EXIT

HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
HEADROOM="$TMP_ROOT/quota-headroom.json"
NEAR_EMPTY="$TMP_ROOT/quota-codex-near-empty.json"
BRIEF="$TMP_ROOT/brief.md"
mkdir -p "$HOME_DIR/config" "$FAKEBIN"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$JG_TEST_QUOTA_FIXTURE"
SH

# Answers the rule Choice named by FAKE_PICK, listing every option so the
# resolver's key and sum checks pass and the answer clears the 0.6 floor.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
  -o) out=${2-}; shift 2 ;;
  *) shift ;;
  esac
done
cat >/dev/null 2>&1 || true
[ -n "$out" ] || exit 0
jq -n --arg choice "${FAKE_PICK:-rule_1}" --argjson n "${FAKE_RULES:-1}" '
  (["default"] + [range(1; $n + 1) | "rule_\(.)"]) as $keys |
  ($keys | length) as $count |
  {model: "jev-fake",
   answers: {rule: {choice: $choice, confidence: 0.9,
     probabilities: ($keys | map({key: ., value: (if . == $choice then 0.9 else (0.1 / ($count - 1)) end)}) | from_entries)}},
   usage: {input_tokens: 11, output_tokens: 7}}' >"$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl" "$FAKEBIN/quota-axi"

# One schema-5 snapshot with every lane measured and healthy, so each case
# shows the routing the tiers declare rather than whatever one account happens
# to be running dry today. Codex 55%, Claude 45%, DeepSeek 80%.
cat > "$HEADROOM" <<'JSON'
{"schemaVersion": 5, "providers": [
  {"provider": "claude", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 45,
     "selection": {"status": "known", "spendPriority": 0.35},
     "runway": {"status": "projected_exhaustion"}}]}},
  {"provider": "codex", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 55,
     "selection": {"status": "known", "spendPriority": 0.62},
     "runway": {"status": "projected_exhaustion"}}]}},
  {"provider": "ollama-cloud", "quotaSemantics": {"status": "known", "effectiveAvailability": [
    {"scope": "all_models", "status": "known", "effectivePercentRemaining": 80,
     "selection": {"status": "known", "spendPriority": 0.90},
     "runway": {"status": "projected_exhaustion"}}]}}
]}
JSON

# The same snapshot with the Codex window nearly empty: 8% left is above zero,
# so only the tier's 15% floor can step the hard route down.
sed 's/"effectivePercentRemaining": 55/"effectivePercentRemaining": 8/; s/"spendPriority": 0.62/"spendPriority": -1.20/' \
  "$HEADROOM" > "$NEAR_EMPTY"

cat > "$BRIEF" <<'EOF'
# Task
## Captain's intent
One bounded change, routed by difficulty.
## Juggernaut spec
1. Do the work.
EOF

# The live tier map and rule-to-tier routing, in the live rule order, so
# rule_2 (architecture) is hard, rule_3 (tough design) is standard, rule_5
# (genuinely hard backend) is hard, and rule_7 (mechanical) is easy.
cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "tiers": {
    "easy": [
      { "harness": "pi", "model": "ollama-cloud/deepseek-v4.1-flash", "provider": "ollama-cloud" },
      { "harness": "claude", "model": "claude-haiku-5-5", "effort": "medium",
        "floor": { "scope": "all_models", "min_percent": 15 } }
    ],
    "standard": [
      { "harness": "pi", "model": "openai-codex/gpt-6-luna", "provider": "codex", "effort": "medium",
        "floor": { "scope": "all_models", "min_percent": 15 } },
      { "harness": "claude", "model": "claude-sonnet-5-5", "effort": "medium",
        "floor": { "scope": "all_models", "min_percent": 15 } }
    ],
    "hard": [
      { "harness": "pi", "model": "openai-codex/gpt-6.1-sol", "provider": "codex", "effort": "high",
        "floor": { "scope": "all_models", "min_percent": 15 } },
      { "harness": "claude", "model": "claude-sonnet-5-5", "effort": "high",
        "floor": { "scope": "all_models", "min_percent": 15 } }
    ],
    "frontier": [
      { "harness": "pi", "model": "openai-codex/gpt-6.1-sol", "provider": "codex", "effort": "high",
        "floor": { "scope": "all_models", "min_percent": 15 } },
      { "harness": "claude", "model": "claude-sonnet-5-5", "effort": "xhigh",
        "floor": { "scope": "all_models", "min_percent": 15 } }
    ]
  },
  "rules": [
    { "when": "Ordinary work on the fleet tools.", "tier": "standard" },
    { "when": "Architecture work.", "tier": "hard" },
    { "when": "Tough work and design-heavy frontend.", "tier": "standard" },
    { "when": "Ordinary frontend implementation.", "tier": "standard" },
    { "when": "Genuinely hard backend work.", "tier": "hard" },
    { "when": "Ordinary backend work.", "tier": "standard" },
    { "when": "Supporting and mechanical work.", "tier": "easy" }
  ],
  "default": [
    { "harness": "pi", "model": "ollama-cloud/deepseek-v4.1-flash", "provider": "ollama-cloud" },
    { "harness": "pi", "model": "openai-codex/gpt-6-luna", "provider": "codex", "effort": "medium",
      "floor": { "scope": "all_models", "min_percent": 15 } },
    { "harness": "claude", "model": "claude-sonnet-5-5", "effort": "medium",
      "floor": { "scope": "all_models", "min_percent": 15 } }
  ]
}
JSON

resolve() {  # <picked-rule> <quota-fixture>; the resolver's block, or its stderr
  TYPESAFE_API_KEY=test-key JG_HOME="$HOME_DIR" JG_TEST_QUOTA_FIXTURE="$2" \
    FAKE_PICK="$1" FAKE_RULES=7 PATH="$FAKEBIN:$PATH" \
    "$RESOLVE" "$BRIEF" 2>&1
}

profile_line() { printf '%s\n' "$1" | grep -F '  profile: ' || :; }

# Hard and architecture work resolves to Sol, never to Opus.
test_hard_routes_to_sol() {
  local out
  out=$(resolve rule_2 "$HEADROOM") || fail "hard: the resolver refused to run: $out"
  assert_contains "$out" "status: clear" "hard: the resolver did not resolve the tier"
  assert_contains "$out" "  tier: hard" "hard: the block does not name the hard tier"
  assert_contains "$(profile_line "$out")" "--model 'openai-codex/gpt-6.1-sol'" \
    "hard: the route is not Sol"
  assert_contains "$(profile_line "$out")" "--effort 'high'" "hard: Sol did not resolve at high effort"
  assert_not_contains "$out" "claude-opus" "hard: a route named an Opus model"
  pass "hard and architecture work resolves to Sol high under headroom"
}

# Medium and design-heavy work resolves to Luna, and Luna is reached before
# Sonnet because it is the cheaper Codex lane.
test_medium_design_routes_to_luna() {
  local out
  out=$(resolve rule_3 "$HEADROOM") || fail "design: the resolver refused to run: $out"
  assert_contains "$out" "status: clear" "design: the resolver did not resolve the tier"
  assert_contains "$out" "  tier: standard" "design: the block does not name the standard tier"
  assert_contains "$(profile_line "$out")" "--model 'openai-codex/gpt-6-luna'" \
    "design: the route is not Luna"
  assert_contains "$(profile_line "$out")" "--effort 'medium'" \
    "design: Luna did not resolve at medium effort"
  assert_not_contains "$out" "claude-opus" "design: a route named an Opus model"
  pass "medium and design-heavy work resolves to Luna medium"
}

# Easy and mechanical work stays on DeepSeek.
test_easy_routes_to_deepseek() {
  local out line
  out=$(resolve rule_7 "$HEADROOM") || fail "easy: the resolver refused to run: $out"
  line=$(profile_line "$out")
  assert_contains "$out" "status: clear" "easy: the resolver did not resolve the tier"
  assert_contains "$out" "  tier: easy" "easy: the block does not name the easy tier"
  assert_contains "$line" "--model 'ollama-cloud/deepseek-v4.1-flash'" \
    "easy: the route is not DeepSeek"
  assert_not_contains "$line" "--effort" "easy: DeepSeek took an effort flag it does not declare"
  assert_not_contains "$out" "claude-opus" "easy: a route named an Opus model"
  pass "easy and mechanical work stays on DeepSeek"
}

# A first route that is nearly empty steps down to the tier's next route
# instead of routing into a window that is about to run dry.
test_nearly_empty_first_route_steps_down() {
  local out
  out=$(resolve rule_5 "$NEAR_EMPTY") || fail "near-empty: the resolver refused to run: $out"
  assert_contains "$out" "status: clear" "near-empty: the resolver did not step down to the next route"
  assert_contains "$out" "not eligible: profile floor all_models below 15%" \
    "near-empty: the nearly empty Codex route was not excluded by its floor"
  assert_contains "$(profile_line "$out")" "--model 'claude-sonnet-5-5'" \
    "near-empty: the resolver did not step down to the tier's next route"
  assert_not_contains "$out" "claude-opus" "near-empty: a route named an Opus model"
  pass "a nearly empty first route steps down to the tier's next route"
}

test_hard_routes_to_sol
test_medium_design_routes_to_luna
test_easy_routes_to_deepseek
test_nearly_empty_first_route_steps_down
