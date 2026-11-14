#!/usr/bin/env bash
# bin/jg-design-gate.sh end to end: the small-tweak size rule on a real git repo, and
# the hand-roll approval for a small UI change (lead or Main, never the asking worker)
# that the merge gate reads.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot design-gate) || fail "no fixture root"
main=$root/main lead=$root/lead repo=$root/repo
mkdir -p "$main/state" "$lead/state" "$repo"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$lead/.jg-squad-lead-parent"
: > "$lead/.jg-squad-lead-home"
unset JG_TASK_ID
gate() { JG_HOME=$1 "$ROOT/bin/jg-design-gate.sh" "${@:2}" 2>&1; }

# Size rule on a real repo: 40 UI lines is a tweak, 41 or a new UI file is design.
git -C "$repo" init -q -b main && git -C "$repo" config user.email t@t && git -C "$repo" config user.name t
seq 1 100 > "$repo/app.css" && seq 1 500 > "$repo/notes.md"
git -C "$repo" add -A && git -C "$repo" commit -qm base
sizeof() {  # <branch> <edit command>: commit the edit on a branch and print the verdict
  git -C "$repo" checkout -q -b "$1" main && (cd "$repo" && eval "$2") && git -C "$repo" add -A && git -C "$repo" commit -qm "$1"
  gate "$main" size "$repo" main "$(git -C "$repo" rev-parse HEAD)"
}
assert_equals "tweak 40 0" "$(sizeof t40 'sed -i "1,20s/\$/x/" app.css')" "40 changed UI lines is a tweak"
assert_equals "design 42 0" "$(sizeof t42 'sed -i "1,21s/\$/x/" app.css')" "42 changed UI lines is design"
assert_equals "design 1 1" "$(sizeof tnew 'echo "<p>" > new.html')" "a new UI file is design"
assert_equals "tweak 0 0" "$(sizeof tdoc 'seq 1 400 > notes.md')" "non-UI lines never count"
pass "size rule: 40 UI lines and no new UI file is the tweak bar"

# A move is measured as a move on both sides. Moving a UI file is not design work, and
# before renames were detected a pure move read as its whole content added, with the new
# path counted as a new UI file, so every rename of a page, stylesheet or image was
# refused at any size (PR 498: ten moved .svg read 58 UI lines and 10 new UI files).
assert_equals "tweak 0 0" "$(sizeof tmove 'mkdir -p lib && git mv app.css lib/app.css')" "a moved UI file is not a new UI file and adds no UI line"
assert_equals "tweak 40 0" "$(sizeof tmove20 'mkdir -p lib && git mv app.css lib/app.css && sed -i "1,20s/\$/y/" lib/app.css')" "a move plus 20 changed lines counts those 20 on both sides and stays a tweak"
# The other direction: the corrected measure must still refuse real design work.
assert_equals "design 42 0" "$(sizeof tmove21 'mkdir -p lib && git mv app.css lib/app.css && sed -i "1,21s/\$/y/" lib/app.css')" "a move plus 21 changed lines is still past the bar"
assert_equals "design 1 1" "$(sizeof tmovethennew 'mkdir -p lib && git mv app.css lib/app.css && echo "<p>" > new.html')" "a genuinely new UI file beside a moved one is still design"
assert_equals "design 41 0" "$(sizeof tappend 'seq 1 41 >> app.css')" "genuinely added UI lines still count and still refuse"
# A file that only loses lines adds none, so taking UI apart is not design work at any
# size and needs no design receipt (byokit PR 923: a removed-only UI change was refused).
assert_equals "tweak 0 0" "$(sizeof tdel 'sed -i "1,60d" app.css')" "UI lines that are only deleted are not design work"
assert_equals "tweak 0 0" "$(sizeof tdelall 'git rm -q app.css')" "removing a UI file outright is not design work"
pass "size rule measures a move as a move, still refuses real design work, and never charges for a deletion"

# A merge past the size rule needs the first-draft receipt even when briefed design_call=no.
head=$(git -C "$repo" rev-parse t42)
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$ROOT/bin/jg-merge-gate-lib.sh"
printf 'worktree=%s\nbase_branch=main\ndesign_call=no\n' "$repo" > "$lead/state/w1.meta"
out=$(JG_HOME=$lead jg_dod_design_gate "$lead/state" w1 "$lead/state/w1.meta" "$head" 2>&1) && fail "oversize hand-rolled work merged: $out"
assert_contains "$out" "past the small-tweak size" "oversize merge refusal"
# The receipt is resolved: a make run record that lists the generated page, never a
# bare reference the gate cannot read.
jq -n --arg f "$repo/designs/option-1.html" '{made:{command:"make",files:[{file:$f}]}}' > "$lead/state/w1-fd.json"
jq -n --arg h "$head" --arg e "first-draft receipt: $lead/state/w1-fd.json" \
  '{schema:1,task:"w1",head:$h,verdict:"PASS",evidence:$e,at:1}' > "$lead/state/w1.run-receipt.json"
