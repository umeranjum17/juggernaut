#!/usr/bin/env bash
# The first-draft rule end to end (bin/jg-merge-gate-lib.sh, bin/jg-dod-lib.sh,
# bin/jg-design-gate.sh): a judge-only receipt and hand-authored option HTML are refused
# at done and at a board post by the option's name, a make or refine record for every
# option passes both, and an ordinary task stays unaffected.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot design-first-draft) || fail "no fixture root"
repo=$root/repo st=$root/taskhome/state
mkdir -p "$st" "$repo"
# shellcheck source=bin/jg-dod-lib.sh
. "$ROOT/bin/jg-dod-lib.sh"

git -C "$repo" init -q -b main && git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
echo 'body { color: #111; }' > "$repo/app.css"
git -C "$repo" add -A && git -C "$repo" commit -qm base
git -C "$repo" checkout -q -b work && mkdir -p "$repo/designs"
printf '<html>option a</html>\n' > "$repo/designs/option-a.html"
printf '<html>option b</html>\n' > "$repo/designs/option-b.html"
git -C "$repo" add -A && git -C "$repo" commit -qm options
head=$(git -C "$repo" rev-parse HEAD)
a=$repo/designs/option-a.html b=$repo/designs/option-b.html

# The records real first-draft runs print: make and refine name the page they generated,
# a judge run names only what it scored.
jq -n --arg f "$a" '{file:$f,generator:{agent:"byokit:claude",model:"m"},critique:{score:7}}' > "$st/judge-only.json"
jq -n --arg a "$a" --arg b "$b" '{made:{command:"make",files:[{file:$a},{file:$b}]}}' > "$st/make-both.json"
jq -n --arg a "$a" '{made:{command:"make",files:[{file:$a}]}}' > "$st/make-a.json"
jq -n --arg b "$b" --arg f "$a" '{refined:{from:$f,file:$b}}' > "$st/refine-b.json"
meta() {  # <id> <extra meta lines...>
  local id=$1
  shift
  { printf 'worktree=%s\nbase_branch=main\nmode=direct-PR\nproject=some-proj\nkind=ship\n' "$repo"
    for line in "$@"; do printf '%s\n' "$line"; done; } > "$st/$id.meta"
}
receipt() {  # <id> <head> [<first-draft receipt ref>]
  local e='ran tests'
  [ -z "${3:-}" ] || e="$e
first-draft receipt: $3"
  jq -n --arg t "$1" --arg h "$2" --arg e "$e" '{schema:1,task:$t,head:$h,verdict:"PASS",evidence:$e,at:1}' > "$st/$1.run-receipt.json"
}
done_gate() { jg_design_done_gate "$st" "$1" "$st/$1.meta" "$head" 2>&1; }

meta d1 design_call=yes
receipt d1 "$head" "$st/judge-only.json"
out=$(done_gate d1) && fail "done accepted a judge-only receipt: $out"
assert_contains "$out" "judge-only run" "done refusal must name the judge-only record"
receipt d1 "$head" "$st/make-a.json"
out=$(done_gate d1) && fail "done accepted hand-authored option HTML: $out"
assert_contains "$out" "option $b has no first-draft make or refine receipt" "done refusal must name the option"
pass "done refuses a judge-only receipt and hand-authored option HTML by name"

receipt d1 "$head" "$st/no-such-run.json"
out=$(done_gate d1) && fail "done accepted a reference to no run record: $out"
assert_contains "$out" "does not resolve to a run record" "an unresolvable reference must be refused"
receipt d1 "$head"
out=$(done_gate d1) && fail "done accepted a design task with no receipt line: $out"
assert_contains "$out" "first-draft receipt" "the refusal must name the missing line"
pass "done refuses an unresolvable reference and a missing first-draft receipt line"
receipt d1 "$head" "$st/make-both.json"
out=$(done_gate d1) || fail "done refused a make record that lists every option: $out"
receipt d1 "$head" "$st/make-a.json,$st/refine-b.json"
out=$(done_gate d1) || fail "done refused a make and refine pair: $out"
pass "done accepts a make or refine record for every option"
# The shared done acceptance runs the gate, so a judge-only receipt stops the lane.
receipt d1 "$head" "$st/judge-only.json"
out=$(jg_dod_accept_ship_done ship direct-PR "$repo" some-proj "done: PR https://github.com/o/r/pull/7" \
  "$st" d1 "$st/d1.meta" 2>&1) && fail "the done acceptance passed: $out"
