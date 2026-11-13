#!/usr/bin/env bash
# tests/jg-decision-group.test.sh - held decisions are grouped, not multiplied (core/decisions/group.sh, H52).
# Three lab holds with one question key make one card with two links, a hold with a new key makes a second
# card, holds are grouped by the ticket that raised them, new holds are counted per home per day, and no
# hold changes state. The holds are made by the real bin/jg-captain-hold.sh in a real Beads-backed home.
set -u
export JG_TASK_PRIORITY_CHECK=/nonexistent
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GROUP="$ROOT/core/decisions/group.sh"
HOLD="$ROOT/bin/jg-captain-hold.sh"
TMP_ROOT=$(jg_test_tmproot jg-decision-group)
home=$TMP_ROOT/home
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
jg_test_beads_home "$home"
: > "$home/config/backlog-intake-loose"
printf 'umer\n' > "$home/.jg-squad-lead-home"

env_run() {
  JG_HOME="$home" JG_CONFIG_OVERRIDE="$home/config" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" "$@"
}
add_hold() {  # <id> <raiser> <question key or empty>
  local body="Fixture decision $1"$'\n'"parent: $2"
  [ -z "$3" ] || body+=$'\n'"question-key: $3"
  jg_test_backlog "$home" add "$1" "[captain-ask] decision $1" --priority 0 --kind captain --repo demo --body "$body" >/dev/null 2>&1 \
    || fail "could not file $1"
  env_run "$HOLD" hold "$1" --reason "lab question" >/dev/null 2>&1 || fail "could not hold $1"
}

jg_test_add "$home" jg-r1 "[feature] raiser one"
jg_test_add "$home" jg-r2 "[feature] raiser two"
add_hold jg-q1 jg-r1 which-db
add_hold jg-q2 jg-r1 which-db
add_hold jg-q3 jg-r2 which-db
add_hold jg-q4 jg-r1 which-queue
add_hold jg-q5 jg-r2 ''

before=$(for i in 1 2 3 4 5; do jg_test_backlog "$home" show "jg-q$i" | grep -E '^  (state|held|hold_kind):'; done)
out=$(env_run "$GROUP" report) || fail "report failed: $out"
after=$(for i in 1 2 3 4 5; do jg_test_backlog "$home" show "jg-q$i" | grep -E '^  (state|held|hold_kind):'; done)

today=$(date -u +%F)
tab=$'\t'
want_cards="card${tab}which-db${tab}jg-q1${tab}jg-r1${tab}jg-q2,jg-q3"
printf '%s\n' "$out" | grep -qxF "$want_cards" || fail "three holds with one key are not one card with two links: $out"
printf '%s\n' "$out" | grep -qxF "card${tab}which-queue${tab}jg-q4${tab}jg-r1${tab}-" || fail "a new key is not a second card: $out"
printf '%s\n' "$out" | grep -qxF "card${tab}jg-q5${tab}jg-q5${tab}jg-r2${tab}-" || fail "a hold with no key is not its own card: $out"
[ "$(printf '%s\n' "$out" | grep -c '^card')" = 3 ] || fail "expected three cards: $out"
printf '%s\n' "$out" | grep -qxF "ticket${tab}jg-r1${tab}2${tab}3" || fail "grouping by raising ticket jg-r1 is wrong: $out"
printf '%s\n' "$out" | grep -qxF "ticket${tab}jg-r2${tab}2${tab}2" || fail "grouping by raising ticket jg-r2 is wrong: $out"
printf '%s\n' "$out" | grep -qxF "day${tab}umer${tab}$today${tab}5" || fail "new decisions per home per day is wrong: $out"
[ -n "$before" ] && [ "$before" = "$after" ] || fail "a hold changed state while grouping"
printf '%s\n' "$before" | grep -c 'held: yes' | grep -qx 5 || fail "not every hold is still held"
env_run "$GROUP" nonsense >/dev/null 2>&1 && fail "an unknown command must exit non-zero"

printf 'five fixture holds: jg-q1, jg-q2, jg-q3 share the question key which-db; jg-q4 has which-queue; jg-q5 has none\n'
printf 'group.sh report (cards: key, primary, raised by, links; by-ticket: raised by, cards, holds; per-day: home, day, new):\n%s\n' "$out"
printf 'all five holds still held, none changed: %s\n' "$(printf '%s\n' "$after" | grep -c 'held: yes')"
echo "PASS: jg-decision-group"
