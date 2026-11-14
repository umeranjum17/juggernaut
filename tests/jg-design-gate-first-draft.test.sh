#!/usr/bin/env bash
# The design-option board check (bin/jg-design-gate.sh board): a judge-only record and hand-authored option HTML are
# refused at a board post by the option's name, and a make or refine record for every option passes. No merge and no
# done is refused on a design receipt any more (pcp-s7), so the old gate functions are gone.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot design-first-draft) || fail "no fixture root"
repo=$root/repo st=$root/taskhome/state
mkdir -p "$st" "$repo"
git -C "$repo" init -q -b main && git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
echo 'body { color: #111; }' > "$repo/app.css"
git -C "$repo" add -A && git -C "$repo" commit -qm base
mkdir -p "$repo/designs"
printf '<html>option a</html>\n' > "$repo/designs/option-a.html"
printf '<html>option b</html>\n' > "$repo/designs/option-b.html"
a=$repo/designs/option-a.html b=$repo/designs/option-b.html

jq -n --arg f "$a" '{file:$f,generator:{agent:"byokit:claude",model:"m"},critique:{score:7}}' > "$st/judge-only.json"
jq -n --arg a "$a" --arg b "$b" '{made:{command:"make",files:[{file:$a},{file:$b}]}}' > "$st/make-both.json"
jq -n --arg a "$a" '{made:{command:"make",files:[{file:$a}]}}' > "$st/make-a.json"
jq -n --arg b "$b" --arg f "$a" '{refined:{from:$f,file:$b}}' > "$st/refine-b.json"
board() { "$ROOT/bin/jg-design-gate.sh" board "$@" 2>&1; }

out=$(board "$st/judge-only.json" "$repo/designs") && fail "board posted on a judge-only receipt: $out"
assert_contains "$out" "judge-only run" "board-post refusal must name the judge-only record"
out=$(board "$st/make-a.json" "$repo/designs") && fail "board posted a hand-authored option: $out"
assert_contains "$out" "option $b has no first-draft make or refine receipt" "board-post refusal must name the option"
out=$(board "$st/no-such-run.json" "$repo/designs") && fail "board posted on a missing run record: $out"
assert_contains "$out" "does not resolve to a run record" "board-post refusal must name the missing record"
pass "a board post of design options is refused for a judge-only receipt and hand-authored HTML"
out=$(board "$st/make-both.json" "$repo/designs") || fail "board refused a make record for every option: $out"
assert_contains "$out" "board: 2 design option(s) made or refined by first-draft" "board pass line"
board "$st/make-a.json,$st/refine-b.json" "$repo/designs" >/dev/null || fail "board refused a make and refine pair"
pass "a board post of design options passes with a make or refine record for every option"

# The generic design gate is gone: the size rule and the hand-roll approval no longer exist as commands or functions.
out=$("$ROOT/bin/jg-design-gate.sh" size "$repo" main HEAD 2>&1) && fail "the size rule still answers: $out"
out=$("$ROOT/bin/jg-design-gate.sh" handroll t1 2>&1) && fail "the hand-roll approval still answers: $out"
# shellcheck source=bin/jg-dod-lib.sh
. "$ROOT/bin/jg-dod-lib.sh"
for fn in jg_dod_design_gate jg_design_done_gate jg_design_size jg_design_handroll_ok; do
  ! declare -F "$fn" >/dev/null || fail "$fn still exists"
done
pass "no size rule, hand-roll approval or design merge/done gate remains"
