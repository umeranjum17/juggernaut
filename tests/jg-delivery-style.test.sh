#!/usr/bin/env bash
# Behavior test for the delivery-style table: each of today's four modes prints its row, an unknown mode is refused,
# and no row or header names a prover.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DS="$ROOT/bin/jg-delivery-style.sh" TABLE="$ROOT/core/machines/styles/delivery-styles.tsv"

assert_equals "no-mistakes direct-PR local-only local-trunk" "$(bash "$DS" --list | tr '\n' ' ' | sed 's/ $//')" "the four mode words"
for m in no-mistakes direct-PR local-only local-trunk; do
  out=$(bash "$DS" "$m" 2>&1); rc=$?
  expect_code 0 "$rc" "$m prints"
  assert_equals "line adds joins publishes review trunk" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" "$m row has six fields"
  if printf '%s\n' "$out" | cut -f2 | grep -qv .; then fail "$m has an empty field"; fi
done
assert_contains "$(bash "$DS" local-trunk)" "the local trunk" "local-trunk line"
assert_contains "$(bash "$DS" direct-PR)" "pull request" "direct-PR joins by pull request"

assert_contains "$(bash "$DS" local-only)" "publishes	no" "local-only publishes nothing"
assert_contains "$(bash "$DS" direct-PR)" "publishes	yes" "direct-PR publishes"

bash "$DS" direct-PR local; expect_code 1 "$?" "direct-PR meets a forge"
bash "$DS" local-trunk local; expect_code 0 "$?" "local-trunk has no feature pull request"
bash "$DS" local-only local; expect_code 0 "$?" "local-only has no pull request"
bash "$DS" no-mistakes review; expect_code 0 "$?" "no-mistakes runs the review"
bash "$DS" direct-PR review; expect_code 1 "$?" "direct-PR runs no review"
bash "$DS" local-trunk trunk; expect_code 0 "$?" "local-trunk lands on the trunk"
bash "$DS" local-only trunk; expect_code 1 "$?" "local-only does not land on the trunk"
bash "$DS" bogus local; expect_code 1 "$?" "an unknown mode has no fact"

out=$(bash "$DS" bogus 2>&1); rc=$?
expect_code 1 "$rc" "unknown mode refused"; assert_contains "$out" "unknown mode 'bogus'" "refusal names the mode"
bash "$DS" >/dev/null 2>&1; expect_code 2 "$?" "no mode is a usage error"

# J20a: the table has two knob rows, pr and local; the four old mode words each print their knob, and nothing else is read from the old word.
assert_equals "pr local" "$(grep '^knob	' "$TABLE" | cut -f2 | tr '\n' ' ' | sed 's/ $//')" "two knob rows"
assert_equals "pr pr local local" "$(for m in no-mistakes direct-PR local-only local-trunk; do bash "$DS" knob "$m"; done | tr '\n' ' ' | sed 's/ $//')" "the four old words print their knob"
bash "$DS" knob bogus >/dev/null 2>&1; expect_code 1 "$?" "an unknown word has no knob"
bash "$DS" knob >/dev/null 2>&1; expect_code 2 "$?" "no word is a usage error"
assert_contains "$(bash "$DS" pr)" "publishes	yes" "the pr knob publishes"
assert_contains "$(bash "$DS" local)" "publishes	no" "the local knob publishes nothing"
# Through the real caller: a registry record with the word no-mistakes reads as before and lands by the pull request path.
reg_dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-ds-reg.XXXXXX")
printf '%s\n' '- Alpha [no-mistakes +yolo] - fixture (added 2026-11-12)' '- Beta [direct-PR] - fixture (added 2026-11-12)' '- Gamma [local-only] - fixture (added 2026-11-12)' '- Delta [local-trunk] - fixture (added 2026-11-12)' > "$reg_dir/projects.md"
for p in Alpha Beta Gamma Delta; do
  read -r word yolo < <(JG_DATA_OVERRIDE="$reg_dir" bash "$ROOT/bin/jg-project-mode.sh" "$p")
  knob=$(bash "$DS" knob "$word")
  case "$p" in Alpha|Beta) want="pr" ;; *) want="local" ;; esac
  assert_equals "$want" "$knob" "$p ($word) reads as $want"
  if [ "$p" = Alpha ]; then
    assert_equals "no-mistakes on" "$word $yolo" "the record with no-mistakes reads as before"
    assert_contains "$(bash "$DS" "$knob")" "joins	the pull request's merge" "Alpha lands by the pull request path"
  fi
done
rm -rf -- "$reg_dir"

if grep -v '^#' "$TABLE" | grep -qi 'prove'; then fail "a row names a prover"; else pass "no row names a prover"; fi
if grep -i '^#' "$TABLE" | grep -q 'No column names a prover'; then pass "header states the rule"; fi
pass "delivery-style table"
