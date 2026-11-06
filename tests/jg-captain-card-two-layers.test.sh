#!/usr/bin/env bash
# tests/jg-captain-card-two-layers.test.sh - the two-layer rule and its
# shadow-first check (bin/jg-captain-card-lib.sh).
#
# The rule: a captain-facing item is a durable record plus a card, and the card is
# one outcome-first line, one recommendation, at most two plain options, and a deep
# link to the record. The check names the failing rule and refuses nothing yet, and
# the board card tool and the chat message path both run it.
#
# The corpus below is the replay over 20 captain-facing messages, with the reader's
# judgement beside each one, so a check that starts refusing good messages fails
# here. Replay a real home's own last 20 with:
#   JG_CAPTAIN_CARD_STORE=<home>/state/branch-outcomes.jsonl bin/jg-test-run.sh <this>
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(jg_test_tmproot jg-captain-card)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
# shellcheck source=bin/jg-captain-card-lib.sh
. "$ROOT/bin/jg-captain-card-lib.sh"

expect_refused() {  # <layer> <text> <options> <rule>
  local line
  line=$(jg_captain_card_refusal "$1" "$2" "$3") && fail "expected a refusal for rule $4: $2"
  assert_contains "$line" "refused: rule $4," "the refusal did not name rule $4: $line"
  assert_equals 1 "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" "the refusal is not one line"
}

expect_allowed() {  # <layer> <text> <options>
  local line
  line=$(jg_captain_card_refusal "$1" "$2" "$3") || fail "a compliant $1 was refused: $line"
}

test_the_check_names_each_failing_rule() {
  local card
  expect_refused message 'PR 290 is green at head 66314538.' 0 1
  expect_refused message 'The census is done: data/guard-replay-census/report.md.' 0 1
  expect_refused message 'The worker in that worktree is still going.' 0 1
  expect_refused card 'Ship the sign-in fix in jg-4a662adc?' 2 1
  card=$(printf 'Which day should it ship?\nThe fixes land Thursday.\nrecord: https://example.test/record')
  expect_refused card "$card" 3 2
  expect_allowed card "$card" 2
  expect_refused message "$(printf '## Status\nThe fix is merged.')" 0 3
  expect_refused message "$(printf -- '- The fix is merged.')" 0 3
  expect_refused message 'Here is what happened:' 0 3
  expect_refused message 'The fix is merged and the release is ready, so every check that the release needs has now reported green on the current head and the next step is to cut the release on Friday morning before the team meets again.' 0 3
  expect_allowed message 'The fix is merged. The release is Friday.' 0
  # A card exists without a link to its full record: the rule this suite exists for.
  expect_refused card "$(printf 'Ship the sign-in fix?\nIt is ready.')" 2 4
  expect_allowed card "$(printf 'Ship the sign-in fix?\nIt is ready.\nrecord: https://example.test/record')" 2
  pass "the check names rules 1 to 4 in one line each, and a card with no record link is refused"
}

test_both_captain_facing_paths_run_the_check() {
  local d=$TMP_ROOT/paths seq
  mkdir -p "$d/home/state" "$d/home/config" "$d/fakebin" "$d/so/.sign-off"
  jg_test_raising_ticket "$d/home"
  printf 'leash: matters\n' > "$d/so/.sign-off/config.yaml"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
b=$SIGN_OFF_HOME/.sign-off/decisions.json
if [ "$1" = list ]; then jq -c '{decisions: [.items[]]}' "$b"
else jq '.items += [{key: "card"}]' "$b" > "$b.t" && mv "$b.t" "$b" && echo card; fi
SH
  chmod +x "$d/fakebin/sign-off-axi"
  card() {  # [extra flags] -> post one card through the real tool
    env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" \
      bash "$ROOT/bin/jg-question-card.sh" post  --route main --ask-ref m1 --must design-pick --raised-by m1 \
      --title "Ship the sign-in fix?" --why "It is ready." \
      --outcome yes="It ships Friday." --outcome no="It waits a week." "$@" 2>&1
  }
  card --record https://example.test/record >/dev/null || fail "a linked card was not posted"
  [ ! -s "$d/home/state/captain-card-shadow.log" ] || fail "a compliant card was logged as a refusal"
  card --key second >/dev/null || fail "an unlinked card was blocked by the shadow check"
  assert_grep 'layer=card refused: rule 4,' "$d/home/state/captain-card-shadow.log" \
    "the board card path did not run the check"
  assert_equals 2 "$(jq -r '.items | length' "$d/so/.sign-off/decisions.json")" \
    "the shadow check blocked a card instead of posting it"
  seq=$(env JG_HOME="$d" JG_STATE_OVERRIDE="$d/home/state" bash "$ROOT/bin/jg-branch-outcome.sh" append \
    --task demo --verdict captain --summary 'PR 290 is green and ready for review.') \
    || fail "the chat message path refused the outcome"
  assert_grep 'layer=message refused: rule 1,' "$d/home/state/captain-card-shadow.log" \
    "the chat message path did not run the check"
  case "$seq" in ''|*[!0-9]*) fail "the shadow check kept the outcome out of the store: $seq" ;; esac
  pass "both captain-facing paths run the check, log it, and still deliver"
}

