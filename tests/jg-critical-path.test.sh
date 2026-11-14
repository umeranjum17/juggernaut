#!/usr/bin/env bash
# The migration's critical path gate: bin/jg-critical-path.sh over briefs scaffolded by the real
# bin/jg-brief.sh. Only the probe (JG_MIGRATION_LIVE_BIN) is a stand-in.
#
# T1 a row past the first pending part is refused with its measurement, pull request and card link.
# T2 the first part not live, and Migration row none, are admitted.   T3 no Migration row line is refused.
# T4 an override is admitted only when the brief quotes the same words.
# T5 the refusal follows the first part not live and lifts when every part is live.
# T6 other projects, unconfigured homes and scouts are unchanged; an unreadable probe is pending.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CP="$ROOT/bin/jg-critical-path.sh"
TMP_ROOT=$(jg_test_tmproot jg-critical-path-tests)
W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
mkdir -p "$PROJ"
jg_test_spawn_home "$HOME_DIR"

cat > "$W/probe" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --link ] || { echo "https://board.example/reports/card-live"; exit 0; }
[ -r "${JG_TEST_PROBE_STATE:-}" ] || exit 3
st=$(awk -v s="$1" '$1 == s { print $2 }' "$JG_TEST_PROBE_STATE")
printf 'part %s\t%s\tmeasured %s is %s\thttps://github.com/example/repo/pull/90\n' "$1" "${st:-absent}" "$1" "${st:-absent}"
SH
chmod +x "$W/probe"
export JG_MIGRATION_LIVE_BIN="$W/probe" JG_TEST_PROBE_STATE="$W/probe.state" JG_HOME="$HOME_DIR"
probe_state() { printf '%s\n' "$@" > "$JG_TEST_PROBE_STATE"; }
probe_state 'nats live' 'accounts pending'
printf 'critical=nats,accounts,wake,inbox\nproject=proj\n' > "$HOME_DIR/config/migration-card"

N=0
# brief <brief-args...>: scaffold a real ship brief; sets BRIEF to its path.
brief() {
  N=$((N + 1))
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "cp$N" proj --mode direct-PR "$@" >/dev/null 2>&1 || return 1
  BRIEF="$HOME_DIR/data/cp$N/brief.md"
}
gate() { "$CP" gate "$BRIEF" "$PROJ" "$@" 2>&1; }

# T1
brief --migration-row deletions || fail "T1 could not scaffold"
out=$(gate); rc=$?
expect_code 1 "$rc" "T1 a row past the first pending part should be refused: $out"
assert_contains "$out" "first part not In use: accounts" "T1 the refusal does not name the first part not live"
assert_contains "$out" "measured accounts is pending" "T1 the refusal does not carry what the probe measured"
assert_contains "$out" "https://github.com/example/repo/pull/90" "T1 the refusal does not name the pull request"
pass "T1 a row past the first pending part is refused with the measurement and the pull request"

# T2
brief --migration-row accounts || fail "T2 could not scaffold"
out=$(gate); expect_code 0 "$?" "T2 work on the first part not live should be admitted: $out"
brief --migration-row none || fail "T2 could not scaffold"
out=$(gate); expect_code 0 "$?" "T2 Migration row none should be admitted: $out"
pass "T2 the first part not live and Migration row none are admitted"

# T3
brief || fail "T3 could not scaffold"
! grep -q '^Migration row:' "$BRIEF" || fail "T3 the plain brief carries a Migration row line"
out=$(gate); rc=$?
expect_code 1 "$rc" "T3 a brief with no Migration row should be refused: $out"
assert_contains "$out" "no Migration row" "T3 the refusal does not say the line is missing"
pass "T3 a brief with no Migration row is refused"

# T4
WORDS="captain: run deletions now"
brief --migration-row deletions --off-critical-path "$WORDS" || fail "T4 could not scaffold"
out=$(gate "$WORDS"); expect_code 0 "$?" "T4 a quoted override should be admitted: $out"
out=$(gate); rc=$?
expect_code 1 "$rc" "T4 a brief override with no flag should be refused: $out"
brief --migration-row deletions || fail "T4 could not scaffold"
out=$(gate "$WORDS"); rc=$?
expect_code 1 "$rc" "T4 a flag the brief does not quote should be refused: $out"
assert_contains "$out" "Critical-path override" "T4 the refusal does not name the missing brief line"
pass "T4 an override is admitted only when the brief quotes the same words"

# T5
probe_state 'nats live' 'accounts live'
brief --migration-row deletions || fail "T5 could not scaffold"
out=$(gate); rc=$?
expect_code 1 "$rc" "T5 deletions should still be refused with accounts live: $out"
assert_contains "$out" "first part not In use: wake" "T5 the refusal does not name wake"
probe_state 'nats live' 'accounts live' 'wake live' 'inbox live'
out=$(gate); expect_code 0 "$?" "T5 with every critical part live nothing should be refused: $out"
pass "T5 the refusal follows the first part not live, and lifts when the path is live"

# T6
probe_state 'nats live' 'accounts pending'
assert_equals "$(printf 'nats\naccounts\nwake\ninbox')" "$("$CP" list)" "T6 list is not the configured order"
assert_equals "accounts" "$("$CP" first-pending)" "T6 first-pending is not accounts"
assert_equals "nats live accounts pending wake absent inbox absent" "$("$CP" rows | cut -f1,2 | tr '\t\n' '  ' | sed 's/ $//')" "T6 rows are not slug and state in order"
assert_equals "nats" "$(JG_MIGRATION_LIVE_BIN="$W/no-such-probe" "$CP" first-pending)" "T6 an unreadable probe was not taken as pending"
brief || fail "T6 could not scaffold"
out=$("$CP" gate "$BRIEF" "$W/other" 2>&1); expect_code 0 "$?" "T6 another project should not be held to the path: $out"
printf 'branch=release/c-6\n' > "$HOME_DIR/config/migration-card"
assert_equals "" "$("$CP" list)$("$CP" rows)$("$CP" first-pending)" "T6 a home with no critical= key printed something"
out=$(gate); expect_code 0 "$?" "T6 a home with no critical= key should be unchanged: $out"
printf 'critical=nats,accounts,wake,inbox\nproject=proj\n' > "$HOME_DIR/config/migration-card"
out=$(JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" cp-scout proj --scout --migration-row none 2>&1); rc=$?
expect_code 1 "$rc" "T6 a scout brief should refuse --migration-row: $out"
pass "T6 other projects, unconfigured homes and scouts are unchanged; an unreadable probe is pending"

echo "all jg-critical-path tests passed"
