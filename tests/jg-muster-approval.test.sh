#!/usr/bin/env bash
# The captain's approval of a muster pack binds the exact revision he saw (bin/jg-muster-approval.sh, core/muster/approval.py).
# The real approval script, bin/jg-captain-hold.sh (the hold, his answer and the signed line), bin/jg-backlog.sh and the
# card rule (bin/jg-ask-gate-lib.sh) run on a throwaway home with throwaway copies of the example pack; only the pack gate
# is a stand-in (JG_MUSTER_GATE: tests/fixtures/muster-approval/stand-in-gate.sh, the prototype of bin/jg-muster-gate.sh).
#
# T1  the card rule refuses the first draft's words and accepts the plain ones.
# T2  a pack the gate refuses (an idea-only decision record, a missing vision) gives no manifest and no ask.
# T3  the valid pack: the manifest holds its check line, the gate passes on the saved copy, a no is recorded and refuses,
#     a later ask answered yes verifies.
# T4  a spec status move keeps the yes; a changed objective, glossary line or saved copy does not.
# T5  a yes on one ticket approves nothing on another; a worker can ask for nothing.
# T6  the planning exception refuses no and passes yes for that ticket only.
# T7  the feature at full depth: its own manifest and both saved copies, still verified after the live baseline changes,
#     refused when its decision record, vision list or glossary list is wrong.
# T8  a plan is compared with the approved manifest and the charter's order.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

FX=$ROOT/tests/fixtures/muster-approval
T=$(jg_test_tmproot jg-muster-approval)
H=$T/home
mkdir -p "$H/state" "$T/tmp"
jg_test_beads_home "$H"

run() { env -u JG_TASK_ID HOME="$T" TMPDIR="$T/tmp" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
  JG_CONFIG_OVERRIDE="$H/config" JG_MUSTER_GATE="$FX/stand-in-gate.sh" "$@"; }
ma() { OUT=$(run "$ROOT/bin/jg-muster-approval.sh" "$@" 2>&1); RC=$?; }
mw() { OUT=$(run env JG_TASK_ID=jg-w1 "$ROOT/bin/jg-muster-approval.sh" "$@" 2>&1); RC=$?; }  # as a worker
bl() { run "$ROOT/bin/jg-backlog.sh" "$@"; }
gate() { "$FX/stand-in-gate.sh" check "$@"; }  # the pack gate, run directly
answer() {  # <ticket> <value>: the captain's answer on the newest open question of the ticket
  local g
  g=$(bl questions --ticket "$1" --all --json | jq -r '[.[] | select(.state == "open")][-1].id')
  printf '%s\t%s\t%s\n' "$g" "$2" "$2" | run "$ROOT/bin/jg-captain-hold.sh" answers --source "board fixture" >/dev/null \
    || fail "could not record the answer $2 on $1"
}
refused() {  # <label> <needle>: the last call exited 1 with that text
  expect_code 1 "$RC" "$1"
  assert_contains "$OUT" "$2" "$1"
}
approved() {  # <label>: the last call exited 0
  expect_code 0 "$RC" "$1: $OUT"
  assert_contains "$OUT" "approved:" "$1"
}
manifests() {  # <ticket>: how many manifests the ticket holds
  local n=0 f
  for f in "$H/data/$1/muster"/manifest-*.tsv; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}
no_manifest() {  # <ticket> <label>
  [ "$(manifests "$1")" = 0 ] || fail "$2: a manifest was written"
}

P=$T/project
cp -a "$FX/helpdesk" "$P"
for t in jg-t1 jg-t2 jg-t3; do
  bl add "$t" "[feature] Fixture muster ticket $t" --priority 2 --kind ship --repo demo --body "Fixture muster ticket" >/dev/null \
    || fail "could not file $t"
done

# T1
# shellcheck source=bin/jg-ask-gate-lib.sh disable=SC1091
. "$ROOT/bin/jg-ask-gate-lib.sh"
for w in "Approve muster pack 70b4185dbba9 for jg-t1 (ask 1)?" "Start planning jg-t1 without an approved pack (ask 1)?"; do
  [ -n "$(jg_ask_card_junk "$w")" ] || fail "T1 the card rule should refuse: $w"
done
for w in "Approve the agreed documents for Help desk bot, version 1?" "Start planning Help desk bot without agreed documents, request 1?"; do
  [ -z "$(jg_ask_card_junk "$w")" ] || fail "T1 the card rule should accept: $w"