assert_contains "$out" "judge-only run" "the done acceptance must refuse at the first-draft gate"
pass "a ship done is refused while a design task's first-draft receipt is judge-only"
# The board-post boundary runs the same check before design options are shown.
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
# The merge path resolves the receipt too (scope: a non-design task, and a code task
# whose screens are not option pages).
meta m1 design_call=yes
receipt m1 "$head" "$st/judge-only.json"
out=$(jg_dod_design_gate "$st" m1 "$st/m1.meta" "$head" 2>&1) && fail "merge gate passed a judge-only receipt"
assert_contains "$out" "judge-only run" "merge refusal must resolve the receipt"
git -C "$repo" checkout -q main && git -C "$repo" checkout -q -b code
echo 'export const x = 1;' > "$repo/screen.tsx"
git -C "$repo" add -A && git -C "$repo" commit -qm screen
code_head=$(git -C "$repo" rev-parse HEAD)
meta c1 design_call=no
receipt c1 "$code_head" "$st/make-both.json"
jg_design_done_gate "$st" c1 "$st/c1.meta" "$code_head" >/dev/null \
  || fail "a code task that adds .tsx screens was refused for having no .html option"
meta c2
jg_design_done_gate "$st" c2 "$st/c2.meta" "$(git -C "$repo" rev-parse main)" >/dev/null || fail "a non-design task was refused"
pass "the merge gate resolves the receipt, and an ordinary task and a code task stay unaffected"

# One lane, several pull requests: the copy sits at a later slice that carries no receipt,
# while the pull request being merged holds a PASS receipt with its first-draft line. The
# design rule is measured at that pull request's head (the forge head, else the recorded
# pr_head), never the copy's HEAD, and a PR head with no first-draft line still refuses.
git -C "$repo" checkout -q work
pr_head=$(git -C "$repo" rev-parse HEAD)
printf 'later slice\n' > "$repo/slice2.txt"
git -C "$repo" add -A && git -C "$repo" commit -qm 'second slice'
later_head=$(git -C "$repo" rev-parse HEAD)
[ "$later_head" != "$pr_head" ] || fail "fixture: the later slice must move HEAD"
# Forge reads after the design gate are not this test's subject.
jg_dod_pr_checks_clear() { return 0; }
jg_dod_recorded_pr_on_forge() { return 0; }
jg_dod_pr_outside_origin() { return 0; }
jg_receipts_accept_done() { return 0; }
pr_url=https://github.com/o/r/pull/7
accept() {  # <id> [<forge-head>]
  jg_dod_accept_ship_done ship direct-PR "$repo" some-proj "done: PR $pr_url" "$st" "$1" "$st/$1.meta" ${2:+"$2"} 2>&1
}
meta s1 design_call=yes "pr=$pr_url" "pr_head=$pr_head"
receipt s1 "$later_head"
out=$(accept s1) && fail "no receipt at either head was accepted: $out"
receipt s1 "$pr_head" "$st/make-both.json"
out=$(accept s1) || fail "the PR head's PASS receipt with a first-draft line was refused at the later copy HEAD: $out"
out=$(accept s1 "$pr_head") || fail "the forge head's receipt was refused at the later copy HEAD: $out"
receipt s1 "$pr_head"
out=$(accept s1) && fail "a receipt at the PR head with no first-draft line was accepted: $out"
assert_contains "$out" "first-draft receipt" "the refusal must name the missing line at the PR head"
receipt s1 "$pr_head" "$st/judge-only.json"
out=$(accept s1) && fail "a judge-only receipt at the PR head was accepted: $out"
assert_contains "$out" "judge-only run" "the refusal must stay as strict at the PR head"
pass "a lane at a later slice is measured at the recorded PR head, and a PR head with no first-draft line still refuses"
