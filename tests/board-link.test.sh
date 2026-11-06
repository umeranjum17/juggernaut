#!/usr/bin/env bash
# Board deep links: the helper builds them from the home's board URL file, and
# jg-question-card prints one for the card it raises, never failing without one.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
T=$(jg_test_tmproot board-link)
mkdir -p "$T/state" "$T/bin"
jg_test_raising_ticket "$T"
export JG_HOME=$T
unset JG_SIGNOFF_URL_FILE

# shellcheck source=bin/jg-board-link-lib.sh
. "$ROOT/bin/jg-board-link-lib.sh"

jg_board_link decide k1 && fail "a missing URL file must give no link"
echo 'http://100.64.0.1:4420/?token=SECRET#old/x' > "$T/state/signoff-board.url"
assert_equals 'http://100.64.0.1:4420/?token=SECRET#decide/k1' "$(jg_board_link decide k1)" "decide link"
assert_equals 'http://100.64.0.1:4420/?token=SECRET#reports/a.b-c' "$(jg_board_link reports a.b-c)" "reports link"
assert_equals 'http://100.64.0.1:4420/?token=SECRET#tickets/jg-abc' "$(jg_board_link tickets jg-abc)" "tickets link"
jg_board_link_fix 'see http://100.64.0.1:4420/#tickets/jg-abc now' || fail "bare tickets link must be fixed"
assert_equals 'see http://100.64.0.1:4420/?token=SECRET#tickets/jg-abc now' "$JG_BOARD_LINK_OUT" "bare tickets link gets the token"
id_main=$("$ROOT/bin/jg-ticket.sh" id t1); id_lead=$("$ROOT/bin/jg-ticket.sh" id t1 lead-a)
assert_equals "jg-$(printf 'main/t1' | sha256sum | cut -c1-32)" "$id_main" "id defaults to main"
assert_equals "jg-$(printf 'lead-a/t1' | sha256sum | cut -c1-32)" "$id_lead" "id takes a home name"
jg_board_link nowhere k1 && fail "unknown section must give no link"
jg_board_link decide 'a b' && fail "unsafe key must give no link"
assert_equals merge-owner-repo-pull-7 "$(jg_board_merge_key https://github.com/owner/repo/pull/7)" "merge key"

# Caller: a fake sign-off-axi whose board gains one card on raise.
cat > "$T/bin/sign-off-axi" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  list) if [ -f "$FAKE_RAISED" ]; then echo '{"decisions":[{"key":"new-card"}]}'; else echo '{"decisions":[]}'; fi ;;
  raise) : > "$FAKE_RAISED" ;;
esac
FAKE
chmod +x "$T/bin/sign-off-axi"
export FAKE_RAISED=$T/raised
card() { PATH="$T/bin:$PATH" bash "$ROOT/bin/jg-question-card.sh" post  --route main --title "Q?" --ask-ref m1 --must design-pick --raised-by m1 \
  --outcome yes="It is." --outcome no="It is not." 2>"$T/err"; }

out=$(card) || fail "question card post failed"
assert_equals new-card "$out" "stdout stays the bare key"
assert_contains "$(cat "$T/err")" 'link: http://100.64.0.1:4420/?token=SECRET#decide/new-card' "link printed on stderr"

rm -f "$FAKE_RAISED" "$T/state/signoff-board.url"
out=$(card) || fail "post must still succeed without a board URL"
assert_equals new-card "$out" "key printed without a link"
assert_not_contains "$(cat "$T/err")" 'link:' "no link line without a URL file"
pass "board deep links"
