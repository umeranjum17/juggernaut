#!/usr/bin/env bash
# Live-only migration progress (bin/jg-progress-claim.sh, the turn-end rule in bin/jg-turnend-guard.sh
# "Migration progress rule", and the card and digest lines built from bin/jg-critical-path.sh).
# Only the probe (JG_MIGRATION_LIVE_BIN) and the board tools (gh, sign-off-axi) are stand-ins.
#
# T1 a message that calls a part live while the probe says pending is refused once, and the block names it.
# T2 the same words pass once that part is live; so do "merged, not live", "working on" and a home with no critical=.
# T3 a merged switch is a milestone only when its row is live, and the outcome leads with the Live line.
# T4 the digest's Released now line carries the migration count.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-progress-claim)
H="$TMP_ROOT/home"
mkdir -p "$H/state" "$H/config" "$TMP_ROOT/bin" "$TMP_ROOT/board"
cp -R "$ROOT/bin" "$H/bin"
git init -q -b main "$H"
: > "$H/AGENTS.md"
jg_test_beads_home "$H"

cat > "$TMP_ROOT/probe" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --link ] || { echo "https://board.example/reports/card"; exit 0; }
[ "${1:-}" != --quiet ] || exit 0
st=$(awk -v s="$1" '$1 == s { print $2 }' "$JG_TEST_PROBE_STATE")
printf 'part %s\t%s\tmeasured %s is %s\thttps://github.com/example/repo/pull/90\n' "$1" "${st:-absent}" "$1" "${st:-absent}"
SH
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
echo '{"baseRefName":"release/c-7","title":"Per-home accounts switch live","additions":10,"deletions":20}'
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/bin/sign-off-axi"
chmod +x "$TMP_ROOT/probe" "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/sign-off-axi"
export JG_MIGRATION_LIVE_BIN="$TMP_ROOT/probe" JG_TEST_PROBE_STATE="$TMP_ROOT/probe.state"
export JG_HOME="$H" JG_ROOT_OVERRIDE="$H" JG_STATE_OVERRIDE="$H/state" PATH="$TMP_ROOT/bin:$PATH"
probe() { printf '%s\n' "$@" > "$JG_TEST_PROBE_STATE"; }
probe 'nats live' 'accounts pending'

stop() {  # <message> -> the guard's exit status, its banner in $TMP_ROOT/err
  jq -cn --arg m "$1" '{session_id: "s", last_assistant_message: $m}' | bash "$H/bin/jg-turnend-guard.sh" >/dev/null 2>"$TMP_ROOT/err"
}
CLAIM="The accounts switch is live. The queue is done."

# T2 (first, since it needs no critical=): a home that does not configure this is unchanged.
stop "$CLAIM"; expect_code 0 "$?" "T2 a home with no critical= was refused"

printf 'critical=nats,accounts\nproject=proj\nbranch=release/c-7\ntarget=1000\nboard=%s/board/board.json\ncard=card\n' "$TMP_ROOT" > "$H/config/migration-card"
: > "$TMP_ROOT/board/board.json"

# T1
stop "$CLAIM"; expect_code 2 "$?" "T1 a part called live while pending ended the turn"
for want in 'MIGRATION PROGRESS CLAIM WITH NO LIVE ROW' 'accounts' 'measured accounts is pending'; do
  assert_contains "$(cat "$TMP_ROOT/err")" "$want" "T1 the block does not name '$want'"
done
stop "$CLAIM"; expect_code 0 "$?" "T1 the same message was charged twice"
pass "T1 an unsupported live claim is refused once, naming the part and what the probe measured"

# T2
stop "The accounts part is merged, not live. We are working on accounts now."; expect_code 0 "$?" "T2 an honest message was refused"
stop "NATS is live, as the probe shows."; expect_code 0 "$?" "T2 a claim about a live part was refused"
probe 'nats live' 'accounts live'
stop "The accounts switch is live again, and it is running."; expect_code 0 "$?" "T2 a live part was refused"
pass "T2 merged-not-live wording, effort wording and live parts pass"

# T3
probe 'nats live' 'accounts pending'
"$H/bin/jg-migration-card.sh" merge https://github.com/o/r/pull/1 >/dev/null || fail "T3 the merge path failed"
out=$(cat "$H/state/branch-outcomes.jsonl")
assert_contains "$out" "merged; accounts still pending" "T3 a pending switch was recorded as live"
assert_contains "$out" "In use: 1 of 2 critical rows (nats)." "T3 the outcome does not lead with the live count"
assert_contains "$out" "Merged, not a live measure" "T3 merged lines are not labelled as merged"
pass "T3 a merged switch whose row is pending is recorded as merged, behind the Live line"

# T4
printf '%s\n' "$TMP_ROOT/board/board.json" > "$H/config/fleet-board"
out=$(bash "$H/bin/jg-status-digest.sh" "$H" record "the accounts switch merged" --left "1 part" --blockers none 2>&1)
assert_contains "$out" "migration: 1 of 2 critical rows In use; first pending accounts" "T4 the digest does not carry the migration count"
pass "T4 the digest's Released now line carries the live count"
echo "all jg-progress-claim tests passed"
