#!/usr/bin/env bash
# The merge path keeps the migration card current: a fresh key per merge, the
# previous card dismissed, a captain digest on a milestone, no repeat for a PR.
set -u
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
T=$(jg_test_tmproot migration-card)
mkdir -p "$T/home/config" "$T/home/state" "$T/bin" "$T/board"
export JG_HOME=$T/home PATH=$T/bin:$PATH FAKE_LOG=$T/calls.log
: > "$T/board/board.json"
printf 'branch=release/c-2\ntarget=31832\nboard=%s\ncard=card-live\nbaseline-deleted=9446\nbaseline-added=13174\n' "$T/board/board.json" > "$T/home/config/migration-card"
cat > "$T/bin/gh" <<'F'
#!/usr/bin/env bash
case "$3" in
  */1) echo '{"baseRefName":"release/c-2","title":"Queue switch live","additions":1200,"deletions":2100}' ;;
  */2) echo '{"baseRefName":"release/c-2","title":"Delete the old path","additions":300,"deletions":4800}' ;;
  *) echo '{"baseRefName":"main","title":"other","additions":1,"deletions":1}' ;;
esac
F
cat > "$T/bin/sign-off-axi" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
F
chmod +x "$T/bin/gh" "$T/bin/sign-off-axi"
run() { "$ROOT/bin/jg-migration-card.sh" merge "https://github.com/o/r/pull/$1"; }

assert_equals card-live-1 "$(run 1)" "the first merge posts a fresh key"
assert_equals card-live-2 "$(run 2)" "the second merge posts the next key"
run 2 >/dev/null; run 3 >/dev/null
assert_equals 2 "$(wc -l < "$T/home/data/migration-card/ledger.tsv")" "a repeat or another base adds nothing"
assert_contains "$(cat "$FAKE_LOG")" "dismiss card-live $T/board/board.json --reason replaced" "the baseline card is dismissed"
assert_contains "$(cat "$FAKE_LOG")" "dismiss card-live-1 $T/board/board.json --reason replaced" "the previous card is dismissed"
page=$T/board/reports/card-live-2/index.html
assert_contains "$(cat "$page")" "16,346 of 31,832 lines deleted" "the page shows the running total"
assert_contains "$(cat "$page")" "15,486 lines are left" "the page shows what is left"
assert_contains "$(cat "$page")" "prefers-color-scheme:dark" "the page has a dark-mode block"
if grep -qE '#[0-9a-fA-F]{3,6}\b|rgb\(' "$page"; then fail "the page writes its own colours"; fi
out=$(cat "$T/home/state/branch-outcomes.jsonl")
assert_contains "$out" "a switch is live" "a switch milestone is a captain outcome"
assert_contains "$out" "15000 lines deleted" "each 5,000 lines is a milestone"
assert_contains "$out" "Release blockers: none recorded" "the digest has its three lines"
pass "migration card follows the merge path"
