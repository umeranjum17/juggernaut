#!/usr/bin/env bash
# Behavior tests for bin/jg-recon-gate.sh.
#
# A standard or deep Recon may not report done on a shallow report. The tests
# scaffold each Recon with the real bin/jg-brief.sh (so the depth line the gate
# reads is the one workers get), fill data/<task>/ with a complete fixture that
# must pass, and then break the fixture one way at a time: every refusal has its
# own failing fixture. Quick is exempt, and so is a brief with no depth line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/jg-recon-gate.sh"
TMP_ROOT=$(jg_test_tmproot jg-recon-gate)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

SECTIONS=(
  "Answer" "What was asked" "Method and depth record" "Prior art and options"
  "Findings" "Design" "Not checked" "Implementation plan"
  "Risks and mitigations" "Open decisions" "Acceptance test"
  "Sources and evidence" "Revision log"
)

run_gate() {  # <task> [gate args...]: sets OUT and RC
  local task=$1; shift
  OUT=$(JG_HOME="$HOME_DIR" bash "$GATE" "$task" "$@" 2>&1); RC=$?
}

# A passing Recon of the given depth: the real scaffold, then every file the
# method writes. Deep adds sources, two-source claims and a separate critic.
make_recon() {  # <task> <level>
  local id=$1 level=$2 dir n kind sources_n kinds=(code docs upstream oss community run) title
  dir="$HOME_DIR/data/$id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" some-proj --scout --depth "$level" >/dev/null 2>&1 \
    || fail "jg-brief.sh $id --scout --depth $level should scaffold"
  sources_n=8; [ "$level" != deep ] || sources_n=20
  : > "$dir/sources.jsonl"
  for n in $(seq 1 "$sources_n"); do
    kind=${kinds[$((n % 5))]}
    printf '{"id":"S-%d","kind":"%s","title":"source %d","link":"x/%d","read":"2026-11-05"}\n' "$n" "$kind" "$n" "$n" >> "$dir/sources.jsonl"
  done
  printf '%s\n' \
    '{"id":"C-1","text":"first load-bearing claim","kind":"fact","sources":["S-1","S-2"],"load_bearing":true}' \
    '{"id":"C-2","text":"a side note","kind":"opinion","sources":["S-3"],"load_bearing":false}' \
    '{"id":"C-10","text":"second load-bearing claim","kind":"measure","sources":["S-4","S-5"],"load_bearing":true}' > "$dir/claims.jsonl"
  printf '%s\n' \
    '{"claim":"C-1","status":"verified","method":"reread","note":"exact words match"}' \
    '{"claim":"C-10","status":"verified","method":"run","note":"re-measured"}' > "$dir/checks.jsonl"
  {
    printf '# Report\n\n'
    n=1
    for title in "${SECTIONS[@]}"; do
      printf '## %d. %s\n' "$n" "$title"
      if [ "$title" = "Not checked" ]; then printf 'Nothing load-bearing is left unchecked; C-2 is an opinion.\n\n'
      else printf 'Body of %s, citing [C-1] and [C-10].\n\n' "$title"; fi
      n=$((n + 1))
    done
  } > "$dir/report.md"
  if [ "$level" = deep ]; then
    printf 'Critic: critic-of-%s\nRound 1: new gaps 2\n- a gap\nRound 2: new gaps 0\n' "$id" > "$dir/critic.md"
  else
    printf 'Critic: self\nRound 1: new gaps 0\n' > "$dir/critic.md"
  fi
}

expect_refused() {  # <task> <fragment> <label>
  run_gate "$1"
  expect_code 1 "$RC" "$3: should be refused (got: $OUT)"
  assert_contains "$OUT" "$2" "$3: the refusal did not say why (got: $OUT)"
}

test_passing_recons_pass() {
  make_recon rg-std standard
  run_gate rg-std
  expect_code 0 "$RC" "a complete standard Recon should pass (got: $OUT)"
  assert_contains "$OUT" "PASS" "the pass line did not say PASS"
  make_recon rg-deep deep
  run_gate rg-deep
  expect_code 0 "$RC" "a complete deep Recon should pass (got: $OUT)"
  pass "jg-recon-gate.sh: a complete standard and a complete deep Recon pass"
}