done
pass "T1 draft 4's words are refused by the card rule, the plain words pass"

# T2
cp -a "$P" "$T/idea"
python3 - "$T/idea/docs/adr/0002-keep-conversations-in-one-store-file.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('- SQLite on the host.\n- Postgres as a separate service.\n', ''))
PY
ma manifest jg-t1 "$T/idea" --depth complete
refused "T2 an idea-only record" "fewer than two considered options"
assert_contains "$OUT" "no manifest, no ask" "T2 the refusal says why nothing was written"
no_manifest jg-t1 "T2 an idea-only record"
cp -a "$P" "$T/novision"
rm -f "$T/novision/docs/vision.md"
ma manifest jg-t1 "$T/novision" --depth complete
refused "T2 a missing vision" "vision"
no_manifest jg-t1 "T2 a missing vision"
ma ask jg-t1 "Help desk bot" 000000000000
refused "T2 an ask with no manifest" "no manifest for version 000000000000"
ma manifest jg-t1 "$P" --depth full
refused "T2 a full manifest with no change pack" "needs --change"
pass "T2 a refused pack gives no manifest, and an ask with no passing manifest is refused"

# T3
ma manifest jg-t1 "$P" --depth complete
expect_code 0 "$RC" "T3 manifest: $OUT"
S1=$OUT
M1=$H/data/jg-t1/muster
assert_grep "check complete - pass " "$M1/manifest-$S1.tsv" "T3 the manifest has no check line"
gate "$M1/pack-$S1" --depth complete >/dev/null || fail "T3 the gate does not pass on the saved copy"
[ "$(grep -cE '^(status|updated): ' "$M1/pack-$S1/docs/specs/helpdesk.md")" = 2 ] || fail "T3 the saved spec lost its status or updated line"
ma ask jg-t1 "Help desk bot" "$S1"
expect_code 0 "$RC" "T3 ask: $OUT"
assert_contains "$OUT" "Approve the agreed documents for Help desk bot, version 1?" "T3 the first ask's words"
g1=$(bl questions --ticket jg-t1 --all --json | jq -r '.[0].id')
assert_grep "$(printf '1\tapprove\t%s\t%s\t' "$S1" "$g1")" "$M1/approvals.tsv" "T3 the ask did not record the gate id the backlog returned"
ma verify jg-t1 "$P"
refused "T3 an unanswered ask" "still open"
answer jg-t1 no
ma verify jg-t1 "$P"
refused "T3 a no" "recorded, not an approval"
ma ask jg-t1 "Help desk bot" "$S1"
assert_contains "$OUT" "version 2?" "T3 the second ask has its own number"
answer jg-t1 yes
ma verify jg-t1 "$P"
approved "T3 a later yes"
pass "T3 the valid pack: check line, saved copy passes the gate, a no refuses, a later yes verifies"

# T4
for st in in-progress implemented tested; do
  sed -i -E "s/^status: [a-z-]+ /status: $st /" "$P/docs/specs/helpdesk.md"
  ma verify jg-t1 "$P"
  approved "T4 spec status $st"
done
cp -a "$P" "$T/glossary"
sed -i 's/One turn from the user or the bot inside a conversation./One turn of a conversation./' "$T/glossary/GLOSSARY.md"
ma verify jg-t1 "$T/glossary"
refused "T4 a changed glossary line" "a fresh approval is needed"
cp -a "$P" "$T/objective"
sed -i 's/given a conversation resolved 6 days ago/given a conversation resolved 5 days ago/' "$T/objective/docs/specs/helpdesk.md"
ma verify jg-t1 "$T/objective"
refused "T4 a changed objective row" "a fresh approval is needed"
cp "$M1/pack-$S1/GLOSSARY.md" "$T/glossary.bak"
echo tampered >> "$M1/pack-$S1/GLOSSARY.md"
ma verify jg-t1 "$P"
refused "T4 an edited saved file" "snapshot of GLOSSARY.md was changed"
cp "$T/glossary.bak" "$M1/pack-$S1/GLOSSARY.md"
SP=$M1/pack-$S1/docs/specs/helpdesk.md
cp "$SP" "$T/spec.bak"
sed -i -E 's/^status: [a-z-]+ /status: tested /' "$SP"
ma verify jg-t1 "$P"
refused "T4 a status word edited inside the saved copy" "snapshot of docs/specs/helpdesk.md was changed"
cp "$T/spec.bak" "$SP"
sed -i '/^status: /d' "$SP"
cp "$M1/manifest-$S1.tsv" "$T/manifest.bak"
sed -i -E "s#^raw docs/specs/helpdesk.md [0-9a-f]+#raw docs/specs/helpdesk.md $(sha256sum "$SP" | cut -d' ' -f1)#" "$M1/manifest-$S1.tsv"
ma verify jg-t1 "$P"
refused "T4 a saved spec with its status line removed and its hash rewritten" "does not pass on the saved copy"
cp "$T/spec.bak" "$SP"
cp "$T/manifest.bak" "$M1/manifest-$S1.tsv"
ma verify jg-t1 "$P"
approved "T4 the restored copy"
pass "T4 a status move keeps the yes; a changed objective, glossary line or saved copy does not"

