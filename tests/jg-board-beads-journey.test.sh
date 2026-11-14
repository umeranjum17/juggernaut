#!/usr/bin/env bash
# The board over the Beads ticket adapter (plan section 11 acceptance journey), on a throwaway store: the sign-off board, started with
# SIGN_OFF_TICKETS_ADAPTER set to bin/jg-ticket-adapter.py, lists the same open tickets as bd, shows id, title, status, assignee and parent as bd
# shows them, adds no board-only key or invented stage, and leaves a closed ticket out. Screenshots at 390 and 1280 px.
# JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT name the pinned builds; JG_SIGN_OFF_DIR names a built sign-off checkout (npm run build); each skips without.
# JG_BOARD_JOURNEY_OUT keeps the evidence there; JG_BOARD_JOURNEY_CELLS (default light:390,light:1280) picks the theme:width runs.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for v in JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT JG_SIGN_OFF_DIR; do
  [ -n "${!v:-}" ] || { printf 'skip: board journey: %s is unset\n' "$v"; exit 0; }
done
[ -f "$JG_SIGN_OFF_DIR/dist/cli.js" ] || { printf 'skip: board journey: %s has no dist/cli.js (run npm run build)\n' "$JG_SIGN_OFF_DIR"; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'skip: board journey: node is not installed\n'; exit 0; }

WRAPPER="$ROOT/bin/jg-beads.sh" ADAPTER="$ROOT/bin/jg-ticket-adapter.py" JOURNEY="$ROOT/tests/fixtures/board-beads/journey.mjs" T=$(jg_test_tmproot jg-board-beads)
OUT=${JG_BOARD_JOURNEY_OUT:-${DONE_DONE_EVIDENCE_ROOT:-$T/evidence}}
mkdir -p "$T/store" "$OUT"
unset BEADS_DB BEADS_DOLT_SHARED_SERVER JG_BEADS_SH
export BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
"$WRAPPER" init --prefix jt >"$T/init.log" 2>&1 || fail "init: $(cat "$T/init.log")"
bd_() { "$WRAPPER" "$@" 2>/dev/null; }

# A throwaway store: an epic, a child under it, a ticket in progress with an assignee, and one closed ticket.
epic=$(bd_ q "Epic parent"); child=$(bd_ q "Open one"); work=$(bd_ q "Working two"); gone=$(bd_ q "Closed three")
bd_ update "$child" --parent "$epic" >/dev/null; bd_ update "$work" --status in_progress --assignee Umer >/dev/null; bd_ close "$gone" >/dev/null

# What bd itself lists is the expectation.
bd_ list --json | python3 -c '
import json, sys
rows = json.load(sys.stdin)
json.dump({"open": [{k: r.get(k) for k in ("id", "title", "status", "assignee", "parent")} for r in rows], "closed": [sys.argv[1]], "closedTitles": ["Closed three"]}, open(sys.argv[2], "w"))' "$gone" "$T/expected.json" || fail "bd list"
[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["open"]))' "$T/expected.json")" = 3 ] || fail "bd lists three open tickets: $(cat "$T/expected.json")"
cp "$T/expected.json" "$OUT/bd-open.json"

IFS=, read -ra cells <<<"${JG_BOARD_JOURNEY_CELLS:-light:390,light:1280}"
for cell in "${cells[@]}"; do
  node "$JOURNEY" "$JG_SIGN_OFF_DIR" "$ADAPTER" "$T/expected.json" "$OUT" "${cell%%:*}" "${cell##*:}" >"$T/run.log" 2>&1 || fail "board journey $cell: $(cat "$T/run.log")"
  cat "$T/run.log"
done
for cell in "${cells[@]}"; do [ -s "$OUT/list.${cell%%:*}.${cell##*:}.png" ] || fail "no list capture for $cell"; done
pass "the board lists bd's open tickets as bd shows them and leaves the closed one out"
