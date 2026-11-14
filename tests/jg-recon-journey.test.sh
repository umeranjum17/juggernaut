#!/usr/bin/env bash
# Journey test for the explicit Recon handoff (rank 5a): one deep Recon goes from its first draft to its cleanup through the real commands,
# in a throwaway home (nothing here touches a live fleet):
#   brief (bin/jg-brief.sh) -> submit the draft and assign the one separate critic (bin/jg-recon-handoff.sh) -> the critic's verdict with
#   gaps -> the researcher's revision -> the same critic's closing verdict -> the exact-hash depth gate (bin/jg-recon-gate.sh) -> the relay
#   move -> cleanup (core/lead-sweep/lead-sweep.sh, which runs the gate through the cleanup step).
# On the way: a restart (a new process with only JG_HOME) reads the same assignment, one assignment per report hash, a stale verdict and
# an old relay receipt cannot approve the new version, a steer delivered after the done line keeps the Recon, only a quiet hour (the sweep's
# own clock, advanced inside the throwaway home) lets cleanup run, and the report survives it.
# The relay move is the line Main's bin/jg-move.sh appends to data/moves.log, written here as the lead-sweep test writes it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RH="$ROOT/bin/jg-recon-handoff.sh"; GATE="$ROOT/bin/jg-recon-gate.sh"; SWEEP="$ROOT/core/lead-sweep/lead-sweep.sh"
T=$(jg_test_tmproot jg-recon-journey)
export HOME="$T/home"; mkdir -p "$HOME"
FM=$T/fm; ID=rj-1; CRITIC=rj-1-critic; D=$FM/data/$ID
mkdir -p "$FM/state" "$FM/data/$CRITIC" "$FM/bin" "$FM/core/machines"
cp "$ROOT/bin/jg-recon-handoff.sh" "$ROOT/bin/jg-machine-guard.sh" "$FM/bin/"
cp -r "$ROOT/core/machines/observers" "$ROOT/core/machines/tables" "$FM/core/machines/"
export JG_HOME=$FM JG_DATA_OVERRIDE=$FM/data JG_STATE_OVERRIDE=$FM/state
rh() { OUT=$(bash "$RH" "$@" 2>&1); RC=$?; }
sha() { sha256sum "$D/report.md" | cut -d' ' -f1; }
gate() { OUT=$(bash "$GATE" "$@" 2>&1); RC=$?; }

# The cleanup step the sweep runs: it refuses unless the real depth gate passes for the lane, so a cleaned Recon is a gate-PASS Recon.
cat > "$T/teardown" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/teardown.log"
out=\$(JG_HOME="$FM" JG_DATA_OVERRIDE="$FM/data" bash "$GATE" "\$1" 2>&1) || { echo "REFUSED: \$out" >&2; exit 1; }
rm -f "$FM/state/\$1.meta"
STUB
printf '#!/usr/bin/env bash\nprintf "control %%s\\n" "$*" >> "%s/teardown.log"\n' "$T" > "$T/control"
printf '#!/usr/bin/env bash\necho alive\n' > "$T/agent"
chmod +x "$T/teardown" "$T/control" "$T/agent"
export JG_LEAD_SWEEP_TEARDOWN=$T/teardown JG_LEAD_SWEEP_CONTROL=$T/control JG_LEAD_SWEEP_AGENT=$T/agent JG_LEAD_SWEEP_GH=/bin/false
cleaned() { grep -c "^$ID\$" "$T/teardown.log" 2>/dev/null || true; }
sweep() { OUT=$(env JG_LEAD_SWEEP_NOW="${1:-$(date +%s)}" bash "$SWEEP" run "$FM" 2>&1); }

