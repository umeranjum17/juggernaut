#!/usr/bin/env bash
# Behavior tests for the trunk line machine table (core/machines/tables/trunk.tsv, observer core/machines/observers/trunk.sh).
# Every record is generated here in the shape bin/jg-trunk.sh writes it; no fleet record is copied. The table is report-only:
# a fixture record in every state prints the right word, the table lints, and a legal move adds no line to the shadow log.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-trunk)
unset JG_MACHINES_TABLES JG_MACHINES_ENUMS JG_MACHINES_MAPS JG_ROOT_OVERRIDE
export JG_HOME="$T/home"; S=$JG_HOME/state; D=$JG_HOME/data; export JG_STATE_OVERRIDE=$S JG_DATA_OVERRIDE=$D
mkdir -p "$S" "$D"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }

jm check trunk; expect_code 0 "$RC" "the trunk table lints"; assert_equals "ok trunk: 4 states, 6 edges" "$OUT" "lint golden"
jm enum trunk; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" "4 values" "the enum holds four values"
jm coverage trunk; expect_code 0 "$RC" "every edge names its test"
assert_equals "clean unverified verifying red" "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/trunk.tsv" | sed 's/ $//')" "the four states"
[ ! -e "$ROOT/core/machines/tables/trunk-pointers.tsv" ] || fail "trunk-pointers.tsv must be gone: the trunk table replaces it"
pass "the trunk table lints with 4 states and 6 moves, each with a test, and trunk-pointers is gone"

# A project clone with three commits: base (the pin), one (above the pin), and a revert of one.
G=$JG_HOME/projects/p; git init -q -b main "$G"
gc() { git -C "$G" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "$1"; git -C "$G" rev-parse HEAD; }
BASE=$(gc base); ONE=$(gc one)
seed() {  # <project> <tip> <green>: the two pointer files, and no verify lock, no red row
  printf '%s' "$2" > "$S/trunk-tip-$1"; printf '%s' "$3" > "$S/trunk-green-$1"; rm -rf "$S/.trunk-verify-$1.lock"; : > "$D/trunk-ci.tsv"
}
word() { jm show trunk "$1"; if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'; else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi; }
: > "$T/states.corpus"
chk() { local w; w=$(word "$1"); echo "show trunk $1 -> $w"; assert_equals "$2" "$w" "$3"; printf '%s\n' "$w" >> "$T/states.corpus"; }

# The project is named p, so the clone above is its repository.
seed p "$BASE" "$BASE"; chk p clean "tip is the green pin"
seed p "$ONE" "$BASE"; chk p unverified "tip is above the pin and no verify runs"
mkdir -p "$S/.trunk-verify-p.lock"; sleep 30 & SLEEPER=$!; printf '%s' "$SLEEPER" > "$S/.trunk-verify-p.lock/pid"
chk p verifying "the verify lock is held by a live process"
printf '99999999' > "$S/.trunk-verify-p.lock/pid"; chk p unverified "a lock whose process is gone is no verify"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
tab p "$ONE" "$(date +%s)" red verify > "$D/trunk-ci.tsv"; chk p red "a charged red on a commit above the pin"
printf '%s' "$ONE" > "$S/trunk-green-p"; chk p clean "the pin and the tip agree, whatever the rows say"
printf '%s' "$BASE" > "$S/trunk-green-p"; REV=$(git -C "$G" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "revert one" -m "reverts: $ONE"; git -C "$G" rev-parse HEAD)
printf '%s' "$REV" > "$S/trunk-tip-p"; chk p unverified "a red that a later commit reverts no longer holds the line red"
seed q "$ONE" "$BASE"; tab p "$BASE" 1 red ci > "$D/trunk-ci.tsv"; chk q unverified "a red of another project is not this line's"
rm -f "$S/trunk-tip-p"; assert_equals "" "$(word p)" "a project with no tip record has no state"; jm show trunk p; expect_code 1 "$RC" "no state is a finding"
for st in clean unverified verifying red; do grep -qx "$st" "$T/states.corpus" || fail "no fixture is in state $st"; done
jm check trunk --corpus "$T/states.corpus"; expect_code 0 "$RC" "every word a fixture printed is a state"
pass "a fixture record in every state prints the right word"

# Moves: the six legal moves replay clean, and a move that skips the verify is a finding.
{ tab clean land unverified; tab unverified verify verifying; tab verifying pass clean; tab verifying pass-behind unverified
  tab verifying fail red; tab red revert unverified; } > "$T/moves.corpus"
jm check trunk --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab unverified pass clean > "$T/bad.corpus"; jm check trunk --corpus "$T/bad.corpus"; expect_code 1 "$RC" "a pass with no verify"
assert_contains "$OUT" "unverified pass clean is not a move" "check names the move"
pass "check replays the six legal moves and refuses a pass that skips the verify"

# The shadow log: a legal move adds no line, an illegal one adds exactly one, and the writer carries on.
LOG=$D/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" trunk "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
seed p "$ONE" "$BASE"
assert_equals 0 "$(shadow p verifying)" "unverified -> verifying is legal"
assert_equals 1 "$(shadow p clean)" "unverified -> clean skips the verify and is illegal"
assert_contains "$(tail -n 1 "$LOG")" trunk "the shadow line names the machine"
pass "a legal move adds no shadow line, an illegal move adds one"
