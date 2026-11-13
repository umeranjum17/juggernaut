#!/usr/bin/env bash
# Behavior tests for the delivery machine (core/machines/tables/delivery.tsv) and for jg-live-claim.sh using it.
# Every record is generated here in the shape its writer prints: a git repo with a trunk, state/trunk-tip-<project>,
# data/trunk-live.tsv rows, config/ switch files and a seeded registry. No fleet record is copied.
# A switched-off change and a switched-on one are walked through every state, and a report that says "live" is
# refused for the first and kept, with its proof, for the second.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"; OBS="$ROOT/core/machines/observers/delivery.sh"; CLAIM="$ROOT/bin/jg-live-claim.sh"
T=$(jg_test_tmproot jg-machine-delivery)
export JG_HOME="$T/home" JG_DELIVERY_CHANGES="$T/changes.tsv"
export GIT_CONFIG_COUNT=0  # the fixture repo takes no launch hook or identity from the session
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_RELEASES_FILE
R=$JG_HOME/projects/juggernaut; S=$JG_HOME/state; D=$JG_HOME/data; C=$JG_HOME/config
mkdir -p "$R" "$S" "$D" "$C"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
g() { git -C "$R" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false "$@"; }
commit() {  # <file> <message>: a commit on the current branch; prints its sha
  printf '%s\n' "$1" >> "$R/$1"; g add -A && g commit -q -m "$2" && g rev-parse HEAD
}
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
word_of() { bash "$JM" show delivery "$1" 2>&1 | awk -F'\t' '$1 == "state" { print $2 }'; }
live_row() { tab "$1" "$2" "$(date +%s)" "$3" "${4:-}" >> "$D/trunk-live.tsv"; }

git init -q -b trunk "$R"
base=$(commit base.txt "base")
commit off.txt $'feature that ships behind a switch\n\nChange: feat-off' >/dev/null
on=$(commit on.txt $'feature that is switched on\n\nChange: feat-on')
commit logged.txt $'feature proved by a log line\n\nChange: feat-log' >/dev/null
commit nosw.txt $'feature with a switch and no proof\n\nChange: feat-noproof' > /dev/null
gone=$(commit gone.txt $'feature that is reverted\n\nChange: feat-gone')
revert=$(commit revert.txt $'Revert "feature that is reverted"\n\nreverts: '"$gone")
g checkout -q -b side "$base"; side=$(commit side.txt "side work"); g checkout -q trunk
printf '%s' "$revert" > "$S/trunk-tip-juggernaut"; ln -s juggernaut "$JG_HOME/projects/pin"; printf '%s' "$revert" > "$S/trunk-tip-pin"
{ tab feat-off juggernaut - feat-off switch "ships behind a switch"
  tab feat-on juggernaut - feat-on switch "is switched on"
  tab feat-log juggernaut - - "log:data/feat.log:^counted [1-9]" "no switch, proved by a counter line"
  tab feat-noproof juggernaut - feat-noproof - "a switch and no proof"
  tab feat-gone juggernaut - - - "is reverted"
  tab feat-side juggernaut "$side" - - "is not on the trunk"
  tab feat-pin pin "$on" - - "a home was pinned back below it"
  tab feat-late juggernaut "$revert" - - "lands later than a skipped home"; } > "$T/changes.tsv"

jm check delivery; expect_code 0 "$RC" "the delivery table lints"
bash "$JM" coverage delivery >/dev/null; expect_code 0 "$?" "every delivery edge names its test"
bash "$OBS" check; expect_code 0 "$?" "the seeded registry lints"
pass "the table and the registry pass their lint"

# unlanded: the commit is on a side branch only. landed: on the trunk, no home row yet.
assert_equals unlanded "$(word_of feat-side)" "a commit off the trunk is unlanded"
assert_equals landed "$(word_of feat-off)" "a commit on the trunk with no home row is landed"
# a skipped home: the batch moved one home and skipped the other, so the change is not in every home.
live_row juggernaut "$revert" live
live_row juggernaut:primary "$revert" live "$base"
live_row juggernaut:lead-a "$revert" "skipped:dirty" "$base"
assert_equals landed "$(word_of feat-off)" "a home that skipped the move keeps the change landed"
pass "unlanded and landed"

# every home live at the tip: the switched-off change is in-homes-off and names its switch; the switched-on one is in-use.
live_row juggernaut:lead-a "$revert" live "$base"
assert_equals in-homes-off "$(word_of feat-off)" "every home runs it and its switch is absent: in-homes-off"
OUT=$(bash "$OBS" detail feat-off); assert_contains "$OUT" "config/feat-off" "detail names the switch file"
assert_equals in-homes-off "$(word_of feat-on)" "the second change is off too until its switch exists"
: > "$C/feat-on"
assert_equals in-use "$(word_of feat-on)" "its switch is on and the proof holds: in-use"
assert_contains "$(bash "$OBS" detail feat-on)" "switch config/feat-on is present" "detail names the proof that held"
rm -f "$C/feat-on"; assert_equals in-homes-off "$(word_of feat-on)" "removing the switch returns it to in-homes-off"
pass "a switched-off change is in-homes-off and a switched-on one is in-use"