# T5
ma verify jg-t2 "$P"
refused "T5 a yes on jg-t1 for jg-t2" "no approval was asked on jg-t2"
mw ask jg-t2 "Help desk bot" "$S1"
refused "T5 a worker's ask" "a worker cannot ask"
mw exception-ask jg-t2 "Help desk bot"
refused "T5 a worker's exception ask" "a worker cannot ask"
pass "T5 a yes on one ticket approves nothing on another, and a worker can ask for nothing"

# T6
ma exception-ask jg-t2 "Second project"
expect_code 0 "$RC" "T6 exception-ask: $OUT"
answer jg-t2 no
ma exception jg-t2
refused "T6 an exception answered no" "recorded, not an approval"
ma exception-ask jg-t2 "Second project"
assert_contains "$OUT" "request 2?" "T6 the second request has its own number"
answer jg-t2 yes
ma exception jg-t2
expect_code 0 "$RC" "T6 an exception answered yes: $OUT"
assert_contains "$OUT" "jg-t2 only" "T6 the exception names its ticket"
ma exception jg-t1
refused "T6 an exception on another ticket" "no exception was asked on jg-t1"
mw exception jg-t2
refused "T6 a worker using the exception" "a worker cannot use the planning exception"
pass "T6 the planning exception refuses no and passes yes for that ticket only"

# T7
R=$T/rated
B=$T/before
cp -a "$FX/rated" "$R"
cp -a "$FX/helpdesk" "$B"
ma manifest jg-t3 "$R" --depth full --change rate-a-conversation --before "$B"
expect_code 0 "$RC" "T7 manifest: $OUT"
S3=$OUT
M3=$H/data/jg-t3/muster
assert_grep "check full rate-a-conversation pass " "$M3/manifest-$S3.tsv" "T7 the feature manifest has no check line"
gate "$M3/pack-$S3" --depth full --change rate-a-conversation --before "$M3/base-$S3" >/dev/null || fail "T7 the gate fails on the saved copy with its saved baseline"
gate "$M3/pack-$S3" --depth full --change rate-a-conversation --before "$FX/helpdesk" >/dev/null || fail "T7 the gate fails on the saved copy with the original before-project"
[ "$(grep -c '^journey ' "$M3/manifest-$S3.tsv")" = 7 ] || fail "T7 the feature manifest should hold 7 journey lines"
[ "$(grep '^journey ' "$M3/manifest-$S3.tsv" | cut -d' ' -f2 | sort | uniq -d | wc -l)" = 0 ] || fail "T7 a journey has two kinds"
for l in "charter R1 B1 -" "charter R2 B2 R1" "batch B1 -" "batch B2 B1"; do assert_grep "$l" "$M3/manifest-$S3.tsv" "T7 the manifest lacks '$l'"; done
[ "$(grep -c '^milestone F1 ' "$M3/manifest-$S3.tsv")" = 1 ] || fail "T7 the manifest lacks milestone F1"
[ "$(grep -cE '^(charter C|milestone M)' "$M3/manifest-$S3.tsv")" = 0 ] || fail "T7 the feature manifest carries the project's charter"
ma ask jg-t3 "Help desk bot rating" "$S3"
expect_code 0 "$RC" "T7 ask: $OUT"
answer jg-t3 yes
ma verify jg-t3 "$R"
approved "T7 the feature at full"
echo "One more line." >> "$B/docs/vision.md"
ma verify jg-t3 "$R"
approved "T7 after the live before-project changed (the saved baseline is used)"
cp -a "$R" "$T/rated-idea"
python3 - "$T/rated-idea/docs/adr/0004-store-the-rating-on-the-conversation.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, 'w').write(s.replace('- A separate ratings list keyed by conversation id, written by a reporting service.\n', ''))
PY
ma verify jg-t3 "$T/rated-idea"
refused "T7 an ADR reduced to an idea" "fewer than two considered options"
ma manifest jg-t3 "$T/rated-idea" --depth full --change rate-a-conversation --before "$FX/helpdesk"
refused "T7 a manifest on the idea-only ADR" "fewer than two considered options"
cp -a "$R" "$T/rated-promise"
sed -i 's/and that score is kept with it\./and that score is kept with it. Support leads can export every rating to a report./' "$T/rated-promise/docs/vision.md"
ma verify jg-t3 "$T/rated-promise"
refused "T7 an unlisted vision promise" "Support leads can export every rating"
ma manifest jg-t3 "$T/rated-promise" --depth full --change rate-a-conversation --before "$FX/helpdesk"
refused "T7 a manifest with an unlisted vision promise" "Support leads can export every rating"
cp -a "$R" "$T/rated-message"
sed -i 's/^One turn from the user or the bot inside a conversation\.$/One turn from the user, the bot or an external auditor inside a conversation./' "$T/rated-message/GLOSSARY.md"
ma verify jg-t3 "$T/rated-message"
refused "T7 a new meaning for Message" "redefines glossary term Message"
ma manifest jg-t3 "$T/rated-message" --depth full --change rate-a-conversation --before "$FX/helpdesk"
refused "T7 a manifest with a new meaning for Message" "redefines glossary term Message"
[ "$(manifests jg-t3)" = 1 ] || fail "T7 a refused manifest was written beside the approved one"
pass "T7 the feature at full: its own manifest, both saved copies, the saved baseline, and the delta refusals"

