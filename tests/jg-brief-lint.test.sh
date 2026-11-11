#!/usr/bin/env bash
# bin/jg-brief-lint.sh against the shipped rule table (defaults/brief-lint-rules.tsv):
# a brief holding copies of the three disagreeing wait-word lines (39, 185, 190) and the two
# skill names that are not installed (lines 157, 169) of a real 9 Nov brief is reported
# with those line numbers; a prohibition and a path are not taken for a skill; a fixed
# brief is clean; the trunk PR-body conflict and the byte budget are reported; a skill in the
# repository or in $HOME/.agents/skills and a command on PATH are there, and a script's argument,
# a journey name or an adjective is no name; a bad row, pattern or file is refused with exit 2.
# shellcheck disable=SC2016 # brief text quotes markdown backticks literally
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-brief-lint)
LINT="$ROOT/bin/jg-brief-lint.sh"
SKILLS="$TMP_ROOT/skills"

# Copies of lines of data/fable-opportunity-recon/brief.md (9 Nov 2026), at their own line numbers.
L39='   Use `paused: {why}` - never `blocked:` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.'
L149='- Expo or store release: run eas-app-stores. Done = build visible in TestFlight with processing complete. Use npx. Never run submit-expo-feedback. Paid EAS builds need firstmate'"'"'s approval.'
L157='- REQUIRED: if the repo has `.agents/skills/verify-<app>/SKILL.md`, run it on the real product. Else run verification-before-completion and write "no verify skill". When the skill is wrong, stale or misses a needed proof, update it with maintain-verification-skill in this task (a project with no verify skill: tell your lead to file create-verification-skill).'
L169='- User-visible change: if the skill cannot capture one of these, extend the skill (maintain-verification-skill) in this task or a linked one; do not hand-capture around it.'
L185='- WAITING = `blocked:` (captain, 4 Oct; this replaces any `paused:` advice in this brief). Name what you wait for and when you expect it to clear.'
L190='- A wait on your own running work (a scan, a test, a measurement) is `paused:` with the expected time, not `blocked:`; `blocked:` is only for a wait on someone else (lead note).'

