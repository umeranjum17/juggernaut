#!/usr/bin/env bash
# Drive a new help desk, then its rating feature, through the public Muster and planning commands.
set -euo pipefail
# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

T=$(jg_test_tmproot muster-acceptance)
FIXTURE=$ROOT/tests/fixtures/muster-acceptance
export JG_HOME=$T/home JG_STATE_OVERRIDE=$T/home/state JG_DATA_OVERRIDE=$T/home/data
export JG_CONFIG_OVERRIDE=$T/home/config JG_PROJECTS_OVERRIDE=$T/home/projects
export HOME=$T/user TMPDIR=$T/tmp JG_CAPTAIN_CHANNEL=$T/channel-off
export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config CLAUDE_CONFIG_DIR=''
export ROOT SIGN_OFF_HOME=$T/board SIGN_OFF_FILER=muster-test ACCEPT_TMP=$T JG_WAR_ROOM_NEXT=0
unset JG_ROOT_OVERRIDE JG_TASK_ID
mkdir -p "$HOME" "$TMPDIR" "$SIGN_OFF_HOME/.sign-off"
printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"
jg_test_spawn_home "$JG_HOME"
jg_test_pin_real_tools "$T/real-tools"
jg_git_identity
fakebin=$(make_spawn_fakebin "$T/terminal")
jg_test_fake_sleep_noop "$fakebin"
export ACCEPT_FAKEBIN=$fakebin
export JG_WAR_ROOM_SPAWN=$FIXTURE/spawn.sh JG_WAR_ROOM_WAIT=40
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$JG_CONFIG_OVERRIDE/host-memory"

jg() { "$ROOT/bin/jg" "$@"; }
plain() {
  local out rc=0
  out=$(jg "$@") || rc=$?
  jq -er .data.stdout <<<"$out"
  return "$rc"
}
ticket() {
  jg ticket add "$1" --why 'Exercise the Muster workflow.' --repo helpdesk --kind ship | jq -er .data.task
}
refuses() {
  local expected=$1 out
  shift
  if out=$(jg "$@" 2>&1); then fail "$* started unexpectedly: $out"; fi
  assert_contains "$out" "$expected" "$*"
}
step_count=0
step() { step_count=$((step_count + 1)); pass "$step_count $1"; }
profile=(--harness codex --model gpt-5.5 --effort high)
war_args=(--project helpdesk --angles "a,b,c" --depth standard "${profile[@]}")
blitz_args=(--harness claude --model claude-haiku-5-5 --effort low --agents 4 --wait)
project=$JG_PROJECTS_OVERRIDE/helpdesk
draft() { python3 -I "$FIXTURE/draft.py" "$ROOT" "$project" "$1" "$2"; }
commit() { git -C "$project" add -A; git -C "$project" commit -qm "$1"; }
note() {
  printf '[chat telegram 42:%s]\n%s\n' "$1" "$2" |
    jg radio inbox note --request-id "tg-42-$1" --json - | jq -er .data.id
}
state() { plain muster round-status "$1"; }
round_card() {
  awk -F '\t' -v q="$2" '$3 == q && $5 != "" { card=$5 } END {print card}' "$JG_DATA_OVERRIDE/$1/muster/rounds.tsv"
}
round() { jg muster round "$1" --questions "$2" --round "$3" --doc "$4" >/dev/null; }
answer_note() { plain muster answer "$1" --note "$(note "$2" "$3")"; }
answer_approval() {
  local gate
  gate=$(sed -n 's/.*(gate \([^)]*\)).*/\1/p' <<<"$1")
  [ -n "$gate" ] || fail "no gate in $1"
  "$FIXTURE/owner-reply.sh" "$gate" "$2" >/dev/null
}
manifest() { plain muster approve manifest "$@"; }
approve() { answer_approval "$(plain muster approve ask "$1" 'Help desk bot' "$2")" "$3"; }

