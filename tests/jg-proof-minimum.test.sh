#!/usr/bin/env bash
# J27: "bare-minimum checks" is a field on the ticket, not a sentence in a brief. Real bin/jg-brief.sh, bin/jg-proof-minimum.sh
# and bin/jg-backlog.sh over a fixture home with a real Beads store; only done-done is a recording stand-in.
#
# M1 a brief with the old sentence and no field is refused, and the refusal holds the new form
# M2 --proof minimum writes the field on the ticket and the brief carries the section that hands the list to done-done
# M3 the proving step (verify) hands exactly the named checks and who named them to `done-done verify --journeys`
# M4 a ticket with no field is not proved by verify; a worker session cannot set the field; a bypass is not a brief flag
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(jg_test_tmproot jg-proof-minimum)
H="$TMP_ROOT/home"
jg_test_beads_home "$H"
: > "$H/config/backlog-intake-loose"
: > "$H/config/delivery-risk-loose"
bl() { jg_test_backlog "$H" "$@"; }
tkt=$(bl add --mint "Small change with a named proof" --repo sample --body why --json | jq -r .task.id) || fail "file the ticket"
task=${tkt//./-}
text="$TMP_ROOT/task.txt"
printf 'Fix the label. Run bare-minimum checks only.\n' > "$text"
brief() { JG_HOME="$H" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-brief.sh" "$task" proj --mode direct-PR --ticket "$tkt" --migration-row none "$@" 2>&1; }
field() { BEADS_DIR=$(cat "$H/config/beads-dir") "$ROOT/bin/jg-beads.sh" show "$tkt" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end).metadata.$1 // \"none\""; }

# M1
out=$(brief --task-text-file "$text"); rc=$?
expect_code 1 "$rc" "M1 the old sentence with no field should be refused: $out"
assert_contains "$out" "--proof minimum --proof-checks" "M1 the refusal must hold the new form"
assert_contains "$out" "bin/jg-proof-minimum.sh set" "M1 the refusal must name the lead's command"
[ ! -e "$H/data/$task/brief.md" ] || fail "M1 a refused scaffold wrote a brief"
[ "$(field proof)" = none ] || fail "M1 a refused scaffold wrote the field"
printf 'ok - M1 old sentence, no field: refused with the new form\n'

# M2
out=$(brief --task-text-file "$text" --proof minimum --proof-checks takeone-journey --proof-named-by lead-umer); rc=$?
expect_code 0 "$rc" "M2 the field and the old sentence together should scaffold: $out"
[ "$(field proof)" = minimum ] && [ "$(field proof_checks)" = takeone-journey ] && [ "$(field proof_named_by)" = lead-umer ] \
  || fail "M2 the ticket must hold the three fields"
grep -q '^# Proof: minimum' "$H/data/$task/brief.md" || fail "M2 the brief must carry the proof section"
# shellcheck disable=SC2016
grep -q 'lead-umer named these checks: `takeone-journey`' "$H/data/$task/brief.md" || fail "M2 the section must name the checks and who named them"
printf 'ok - M2 --proof minimum writes the field and the brief hands the list on\n'

# M3: the real verify step over a recording done-done.
cat > "$TMP_ROOT/done-done" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DD_LOG"
EOS
chmod +x "$TMP_ROOT/done-done"
DD_LOG="$TMP_ROOT/dd.log" JG_DONE_DONE_BIN="$TMP_ROOT/done-done" JG_HOME="$H" JG_CONFIG_OVERRIDE="$H/config" \
  "$ROOT/bin/jg-proof-minimum.sh" verify "$tkt" --outcome "a user can read the label" || fail "M3 verify failed"
[ "$(cat "$TMP_ROOT/dd.log")" = "verify --journeys takeone-journey --named-by lead-umer --outcome a user can read the label" ] \
  || fail "M3 done-done got: $(cat "$TMP_ROOT/dd.log")"
printf 'ok - M3 verify runs only the named checks, with who named them\n'

# M4
tkt2=$(bl add --mint "Plain ticket" --repo sample --body why --json | jq -r .task.id) || fail "file the second ticket"
out=$(JG_DONE_DONE_BIN="$TMP_ROOT/done-done" JG_HOME="$H" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-proof-minimum.sh" verify "$tkt2" --outcome x 2>&1); rc=$?
expect_code 1 "$rc" "M4 a ticket with no field must not take the minimum proof: $out"
out=$(JG_TASK_ID=some-worker JG_HOME="$H" JG_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/jg-proof-minimum.sh" set "$tkt2" --checks a 2>&1); rc=$?
expect_code 1 "$rc" "M4 a worker session must not set the field: $out"
out=$(brief --proof bypass); rc=$?
expect_code 1 "$rc" "M4 a bypass is never a brief flag: $out"
printf 'ok - M4 no field, no minimum proof; a worker cannot set it; bypass is not a flag\n'
