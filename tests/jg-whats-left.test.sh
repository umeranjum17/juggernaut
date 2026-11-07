#!/usr/bin/env bash
# Journey: the standing view of what is left follows the records with no manual step.
# A refresh publication (the call the watcher, spawn and teardown make) renders
# state/whats-left.md from the backlog; a changed record shows in the file after
# the next publication, and `show` re-renders by itself when a record is newer.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(jg_test_tmproot jg-whats-left)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$HOME_DIR/fakebin"
jg_test_beads_home "$HOME_DIR"
jg_fake_exit0 "$HOME_DIR/fakebin" tmux treehouse no-mistakes gh gh-axi
VIEW="$HOME_DIR/state/whats-left.md"

jg_test_add "$HOME_DIR" jg-login-fix "[feature] Fix the login refresh"
jg_test_add "$HOME_DIR" jg-login-docs "[feature] Document the login refresh" --blocked-by jg-login-fix

refresh() {  # the automatic call: a best-effort publication
  PATH="$HOME_DIR/fakebin:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
    JG_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/jg-home-summary-refresh.sh" --best-effort
}

refresh
[ -s "$VIEW" ] || fail "a publication did not render the standing view"
grep -q 'jg-login-fix' "$VIEW" || fail "the view misses a queued item"
grep -q 'jg-login-docs.*waits on jg-login-fix' "$VIEW" || fail "the view misses what the item waits on: $(cat "$VIEW")"
pass "a publication renders the view with what each item waits on"

# Change the records only: add an item. The next publication carries it.
sleep 1
jg_test_add "$HOME_DIR" jg-extra "[feature] A newly filed item"
refresh
grep -q 'jg-extra' "$VIEW" || fail "a changed record did not reach the view: $(cat "$VIEW")"
pass "a changed record reaches the view after the next publication"

# Change the records again, with no publication: `show` notices and re-renders.
sleep 1
jg_test_add "$HOME_DIR" jg-late "[feature] Filed after the last publication"
out=$(PATH="$HOME_DIR/fakebin:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
  JG_DATA_OVERRIDE="$HOME_DIR/data" "$ROOT/bin/jg-whats-left.sh" show) || fail "show failed"
printf '%s\n' "$out" | grep -q 'jg-late' || fail "show printed a stale view: $out"
pass "show re-renders when a record is newer than the file"

# A queued item the captain holds shows under the person section.
printf '%s\n' "$out" | grep -q '^## Waiting on a person' || fail "the person section is missing"
pass "the view has the person section"

jg_test_cleanup 2>/dev/null || true
echo "jg-whats-left: all passed"