test_missing_and_empty_sections_are_refused() {
  local dir
  make_recon rg-nosec standard
  dir="$HOME_DIR/data/rg-nosec"
  grep -v '^## 6\. Design$' "$dir/report.md" > "$dir/r" && mv "$dir/r" "$dir/report.md"
  expect_refused rg-nosec "no section '## 6. Design'" "a report missing its Design section"
  make_recon rg-empty standard
  dir="$HOME_DIR/data/rg-empty"
  awk '/^## 9\. /{print; skip=1; next} skip && /^## /{skip=0} !skip' "$dir/report.md" > "$dir/r" && mv "$dir/r" "$dir/report.md"
  expect_refused rg-empty "section 9 'Risks and mitigations' is empty" "a report with an empty section"
  make_recon rg-noreport standard
  rm -f "$HOME_DIR/data/rg-noreport/report.md"
  expect_refused rg-noreport "report.md is missing" "a Recon with no report"
  pass "jg-recon-gate.sh: a missing, empty or absent report section is refused"
}

test_deep_may_not_skip_plan_or_acceptance() {
  local dir
  make_recon rg-deep-na deep
  dir="$HOME_DIR/data/rg-deep-na"
  sed -i '/^## 8\. Implementation plan$/{n;s/.*/Not applicable - nothing to build./}' "$dir/report.md"
  expect_refused rg-deep-na "may not write 'Not applicable' under section 8" "a deep report that skips its plan"
  make_recon rg-std-na standard
  dir="$HOME_DIR/data/rg-std-na"
  sed -i '/^## 8\. Implementation plan$/{n;s/.*/Not applicable - a pure question./}' "$dir/report.md"
  run_gate rg-std-na
  expect_code 0 "$RC" "a standard report may mark section 8 not applicable (got: $OUT)"
  pass "jg-recon-gate.sh: deep needs a real plan and acceptance test, standard may decline them"
}

test_unverified_load_bearing_claims() {
  local dir
  make_recon rg-unver standard
  dir="$HOME_DIR/data/rg-unver"
  printf '%s\n' '{"claim":"C-10","status":"unverified","method":"reread","note":"source gone"}' >> "$dir/checks.jsonl"
  expect_refused rg-unver "load-bearing claim C-10 is unverified" "an unverified load-bearing claim left out of Not checked"
  sed -i 's/^Nothing load-bearing is left unchecked; C-2 is an opinion\.$/Not checked: C-10 could not be re-read./' "$dir/report.md"
  run_gate rg-unver
  expect_code 0 "$RC" "an unverified claim listed under Not checked should pass (got: $OUT)"
  make_recon rg-nocheck standard
  dir="$HOME_DIR/data/rg-nocheck"
  grep -v '"C-1"' "$dir/checks.jsonl" > "$dir/c" && mv "$dir/c" "$dir/checks.jsonl"
  expect_refused rg-nocheck "load-bearing claim C-1 is unverified" "a load-bearing claim with no check row"
  make_recon rg-prefix standard
  dir="$HOME_DIR/data/rg-prefix"
  printf '%s\n' '{"claim":"C-1","status":"single-source","method":"reread","note":"one source"}' >> "$dir/checks.jsonl"
  sed -i 's/^Nothing load-bearing is left unchecked; C-2 is an opinion\.$/Not checked: C-10 only./' "$dir/report.md"
  expect_refused rg-prefix "load-bearing claim C-1 is single-source" "C-10 in Not checked must not cover C-1"
  pass "jg-recon-gate.sh: a load-bearing claim must be verified or named under Not checked"
}