# 1. A real deep Recon: the real scaffold, then the files the method writes. No critic.md yet.
bash "$ROOT/bin/jg-brief.sh" "$ID" some-proj --scout --depth deep >/dev/null 2>&1 || fail "jg-brief.sh should scaffold a deep Recon"
kinds=(code docs upstream oss community run)
: > "$D/sources.jsonl"
for n in $(seq 1 20); do printf '{"id":"S-%d","kind":"%s","title":"source %d","link":"x/%d","read":"2026-11-05"}\n' "$n" "${kinds[$((n % 5))]}" "$n" "$n" >> "$D/sources.jsonl"; done
printf '%s\n' '{"id":"C-1","text":"first claim","kind":"fact","sources":["S-1","S-2"],"load_bearing":true}' \
  '{"id":"C-2","text":"second claim","kind":"measure","sources":["S-4","S-5"],"load_bearing":true}' > "$D/claims.jsonl"
printf '%s\n' '{"claim":"C-1","status":"verified","method":"reread","note":"exact words"}' \
  '{"claim":"C-2","status":"verified","method":"run","note":"re-measured"}' > "$D/checks.jsonl"
{
  printf '# Report for %s\n\n' "$ID"; n=1
  for title in "Answer" "What was asked" "Method and depth record" "Prior art and options" "Findings" "Design" "Not checked" \
    "Implementation plan" "Risks and mitigations" "Open decisions" "Acceptance test" "Sources and evidence" "Revision log"; do
    printf '## %d. %s\n' "$n" "$title"
    if [ "$title" = "Not checked" ]; then printf 'Nothing load-bearing is left unchecked.\n\n'; else printf 'Body of %s, citing [C-1] and [C-2].\n\n' "$title"; fi
    n=$((n + 1))
  done
} > "$D/report.md"
printf 'kind=scout\nproject=%s/projects/some-proj\nbranch=fm/%s\nticket=t-%s\n' "$FM" "$ID" "$ID" > "$FM/state/$ID.meta"
printf 'working [at=1]: researching\n' > "$FM/state/$ID.status"
H1=$(sha)
gate "$ID"; expect_code 1 "$RC" "the gate refuses a deep report with no critic"
assert_contains "$OUT" "critic.md" "the refusal names the critic file"
pass "a real deep Recon exists and the gate refuses it until a critic has read it"

# 2. Submit the draft, then restart: a new process with only JG_HOME reads the same record.
echo "done [at=2]: report ready" >> "$FM/state/$ID.status"
rh draft "$ID"; expect_code 0 "$RC" "the draft is submitted"
assert_equals drafted "$(cd / && env -i PATH="$PATH" JG_HOME="$FM" bash "$RH" phase "$ID")" "a restart after the submit reads drafted"
sweep; assert_equals 0 "$(cleaned)" "a draft with no critic verdict is not cleaned up"
rh assign "$ID" --critic "$CRITIC"; expect_code 0 "$RC" "the one separate critic is assigned"
rh assign "$ID" --critic "$CRITIC"; expect_code 0 "$RC" "assigning again after a restart is a no-op"
assert_equals 1 "$(grep -c "$(printf '\tassign\t')" "$D/handoff.tsv")" "one assignment per report hash"
assert_equals "$(printf '%s\t1\t%s' "$CRITIC" "$H1")" "$(cd / && env -i PATH="$PATH" JG_HOME="$FM" bash "$RH" assignee "$ID")" "the next action survives a restart: the critic, generation 1, the hash"
pass "submit, restart and the one critic assignment drive through the real owner script"

# 3. A stale verdict and a verdict from another ticket close nothing; the critic's verdict with gaps moves the draft to critiqued.
rh verdict "$ID" --critic "$CRITIC" --hash "$(printf 'an older draft' | sha256sum | cut -d' ' -f1)" --gaps 0; expect_code 1 "$RC" "a stale verdict is refused"
rh verdict "$ID" --critic someone-else --hash "$H1" --gaps 0; expect_code 1 "$RC" "a verdict from another ticket is refused"
assert_equals assigned "$(bash "$RH" phase "$ID")" "neither closed the draft"
rh verdict "$ID" --critic "$CRITIC" --hash "$H1" --gaps 2; expect_code 0 "$RC" "the critic's verdict with gaps is recorded"
assert_equals critiqued "$(bash "$RH" phase "$ID")" "gaps leave the draft critiqued"
gate "$ID"; expect_code 1 "$RC" "the gate refuses a round with gaps and no closure"
# The relay of that first draft: a receipt for a draft that is not the accepted one.
printf '%s\tt-%s\tproving\trelayed\tproving\n' "$(date +%s)" "$ID" >> "$FM/data/moves.log"
sweep; assert_equals 0 "$(cleaned)" "a relay receipt for a critiqued draft does not clean the Recon up"
pass "stale and foreign verdicts close nothing; a verdict with gaps keeps the Recon"

