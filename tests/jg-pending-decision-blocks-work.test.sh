#!/usr/bin/env bash
# An open captain decision stops the work linked to it: no start, no merge.
# Real bin/jg-spawn.sh and bin/jg-pr-merge.sh over fixture homes; the terminal, forge and model are stand-ins.
# Incident shape: a [design-ux] ticket is only filed (no hold, no ask) and a pull request naming it merged anyway.
# S* starts, M* merges: linked work is refused; unrelated work, `parent: upkeep` and a filed [captain-ask] move.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }
export JG_TASK_PRIORITY_CHECK=/nonexistent

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-pending-decision)
TASKS_AXI_BIN=$(command -v tasks-axi)
PASS_LINT="$TMP_ROOT/pass-lint.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "checks-lint: PASS"' > "$PASS_LINT"
chmod +x "$PASS_LINT"

W="$TMP_ROOT/world"
SH="$W/home"
PROJ="$W/proj"
mkdir -p "$W" && git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm c1 && git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q && git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$SH"
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$SH/config/host-memory"
jg_test_tasks_toml "$SH/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$SH/data/backlog.md"

tasks_s() { (cd "$SH" && tasks-axi "$@"); }
captain() {  # <home> <fakebin> <args...>
  local h=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" \
    JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
printf 'Use the compact layout.\n' > "$TMP_ROOT/pick.txt"
record_pick() {  # <home> <fakebin> <ticket>: hold, then the captain's recorded answer
  captain "$1" "$2" hold "$3" --reason "captain must pick" >/dev/null 2>&1 || fail "could not hold $3"
  captain "$1" "$2" answer "$3" --decision-file "$TMP_ROOT/pick.txt" --release >/dev/null 2>&1 \
    || fail "could not record the pick on $3"
}

scaffold() {  # <id>
  JG_HOME="$SH" "$ROOT/bin/jg-brief.sh" "$1" proj --project "$PROJ" --mode direct-PR >"$W/scaffold.out" 2>&1 \
    || { cat "$W/scaffold.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the decision gate./;s/{JUGGERNAUT_SPEC}/Exercise the decision gate end to end./' "$SH/data/$1/brief.md"
}
file_s() {  # <id> <title> [body]: a queued ship ticket in the start home, with its instructions
  tasks_s add "$1" "$2" --priority 2 --kind ship --repo proj ${3:+--body "$3"} >/dev/null 2>&1 || fail "could not file $1"
  case "$2" in "[design-ux]"*) ;; *) scaffold "$1" || fail "could not scaffold $1" ;; esac
}
spawn() {  # <id>
  local wt="$W/wt-$1-$RANDOM"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  jg_test_run_spawn "$SH" "$wt" "$FAKEBIN" "$1" "$PROJ" codex --mode direct-PR --yolo off
}
refused_clean() { [ ! -e "$SH/state/$1.meta" ] || fail "the refused start of $1 wrote a task record"; }

# S1: the design ticket is only filed - no hold, no ask.
file_s dz1 "[design-ux] Tickets page design"
file_s dz2 "[design-ux] Settings page design" "linked-to: sb2"
file_s sa1 "Build the tickets page" "linked-to: dz1"
file_s sb2 "Build the settings page"
file_s sc3 "Build the tickets filters" "parent: dz1"
for pair in "sa1 dz1" "sb2 dz2" "sc3 dz1"; do  # names it, named by it, parent link
  # shellcheck disable=SC2086
  set -- $pair
  out=$(spawn "$1"); rc=$?
  expect_code 1 "$rc" "S1 the start of $1 linked to open design ticket $2 should be refused: $out"
  assert_contains "$out" "$2" "S1 the refusal of $1 does not name $2"
  refused_clean "$1"
done
file_s su1 "Fix the footer"
file_s su2 "Fix the header" "parent: upkeep"
file_s sq1 "[captain-ask] Make the footer taller"
file_s su3 "Make the footer taller" "linked-to: sq1"
for t in su1 su2 su3; do
  out=$(spawn "$t"); rc=$?
  expect_code 0 "$rc" "S2 $t should start: $out"
done
record_pick "$SH" "$FAKEBIN" dz1
record_pick "$SH" "$FAKEBIN" dz2
for t in sa1 sb2 sc3; do
  out=$(spawn "$t"); rc=$?
  expect_code 0 "$rc" "S3 $t should start after the recorded pick: $out"
done

