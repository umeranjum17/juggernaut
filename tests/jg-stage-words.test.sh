#!/usr/bin/env bash
# The four delivery words and the lint that lists stage-sense "live" used alone (core/stage-words, H49a).
# Every case runs the real command, core/stage-words/lint.sh, on files it is given or on a fixture git repository
# it lints by tracked files, and reads its exit status and its printed lines.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/core/stage-words/lint.sh"
TMP_ROOT=$(jg_test_tmproot jg-stage-words)

test_the_list_holds_the_four_words() {
  local out
  out=$(bash "$LINT" --words)
  assert_contains "$out" 'Built: the worker finished its commit' 'Built is on the list'
  assert_contains "$out" 'Landed: joined the shared work branch' 'Landed is on the list'
  assert_contains "$out" 'In use: the homes run it; nobody else has it' 'In use is on the list'
  assert_contains "$out" 'Released: on GitHub main and npm; everyone has it' 'Released is on the list'
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 4 ] || fail "the list must hold exactly four words, got: $out"
  pass 'the list holds the four delivery words and what each means'
}

test_live_alone_is_listed_and_other_senses_are_accepted() {
  local f="$TMP_ROOT/text.md" out rc
  # shellcheck disable=SC2016
  printf '%s\n' 'The change went live.' 'Run a live test first.' 'The pane is a live pane.' 'Read `live` as code.' \
    'The record is jg-trunk-live, in live/x and live.tsv.' 'Goes Live at noon.' > "$f"
  out=$(bash "$LINT" "$f"); rc=$?
  [ "$rc" -eq 0 ] || fail "report-only must exit 0, got $rc"
  assert_contains "$out" "$f:1: The change went live." 'live alone at the end of a sentence is listed'
  assert_contains "$out" "$f:6: Goes Live at noon." 'live alone in another case is listed'
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] || fail "only the two stage-sense lines may be listed, got: $out"
  bash "$LINT" --strict "$f" >/dev/null; rc=$?
  [ "$rc" -eq 1 ] || fail "--strict must exit 1 on a finding, got $rc"
  pass 'live alone is listed, a live test, a live pane, code quotes and names are accepted, report-only exits 0 and --strict exits 1'
}

test_a_clean_file_passes_strict() {
  local f="$TMP_ROOT/clean.md"
  printf '%s\n' 'The change is Built, then Landed, In use and Released.' > "$f"
  [ -z "$(bash "$LINT" --strict "$f")" ] || fail 'a file with no stage-sense live must print nothing'
  pass 'a file with the four words and no stage-sense live passes --strict'
}

test_with_no_file_it_lints_the_tracked_files() {
  local out
  out=$(bash "$LINT")
  assert_not_contains "$out" 'core/stage-words/' 'the list directory is never linted'
  assert_contains "$out" 'docs/trunk-flow.md:' 'the tracked files of the repository are linted'
  pass 'with no file the lint covers the tracked files and leaves its own directory out'
}

test_the_list_holds_the_four_words
test_live_alone_is_listed_and_other_senses_are_accepted
test_a_clean_file_passes_strict
test_with_no_file_it_lints_the_tracked_files