test_refuted_and_single_source_deep_claims() {
  local dir
  make_recon rg-refuted standard
  dir="$HOME_DIR/data/rg-refuted"
  printf '%s\n' '{"claim":"C-1","status":"refuted","method":"reread","note":"source says the opposite"}' >> "$dir/checks.jsonl"
  sed -i 's/^Nothing load-bearing is left unchecked; C-2 is an opinion\.$/Not checked: C-1 was refuted./' "$dir/report.md"
  expect_refused rg-refuted "refuted claim C-1 is still cited" "a refuted claim still cited in the findings"
  make_recon rg-onesrc deep
  dir="$HOME_DIR/data/rg-onesrc"
  printf '%s\n' '{"id":"C-1","text":"one source only","kind":"fact","sources":["S-1"],"load_bearing":true}' > "$dir/c"
  grep -v '"C-1"' "$dir/claims.jsonl" >> "$dir/c" && mv "$dir/c" "$dir/claims.jsonl"
  expect_refused rg-onesrc "C-1 is verified on one source with no hands-on run" "a deep claim verified on one source"
  pass "jg-recon-gate.sh: a refuted claim may not be cited and a deep claim needs two sources or a run"
}

test_critic_is_required() {
  local dir
  make_recon rg-nocritic standard
  rm -f "$HOME_DIR/data/rg-nocritic/critic.md"
  expect_refused rg-nocritic "critic.md is missing" "a Recon with no critic"
  make_recon rg-gaps standard
  dir="$HOME_DIR/data/rg-gaps"
  printf 'Critic: self\nRound 1: new gaps 3\n' > "$dir/critic.md"
  expect_refused rg-gaps "found 3 new gaps" "a critic whose last round found new gaps"
  make_recon rg-norounds standard
  printf 'Critic: self\nlooks fine\n' > "$HOME_DIR/data/rg-norounds/critic.md"
  expect_refused rg-norounds "no 'Round <n>: new gaps <k>' line" "a critic file with no round line"
  make_recon rg-self deep
  printf 'Critic: self\nRound 1: new gaps 0\n' > "$HOME_DIR/data/rg-self/critic.md"
  expect_refused rg-self "needs a separate critic worker" "a deep Recon whose critic is the researcher"
  make_recon rg-own deep
  printf 'Critic: rg-own\nRound 1: new gaps 0\n' > "$HOME_DIR/data/rg-own/critic.md"
  expect_refused rg-own "needs a separate critic worker" "a deep Recon whose critic names its own task id"
  make_recon rg-four deep
  printf 'Critic: other-worker\nRound 1: new gaps 2\nRound 2: new gaps 1\nRound 3: new gaps 1\nRound 4: new gaps 1\nClosure check: 1 closed by other-worker\n' > "$HOME_DIR/data/rg-four/critic.md"
  expect_refused rg-four "allows 3" "a deep critic that ran a fourth new-gap round"
  pass "jg-recon-gate.sh: the critic must exist, be separate for deep, and end on a round with no new gaps"
}

# K6: a gap found in the last round can be fixed but never re-checked by a
# further round, so a closure line by the same critic stands in for that round.
test_closure_check_closes_the_last_round() {
  local dir
  make_recon rg-close deep
  printf 'Critic: other-worker\nRound 1: new gaps 2\nRound 2: new gaps 1\nRound 3: new gaps 2\n- gap a\n- gap b\nClosure check: 2 closed by other-worker\n' > "$HOME_DIR/data/rg-close/critic.md"
  run_gate rg-close
  expect_code 0 "$RC" "a third-round gap closed by the same critic should pass (got: $OUT)"
  make_recon rg-three-zero deep
  printf 'Critic: other-worker\nRound 1: new gaps 2\nRound 2: new gaps 1\nRound 3: new gaps 1\nClosure check: 1 closed by other-worker\nRound 4: new gaps 0\n' > "$HOME_DIR/data/rg-three-zero/critic.md"
  run_gate rg-three-zero
  expect_code 0 "$RC" "three new-gap rounds then a clean round should pass: the cap counts new-gap rounds (got: $OUT)"
  make_recon rg-other deep
  printf 'Critic: other-worker\nRound 1: new gaps 1\nClosure check: 1 closed by someone-else\n' > "$HOME_DIR/data/rg-other/critic.md"
  expect_refused rg-other "not the critic 'other-worker'" "a closure by a different worker"
  make_recon rg-selfclose deep
  printf 'Critic: other-worker\nRound 1: new gaps 1\nClosure check: 1 closed by self\n' > "$HOME_DIR/data/rg-selfclose/critic.md"
  expect_refused rg-selfclose "closure check" "a closure the researcher certifies itself"
  make_recon rg-owncl deep
  printf 'Critic: other-worker\nRound 1: new gaps 1\nClosure check: 1 closed by rg-owncl\n' > "$HOME_DIR/data/rg-owncl/critic.md"
  expect_refused rg-owncl "closure check" "a closure naming the researcher's own task id"
  make_recon rg-short deep
  printf 'Critic: other-worker\nRound 1: new gaps 3\nClosure check: 2 closed by other-worker\n' > "$HOME_DIR/data/rg-short/critic.md"
  expect_refused rg-short "closes 2 of 3" "a closure that leaves a gap open"
  make_recon rg-stale deep
  printf 'Critic: other-worker\nRound 1: new gaps 1\nClosure check: 1 closed by other-worker\nRound 2: new gaps 2\n' > "$HOME_DIR/data/rg-stale/critic.md"
  expect_refused rg-stale "round 2 found 2 new gaps" "a closure written before the last round"
  make_recon rg-stdself standard
  printf 'Critic: self\nRound 1: new gaps 1\nClosure check: 1 closed by self\n' > "$HOME_DIR/data/rg-stdself/critic.md"
  expect_refused rg-stdself "closure check" "a standard self-critic certifying its own closure"
  pass "jg-recon-gate.sh: a closure check by the same separate critic closes the last round's gaps, never a self-certified one"
}

