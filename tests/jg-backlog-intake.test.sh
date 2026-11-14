#!/usr/bin/env bash
# Strict intake reads fields, not text: `add` refuses a title that is not plain words (and names the fix), a new item with no
# priority, and a body without the sections bd's lint.sections.task asks for (bd itself refuses it, through create --validate);
# --release lands in metadata.release (`later` when absent) and a `release:` body line is not read; a leading type tag is still
# taken as input; an owner ask gets priority 0 by itself; and config/backlog-intake-loose turns all of it off. Every call runs on
# a real embedded store with no network. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds, which skip without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" CLI="$ROOT/bin/jg-backlog.sh" T=$(jg_test_tmproot jg-backlog-intake)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
"$WRAPPER" init --prefix jg >"$T/init.log" 2>&1 || fail "init: $(cat "$T/init.log")"
tasks() {
  env HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$CLI" "$@" 2>&1
}
field() { "$WRAPPER" show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
gone() { [ -z "$("$WRAPPER" show "$1" --json 2>/dev/null | jq -r 'if type == "array" then .[0].id else .id end // empty')" ]; }
SECTIONS=$'## Captain\nwhat the owner said\n## Ask\nthe change\n## Why\nthe reason\n## Done when\nit works\n## Acceptance Criteria\nit is proved'

# A title that is not plain words is refused, with the fix line, and nothing is filed.
out=$(tasks add jg-long "A title that is far too long to read as a title at all" --priority 2 --body "$SECTIONS") && fail "a long title must be refused"
assert_contains "$out" "2 to 7 plain words" "the refusal must carry the fix line"
gone jg-long || fail "a refused title must file nothing"
out=$(tasks add jg-id "Fix jg-abc now" --priority 2 --body "$SECTIONS") && fail "a title with an id must be refused"
assert_contains "$out" "carries an id" "the refusal must name the id"

# A new item with no priority is refused, naming the flag.
out=$(tasks add jg-noprio "Plain words" --body "$SECTIONS") && fail "no priority must be refused"
assert_contains "$out" "--priority 0|1|2|3" "the refusal must name the flag"

# A body without the sections is refused by bd itself.
out=$(tasks add jg-nosec "Plain words" --priority 2 --body "just a line") && fail "a body without the sections must be refused"
assert_contains "$out" "missing required sections" "bd must refuse the body"
assert_contains "$out" "Done when" "the refusal must name a missing section"
gone jg-nosec || fail "a body bd refused must file nothing"

# A whole item files; --release lands in metadata.release and a release: body line is not read.
tasks add jg-ok "Plain words" --priority 2 --release v9 --body "$SECTIONS" >/dev/null || fail "a whole item must file"
[ "$(field jg-ok .metadata.release)" = v9 ] || fail "--release must land in metadata.release: $(field jg-ok .metadata.release)"
tasks add jg-line "Plain words two" --priority 2 --body "$SECTIONS"$'\nrelease: now' >/dev/null || fail "a whole item with a release line must file"
[ "$(field jg-line .metadata.release)" = later ] || fail "a release: body line must not be read: $(field jg-line .metadata.release)"

# A leading type tag is taken as input and stored as the label; an owner ask gets priority 0 by itself.
tasks add jg-ask "[captain-ask] Plan the route" --body "$SECTIONS" >/dev/null || fail "an owner ask must file with no priority"
[ "$(field jg-ask .priority)" = 0 ] && [ "$(field jg-ask .title)" = "Plan the route" ] || fail "the ask: $(field jg-ask '[.priority, .title] | join(",")')"
[ "$(field jg-ask '.labels | join(",")')" = captain-ask ] || fail "the tag must become the label"

# The presence flag turns all of it off.
: > "$H/config/backlog-intake-loose"
tasks add jg-loose "A title that is far too long to read as a title at all" --body plain >/dev/null || fail "loose intake must file anything"
pass "strict intake: title, priority, sections, release field, tag as input, loose flag"