JG_HOME=$lead jg_dod_design_gate "$lead/state" w1 "$lead/state/w1.meta" "$head" >/dev/null 2>&1 || fail "oversize work with a first-draft receipt was refused"
pass "a change past the size rule needs first-draft whatever its design call"

# Hand-roll: a small UI change merges only with the lead's or Main's approval, never
# the asker's, and a hand-roll approval never covers a change past the size rule.
git -C "$repo" checkout -q t40
small=$(git -C "$repo" rev-parse t40)
printf 'worktree=%s\nbase_branch=main\ndesign_call=no\n' "$repo" > "$lead/state/h1.meta"
mg() { JG_HOME=$lead jg_dod_design_gate "$lead/state" "$1" "$lead/state/$1.meta" "$2" 2>&1; }
out=$(mg h1 "$small") && fail "an unapproved hand-roll merged"
assert_contains "$out" "no hand-roll approval" "hand-roll merge refusal"
out=$(JG_TASK_ID=h1 gate "$lead" handroll h1) && fail "the asking worker approved its own hand-roll"
assert_contains "$out" "never approves" "asker hand-roll refusal"
[ ! -e "$lead/state/design-approvals/h1.handroll.json" ] || fail "a refused hand-roll wrote an approval"
out=$(gate "$lead" handroll h1) || fail "the lead could not approve a small hand-roll: $out"
mg h1 "$small" >/dev/null || fail "an approved small hand-roll was refused"
pass "a small hand-roll merges with the lead's approval, never the asker's"

git -C "$repo" checkout -q t42
printf 'worktree=%s\nbase_branch=main\ndesign_call=no\n' "$repo" > "$lead/state/h2.meta"
out=$(gate "$main" handroll h2 --task-home "$lead") && fail "Main approved a hand-roll past the size rule"
assert_contains "$out" "past the small-tweak size" "oversize hand-roll refusal"
git -C "$repo" checkout -q t40
gate "$main" handroll h2 --task-home "$lead" >/dev/null || fail "Main could not approve a lead's small hand-roll"
out=$(mg h2 "$head") && fail "a hand-roll approval covered a change past the size rule"
assert_contains "$out" "past the small-tweak size" "oversize merge needs first-draft"
mg h2 "$(git -C "$repo" rev-parse tdoc)" >/dev/null || fail "a change with no UI lines needed an approval"
pass "a hand-roll approval never covers a change past the size rule"

# A local-trunk lane is measured against the trunk tip it was cut from (meta base=<sha>), not against origin/main, which the
# local trunk runs ahead of: slices already landed on the trunk are not the lane's change (design-gate-stale-base).
tr=$root/trunk-repo ts=$lead/state
mkdir -p "$tr" && git -C "$tr" init -q -b main && git -C "$tr" config user.email t@t && git -C "$tr" config user.name t
seq 1 100 > "$tr/app.css" && git -C "$tr" add -A && git -C "$tr" commit -qm base
git -C "$tr" update-ref refs/remotes/origin/main HEAD
git -C "$tr" checkout -q -b trunk-v7 && seq 1 200 >> "$tr/app.css" && git -C "$tr" commit -qam "landed UI slice"
tip=$(git -C "$tr" rev-parse HEAD)
lane() {  # <branch> <edit command>: one lane commit on the trunk tip; prints its head
  git -C "$tr" checkout -q -b "$1" "$tip" && (cd "$tr" && eval "$2") && git -C "$tr" add -A && git -C "$tr" commit -qm "$1"
  git -C "$tr" rev-parse HEAD
}
testsonly=$(lane lane-tests 'mkdir -p tests && echo t > tests/a.test.sh')
real=$(lane lane-ui 'seq 1 60 >> app.css')
printf 'worktree=%s\nmode=local-trunk\nbase=%s\ndesign_call=no\n' "$tr" "$tip" > "$ts/tr.meta"
JG_HOME=$lead jg_dod_design_gate "$ts" tr "$ts/tr.meta" "$testsonly" >/dev/null 2>&1 || fail "a tests-only local-trunk lane was refused by the design gate"
out=$(JG_HOME=$lead jg_dod_design_gate "$ts" tr "$ts/tr.meta" "$real" 2>&1) && fail "a local-trunk lane that adds 60 UI lines passed: $out"
assert_contains "$out" "changes 60 " "a real UI change is measured as the lane's own lines only"
assert_equals "tweak 0 0" "$(JG_HOME=$main "$ROOT/bin/jg-design-gate.sh" size "$tr" "$tip" "$testsonly" 2>&1)" "size reads the trunk tip as the base"
pass "a local-trunk lane is measured against its own trunk tip, not a stale origin/main"