# a proof that is a log line: no switch, in-homes until the counter shows work.
assert_equals in-homes "$(word_of feat-log)" "no proof line yet: in-homes, never in-use"
printf 'counted 0\n' > "$D/feat.log"; assert_equals in-homes "$(word_of feat-log)" "a counter of zero is no proof"
printf 'counted 3\n' > "$D/feat.log"; assert_equals in-use "$(word_of feat-log)" "a counter line proves use: in-use"
: > "$C/feat-noproof"; assert_equals in-homes "$(word_of feat-noproof)" "a switch with no named proof is in-homes"
pass "a change is in-use only with a named proof that holds"

# reverted and pinned-behind
assert_equals reverted "$(word_of feat-gone)" "a revert on the trunk makes it reverted"
: > "$C/feat-on"
live_row pin:primary "$base" "live,pinned-back-from:${on:0:12}" "$on"
assert_equals pinned-behind "$(word_of feat-pin)" "a home pinned back below the commit is pinned-behind"
rm -f "$C/feat-on"
pass "reverted and pinned-behind"

# every observed state is a state of the table and the moves between them are table edges
{ for w in unlanded landed in-homes in-homes-off in-use pinned-behind reverted; do printf '%s\n' "$w"; done
  tab unlanded land landed; tab landed live-off in-homes-off; tab landed live-on in-use; tab in-homes-off switch-on in-use
  tab in-use switch-off in-homes-off; tab in-use proof-lost in-homes; tab in-homes-off switch-named in-homes
  tab in-use pin-back pinned-behind; tab pinned-behind live-on in-use; tab in-use revert reverted; } > "$T/corpus"
jm check delivery --corpus "$T/corpus"; expect_code 0 "$RC" "the observed states and moves are in the table"
jm check delivery --corpus <(tab in-homes-off live in-use); expect_code 1 "$RC" "a move the table lacks is refused (off to in-use needs the switch)"
bash "$JM" edge-check delivery reverted in-use >/dev/null 2>&1; expect_code 1 "$?" "reverted is terminal"
pass "the table holds the observed states and moves"

# the report rule: live is said only for in-use, with the proof
claim() { OUT=$(bash "$CLAIM" "done" "$1" 2>/dev/null); RC=$?; }
claim "feat-off is live"; expect_code 3 "$RC" "live for a switched-off change is refused"
assert_contains "$OUT" "in the homes, off (switch config/feat-off)" "the claim becomes in the homes, off, naming the switch"
claim "feat-off is live, in the homes, off until config/feat-off exists"; expect_code 0 "$RC" "saying in the homes, off stands"
claim "feat-side is fixed"; expect_code 3 "$RC" "a change not on the trunk is not fixed"; assert_contains "$OUT" "Built, not landed:" "unlanded reads as Built, not landed"
claim "feat-gone is done"; expect_code 3 "$RC" "a reverted change is not done"; assert_contains "$OUT" "reverted:" "reverted says reverted"
: > "$C/feat-on"
claim "feat-on is live"; expect_code 3 "$RC" "in-use without its proof is extended"
assert_contains "$OUT" "proof: switch config/feat-on is present" "the proof that held is added"
claim "feat-on is live; proof: the fleet view shows it"; expect_code 0 "$RC" "in-use with its proof stands as written"
rm -f "$C/feat-on"
claim "the feat on change is live"; expect_code 3 "$RC" "a switch name in words engages the machine too"
claim "the build is fixed; screen: none"; expect_code 0 "$RC" "a claim that names no registered change keeps the old rule"
OUT=$(bash "$CLAIM" working "feat-off is live" 2>&1); expect_code 0 "$?" "only a done report is judged"
pass "live-claim says live only for in-use, with the proof"

# the shipped registry and the shipped state machine slices
unset JG_DELIVERY_CHANGES
bash "$OBS" check; expect_code 0 "$?" "the shipped registry lints"
ids=$(bash "$OBS" ids)
for s in s1a s1b s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12; do assert_contains "$ids" "sm-$s-" "slice $s is registered"; done
OUT=$(bash "$OBS" mentions <<< "the machine view is live"); assert_contains "$OUT" "sm-s2-task-lifecycle" "the machine view switch names its slices"
OUT=$(bash "$OBS" mentions <<< "machine-enforce is live"); assert_contains "$OUT" "sm-s12-enforce" "the machine-enforce switch names its slice"
pass "the shipped registry names the state machine slices and both switches"