# 1. A runnable skeleton has no pack and the rule distinguishes a new project from a fix.
draft /dev/null skeleton
git -C "$project" init -qb main
printf '.done-done/\n' > "$project/.gitignore"
commit skeleton
base=$(git -C "$project" rev-parse HEAD)
[ ! -e "$project/docs" ] || fail 'pack already present'
out=$(node "$project/src/cli.ts" "$T/store.json" unknown conv || :)
assert_contains "$out" 'unknown command' 'the skeleton starts'
assert_equals complete "$(plain muster depth 'start a new help desk bot project')" 'new project depth'
assert_equals skip "$(plain muster depth --project mature 'Fix a bug in the login sync')" 'fix depth'
t=$(ticket 'Start a new help desk bot project')
out=$(plain muster depth record --ticket "$t")
assert_contains "$out" 'recorded: Muster: complete' 'complete is recorded'
assert_contains "$(plain muster depth record --ticket "$t")" 'unchanged: Muster: complete' 'depth is written once'
step 'runnable skeleton and depth'

# 2. A council gathers questions before any pack and a planning start needs approval.
plain plan war-room lenses "$t" --project helpdesk --lenses user,domain "${profile[@]}" || {
  cat "$JG_DATA_OVERRIDE/war-room/$t/"*.log >&2
  fail 'lens launches'
}
for _ in {1..40}; do
  if out=$(plain muster council "$t" 2>&1); then break; fi
  /bin/sleep 0.25
done
assert_contains "$out" 'merged: round 1' 'the lens drafts merge as round 1'
refuses 'no approval was asked' plan war-room start "$t" "${war_args[@]}"
refuses 'no approval was asked' plan war-room lite "$t" "${profile[@]}"
step 'council starts before the pack and planning refuses'

# 3. Actual owner words and their round ids reach the draft.
decisions=$T/decisions.md
sed -n '/^## Decisions/,$p' "$ROOT/.agents/skills/muster/templates/vision.md" > "$decisions"
jq '.[0:2]' "$FIXTURE/questions.json" > "$T/r1.json"
jq '.[2:3]' "$FIXTURE/questions.json" > "$T/r2.json"
round "$t" "$T/r1.json" 1 "$decisions"
delayed='yes to the rest'
mv "$decisions" "$T/vision-away"
refuses 'document' muster answer "$t" --card "$(round_card "$t" R1Q1)" --value a
mv "$T/vision-away" "$decisions"
assert_contains "$(plain muster repair "$t")" 'repaired' 'restart completes the interrupted answer'
assert_contains "$(cat "$decisions")" 'R1Q1: "TypeScript"' 'board pick is recorded'
round "$t" "$T/r2.json" 2 "$decisions"
answer_note "$t" 102 'R1Q2 b; yes to the rest'
out=$(answer_note "$t" 101 "$delayed")
assert_contains "$out" 'unbound' 'delayed bare reply binds nothing'
assert_contains "$(state "$t")" 'R2Q1' 'round 2 remains open'
! grep -q R2Q1 "$decisions" || fail 'round 2 was answered by the old reply'
answer_note "$t" 103 'R2 yes to the rest'
plain muster revise "$t" R1Q1 --words 'TypeScript, shared with the widget'
draft "$decisions" helpdesk
assert_contains "$(cat "$project/docs/vision.md")" 'TypeScript, shared with the widget" (revision 2)' 'vision carries the revised owner words'
step 'board and chat answers bind to the right round and revision'

# 4. Use the existing journey for the exact pinned standards, including its fault/allow pairs.
assert_grep 'core/standards/typescript-react/base.js' "$project/docs/ways-of-working.md" 'the pack names the preset'
bash "$ROOT/tests/standards-typescript-react.test.sh"
step 'standards fault, allowed case and resolver control'

