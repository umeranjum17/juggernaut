#!/usr/bin/env bash
# Journey: the owner asks for what is left and gets his own asks, in his words, grouped
# Needs you / Not done / Done (verified), from the main home and a Squad Lead home.
# A merged ask is Done only when the release record carries it and the release is live; a
# merged but unreleased ask is Not done with that as its one reason. No model is called.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(jg_test_tmproot jg-owner-asks)
MAIN="$TMP_ROOT/main"
LEAD="$TMP_ROOT/lead"
for h in "$MAIN" "$LEAD"; do
  mkdir -p "$h/data" "$h/state" "$h/config"
  jg_test_tasks_toml "$h/.tasks.toml"
done

cat > "$MAIN/data/backlog.md" <<'BL'
## In flight
- [ ] ask-hold - [captain-ask] Pick the colour (repo: demo) (kind: ship) (priority: 0) (hold: Red or blue for the badge?) (hold-kind: captain) (since 2026-11-01)
  Captain hold set: 2026-11-04
  Captain: "I want the badge to match my brand"
- [ ] ask-work - [captain-ask] Faster start (repo: demo) (kind: ship) (priority: 0) (since 2026-11-01)
  Make start-up faster
- [ ] ask-pr - [captain-ask] Show the cost (repo: demo) (kind: ship) (priority: 0) (since 2026-11-01) https://github.com/o/r/pull/31
  Show what each run costs

## Queued
- [ ] ask-wait - [captain-ask] Tell me when it ends (repo: demo) (kind: ship) (priority: 0) (since 2026-11-01)
  Captain: Tell me when it ends
- [ ] plain-hold - [feature] Rename the board (repo: demo) (kind: ship) (hold: Keep the old name?) (hold-kind: captain) (since 2026-11-02)
  Captain hold set: 2026-11-04
- [ ] work-item - [feature] An internal tidy-up (repo: demo) (kind: ship) (since 2026-11-02)

## Done
- [x] ask-live - [captain-ask] Fix the login (repo: demo) (kind: ship) (priority: 0) (merged 2026-11-02) https://github.com/o/r/pull/12
  Captain: Login must not log me out
- [x] ask-unreleased - [captain-ask] Dark mode (repo: demo) (kind: ship) (priority: 0) (merged 2026-11-04) https://github.com/o/r/pull/20
  Captain: Give me a dark mode
- [x] ask-noproof - [captain-ask] Old thing (repo: demo) (kind: ship) (priority: 0) (done 2026-11-03)
  Captain: Do the old thing
BL
cat > "$MAIN/data/releases" <<'REL'
# ref  prs
v1.2 prs=12
REL
printf '%s\n' "- lead1 - A lead (home: $LEAD; scope: demo; projects: demo; added 2026-11-01)" \
  "- far - A far lead (host: h; root: /r; home: /h; scope: x; projects: y; added 2026-11-01)" > "$MAIN/data/squad_leads.md"
cat > "$LEAD/data/backlog.md" <<'BL'
## In flight

## Queued
- [ ] lead-ask - [captain-ask] Lead ask (repo: demo) (kind: ship) (priority: 0) (since 2026-11-01)
  Captain: Do the lead thing

## Done
BL

# A stub that says the release is running; a second stub that says it is not.
printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/up.sh"; printf '#!/bin/sh\necho "api down"; exit 1\n' > "$TMP_ROOT/down.sh"
chmod +x "$TMP_ROOT/up.sh" "$TMP_ROOT/down.sh"

asks() {  # <services stub> [args]
  local stub=$1; shift
  JG_HOME="$MAIN" JG_STATE_OVERRIDE="$MAIN/state" JG_DATA_OVERRIDE="$MAIN/data" \
    JG_LIVE_SERVICES_BIN="$stub" "$ROOT/bin/jg-owner-asks.sh" "$@"
}

out=$(asks "$TMP_ROOT/up.sh") || fail "text form failed: $out"
section() { printf '%s\n' "$out" | awk -v h="$1" '$0 ~ "^" h { f = 1; next } f && /^$/ { exit } f { print }'; }