test_source_budget() {
  local dir
  make_recon rg-few standard
  dir="$HOME_DIR/data/rg-few"
  head -7 "$dir/sources.jsonl" > "$dir/s" && mv "$dir/s" "$dir/sources.jsonl"
  expect_refused rg-few "source budget not met for standard: 7 sources" "a standard Recon with 7 sources"
  make_recon rg-kinds standard
  dir="$HOME_DIR/data/rg-kinds"
  sed -i 's/"kind":"[a-z]*"/"kind":"code"/' "$dir/sources.jsonl"
  expect_refused rg-kinds "over 1 kinds, need 8 over 3" "a standard Recon with one source kind"
  make_recon rg-deep-few deep
  dir="$HOME_DIR/data/rg-deep-few"
  head -19 "$dir/sources.jsonl" > "$dir/s" && mv "$dir/s" "$dir/sources.jsonl"
  expect_refused rg-deep-few "need 20 over 5" "a deep Recon with 19 sources"
  pass "jg-recon-gate.sh: the source budget of the level is enforced"
}

test_quick_and_legacy_are_exempt() {
  local dir
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" rg-quick some-proj --scout --depth quick >/dev/null 2>&1 || fail "quick scaffold failed"
  run_gate rg-quick
  expect_code 0 "$RC" "a quick Recon with nothing else should pass (got: $OUT)"
  assert_contains "$OUT" "exempt" "the quick pass line did not say it is exempt"
  dir="$HOME_DIR/data/rg-legacy"
  mkdir -p "$dir"; printf '# Task\nno depth line here\n' > "$dir/brief.md"
  run_gate rg-legacy
  expect_code 0 "$RC" "a brief with no depth line is a quick Recon (got: $OUT)"
  run_gate rg-quick --depth standard
  expect_code 1 "$RC" "an explicit --depth standard overrides the brief (got: $OUT)"
  pass "jg-recon-gate.sh: quick and a legacy brief are exempt, and --depth overrides the brief"
}

