#!/usr/bin/env bash
# Slices are real children: `add --parent` files a child under bd's own numbering, three levels deep (ask, slice, piece),
# gives the child only the labels a slice needs, makes the parent an epic, and refuses a fourth level and the own ids that
# would collide with a child's task name. The owner-rules tree then reads the parent from the edge. Every call runs on a
# real embedded store with no network. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds, which skip without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" CLI="$ROOT/bin/jg-backlog.sh" T=$(jg_test_tmproot jg-beads-parent)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
: > "$H/config/backlog-intake-loose"
"$WRAPPER" init --prefix jg >"$T/real-init.log" 2>&1 || fail "init: $(cat "$T/real-init.log")"

bd_() { "$WRAPPER" "$@" 2>/dev/null; }
tasks() {  # <backlog args...>: the CLI on the Beads home, stdout and stderr together.
  env HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$CLI" "$@" 2>&1
}
field() {  # <id> <jq filter>: one field of a row, as bd stores it.
  bd_ show "$1" --json | jq -r "(if type == \"array\" then .[0] else . end) | $2"
}
labels() { field "$1" '.labels | sort | join(",")'; }

# The ask is minted; it carries labels beyond the two a slice inherits.
ask=$(tasks add --mint "[captain-ask] Plan it" --repo sample --label other --body why --json | jq -r .task.id) || fail "mint the ask"
[ -n "$ask" ] && [ "$ask" != null ] || fail "the ask must have an id"
[ "$(labels "$ask")" = "other,project:sample" ] || fail "the ask labels: $(labels "$ask")"
bd_ update "$ask" --add-label captain-ask >/dev/null

# A slice is bd's child of the ask, numbered by bd, with exactly the two labels plus the call's own.
slice=$(tasks add --parent "$ask" "[feature] Slice one" --label extra --body why --json | jq -r .task.id) || fail "file a slice"
[ "$slice" = "$ask.1" ] || fail "the slice must take bd's child id, got $slice"
[ "$(labels "$slice")" = "captain-ask,extra,project:sample" ] || fail "the slice must take only captain-ask, project and its own label: $(labels "$slice")"
[ "$(field "$slice" '.dependencies[0].id + " " + .dependencies[0].dependency_type')" = "$ask parent-child" ] || fail "the slice must hang under the ask"
[ "$(field "$ask" .issue_type)" = epic ] || fail "the parent must become an epic"
epics=$(bd_ epic status --json)
[ "$(jq -r --arg a "$ask" '.[] | select(.epic.id == $a) | .total_children' <<<"$epics")" = 1 ] || fail "epic status must list the ask with its slice: $epics"

# A piece is the slice's child; the slice becomes an epic too, and the call's repo replaces the parent's.
piece=$(tasks add --parent "$slice" "[feature] Piece" --repo other --body why --json | jq -r .task.id) || fail "file a piece"
[ "$piece" = "$slice.1" ] || fail "the piece must take bd's child id, got $piece"
[ "$(labels "$piece")" = "captain-ask,project:other" ] || fail "the piece labels: $(labels "$piece")"

# A piece has no parts, and an own id cannot go with --parent.
out=$(tasks add --parent "$piece" "[feature] Too deep") && fail "a fourth level must be refused"
assert_contains "$out" "already a piece" "the refusal must say why"
[ "$(bd_ list --all --json | jq length)" = 3 ] || fail "a refused fourth level must add no row"
out=$(tasks add jg-own "[feature] Own id" --parent "$ask") && fail "an own id with --parent must be refused"
assert_contains "$out" "--parent cannot go with an own id" "the refusal must say why"

# An own id may not be another row's task name, nor the dash form of a child's task name.
bd_ create --title=moved --id jg-moved --force --metadata '{"legacy_item":"jg-old"}' >/dev/null || fail "make the moved row"
out=$(tasks add jg-old "[feature] Taken name" --body why) && fail "another row's task name must be refused as an id"
assert_contains "$out" "task name of row jg-moved" "the refusal must name the row, not end in a Python error"
out=$(tasks add "$ask-1" "[feature] Dash form" --body why) && fail "<existing id>-<number> must be refused as an id"
assert_contains "$out" "form of a child's task name" "the refusal must say why"
assert_contains "$(tasks add jg-moved "[feature] again" --body why)" "already exists" "an own id that exists still converges"

# The owner-rules tree reads the parent from the edge: the slice has no parent: line in its body.
tree=$(bash "$ROOT/core/owner-rules/bin/jg-owner-rules-tree.sh" <(tasks markdown))
assert_contains "$tree" "$slice: $slice -> $ask -> [epic root]" "the tree must follow the slice's edge to the ask"
pass "slices are real children: ask, slice, piece, labels, refused fourth level and own ids, epic status, tree"