# brief <file> <line>=<text>...: filler lines with the given texts at their line numbers.
brief() {
  local file=$1 n spec
  shift
  local -A at=()
  for spec in "$@"; do at[${spec%%=*}]=${spec#*=}; done
  for n in $(seq 1 200); do
    if [ -n "${at[$n]+x}" ]; then printf '%s\n' "${at[$n]}"; else printf 'Filler line %s of the brief.\n' "$n"; fi
  done > "$file"
}

skill() { mkdir -p "$1/$2" && printf -- '---\nname: %s\n---\n' "$2" > "$1/$2/SKILL.md"; }

for s in eas-app-stores verification-before-completion systematic-debugging; do skill "$SKILLS" "$s"; done

test_real_brief_lines() {
  local f="$TMP_ROOT/recon-brief.md" out code
  brief "$f" "39=$L39" "149=$L149" "157=$L157" "169=$L169" "185=$L185" "190=$L190" \
    '120=- Run systematic-debugging before the first fix; `bin/jg-made-up-skill.sh` is a path.'
  out=$("$LINT" --skills-dir "$SKILLS" "$f"); code=$?
  assert_equals 1 "$code" "findings exit 1"
  assert_equals "$f:39,185,190: conflict wait-word: 39,190 vs 185: one rule says a wait is \`paused:\` and not \`blocked:\`, the other says a wait is \`blocked:\`
$f:157,169: dead-name maintain-verification-skill: no skill or command of that name
$f:157: dead-name create-verification-skill: no skill or command of that name" "$out" \
    "the wait-word conflict of lines 39, 185 and 190 and the two missing skills, each with its lines"
  pass "the three disagreeing lines and the two missing skill names of the 9 Nov brief are reported"
}

test_fixed_brief_is_clean() {
  local f="$TMP_ROOT/fixed-brief.md" skills="$TMP_ROOT/skills-all" out code s
  for s in eas-app-stores verification-before-completion systematic-debugging maintain-verification-skill create-verification-skill; do
    skill "$skills" "$s"
  done
  brief "$f" "39=$L39" "149=$L149" "157=$L157" "169=$L169" "190=$L190"
  out=$("$LINT" --skills-dir "$skills" "$f"); code=$?
  assert_equals 0 "$code" "a clean brief exits 0"
  assert_equals "" "$out" "a clean brief prints nothing"
  pass "with the 'every wait is blocked' line gone and the skills installed, the brief is clean"
}

test_trunk_pr_body_and_budget() {
  local f="$TMP_ROOT/trunk-brief.md" rules="$TMP_ROOT/budget.tsv" out code past
  brief "$f" '30=This project is registered local-trunk: there is no feature pull request, and the only pull request is the release one.' \
    '120=   c. Put a `## Checks` block in the PR body with four lines.'
  out=$("$LINT" --skills-dir "$SKILLS" "$f"); code=$?
  assert_equals 1 "$code" "a trunk brief that writes a PR body has a finding"
  assert_equals "$f:30,120: conflict pr-body-on-trunk: 30 vs 120: one rule says there is no feature pull request, the other puts text in the PR body" "$out" \
    "the trunk lane's PR-body step is reported against the no-PR rule"
  printf 'budget\tsmall\t1000\n' > "$rules"
  out=$("$LINT" --rules "$rules" --skills-dir "$SKILLS" "$f"); code=$?
  assert_equals 1 "$code" "an over-budget file has a finding"
  past=$(awk '{ n += length($0) + 1 } n > 1000 { print NR; exit }' "$f")
  assert_equals "$f:$past: over-budget small: $(wc -c < "$f" | tr -d ' ') bytes, budget 1000" "$out" \
    "the size, the budget and the first line past it are reported"
  pass "the trunk PR-body conflict and the byte budget are reported with their lines"
}

test_what_counts_as_there() {
  local home="$TMP_ROOT/home" tooldir="$TMP_ROOT/tools" f="$TMP_ROOT/defaults-brief.md" out code
  skill "$home/.agents/skills" home-only-skill-x
  mkdir -p "$tooldir" && printf '#!/bin/sh\n' > "$tooldir/fake-tool-x" && chmod +x "$tooldir/fake-tool-x"
  brief "$f" '5=Load the `prior-art` skill for the procedure.' '6=Then run home-only-skill-x.' '7=Then run nowhere-skill-x.' \
    '8=Run fake-tool-x with the same arguments.' \
    "9=Register it: \`jg-scratch.sh' register made-up-task-skill <dir>\`, then done-done run made-up-journey-x." \
    '10=Read the agent-only skills and the always-on skill listing.'
  out=$(HOME="$home" PATH="$tooldir:$PATH" "$LINT" "$f"); code=$?
  assert_equals 1 "$code" "the missing skill is a finding"
  assert_equals "$f:7: dead-name nowhere-skill-x: no skill or command of that name" "$out" \
    "only the name that is neither a skill nor a command is reported"
  pass "a repository skill, a \$HOME/.agents/skills skill and a command are there; a script argument, a journey and an adjective are not names"
}

test_bad_input_exits_2() {
  local f="$TMP_ROOT/ok.md" rules="$TMP_ROOT/bad.tsv" err
  printf 'nothing to see\n' > "$f"
  err=$("$LINT" --skills-dir "$SKILLS" "$TMP_ROOT/absent.md" 2>&1); expect_code 2 $? "an unreadable file"
  assert_contains "$err" "cannot read $TMP_ROOT/absent.md" "the unreadable file is named"
  printf '# ok\nconflict\tonly-one\tpattern\n' > "$rules"
  err=$("$LINT" --rules "$rules" "$f" 2>&1); expect_code 2 $? "a short conflict row"
  assert_contains "$err" "$rules:2: a conflict row is" "the bad row is named by file and line"
  printf 'conflict\tbroken\t(unclosed\tok\twhy\n' > "$rules"
  err=$("$LINT" --rules "$rules" "$f" 2>&1); expect_code 2 $? "a pattern that is not a regular expression"
  assert_contains "$err" "$rules:1: not an extended regular expression: (unclosed" "the bad pattern is named"
  err=$("$LINT" 2>&1); expect_code 2 $? "no file named"
  pass "an unreadable file, a bad row, a bad pattern and no file are refused with exit 2"
}

test_real_brief_lines
test_fixed_brief_is_clean
test_trunk_pr_body_and_budget
test_what_counts_as_there
test_bad_input_exits_2
echo "brief lint: disagreeing rules, missing skill names and the byte budget are reported with their lines"