# ---- the merge side --------------------------------------------------------
MH="$TMP_ROOT/merge-home"
mkdir -p "$MH/data" "$MH/state" "$MH/config" "$MH/projects"
jg_test_tasks_toml "$MH/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MH/data/backlog.md"
MFAKE=$(jg_fakebin "$MH")
jg_fake_exit0 "$MFAKE" tmux treehouse no-mistakes gh gh-axi
cat > "$MFAKE/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_TEST_GH_LOG"
H=1111111111111111111111111111111111111111
case "${1:-} ${2:-}" in
  "pr view") case " $* " in
    *statusCheckRollup*) printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' "$H" ;;
    *headRefOid*) echo "$H" ;; esac ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "api graphql") printf '%s\n' state=MERGED merged=true queued=false base=main ;;
  "api --paginate") echo '[]' ;;
  "api repos/"*) echo '{"name":"main","protected":false}' ;;
esac
SH
chmod +x "$MFAKE/gh"
: > "$MH/gh.log"

tasks_m() { (cd "$MH" && tasks-axi "$@"); }
PRN=100
# ship_m <id> [body]: an in-flight ship with an open pull request; sets PR.
ship_m() {
  local id=$1 repo wt
  PRN=$((PRN + 1))
  PR="https://github.com/sample/sample/pull/$PRN"
  repo="$MH/projects/sample-$id"
  wt="$MH/projects/$id"
  jg_git_worktree "$repo" "$wt" "fm/$id"
  tasks_m add "$id" "Ship $id" --kind ship --repo sample ${2:+--body "$2"} --start >/dev/null || fail "could not file $id"
  jg_write_meta "$MH/state/$id.meta" "worktree=$wt" "project=$repo" "kind=ship" "mode=no-mistakes" "pr=$PR"
  printf 'done: merge ready\n' > "$MH/state/$id.status"
}
merge() {  # <id> <url>
  PATH="$MFAKE:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$MH" \
    JG_STATE_OVERRIDE="$MH/state" JG_DATA_OVERRIDE="$MH/data" \
    JG_CONFIG_OVERRIDE="$MH/config" JG_TEST_GH_LOG="$MH/gh.log" \
    JG_PR_MERGE_CHECKS_LINT="$PASS_LINT" \
    "$ROOT/bin/jg-pr-merge.sh" "$1" "$2"
}
merged_pr() { grep -q "^pr merge ${1##*/} " "$MH/gh.log"; }

# M1: the design ticket is only filed - no hold, no ask.
tasks_m add mz1 "[design-ux] Tickets page design" --kind ship --repo sample >/dev/null || fail "M1 could not file mz1"
ship_m ma1 "linked-to: mz1"; pa1=$PR
ship_m mb2; pb2=$PR
ship_m mc3 "parent: mz1"; pc3=$PR
ship_m md4; pd4=$PR
tasks_m add mh1 "Pick the export format" --kind ship --repo sample >/dev/null || fail "M1 could not file mh1"
captain "$MH" "$MFAKE" hold mh1 --reason "captain must pick" >/dev/null 2>&1 || fail "M1 could not hold mh1"
ship_m mf6 "linked-to: mh1"; pf6=$PR
tasks_m add mz2 "[design-ux] Settings page design" --kind ship --repo sample --body "linked-to: mb2" >/dev/null || fail "M1 could not file mz2"
for tuple in "ma1 $pa1 mz1" "mb2 $pb2 mz2" "mc3 $pc3 mz1" "mf6 $pf6 mh1"; do
  # shellcheck disable=SC2086
  set -- $tuple
  out=$(merge "$1" "$2" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "M1 the merge of $1 linked to open design ticket $3 went through: $out"
  assert_contains "$out" "$3" "M1 the refusal of $1 does not name $3"
  merged_pr "$2" && fail "M1 the refused merge of $1 reached the forge"
done
ship_m me5 "parent: upkeep"; pe5=$PR
tasks_m add mq1 "[captain-ask] Make the footer taller" --kind ship --repo sample >/dev/null || fail "M2 file mq1"
ship_m mg7 "linked-to: mq1"; pg7=$PR
for pair in "md4 $pd4" "me5 $pe5" "mg7 $pg7"; do
  # shellcheck disable=SC2086
  set -- $pair
  out=$(merge "$1" "$2" 2>&1); rc=$?
  expect_code 0 "$rc" "M2 $1 should merge: $out"
  merged_pr "$2" || fail "M2 the merge of $1 did not reach the forge"
done
record_pick "$MH" "$MFAKE" mz1
record_pick "$MH" "$MFAKE" mz2
captain "$MH" "$MFAKE" answer mh1 --decision-file "$TMP_ROOT/pick.txt" --release >/dev/null 2>&1 || fail "M3 could not answer mh1"
for pair in "ma1 $pa1" "mb2 $pb2" "mc3 $pc3" "mf6 $pf6"; do
  # shellcheck disable=SC2086
  set -- $pair
  out=$(merge "$1" "$2" 2>&1); rc=$?
  expect_code 0 "$rc" "M3 $1 should merge after the recorded pick: $out"
  merged_pr "$2" || fail "M3 $1 did not reach the forge after the recorded pick"
done
pass "linked starts and merges are refused while a decision is open, unrelated work moves, a recorded pick releases both"

# ---- the replay of the incident: a design card is posted, the ticket that raised it is merged ----
# D*: the card is posted the only way that files a design row; the ticket's pull request names no link of its own.
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
SO="$W/so"
mkdir -p "$SO/.sign-off"
printf '{"schema":2,"items":[]}\n' > "$SO/.sign-off/decisions.json"
: > "$SO/.sign-off/decisions.answers.jsonl"
printf 'leash: matters\n' > "$SO/.sign-off/config.yaml"
printf 'set mode off\n' > "$W/channel-off"
cat > "$MFAKE/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: [.items[]]}' "$board" ;;
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  dismiss) ;;
  raise)
    key='' title=''
    while [ "$#" -gt 0 ]; do
      case "$1" in --key) key=$2; shift ;; --title) title=$2; shift ;; esac
      shift
    done
    key=${key:-card}
    jq --arg k "$key" --arg t "$title" '.items += [{key: $k, kind: "decision", title: $t}]' "$board" > "$board.t" && mv "$board.t" "$board"
    printf '%s\n' "$key" ;;
