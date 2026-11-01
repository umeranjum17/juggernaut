#!/usr/bin/env bash
# Behavioral regressions for the shared owner-rules surface (data/owner-rules.md),
# its audit for quotes trapped in a private note, and the turn boundary printing
# no block for a question while the card path still posts its key.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES="$ROOT/bin/jg-owner-rules.sh"
CARD="$ROOT/bin/jg-question-card.sh"
GUARD="$ROOT/bin/jg-turnend-guard.sh"
TMP_ROOT=$(jg_test_tmproot jg-owner-rules)

test_add_refuses_an_entry_it_cannot_enforce() {
  local home out rc
  home="$TMP_ROOT/refuse"
  mkdir -p "$home/data"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner --scope s --enforce bin/jg-pr-merge.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no owner words is accepted"
  case "$out" in
    *"needs the owner's own words"*) ;;
    *) fail "no-words refusal did not name the missing owner words: $out" ;;
  esac

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner --words "always keep the fleet moving" --scope s 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no enforcement point is accepted"
  case "$out" in
    *"needs an enforcement point"*) ;;
    *) fail "no-enforcement refusal did not name the enforcement point: $out" ;;
  esac

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner --words "always keep the fleet moving" --scope s --enforce none 2>&1); rc=$?
  assert_equals 2 "$rc" "an enforcement point of 'none' is accepted"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner --words "always keep the fleet moving" --scope s --enforce bin/not-a-script.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an enforcement point naming a missing path is accepted"
  case "$out" in
    *"does not exist in this checkout"*) ;;
    *) fail "missing-path refusal did not name the path: $out" ;;
  esac

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind owner --words "always keep the fleet moving" --scope s 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no scope is accepted"
  assert_absent "$home/data/owner-rules.md" "a refused entry created a surface"
  pass "an entry with no words, no scope, or no real enforcement point is refused"
}

test_the_surface_starts_empty_and_records_an_owner_entry() {
  local home surface
  home="$TMP_ROOT/surface"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1 \
    || fail "init did not write the shared rules surface"
  assert_grep 'bin/jg-owner-rules.sh add --kind owner' "$surface" \
    "the surface header does not say which kind it takes"
  assert_equals 0 "$(grep -c '^- Owner'\''s words:' "$surface" || true)" \
    "init inferred an entry, and an entry is the owner's own call"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1
  assert_not_equals 0 "$?" "init overwrote an existing surface"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --kind owner --words "never ship an unproven screen" --scope "every user-visible change" \
    --enforce bin/jg-pr-merge.sh --date 2026-10-25 >/dev/null 2>&1 \
    || fail "a complete owner entry was refused"
  assert_grep '## 2026-10-25 - never ship an unproven screen' "$surface" \
    "the recorded entry lost its date and title"
  assert_grep '- Kind: owner' "$surface" \
    "the recorded entry lost its kind"
  assert_grep 'Enforced by: bin/jg-pr-merge.sh' "$surface" \
    "the recorded entry lost its enforcement point"
  assert_grep 'words: "never ship an unproven screen"' "$surface" \
    "the recorded entry lost the owner's verbatim words"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --kind owner --words "never ship an unproven screen" --scope x --enforce bin/jg-pr-merge.sh >/dev/null 2>&1
  assert_not_equals 0 "$?" "the same owner words were recorded twice"
  pass "the surface starts empty and a recorded owner entry carries the words, the date, the scope, the kind and the enforcer"
}

test_add_asks_for_the_kind_and_refuses_a_product_rule() {
  local home out rc
  home="$TMP_ROOT/kind"
  mkdir -p "$home/data"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --words "keep the fleet moving" --scope s --enforce bin/jg-pr-merge.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no kind was accepted"
  case "$out" in
    *"--kind owner"*) ;;
    *) fail "the no-kind refusal did not ask for the kind: $out" ;;
  esac

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind product \
    --words "keep CI thin: no full suite on every push" --scope "every project" --enforce bin/jg-lint.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "a product rule was accepted into the owner surface"
  case "$out" in
    *"bin/jg-tasks-axi.sh add"*) ;;
    *) fail "the product refusal did not point at a ticket: $out" ;;
  esac
  case "$out" in
    *"AGENTS.md"*) ;;
    *) fail "the product refusal did not name where a product rule ships: $out" ;;
  esac
  assert_absent "$home/data/owner-rules.md" "a refused product rule wrote a surface"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" add --kind taste \
    --words "keep the fleet moving" --scope s --enforce bin/jg-pr-merge.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an unknown kind was accepted"
  pass "add asks for the kind, refuses a product rule with the ticket path, and writes nothing"
}