# 4. The researcher revises; the same critic closes the new hash. The old verdict and the old relay receipt do not count.
printf 'Revision: closed the two gaps the critic named.\n' >> "$D/report.md"; H2=$(sha)
rh revise "$ID"; expect_code 0 "$RC" "the revision is recorded"
assert_equals none "$(bash "$RH" assignee "$ID")" "the revision retired the assignment"
rh verdict "$ID" --critic "$CRITIC" --hash "$H1" --gaps 0; expect_code 1 "$RC" "the verdict for the first draft cannot close the revision"
rh assign "$ID" --critic "$CRITIC"; expect_code 0 "$RC" "the same critic takes the revised draft"
assert_equals "$(printf '%s\t2\t%s' "$CRITIC" "$H2")" "$(bash "$RH" assignee "$ID")" "generation 2 holds the new hash"
sleep 1
rh verdict "$ID" --critic "$CRITIC" --hash "$H2" --gaps 0; expect_code 0 "$RC" "the same critic's closing verdict is recorded"
assert_equals accepted "$(bash "$RH" phase "$ID")" "the draft is accepted"
assert_equals "$(printf 'Critic: %s\nRound 1: new gaps 2 report %s\nRound 2: new gaps 0 report %s' "$CRITIC" "$H1" "$H2")" "$(cat "$D/critic.md")" "critic.md holds the gate's lines for both hashes"
gate "$ID"; expect_code 0 "$RC" "the exact-hash depth gate passes the accepted report (got: $OUT)"
assert_contains "$OUT" PASS "the gate says PASS"
gate "$CRITIC"; expect_code 0 "$RC" "the gate passes the critic ticket on the owner's lines (got: $OUT)"
sweep; assert_equals 0 "$(cleaned)" "the old relay receipt does not clean up the accepted revision"
pass "revision, same-critic closure and the exact-hash gate PASS drive through the real commands"

# 5. Relay after the verdict. A steer that reaches the inbox after the done line keeps the Recon until it is handled; then a quiet hour.
sleep 1; printf '%s\tt-%s\tproving\trelayed\tproving\n' "$(date +%s)" "$ID" >> "$FM/data/moves.log"
mkdir -p "$FM/state/$ID.inbox/handled"; echo "one more question" > "$FM/state/$ID.inbox/1.msg"
sweep "$(( $(date +%s) + 2 * 3600 ))"; assert_equals 0 "$(cleaned)" "a steer still waiting keeps the relayed Recon, even after a quiet hour"
mv "$FM/state/$ID.inbox/1.msg" "$FM/state/$ID.inbox/handled/"
sweep; assert_equals 0 "$(cleaned)" "a message handled just now restarts the quiet hour"
sweep "$(( $(date +%s) + 2 * 3600 ))"
assert_equals 1 "$(cleaned)" "the accepted, relayed Recon is cleaned up after the quiet hour, once"
assert_contains "$OUT" "$ID cleaned up" "the sweep says so"
sweep "$(( $(date +%s) + 3 * 3600 ))"; assert_equals 1 "$(cleaned)" "a later sweep does not clean it up again"
assert_equals "" "$(grep -c -- '--force' "$T/teardown.log" | grep -v '^0$')" "cleanup never forced anything"
[ -s "$D/report.md" ] && [ "$(sha)" = "$H2" ] || fail "the report did not survive the cleanup"
pass "relay, a pending steer, the quiet hour and cleanup run through the real sweep; the report survives"