# 5. Run only the base half while the project is still a skeleton.
assert_contains "$(plain muster gate "$project" --depth complete)" PASS 'new project pack'
out=$(plain muster objectives "$project" --base "$base")
assert_contains "$out" 'PASS' 'base objectives'
assert_equals 12 "$(grep -c 'base exit 1 "assert: ' <<<"$out")" 'every new journey fails on its named assertion'
[ "$(git -C "$project" rev-parse HEAD)" = "$base" ] || fail 'code landed before the base proof'
cp -a "$project" "$T/bad-pack"
sed -i '/^- SQLite on the host\.$/d; /^- Postgres as a separate service\.$/d' "$T/bad-pack/docs/adr/0002-keep-conversations-in-one-store-file.md"
refuses 'no manifest, no ask' muster approve manifest "$t" "$T/bad-pack" --depth complete
rm "$T/bad-pack/docs/vision.md"
refuses 'vision' muster approve manifest "$t" "$T/bad-pack" --depth complete
[ -z "$(find "$JG_DATA_OVERRIDE/$t/muster" -name 'manifest-*.tsv' -print -quit)" ] || fail 'invalid pack created a manifest'
step 'pack gate and base-only objective proof'

# 6. Approval binds the ticket, depth and exact document revision.
sha=$(manifest "$t" "$project" --depth complete)
approve "$t" "$sha" no
refuses 'not yes' plan war-room start "$t" "${war_args[@]}"
approve "$t" "$sha" yes
plain plan war-room check "$t"
assert_contains "$(plain plan war-room start "$t" "${war_args[@]}")" ' live' 'approved variants start'
out=$(plain plan war-room lite "$t")
assert_contains "$out" 'synthesis:' 'lite starts its synthesis'
synthesis=$(sed -n 's/^synthesis: \([^ ]*\) live$/\1/p' <<<"$out")
[ -n "$synthesis" ] || fail 'lite did not return a live synthesis'
grep -lF "Muster manifest SHA: $sha" "$JG_DATA_OVERRIDE"/*/brief.md >/dev/null || fail 'lane briefs lack the approved manifest'
cp "$project/GLOSSARY.md" "$T/glossary"
sed -i 's/inside a conversation/inside one conversation/' "$project/GLOSSARY.md"
refuses 'fresh approval is needed' plan war-room start "$t" "${war_args[@]}"
refuses 'fresh approval is needed' plan war-room lite "$t"
cp "$T/glossary" "$project/GLOSSARY.md"
review=$(ticket 'War room council')
refuses "jg muster depth record --ticket $review" plan war-room start "$review" "${war_args[@]}"
jg muster depth record --ticket "$review" --depth skip --reason 'fixture startup' >/dev/null
plain plan war-room check "$review" >/dev/null
exception=$(ticket 'Create a new help desk project')
jg muster depth record --ticket "$exception" --depth complete --reason 'new project' >/dev/null
answer_approval "$(plain muster exception ask "$exception" 'Help desk bot')" yes
plain plan war-room start "$exception" "${war_args[@]}" --exception
grep -F 'Muster: let through by Start planning' "$JG_DATA_OVERRIDE/war-room/$exception/record" >/dev/null
other=$(ticket 'Create a new support project')
jg muster depth record --ticket "$other" --depth complete --reason 'new project' >/dev/null
refuses 'no exception was asked' plan war-room start "$other" "${war_args[@]}" --exception
step 'no, yes, changed pack, review and ticket-specific exception'

# 7. Swarm validation must run on the submitted plan, not just the draft the owner saw.
export JG_BLITZ_TERM=$T/blitz-terminal
export JG_SWARM_ARM_KICK=0
mkdir "$JG_BLITZ_TERM"
printf '%s\n' '- helpdesk [local-trunk +yolo] - the disposable project (added 2026-11-22)' > "$JG_DATA_OVERRIDE/projects.md"
plan() {
  python3 -I "$FIXTURE/build.py" plan "$1" "$JG_DATA_OVERRIDE/$1/muster/manifest-$2.tsv" "$3" "$4"
}
build() {
  local name
  name=$(jq -er .plan "$1")
  python3 -I "$FIXTURE/build.py" build "$project" "$ROOT/tests/fixtures/muster/example/$2" \
    "$JG_BLITZ_TERM" "$JG_DATA_OVERRIDE/swarm/$name/plan.json" "$JG_HOME"
}
work_plan=$JG_DATA_OVERRIDE/$synthesis/orders/plan.json
variants=${work_plan%/*}
plan "$t" "$sha" "$project/docs/charter.md" "$work_plan"
jq 'del(.muster) | .slices |= map(del(.journeys,.charter))' "$work_plan" > "$variants/no-block.json"
refuses 'has no muster block' plan blitz start "$variants/no-block.json" "${blitz_args[@]}"
jq '.slices[] |= if .id == "c3" then .depends_on -= ["c1"] else . end' "$work_plan" > "$variants/reversed.json"
refuses 'claims C3 and must depend on c1, which claims C1' plan blitz start "$variants/reversed.json" "${blitz_args[@]}"
objective=$(jq -er '.muster.journeys[0].id' "$work_plan")
jq --arg id "$objective" 'del(.muster.journeys[] | select(.id == $id))
  | .muster.milestones[].journeys -= [$id] | .slices[].journeys -= [$id]' "$work_plan" > "$variants/omitted.json"
refuses "$objective" plan blitz start "$variants/omitted.json" "${blitz_args[@]}"
assert_contains "$(plain plan swarm start "$work_plan" "${blitz_args[@]}")" '4 slices filed and approved' 'approved plan starts via alias'
derived=$JG_DATA_OVERRIDE/swarm/$(jq -er .plan "$work_plan")/plan.json
jq -e '[.slices[] | select(.depends_on == []) | .id] | sort == ["c1","c2"]' "$derived" >/dev/null || fail 'C1 and C2 do not start together'
grep -F "Muster manifest SHA: $sha" "$(jq -er '.slices[0].order_path' "$derived")" >/dev/null || fail 'order lacks the approved pack'
build "$work_plan" helpdesk
built=$(git -C "$project" rev-parse HEAD)
step 'Blitz refuses missing docs and charter faults, then arms the matching plan'

# 8. Proof on both revisions and genuine done-done run records for the model work.
out=$(plain muster objectives "$project" --base "$base" --head "$built")
assert_equals 12 "$(grep -c 'head exit 0' <<<"$out")" 'all new journeys pass on the head'
assert_equals 12 "$(grep -c 'base exit 1 "assert: ' <<<"$out")" 'all new journeys still fail on the base'
receipts=$T/receipts
mkdir "$receipts"
record_journey() (
  cd "$project"
  DONE_DONE_EVIDENCE_ROOT="$receipts" done-done run "$1" -- bash "$FIXTURE/capture.sh" "$1"
)
status() {
  printf '%s\n' "$project" > "$JG_DATA_OVERRIDE/$t/muster/project"
  # Steering 006 supplies the missing project directory to the real verifier.
  JG_MUSTER_APPROVAL_VERIFY=$FIXTURE/verify.sh plain muster status "$t"
}
mapfile -t journeys < <(jq -r '.muster.journeys[].id' "$work_plan")
record_journey "${journeys[0]}"
# The observer reads its run records in the fixture project.
mkdir -p "$project/.done-done/runs"
cp "$receipts/.done-done/runs/"*.json "$project/.done-done/runs/"
assert_contains "$(status)" 'landed, not secured' 'a missing objective blocks secured'
for journey in "${journeys[@]:1}"; do record_journey "$journey"; done
cp "$receipts/.done-done/runs/"*.json "$project/.done-done/runs/"
for journey in "${journeys[@]}"; do
  out=$(jq -r --arg journey "$journey" --arg head "$built" \
    'select(.journey == $journey and .commit == $head and .exit == 0 and .dirty == false) | .journey' \
    "$project/.done-done/runs/"*.json)
  assert_equals "$journey" "$out" "clean receipt for $journey on the build"
done
step 'all new journeys fail on the skeleton, pass on the build, and have receipts'

# 9. The state reaches secured only after the built commit is also released.
assert_contains "$(status)" 'landed, not released' 'receipts alone cannot secure the pack'
assert_contains "$(plain muster code "$project")" PASS 'model behaviours are implemented'
printf '%s prs=2\n' "$built" > "$JG_DATA_OVERRIDE/releases"
assert_contains "$(status)" $'state\tsecured' 'release and proof secure the pack'
step 'landed and secured agree with the receipts and release record'

# 10. A change pack reflects the real project delta and its own charter.
feature=$(ticket 'Let users rate a resolved conversation')
assert_equals light "$(plain muster depth --project helpdesk 'let users rate a resolved conversation')" 'feature picker'
out=$(plain muster depth record --ticket "$feature" --depth full --reason 'changes the Conversation state machine')
assert_contains "$out" 'Muster: full - changes the Conversation state machine' 'Main raises the depth'
sed -n '/^## Decisions/,$p' "$ROOT/.agents/skills/muster/templates/vision.md" > "$T/feature-decisions.md"
jq '.[3:]' "$FIXTURE/questions.json" > "$T/feature-questions.json"
round "$feature" "$T/feature-questions.json" 1 "$T/feature-decisions.md"
plain muster answer "$feature" --card "$(round_card "$feature" R1Q1)" --words 'Keep one rating on the conversation'
before=$T/released
mkdir "$before"
git -C "$project" archive "$built" | tar -x -C "$before"
draft "$T/feature-decisions.md" rated
assert_contains "$(cat "$project/docs/vision.md")" 'Keep one rating on the conversation' 'feature owner words'
change=rate-a-conversation
assert_contains "$(plain muster gate "$project" --depth full --change "$change" --before "$before")" PASS 'feature pack matches the real diff'
cp -a "$project" "$T/bad-feature"
sed -i '/^## End state$/a A user can ask to see all conversations in the store.' "$T/bad-feature/docs/vision.md"
refuses 'vision' muster approve manifest "$feature" "$T/bad-feature" --depth full --change "$change" --before "$before"
cp "$project/docs/vision.md" "$T/bad-feature/docs/vision.md"
sed -i '/^### Message$/,/^### /s/inside a conversation/inside any conversation/' "$T/bad-feature/GLOSSARY.md"
refuses 'Message' muster approve manifest "$feature" "$T/bad-feature" --depth full --change "$change" --before "$before"
[ -z "$(find "$JG_DATA_OVERRIDE/$feature/muster" -name 'manifest-*.tsv' -print -quit)" ] || fail 'invalid change created a manifest'
out=$(plain muster objectives "$project" --base "$built" --change "$change")
assert_equals 5 "$(grep -c 'base exit 1 "assert: ' <<<"$out")" 'feature journeys fail before feature code'
assert_equals 2 "$(grep -c '(preserve): base exit 0' <<<"$out")" 'preserve journeys still pass'
feature_sha=$(manifest "$feature" "$project" --depth full --change "$change" --before "$before")
approve "$feature" "$feature_sha" yes
change_plan=$T/rated/plan.json
plan "$feature" "$feature_sha" "$project/docs/changes/$change.md" "$change_plan"
jq -e '(.muster.charter | map(.ticket) | sort == ["R1","R2"]) and
  (.muster.milestones | map(.id) == ["F1"]) and (.muster.journeys | length == 7)' "$change_plan" >/dev/null
jq '.slices[] |= if .id == "r2" then .depends_on = [] | .files = ["rating.txt (new)"] else . end' "$change_plan" > "$T/rated/reversed.json"
refuses 'claims R2 and must depend on r1, which claims R1' plan blitz start "$T/rated/reversed.json" "${blitz_args[@]}"
jq '.slices = [(.slices[0] + {charter: ["R1","R2"], journeys: [.muster.journeys[].id]})]' "$change_plan" > "$T/rated/combined.json"
refuses 'claims R2 together with R1' plan blitz start "$T/rated/combined.json" "${blitz_args[@]}"
assert_contains "$(plain plan blitz start "$change_plan" "${blitz_args[@]}")" '2 slices filed and approved' 'feature plan starts'
build "$change_plan" rated
head=$(git -C "$project" rev-parse HEAD)
out=$(plain muster objectives "$project" --base "$built" --head "$head" --change "$change")
assert_equals 5 "$(grep -c '(new): base exit 1 "assert: .*head exit 0' <<<"$out")" 'new feature journeys pass after build'
assert_equals 2 "$(grep -c '(preserve): base exit 0 .*head exit 0' <<<"$out")" 'preserve journeys pass on both revisions'
step 'feature muster, delta mutants, charter mutants and the built feature'

printf 'acceptance: %s/10\n' "$step_count"
