#!/usr/bin/env bash
# done-done journey: a local-trunk lane is rebased onto a newer trunk tip while its task record still holds the old cut tip.
# Real git repos, the real jg_dod_design_gate from bin/jg-merge-gate-lib.sh: a tests-only lane is measured at 0 UI lines and
# passes with no first-draft receipt; a lane that really adds 60 UI lines is still measured at 60 and refused without one.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/state" "$T/proj"
export JG_HOME="$T/home"
jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
# shellcheck source=bin/jg-merge-gate-lib.sh
. "$REPO/bin/jg-merge-gate-lib.sh"
g() { git -C "$T/proj" "$@"; }
g init -q -b main && g config user.email t@t && g config user.name t
seq 1 100 > "$T/proj/app.css" && g add -A && g commit -qm base
g update-ref refs/remotes/origin/main HEAD
g checkout -q -b trunk-v7
cut=$(g rev-parse HEAD)
lane() {  # <branch> <file> <content command>: one lane commit cut from the old tip
  g checkout -q -b "$1" "$cut" && (cd "$T/proj" && eval "$3") && g add -A && g commit -qm "$1"
}
lane tests-lane x 'echo t > a.test.sh'; tests_head=$(g rev-parse HEAD)
lane ui-lane x 'seq 1 60 > other.css'; ui_head=$(g rev-parse HEAD)
g checkout -q trunk-v7 && seq 1 300 >> "$T/proj/app.css" && g commit -qam "landed UI slice"
printf 'trunk-v7\n' > "$T/home/state/trunk-branch-proj"
for b in tests-lane ui-lane; do g checkout -q "$b" && g rebase -q trunk-v7; done
tests_head=$(g rev-parse tests-lane); ui_head=$(g rev-parse ui-lane)
printf 'worktree=%s\nproject=%s\nmode=local-trunk\nbase=%s\ndesign_call=no\n' "$T/proj" "$T/proj" "$cut" > "$T/home/state/t.meta"
{
  echo "recorded cut tip: $cut; current trunk tip: $(g rev-parse trunk-v7)"
  echo "tests-only lane, rebased:"; jg_dod_design_gate "$T/home/state" t "$T/home/state/t.meta" "$tests_head" 2>&1; echo "exit=$?"
  echo "UI lane (60 lines), rebased:"; jg_dod_design_gate "$T/home/state" t "$T/home/state/t.meta" "$ui_head" 2>&1; echo "exit=$?"
} > "$OUT/rebased-lane.txt"
cat "$OUT/rebased-lane.txt"
grep -q "tests-only lane, rebased:" "$OUT/rebased-lane.txt" || exit 1
sed -n '/tests-only/,/UI lane/p' "$OUT/rebased-lane.txt" | grep -q "exit=0" || { echo "FAIL: tests-only lane refused"; exit 1; }
sed -n '/UI lane/,$p' "$OUT/rebased-lane.txt" | grep -q "changes 60 .*first-draft receipt" || { echo "FAIL: UI lane not refused at 60 lines"; exit 1; }
sed -n '/UI lane/,$p' "$OUT/rebased-lane.txt" | grep -q "exit=1" || { echo "FAIL: UI lane exit"; exit 1; }
jq -n --arg v "$(git -C "$REPO" rev-parse --short HEAD)" \
  '{target:{version:$v}, start:"a local-trunk lane cut from an old trunk tip, then rebased onto a newer tip that landed 300 UI lines",
    steps:["rebase a tests-only lane and a 60-UI-line lane onto the new tip", "run the merge gate design rule on each lane head with the task record still holding the old cut tip"],
    result:"the tests-only lane passes with no first-draft receipt; the 60-UI-line lane is refused as changing 60 UI lines with no first-draft receipt"}' > "$OUT/steps.json"
echo "ok"