# T8
plan() {  # <manifest> <charter document> <ticket> <variant>
  python3 -I "$FX/plan-fixture.py" "$1" "$2" "$3" "$4" "$T/plan-$3-$4.json" >/dev/null || fail "could not build the $4 plan"
  PLAN=$T/plan-$3-$4.json
}
plan_ok() {  # <manifest> <charter document> <ticket> <variant> <needle>: <needle> empty means the plan is accepted
  plan "$1" "$2" "$3" "$4"
  ma verify-plan "$3" "$PLAN"
  if [ -z "$5" ]; then
    expect_code 0 "$RC" "T8 the $3 $4 plan: $OUT"
    assert_contains "$OUT" "plan ok" "T8 the $3 $4 plan"
  else
    refused "T8 the $3 $4 plan" "$5"
  fi
}
FM=$M3/manifest-$S3.tsv FC=$R/docs/changes/rate-a-conversation.md
plan_ok "$FM" "$FC" jg-t3 matching ""
plan_ok "$FM" "$FC" jg-t3 drop-objective "journey lines differ"
plan_ok "$FM" "$FC" jg-t3 change-kind "journey lines differ"
plan_ok "$FM" "$FC" jg-t3 other-ticket "names ticket jg-other"
plan_ok "$FM" "$FC" jg-t3 other-manifest "was made from version 000000000000"
plan_ok "$FM" "$FC" jg-t3 drop-charter "charter lines differ"
plan_ok "$FM" "$FC" jg-t3 project-order "charter lines differ"
plan_ok "$FM" "$FC" jg-t3 r2-first "can start before slice s-r1"
plan_ok "$FM" "$FC" jg-t3 combined "claims charter R2 together with R1"
plan_ok "$FM" "$FC" jg-t3 unclaimed "is claimed by no slice"
PM=$M1/manifest-$S1.tsv PC=$P/docs/charter.md
plan_ok "$PM" "$PC" jg-t1 matching ""
plan_ok "$PM" "$PC" jg-t1 c3-free "can start before slice s-c1"
plan_ok "$PM" "$PC" jg-t1 c1c2-one ""
[ "$(jq -r '[.slices[] | select(.charter == ["C1"] or .charter == ["C2"]) | .depends_on | length] | add' "$T/plan-jg-t1-matching.json")" = 0 ] \
  || fail "T8 the matching project plan should start C1 and C2 with no edge between them"
ma verify-plan jg-t2 "$T/plan-jg-t1-matching.json"
refused "T8 a plan for a ticket with no approval" "no approval was asked on jg-t2"
pass "T8 a plan is compared with the approved manifest and the charter's order"
