#!/usr/bin/env bash
# Behavior tests for native types and ids on a Beads backlog: a captain decision is written as bd's decision type and
# callers still read it as captain, and --mint leaves the id to bd. Every call runs on a real embedded store with no
# network. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds, which skip plainly without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

WRAPPER="$ROOT/bin/jg-beads.sh" CLI="$ROOT/bin/jg-tasks-axi.sh" T=$(jg_test_tmproot jg-beads-native-n6)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/user" "$T/real"
export BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$H/config/beads-dir"
jail=()
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
"${jail[@]}" "$WRAPPER" init --prefix jg >/dev/null 2>&1 || fail "init"

bd_() { "${jail[@]}" "$WRAPPER" "$@" 2>/dev/null; }
tasks() {  # <backlog args...>: the CLI on the Beads home, stdout and stderr together.
  env HOME="$T/user" TMPDIR="$T" PATH=/usr/bin:/bin JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "${jail[@]}" "$CLI" "$@" 2>&1
}
field() {  # <id> <jq filter>: one field of a row, as bd stores it.
  bd_ show "$1" --json | jq -r "(if type == \"array\" then .[0] else . end) | $2"
}

# A decision is written as the decision type, with no kind kept in metadata, and callers still read captain.
out=$(tasks add jg-ask "[captain-ask] Pick the route" --kind captain --priority 0 --body why --json) || fail "add a decision: $out"
assert_contains "$out" '"kind": "captain"' "the add reply must show captain"
[ "$(field jg-ask .issue_type)" = decision ] || fail "a decision must be stored as type decision"
[ "$(field jg-ask '.metadata.kind // "none"')" = none ] || fail "a decision must keep no kind in metadata"
assert_contains "$(tasks show jg-ask --full)" "kind: captain" "show must read the decision as captain"
assert_contains "$(tasks list --kind captain --fields kind)" "jg-ask,queued,captain" "list by kind must find the decision"
assert_contains "$(tasks add jg-ask "[captain-ask] Pick the route" --kind captain --priority 0 --body why)" "already exists" "a rerun must converge"

# Any other kind stays metadata on a task.
tasks add jg-ship "[feature] Ship it" --kind ship --priority 2 --body why >/dev/null || fail "add a ship"
[ "$(field jg-ship .issue_type)" = task ] && [ "$(field jg-ship .metadata.kind)" = ship ] || fail "a ship must stay a task with kind metadata"

# Changing the kind moves the row between the two forms and back.
tasks update jg-ship --kind captain >/dev/null || fail "make it a decision"
[ "$(field jg-ship .issue_type)" = decision ] && [ "$(field jg-ship '.metadata.kind // "none"')" = none ] || fail "a ship made captain must become a decision"
assert_contains "$(tasks show jg-ship --full)" "kind: captain" "the changed row must read as captain"
tasks update jg-ship --kind recon >/dev/null || fail "make it a recon"
[ "$(field jg-ship .issue_type)" = task ] && [ "$(field jg-ship .metadata.kind)" = recon ] || fail "a decision made recon must become a task with kind metadata"

# A row written before this change, with kind in metadata, still reads as captain beside the new form.
bd_ create "[captain-ask] Old form" --id jg-old --metadata '{"kind":"captain"}' >/dev/null || fail "seed an old row"
out=$(tasks list --kind captain --fields kind)
assert_contains "$out" jg-old "an old captain row must still list"
assert_contains "$out" jg-ask "a decision must list beside it"

# A held decision reads its hold kind like any other row.
bd_ update jg-ask --status on_hold --set-metadata hold_reason="owner picks" --set-metadata hold_kind=captain >/dev/null || fail "hold the decision"
assert_contains "$(tasks show jg-ask --full)" "hold_kind: captain" "a held decision must keep its hold kind"
[ "$(field jg-ask .issue_type)" = decision ] || fail "a hold must keep the decision type"

# --mint leaves the id to bd, under the store prefix.
out=$(tasks add --mint "[feature] Mint me" --priority 2 --body why --json) || fail "mint: $out"
id=$(printf '%s\n' "$out" | jq -r .task.id)
case "$id" in jg-*[!a-z0-9]* | jg-) fail "a minted id must be bd's own: $id" ;; jg-*) ;; *) fail "a minted id must carry the store prefix: $id" ;; esac
case "$id" in *mint*) fail "a minted id must not be built from the title: $id" ;; esac
[ "$(field "$id" .title)" = "[feature] Mint me" ] || fail "the minted row must answer to its id"
out=$(tasks add --mint "[captain-ask] Mint a decision" --kind captain --body why --json) || fail "mint a decision: $out"
[ "$(field "$(printf '%s\n' "$out" | jq -r .task.id)" .issue_type)" = decision ] || fail "a minted decision must be a decision"
out=$(tasks add --mint "[feature] Prefixed" --prefix zz --body why) && fail "a prefix cannot go with a mint"
assert_contains "$out" "--prefix cannot go with --mint" "the refusal must say why"
pass "beads native types and ids: decisions are decision rows, callers read captain, mint gives a bd id"