test_a_critic_task_passes_on_its_critic_md() {
  local dir=$HOME_DIR/data/rg-critic
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" rg-critic some-proj --scout --depth deep >/dev/null 2>&1 || fail "critic scaffold failed"
  run_gate rg-critic
  expect_code 1 "$RC" "a deep task with no report and no critic.md is refused (got: $OUT)"
  printf 'Critic: rg-critic\nRound 1: new gaps 2\n- a gap\n' > "$dir/critic.md"
  run_gate rg-critic
  expect_code 0 "$RC" "a critic task passes on its critic.md, with no report (got: $OUT)"
  assert_contains "$OUT" "critic task" "the pass line did not say it judged a critic task"
  JG_HOME="$HOME_DIR" bash "$GATE" rg-critic --is-critic || fail "--is-critic should accept the critic task"
  printf 'Critic: rg-critic\n' > "$dir/critic.md"
  expect_refused rg-critic "no 'Round <n>: new gaps <k>' line" "a critic.md with no round line"
  printf 'Critic: someone-else\nRound 1: new gaps 0\n' > "$dir/critic.md"
  expect_refused rg-critic "report.md is missing" "a critic.md naming another critic is not a critic task"
  make_recon rg-notcritic deep
  JG_HOME="$HOME_DIR" bash "$GATE" rg-notcritic --is-critic && fail "a researcher is not a critic task"
  pass "jg-recon-gate.sh: a critic task passes on its critic.md and a researcher is not one"
}

test_the_owners_bypass_lets_a_recon_through_and_a_waiver_by_main_does_not() {
  local wdir=$HOME_DIR/state/recon-gate-waiver
  make_recon rg-waive deep
  rm -f "$HOME_DIR/data/rg-waive/report.md"
  expect_refused rg-waive "report.md is missing" "a deep Recon with no report, no bypass yet"
  # A waiver file by Main alone is refused, with the reason.
  mkdir -p "$wdir"
  printf 'waived-by: Main\nreason: the owner dropped the report\n' > "$wdir/rg-waive"
  expect_refused rg-waive "no longer read" "a whole waiver file by Main"
  expect_refused rg-waive "owner's recorded bypass" "the refusal names the way through"
  # The owner's bypass, written by the real command, passes the gate and says whose word it is.
  JG_HOME="$HOME_DIR" bash "$ROOT/bin/jg-proof-bypass.sh" grant --ticket rg-waive --word owner-rule-abc123 >/dev/null 2>&1 \
    || fail "could not grant the ticket bypass"
  run_gate rg-waive
  expect_code 0 "$RC" "a ticket bypass passes the gate (got: $OUT)"
  assert_contains "$OUT" "BYPASSED by the owner's word owner-rule-abc123" "the pass line did not say whose word it is"
  make_recon rg-nowaive deep
  rm -f "$HOME_DIR/data/rg-nowaive/report.md"
  expect_refused rg-nowaive "report.md is missing" "a ticket bypass for one task does not cover another"
  pass "jg-recon-gate.sh: the owner's bypass passes a Recon and prints whose word it is; a waiver by Main is refused"
}

test_a_deep_draft_with_only_its_critic_open_is_the_step_critic() {
  local dir
  make_recon rg-step deep
  dir="$HOME_DIR/data/rg-step"
  rm -f "$dir/critic.md"
  run_gate rg-step
  expect_code 1 "$RC" "the plain gate refuses a deep Recon whose critic is open (got: $OUT)"
  run_gate rg-step --step
  expect_code 0 "$RC" "the step reading lets the draft through to its critic (got: $OUT)"
  assert_contains "$OUT" "STEP critic" "the step line did not name the step critic (got: $OUT)"
  printf 'Critic: critic-of-rg-step\nRound 1: new gaps 2\n- a gap\n' > "$dir/critic.md"
  run_gate rg-step --step
  expect_code 0 "$RC" "a round with open gaps is still the step critic (got: $OUT)"
  assert_contains "$OUT" "STEP critic" "round with gaps: not the step critic (got: $OUT)"
  printf 'Critic: critic-of-rg-step\nRound 1: new gaps 0\n' > "$dir/critic.md"
  run_gate rg-step --step
  expect_code 0 "$RC" "a closed critic passes (got: $OUT)"
  assert_contains "$OUT" "PASS" "a closed critic is PASS, not the step critic (got: $OUT)"
  rm -f "$dir/critic.md"; sed -i '/^## 5\./,/^$/d' "$dir/report.md"
  run_gate rg-step --step
  expect_code 1 "$RC" "a draft with a hole other than the critic is still refused (got: $OUT)"
  make_recon rg-step-std standard
  rm -f "$HOME_DIR/data/rg-step-std/critic.md"
  run_gate rg-step-std --step
  expect_code 1 "$RC" "a standard Recon has no critic step (got: $OUT)"
  pass "jg-recon-gate.sh --step: a deep draft with only its separate critic open is the step critic; any other hole, or a standard Recon, is refused"
}