printf '%s\n' "$out" | grep -q '^Needs you (2)' || fail "needs you should hold the two open holds: $out"
section 'Needs you' | grep -q 'I want the badge to match my brand' || fail "the owner's quoted words are not the line: $out"
section 'Needs you' | grep -q 'Decision: Red or blue for the badge?' || fail "the decision is not in plain words: $out"
section 'Needs you' | grep -q 'Rename the board' || fail "a hold on a non-ask ticket is missing: $out"
pass "open holds are Needs you, in the owner's words, with the decision"

section 'Not done' | grep -q 'Make start-up faster' || fail "body prose should be the fallback words: $out"
section 'Not done' | grep -q 'Why: work is under way' || fail "an ask in progress has no reason: $out"
section 'Not done' | grep -q 'Why: PR is open: https://github.com/o/r/pull/31' || fail "an open PR is not the reason: $out"
section 'Not done' | grep -q 'Why: work has not started' || fail "a queued ask has no reason: $out"
section 'Not done' | grep -q 'Give me a dark mode' || fail "a merged unreleased ask must be Not done: $out"
section 'Not done' | grep -q 'Why: merged, not released' || fail "merged but unreleased must be the reason: $out"
section 'Not done' | grep -q 'Why: closed, but no proof is recorded' || fail "a closed ask with no proof must be Not done: $out"
section 'Not done' | grep -q 'Do the lead thing' || fail "the Squad Lead home was not read: $out"
printf '%s\n' "$out" | grep -q 'An internal tidy-up' && fail "a plain work item is not an owner ask: $out"
pass "unfinished asks are Not done with one reason; a Squad Lead home is read"

section 'Done' | grep -q 'Login must not log me out' || fail "a merged, released, running ask should be Done: $out"
section 'Done' | grep -q 'Proof: live in v1.2' || fail "the done line should carry its release: $out"
printf '%s\n' "$out" | grep -q 'Not read: far (a remote home is not read here)' || fail "the unread remote home is not named: $out"
printf '%s\n' "$out" | grep -qE 'ask-(hold|work|pr|wait|live)|lead-ask|plain-hold' && fail "a ticket id leaked into the owner text: $out"
pass "a released and running ask is Done (verified); an unread home is named; no ids leak"

# A release that is recorded but not running does not count as live.
down=$(asks "$TMP_ROOT/down.sh") || fail "text form failed with services down"
printf '%s\n' "$down" | awk '/^Done/ { f = 1; next } f && /^$/ { exit } f { print }' | grep -q 'Login must not' \
  && fail "an ask whose release is not running must not be Done: $down"
printf '%s\n' "$down" | grep -q 'Why: released, but the release is not running yet' || fail "the not-running reason is missing: $down"
pass "a recorded release that is not running keeps the ask Not done"

# The JSON form feeds the board.
json=$(asks "$TMP_ROOT/up.sh" --json) || fail "json form failed"
[ "$(jq -r '.counts | "\(.needs_you) \(.not_done) \(.done)"' <<<"$json")" = "2 6 1" ] || fail "json counts are wrong: $(jq -c .counts <<<"$json")"
[ "$(jq -r '.done[0].home + " " + .done[0].id' <<<"$json")" = "main ask-live" ] || fail "json done row is wrong: $json"
[ "$(jq -r '.not_read[0].home' <<<"$json")" = far ] || fail "json lacks the unread home"
pass "--json carries the same groups, ids and unread homes"

# The Done list is bounded, and says so.
short=$(JG_OWNER_ASKS_DONE=0 asks "$TMP_ROOT/up.sh") || fail "bounded form failed"
printf '%s\n' "$short" | grep -q 'Done, verified (0 of 1 shown)' || fail "the bound is not stated: $short"
pass "the Done list is bounded and states the total"

jg_test_cleanup 2>/dev/null || true
echo "jg-owner-asks: all passed"