# --- replay over the last 20 captain-facing messages ------------------------

# <label><TAB><message>; `compliant` is the reader's judgement that the message
# already meets the two-layer definition, so refusing it is a false refusal.
corpus() {
  printf '%s\t%s\n' \
    compliant 'The sign-in fix is merged. The release is Friday.' \
    compliant 'The export bug is fixed. I recommend the release waits for Monday.' \
    compliant 'The dashboard loads faster now. Next comes the settings page.' \
    compliant 'Both fixes are in the release. The checks are green.' \
    compliant 'The fix is merged, and every check behind it was green.' \
    compliant 'The guard census is finished, and the report has every number.' \
    compliant 'The sign-in screen is ready, so the release can go out on Friday.' \
    not 'PR 290 is green at head 66314538 and ready to merge.' \
    not 'PR 290 (board asks gated on a must category) is merged and live.' \
    not 'The census is finished: data/guard-replay-census/report.md.' \
    not 'The six-tool report is done: data/tools-stack-report/report.md.' \
    not 'The worker in that worktree is still going, so nothing changed.' \
    not 'Merge-gate slice 2 landed, and the daemon restarted with it.' \
    not 'The flaky-test lane stopped on a decision, so the pipeline waits.' \
    not 'Both merge-gate pull requests are red on the same shard, 303 and 304.' \
    not 'The worker is still going, so nothing changed.' \
    not '- The fix is merged.' \
    not 'Here is what happened:' \
    not 'The top item is superseded, and the rebase left no diff behind it at all, so the branch has nothing to carry.' \
    not 'Slice A is merge-ready: https://github.com/owner/repo/pull/281 is clean with every check green.'
}

# The replay: check every captain message the store holds, newest 20, and count
# the refusals a message the reader called compliant proves false.
replay() {  # <store> <labels> -> report on stdout; rc 1 on a false refusal
  local store=$1 labels=$2 checked=0 refused=0 bad=0 unjudged=0 label text line
  while IFS= read -r text; do
    checked=$((checked + 1))
    if line=$(jg_captain_card_refusal message "$text" 0); then continue; fi
    refused=$((refused + 1))
    label=$(sed -n "${checked}p" "$labels" 2>/dev/null)
    printf '%s\n' "$line"
    case "$label" in
      compliant) bad=$((bad + 1)); printf 'false refusal: %s\n' "$text" ;;
      '') unjudged=$((unjudged + 1)) ;;
    esac
  done < <(jq -r 'select(.verdict == "captain") | .summary' "$store" | tail -n 20)
  printf 'checked=%s refused=%s false-refusals=%s unjudged=%s\n' "$checked" "$refused" "$bad" "$unjudged"
  [ "$bad" -eq 0 ]
}

test_replay_of_the_last_20_captain_messages() {
  local d=$TMP_ROOT/replay label text report
  mkdir -p "$d"
  : > "$d/store.jsonl"
  : > "$d/labels"
  while IFS=$'\t' read -r label text; do
    [ -n "$label" ] || continue
    jq -cn --arg s "$text" '{verdict: "captain", summary: $s}' >> "$d/store.jsonl"
    printf '%s\n' "$label" >> "$d/labels"
  done <<< "$(corpus)"
  report=$(replay "$d/store.jsonl" "$d/labels") \
    || fail "the replay found a false refusal among the compliant messages"
  assert_contains "$report" 'checked=20 refused=12 false-refusals=0 unjudged=0' \
    "the replay numbers moved: $(printf '%s\n' "$report" | tail -1)"
  assert_contains "$report" 'refused: rule 1,' "the replay reported no internal-name refusal"
  assert_contains "$report" 'refused: rule 3,' "the replay reported no outcome-line refusal"
  pass "replay: 20 checked, 12 refused, 0 false refusals among the compliant 8; a false refusal fails it"
  # The assertion bites: a compliant message the check refuses fails the replay.
  jq -cn --arg s 'PR 290 is green.' '{verdict: "captain", summary: $s}' > "$d/bad.jsonl"
  printf 'compliant\n' > "$d/bad-labels"
  report=$(replay "$d/bad.jsonl" "$d/bad-labels") && fail "the replay passed a false refusal"
  assert_contains "$report" 'false-refusals=1' "the replay did not count the false refusal"
  [ -z "${JG_CAPTAIN_CARD_STORE:-}" ] || {
    report=$(replay "$JG_CAPTAIN_CARD_STORE" /dev/null) \
      || fail "the real store replay found a refusal: ${report##*$'\n'}"
    pass "replay on a real store: $(printf '%s\n' "$report" | tail -1)"
  }
}

test_the_check_names_each_failing_rule
test_both_captain_facing_paths_run_the_check
test_replay_of_the_last_20_captain_messages