test_usage_errors() {
  local out rc
  out=$(JG_HOME="$HOME_DIR" bash "$GATE" 2>&1); rc=$?
  expect_code 2 "$rc" "no task id should be a usage error (got: $out)"
  out=$(JG_HOME="$HOME_DIR" bash "$GATE" no-such-task 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown task should be a usage error (got: $out)"
  out=$(JG_HOME="$HOME_DIR" bash "$GATE" ../x 2>&1); rc=$?
  expect_code 2 "$rc" "a path-like task id should be refused (got: $out)"
  pass "jg-recon-gate.sh: usage errors exit 2"
}

test_board_report_is_written_by_the_command() {
  local dir page card first
  make_recon rg-page standard
  dir="$HOME_DIR/data/rg-page"
  page="$dir/board-report/page.html"; card="$dir/board-report/report.json"
  sed -i '/^## 8\. Implementation plan$/,/^## 9\. /{/^Body of/c\
| Slice | Owner | Outcome |\
| --- | --- | --- |\
| J1 | lead | The ticket table is the first drawing |
}' "$dir/report.md"
  printf '%s\n' '{"key":"rg-page-1","title":"Page of {{count:moves}} moves","filed":"2026-11-12T00:00:00Z","filer":"rg-page","project":"Juggernaut",' \
    ' "drawings":[{"label":"Delivering","machine":"delivering"}],' \
    ' "counts":[{"label":"Moves the table lacks","ledger":"moves"}]}' > "$dir/page.json"
  printf 'moves\t230\tshadow log\n' > "$dir/ledger.tsv"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-report-page.sh" build rg-page >/dev/null || fail "the page should build"
  first=$(cat "$page" "$card")
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-report-page.sh" build rg-page >/dev/null
  [ "$first" = "$(cat "$page" "$card")" ] || fail "two builds from the same sources should match byte for byte"
  assert_contains "$(cat "$page")" "resolving" "the page should draw the machine's states from its table"
  assert_contains "$(cat "$card")" '"title": "Page of 230 moves"' "the card should take the count from the ledger"
  assert_contains "$(cat "$card")" '"title": "J1"' "the card should take the plan from section 8"
  run_gate rg-page
  expect_code 0 "$RC" "a page the command wrote should pass (got: $OUT)"
  printf 'moves\t231\tshadow log\n' > "$dir/ledger.tsv"
  expect_refused rg-page "board-report/page.html is stale" "a ledger count that changed after the build"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-report-page.sh" build rg-page >/dev/null
  assert_contains "$(cat "$card")" "Page of 231 moves" "a changed ledger count should change the card on the next run"
  sed -i 's/resolving/resolvingX/' "$page"
  expect_refused rg-page "board-report/page.html was edited by hand" "a hand edit of the page"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-report-page.sh" build rg-page >/dev/null
  sed -i 's/"project": "Juggernaut"/"project": "Other"/' "$card"
  expect_refused rg-page "board-report/report.json was edited by hand" "a hand edit of the card"
  printf '{"title":"typed"}\n' > "$card"
  expect_refused rg-page "board-report/report.json carries no jg-report-page stamp" "a card the command did not write"
  pass "jg-recon-gate.sh: a board page and card must be written by jg-report-page.sh"
}

test_passing_recons_pass
test_missing_and_empty_sections_are_refused
test_deep_may_not_skip_plan_or_acceptance
test_unverified_load_bearing_claims
test_refuted_and_single_source_deep_claims
test_critic_is_required
test_closure_check_closes_the_last_round
test_source_budget
test_quick_and_legacy_are_exempt
test_a_critic_task_passes_on_its_critic_md
test_the_owners_bypass_lets_a_recon_through_and_a_waiver_by_main_does_not
test_a_deep_draft_with_only_its_critic_open_is_the_step_critic
test_usage_errors
test_board_report_is_written_by_the_command