esac
SH
chmod +x "$MFAKE/sign-off-axi"
DCARD="tickets-layout-pick"
dcard() {  # <post flags...>: post one design card from the merge home
  PATH="$MFAKE:$PATH" JG_HOME="$MH" JG_STATE_OVERRIDE="$MH/state" JG_DATA_OVERRIDE="$MH/data" JG_CONFIG_OVERRIDE="$MH/config" \
    SIGN_OFF_HOME="$SO" JG_CAPTAIN_CHANNEL="$W/channel-off" JG_SEND_SETTLE=0 \
    "$ROOT/bin/jg-question-card.sh" post --route main --ask-ref ticket-layout --key "$DCARD" --must design-pick \
    --title "Which layout should the ticket list use?" --why "The list page needs one layout." \
    --outcome yes="It uses the compact layout." --outcome no="It keeps the wide layout." "$@" 2>&1
}
board_items() { jq -r '.items | length' "$SO/.sign-off/decisions.json"; }
ship_m mr1; pr1=$PR
out=$(dcard); rc=$?
[ "$rc" -ne 0 ] || fail "D1 a design card with no raising ticket was posted: $out"
assert_contains "$out" "must name the ticket that raised it" "D1 the refusal does not say the raising ticket is missing"
out=$(dcard --raised-by no-such-ticket); rc=$?
[ "$rc" -ne 0 ] || fail "D2 a design card naming a ticket this home lacks was posted: $out"
assert_equals 0 "$(board_items)" "D2 a refused design card reached the board"
tasks_m show "$DCARD" >/dev/null 2>&1 && fail "D2 a refused design card filed a design row"
out=$(merge mr1 "$pr1" 2>&1); rc=$?
expect_code 0 "$rc" "D3 the ticket merges while no card is open: $out"
merged_pr "$pr1" || fail "D3 the merge did not reach the forge"
ship_m mr2; pr2=$PR
out=$(dcard --raised-by mr2); rc=$?
expect_code 0 "$rc" "D4 a design card naming its raising ticket should post: $out"
assert_equals 1 "$(board_items)" "D4 the design card did not reach the board"
out=$(dcard --raised-by mr2); rc=$?
expect_code 0 "$rc" "D4 a repeat post should converge: $out"
tasks_m show "$DCARD" 2>&1 | grep -q 'linked-to: mr2' || fail "D4 the design row is not linked to the ticket that raised it"
out=$(merge mr2 "$pr2" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "D5 the merge of the ticket that raised an open design card went through: $out"
assert_contains "$out" "$DCARD" "D5 the refusal does not name the open design card"
merged_pr "$pr2" && fail "D5 the refused merge reached the forge"
printf '{"key":"%s","answer":"yes","label":"yes","close":"done","at":"2026-11-06T07:00:00Z"}\n' "$DCARD" >> "$SO/.sign-off/decisions.answers.jsonl"
PATH="$MFAKE:$PATH" JG_HOME="$MH" JG_STATE_OVERRIDE="$MH/state" JG_DATA_OVERRIDE="$MH/data" JG_CONFIG_OVERRIDE="$MH/config" \
  SIGN_OFF_HOME="$SO" JG_SEND_SETTLE=0 "$ROOT/bin/jg-board-answers.sh" check >/dev/null 2>&1
out=$(merge mr2 "$pr2" 2>&1); rc=$?
expect_code 0 "$rc" "D6 the ticket should merge after the recorded pick: $out"
merged_pr "$pr2" || fail "D6 the merge did not reach the forge after the recorded pick"
pass "replay: the ticket that raised an open design card is refused at merge, and merges once the pick is recorded"