test_split_reports_kinds_and_writes_the_owner_half_back() {
  local home surface out rc
  home="$TMP_ROOT/split"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"
  cat > "$surface" <<'EOF'
# Owner rules

## 2026-10-25 - No forecast dates
- Kind: owner
- Scope: every report
- Enforced by: AGENTS.md
- Owner's words: "never forecast a date"

## 2026-10-25 - Thin CI
- Kind: product
- Scope: every project
- Enforced by: bin/jg-lint.sh
- Owner's words: "keep CI thin"

## 2026-10-26 - No kind yet
- Scope: somewhere
- Enforced by: AGENTS.md
- Owner's words: "an unclassified entry"
EOF

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" split 2>&1); rc=$?
  assert_equals 1 "$rc" "a split with an unclassified entry exited 0"
  for want in 'product: 2026-10-25 - Thin CI' 'no kind: 2026-10-26 - No kind yet' \
    'total: 3' 'owners: 1' 'products: 1' 'unclassified: 1'; do
    assert_contains "$out" "$want" "the split report did not print '$want'"
  done

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" split --apply 2>&1); rc=$?
  assert_equals 2 "$rc" "--apply rewrote a surface that still holds an unclassified entry"
  assert_grep 'No kind yet' "$surface" "the refused --apply changed the surface"

  sed -i '/^## 2026-10-26 - No kind yet$/a - Kind: product' "$surface"
  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" split --apply 2>&1); rc=$?
  assert_equals 0 "$rc" "a fully classified surface did not apply: $out"
  assert_contains "$out" 'owners: 1' "the applied split did not report the owner count"
  assert_grep 'No forecast dates' "$surface" "--apply dropped the owner entry"
  assert_no_grep 'Thin CI' "$surface" "--apply kept a product entry in the surface"
  assert_no_grep 'No kind yet' "$surface" "--apply kept a product entry in the surface"
  pass "split reports the owner and product counts and --apply leaves only the owner entries"
}

test_audit_flags_a_correction_left_in_a_private_note() {
  local home out rc
  home="$TMP_ROOT/audit"
  mkdir -p "$home/data"
  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1
  printf -- '- from tonight: he said "never use step 5 preview for anything at all" and I noted it here\n' \
    > "$home/data/learnings.md"

  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" audit 2>&1); rc=$?
  assert_equals 0 "$rc" "a findings report failed the default audit"
  assert_contains "$out" "$home/data/learnings.md" "the audit did not name the private note holding the quote"
  assert_contains "$out" "never use step 5 preview for anything at all" "the audit did not show the trapped words"
  assert_contains "$out" "jg-owner-rules.sh add" "the audit did not name the fix"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" audit --fail >/dev/null 2>&1
  assert_not_equals 0 "$?" "--fail did not fail on a trapped rule"

  JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --kind owner --words "never use step 5 preview for anything at all" --scope dispatch \
    --enforce bin/jg-dispatch-resolve.sh >/dev/null 2>&1
  out=$(JG_HOME="$home" JG_ROOT_OVERRIDE="$ROOT" "$RULES" audit 2>&1)
  assert_contains "$out" "clean:" "recording the rule did not clear the audit"
  pass "a rule quoted only in a private note is flagged until the surface records it"
}

# Build a genuine primary home and a transcript holding one assistant reply.
make_guard_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'rule-test-home\n' > "$dir/.jg-squad-lead-home"
}

reply_payload() {  # <dir> <reply text>
  local text
  text=${2//\\/\\\\}
  text=${text//\"/\\\"}
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$text" > "$1/reply.jsonl"
  printf '{"session_id":"s","transcript_path":"%s/reply.jsonl"}' "$1"
}

test_turn_boundary_prints_no_block_for_a_question() {
  local home payload board rc
  home="$TMP_ROOT/question"
  board="$TMP_ROOT/question-board"
  make_guard_home "$home"
  mkdir -p "$board"

  payload=$(reply_payload "$home" "The blocker cleared and the fix is in. Should I merge it?")
  printf '%s' "$payload" | JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "a reply ending in an unfiled question was blocked at the turn boundary"

  payload=$(reply_payload "$home" "Merged and cleaned up. Nothing outstanding.")
  printf '%s' "$payload" | JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "a reply that asks nothing was blocked"

  command -v sign-off-axi >/dev/null 2>&1 || {
    pass "the turn boundary prints no block for a question (card half skipped: no sign-off-axi)"
    return 0
  }
  local key again
  key=$(SIGN_OFF_HOME="$board" "$CARD" post --ask-ref chat-1 --must design-pick \
    --title "Should the fix merge now?" --why "The fix is green and in scope." \
    --outcome yes="It merges once the captain says so." --outcome no="It waits for his review." \
    --recommend yes --recommend-reason "His word is the merge call." --default no 2>/dev/null)
  [ -n "$key" ] || fail "jg-question-card.sh printed no board key"

  payload=$(reply_payload "$home" "The fix is green. Card $key on the board covers it - your call there.")
  printf '%s' "$payload" | JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "a reply citing an open board card was blocked"

  again=$(SIGN_OFF_HOME="$board" "$CARD" post --ask-ref chat-1 --must design-pick \
    --title "Should the fix merge now?" --why "The fix is green and in scope." \
    --outcome yes="It merges once the captain says so." --outcome no="It waits for his review." \
    --recommend yes --recommend-reason "His word is the merge call." --default no 2>/dev/null)
  assert_equals "$key" "$again" "re-posting the same open question did not return the existing key"
  pass "the turn boundary prints no block for a question, and the card key still posts once"
}

test_add_refuses_an_entry_it_cannot_enforce
test_the_surface_starts_empty_and_records_an_owner_entry
test_add_asks_for_the_kind_and_refuses_a_product_rule
test_split_reports_kinds_and_writes_the_owner_half_back
test_audit_flags_a_correction_left_in_a_private_note
test_turn_boundary_prints_no_block_for_a_question
