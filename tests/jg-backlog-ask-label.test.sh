#!/usr/bin/env bash
# The type tag and the kind leave the title: `add` stores [captain-ask] words and -l captain-ask words the same way (the label, a title with
# no tag), --kind captain is metadata on a task, a design ask's slice takes no design-ux label, the store answers "the ask itself" and
# "under an ask" in one place, and the one-time pass (`retag`) brings an old home to the same shape. Every call runs on a real embedded
# store with no network. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds, which skip without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" CLI="$ROOT/bin/jg-backlog.sh" T=$(jg_test_tmproot jg-backlog-ask-label)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
H=$T/home; export JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
: > "$H/config/backlog-intake-loose"  # this suite is about the label, and tests/jg-backlog-intake.test.sh is about strict intake
"$WRAPPER" init --prefix jg >"$T/init.log" 2>&1 || fail "init: $(cat "$T/init.log")"
bd_() { "$WRAPPER" "$@" 2>/dev/null; }
tasks() {
  env HOME="$T/user" TMPDIR="$T" XDG_DATA_HOME="$T/xdg" PATH=/usr/bin:/bin JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$CLI" "$@" 2>&1
}
field() { bd_ show "$1" --json | jq -r "(if type == \"array\" then .[0] else . end) | $2"; }
labels() { field "$1" '.labels | sort | join(",")'; }
role() { tasks show "$1" --full | sed -n 's/^  ask: //p'; }

# The tag and the label give one stored shape: the label, and a title with no tag.
tasks add jg-tag "[captain-ask] Plan the route" --body why >/dev/null || fail "add with the tag"
tasks add jg-lab -l captain-ask "Plan the route" --body why >/dev/null || fail "add with the label"
for id in jg-tag jg-lab; do
  [ "$(field "$id" .title)" = "Plan the route" ] || fail "$id: the title must hold no tag: $(field "$id" .title)"
  [ "$(labels "$id")" = captain-ask ] || fail "$id: the label must be stored: $(labels "$id")"
  [ "$(field "$id" .priority)" = 0 ] || fail "$id: an owner ask stays at priority 0"
  [ "$(role "$id")" = ask ] || fail "$id: the store must answer that it is the ask"
done
[ "$(tasks add jg-plain -l feature "Plain words" --body why >/dev/null; role jg-plain)" = "" ] || fail "a feature is no owner ask"

# Kind is metadata on a task, never bd's decision type.
tasks add jg-kind "[captain-ask] Pick a route" --kind captain --body why >/dev/null || fail "add with kind"
[ "$(field jg-kind .issue_type)" = task ] && [ "$(field jg-kind .metadata.kind)" = captain ] || fail "kind captain: $(field jg-kind '[.issue_type, .metadata.kind] | join(",")')"

# A design ask with one slice: the slice is under the ask and has no design-ux label.
tasks add jg-design "[design-ux] Pick the page" --body why --repo p >/dev/null || fail "add the design ask"
tasks add --parent jg-design "[feature] Build the page" --body why >/dev/null || fail "add the slice"
[ "$(labels jg-design)" = "design-ux,project:p" ] || fail "the design ask labels: $(labels jg-design)"
case "$(labels jg-design.1)" in *design-ux*) fail "the slice must not take design-ux: $(labels jg-design.1)" ;; esac
tasks add jg-ask2 "[captain-ask] Ask with a slice" --body why >/dev/null || fail "add the ask"
tasks add --parent jg-ask2 "[feature] The slice" --body why >/dev/null || fail "add its slice"
[ "$(role jg-ask2)" = ask ] && [ "$(role jg-ask2.1)" = under ] || fail "ask and slice roles: $(role jg-ask2) $(role jg-ask2.1)"

# An old home: tags in titles, no labels, decision rows, an old child under an old ask, a parent that is no epic.
bd_ create --title="[captain-ask] Old ask" --id jg-old -p 0 --type decision >/dev/null || fail "seed the old ask"
bd_ create --title="[feature] Old child" --id jg-oldkid -p 2 >/dev/null || fail "seed the old child"
bd_ dep add jg-oldkid jg-old --type parent-child >/dev/null || fail "link the old child"
bd_ create --title="[design-ux] Old pick" --id jg-pick -p 1 --type decision >/dev/null || fail "seed the old decision"
bd_ create --title="[security] Plain old" --id jg-sec -p 1 >/dev/null || fail "seed the old row"
[ "$(role jg-old)" = ask ] || fail "before the pass an old row with the tag still counts as an ask: $(role jg-old)"
tasks retag | grep -q '^retagged ' || fail "retag must report"
[ "$(field jg-old .title)" = "Old ask" ] && [ "$(labels jg-old)" = captain-ask ] || fail "the old ask: $(field jg-old .title) $(labels jg-old)"
[ "$(labels jg-oldkid)" = "captain-ask,feature" ] || fail "captain-ask must go down to the old child: $(labels jg-oldkid)"
[ "$(role jg-old)" = ask ] && [ "$(role jg-oldkid)" = under ] || fail "roles after the pass: $(role jg-old) $(role jg-oldkid)"
[ "$(field jg-old .issue_type)" = epic ] && [ "$(field jg-old .metadata.kind)" = captain ] || fail "a decision with a child is an epic with kind captain"
[ "$(field jg-pick .issue_type)" = task ] && [ "$(field jg-pick .metadata.kind)" = captain ] || fail "a decision is a task with kind captain"
[ "$(labels jg-pick)" = design-ux ] && [ "$(labels jg-sec)" = security ] || fail "the other tags become labels"
[ "$(tasks retag)" = "retagged 0 of $(bd_ list --all --json | jq length) rows" ] || fail "a rerun must find nothing left"
pass "tag and kind leave the title: add, kind, design slice, one answer for the ask, the one-time pass"
