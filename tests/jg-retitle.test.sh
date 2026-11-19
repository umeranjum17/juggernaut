#!/usr/bin/env bash
# Plain outcome names for tickets. `add` refuses a title that starts with a plan code (J20d-3, S18c, mf-m2) and names the fix;
# bin/jg-retitle.py `list` names the open rows whose title is not plain words, and `apply` renames them in one pass: a
# dry run writes nothing, a title that fails the rule stops the whole pass, the plan code and the earlier title move into the
# body, and a second pass changes nothing. Every call runs on a real embedded store with no network. JG_BEADS_TEST_BD and
# JG_BEADS_TEST_DOLT name the pinned builds, which skip without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" CLI="$ROOT/bin/jg-backlog.sh" T=$(jg_test_tmproot jg-retitle)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
H=$T/home; export JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
"$WRAPPER" init --prefix jg >"$T/init.log" 2>&1 || fail "init: $(cat "$T/init.log")"
run() {
  env HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin:"$(dirname "$(command -v python3)")" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" \
    JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$@" 2>&1
}
tasks() { run "$CLI" "$@"; }
field() { "$WRAPPER" show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
gone() { [ -z "$("$WRAPPER" show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0].id else .id end // empty')" ]; }
SECTIONS=$'## Captain\nwhat the owner said\n## Ask\nthe change\n## Why\nthe reason\n## Done when\nit works\n## Acceptance Criteria\nit is proved'

# The create path refuses a title that starts with a code, with or without a leading type tag, and files nothing.
for title in 'J20d-3: nm bin rest' 'S18c split the lane' 'mf-m2 lone lane lands' '[feature] TC4b: core file swap'; do
  out=$(tasks add jg-code "$title" --priority 2 --body "$SECTIONS") && fail "a title that starts with a code must be refused: $title"
  assert_contains "$out" "plan code" "the refusal must name the plan code: $title"
  assert_contains "$out" "body" "the refusal must say the code belongs in the body: $title"
  gone jg-code || fail "a refused title must file nothing: $title"
done
tasks add jg-plain "Each change lands by itself" --priority 2 --body "$SECTIONS" >/dev/null || fail "a plain outcome title must file"
tasks add jg-num "Fix the 3 failing checks" --priority 2 --body "$SECTIONS" >/dev/null || fail "a number later in a plain title must file"

# Open tickets as the old backlog holds them: a code in front, a tag, a long title. The loose flag stands in for that history.
: > "$H/config/backlog-intake-loose"
tasks add jg-a "[feature] J20d-3: nm bin rest and name gate" --priority 2 --body "old a" >/dev/null || fail "seed a"
tasks add jg-b "[feature] mf-m2: Lone ready lane lands" --priority 2 --body "old b" >/dev/null || fail "seed b"
tasks add jg-c "S18c" --priority 2 --body "old c" >/dev/null || fail "seed c"
rm -f "$H/config/backlog-intake-loose"
listed=$(run python3 "$ROOT/bin/jg-retitle.py" list) || fail "list: $listed"
for id in jg-a jg-b jg-c; do assert_contains "$listed" "$id" "list must name $id"; done
case $listed in *jg-plain*|*jg-num*) fail "list must not name a plain title: $listed" ;; esac

map=$T/map.tsv
printf 'jg-a\tName gate covers the rest of bin\njg-b\tA lone ready lane lands by itself\njg-c\tEach change lands by itself when ready\n' > "$map"

# A title that fails the rule stops the whole pass: nothing is written, the refusal names the row.
printf 'jg-a\tName gate covers the rest of bin\njg-b\tmf-m2 still a code\n' > "$T/bad.tsv"
out=$(run python3 "$ROOT/bin/jg-retitle.py" apply "$T/bad.tsv" --write) && fail "a code title in the map must stop the pass"
assert_contains "$out" "jg-b" "the refusal must name the row"
[ "$(field jg-a .title)" = "J20d-3: nm bin rest and name gate" ] || fail "a stopped pass must write nothing: $(field jg-a .title)"

# A dry run prints the plan and writes nothing.
out=$(run python3 "$ROOT/bin/jg-retitle.py" apply "$map") || fail "dry run: $out"
assert_contains "$out" "would be renamed" "the dry run must say it wrote nothing"
[ "$(field jg-c .title)" = "S18c" ] || fail "a dry run must write nothing: $(field jg-c .title)"

# The pass renames, and the code and the earlier title move into the body.
out=$(run python3 "$ROOT/bin/jg-retitle.py" apply "$map" --write) || fail "apply: $out"
[ "$(field jg-a .title)" = "Name gate covers the rest of bin" ] || fail "jg-a title: $(field jg-a .title)"
[ "$(field jg-c .title)" = "Each change lands by itself when ready" ] || fail "jg-c title: $(field jg-c .title)"
body=$(field jg-a .description)
assert_contains "$body" "old a" "the body keeps its words"
assert_contains "$body" "Plan code: J20d-3" "the code moves into the body"
assert_contains "$body" "Earlier title: J20d-3: nm bin rest and name gate" "the earlier title moves into the body"
assert_contains "$(field jg-c .description)" "Plan code: S18c" "a title that was only a code keeps it in the body"

# A second pass changes nothing, and the list is empty of these rows.
out=$(run python3 "$ROOT/bin/jg-retitle.py" apply "$map" --write) || fail "second apply: $out"
assert_contains "$out" "0 title(s) renamed" "a second pass must change nothing"
listed=$(run python3 "$ROOT/bin/jg-retitle.py" list) || fail "list again: $listed"
case $listed in *jg-a*|*jg-b*|*jg-c*) fail "a renamed ticket must leave the list: $listed" ;; esac
pass "plain ticket names: create refuses a code title; one pass renames open tickets and keeps the code and old title in the body"
