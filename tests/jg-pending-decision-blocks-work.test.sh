#!/usr/bin/env bash
# An open captain decision stops the work linked to it: no start, no merge.
# Real bin/jg-spawn.sh and bin/jg-pr-merge.sh over fixture homes; the terminal, forge and model are stand-ins.
# Incident shape: a [design-ux] ticket is only filed (no hold, no ask) and a pull request naming it merged anyway.
# S* starts, M* merges: linked work is refused; unrelated work, `parent: upkeep` and a filed [captain-ask] move.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }
export JG_TASK_PRIORITY_CHECK=/nonexistent

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-pending-decision)
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
jg_test_beads_home "$SH"

# add_row <home> <id> <title> <kind> <repo> [extra-body-line] [more flags]: one fixture row; the first body line is its justification.
add_row() {
  local home=$1 id=$2 title=$3 kind=$4 repo=$5 extra=${6:-} prio=2
  shift 6 2>/dev/null || shift $#
  case $title in '[captain-ask]'*) prio=0 ;; esac
  jg_test_backlog "$home" add "$id" "$title" --priority "$prio" --kind "$kind" --repo "$repo" \
    --body "Fixture ticket $id${extra:+$'\n'$extra}" "$@"
}
captain() {  # <home> <fakebin> <args...>
  local h=$1 fb=$2
  shift 2
  PATH="$fb:$PATH" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" \
    JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
printf 'Use the compact layout.\n' > "$TMP_ROOT/pick.txt"
record_pick() {  # <home> <fakebin> <ticket>: hold, then the captain's recorded answer
  captain "$1" "$2" hold "$3" --reason "captain must pick" >/dev/null 2>&1 || fail "could not hold $3"
  captain "$1" "$2" answer "$3" --decision-file "$TMP_ROOT/pick.txt" >"$TMP_ROOT/pick.out" 2>&1 \
    || fail "could not record the pick on $3: $(cat "$TMP_ROOT/pick.out")"
}

scaffold() {  # <id>
  JG_HOME="$SH" "$ROOT/bin/jg-brief.sh" "$1" proj --project "$PROJ" --mode direct-PR >"$W/scaffold.out" 2>&1 \
    || { cat "$W/scaffold.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the decision gate./;s/{JUGGERNAUT_SPEC}/Exercise the decision gate end to end./' "$SH/data/$1/brief.md"
}
file_s() {  # <id> <title> [body]: a queued ship ticket in the start home, with its instructions
  add_row "$SH" "$1" "$2" ship proj "${3:-}" >/dev/null 2>&1 || fail "could not file $1"
  case "$2" in "[design-ux]"*) ;; *) scaffold "$1" || fail "could not scaffold $1" ;; esac
}
spawn() {  # <id>
  local wt="$W/wt-$1-$RANDOM"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  jg_test_run_spawn "$SH" "$wt" "$FAKEBIN" "$1" "$PROJ" codex --mode direct-PR --yolo off
}
refused_clean() { [ ! -e "$SH/state/$1.meta" ] || fail "the refused start of $1 wrote a task record"; }

# S1: the design ticket is only filed - no hold, no ask.
file_s jg-dz1 "[design-ux] Tickets page design"
file_s jg-dz2 "[design-ux] Settings page design" "linked-to: jg-sb2"
file_s jg-sa1 "[feature] Build the tickets page" "linked-to: jg-dz1"
file_s jg-sb2 "[feature] Build the settings page"
file_s jg-sc3 "[feature] Build the tickets filters" "parent: jg-dz1"
for pair in "jg-sa1 jg-dz1" "jg-sb2 jg-dz2" "jg-sc3 jg-dz1"; do  # names it, named by it, parent link
  # shellcheck disable=SC2086
  set -- $pair
  out=$(spawn "$1"); rc=$?
  expect_code 1 "$rc" "S1 the start of $1 linked to open design ticket $2 should be refused: $out"
  assert_contains "$out" "$2" "S1 the refusal of $1 does not name $2"
  refused_clean "$1"
done
file_s jg-su1 "[feature] Fix the footer"
file_s jg-su2 "[feature] Fix the header" "parent: upkeep"
file_s jg-sq1 "[captain-ask] Make the footer taller"
file_s jg-su3 "[feature] Make the footer taller" "linked-to: jg-sq1"
for t in jg-su1 jg-su2 jg-su3; do
  out=$(spawn "$t"); rc=$?
  expect_code 0 "$rc" "S2 $t should start: $out"
done
record_pick "$SH" "$FAKEBIN" jg-dz1
record_pick "$SH" "$FAKEBIN" jg-dz2
for t in jg-sa1 jg-sb2 jg-sc3; do
  out=$(spawn "$t"); rc=$?
  expect_code 0 "$rc" "S3 $t should start after the recorded pick: $out"
done

# ---- the merge side --------------------------------------------------------
MH="$TMP_ROOT/merge-home"
mkdir -p "$MH/data" "$MH/state" "$MH/config" "$MH/projects"
jg_test_beads_home "$MH"
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

tasks_m() { jg_test_backlog "$MH" "$@"; }
PRN=100
# ship_m <id> [body]: an in-flight ship with an open pull request; sets PR.
ship_m() {
  local id=$1 repo wt
  PRN=$((PRN + 1))
  PR="https://github.com/sample/sample/pull/$PRN"
  repo="$MH/projects/sample-$id"
  wt="$MH/projects/$id"
  jg_git_worktree "$repo" "$wt" "fm/$id"
  { add_row "$MH" "$id" "[feature] Ship $id" ship sample "${2:-}" && tasks_m start "$id"; } >/dev/null || fail "could not file $id"
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
add_row "$MH" jg-mz1 "[design-ux] Tickets page design" ship sample "" >/dev/null || fail "M1 could not file jg-mz1"
ship_m jg-ma1 "linked-to: jg-mz1"; pa1=$PR
ship_m jg-mb2; pb2=$PR
ship_m jg-mc3 "parent: jg-mz1"; pc3=$PR
ship_m jg-md4; pd4=$PR
add_row "$MH" jg-mh1 "[feature] Pick the export format" ship sample "" >/dev/null || fail "M1 could not file jg-mh1"
captain "$MH" "$MFAKE" hold jg-mh1 --reason "captain must pick" >/dev/null 2>&1 || fail "M1 could not hold jg-mh1"
ship_m jg-mf6 "linked-to: jg-mh1"; pf6=$PR
add_row "$MH" jg-mz2 "[design-ux] Settings page design" ship sample "linked-to: jg-mb2" >/dev/null || fail "M1 could not file jg-mz2"
for tuple in "jg-ma1 $pa1 jg-mz1" "jg-mb2 $pb2 jg-mz2" "jg-mc3 $pc3 jg-mz1" "jg-mf6 $pf6 jg-mh1"; do
  # shellcheck disable=SC2086
  set -- $tuple
  out=$(merge "$1" "$2" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "M1 the merge of $1 linked to open design ticket $3 went through: $out"
  assert_contains "$out" "$3" "M1 the refusal of $1 does not name $3"
  merged_pr "$2" && fail "M1 the refused merge of $1 reached the forge"
done
ship_m jg-me5 "parent: upkeep"; pe5=$PR
add_row "$MH" jg-mq1 "[captain-ask] Make the footer taller" ship sample "" >/dev/null || fail "M2 file jg-mq1"
ship_m jg-mg7 "linked-to: jg-mq1"; pg7=$PR
for pair in "jg-md4 $pd4" "jg-me5 $pe5" "jg-mg7 $pg7"; do
  # shellcheck disable=SC2086
  set -- $pair
  out=$(merge "$1" "$2" 2>&1); rc=$?
  expect_code 0 "$rc" "M2 $1 should merge: $out"
  merged_pr "$2" || fail "M2 the merge of $1 did not reach the forge"
done
record_pick "$MH" "$MFAKE" jg-mz1
record_pick "$MH" "$MFAKE" jg-mz2
captain "$MH" "$MFAKE" answer jg-mh1 --decision-file "$TMP_ROOT/pick.txt" >/dev/null 2>&1 || fail "M3 could not answer jg-mh1"
for pair in "jg-ma1 $pa1" "jg-mb2 $pb2" "jg-mc3 $pc3" "jg-mf6 $pf6"; do
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
ship_m jg-mr1; pr1=$PR
out=$(dcard); rc=$?
[ "$rc" -ne 0 ] || fail "D1 a design card with no raising ticket was posted: $out"
assert_contains "$out" "must name the ticket that raised it" "D1 the refusal does not say the raising ticket is missing"
out=$(dcard --raised-by no-such-ticket); rc=$?
[ "$rc" -ne 0 ] || fail "D2 a design card naming a ticket this home lacks was posted: $out"
assert_equals 0 "$(board_items)" "D2 a refused design card reached the board"
tasks_m show "$DCARD" >/dev/null 2>&1 && fail "D2 a refused design card filed a design row"
out=$(merge jg-mr1 "$pr1" 2>&1); rc=$?
expect_code 0 "$rc" "D3 the ticket merges while no card is open: $out"
merged_pr "$pr1" || fail "D3 the merge did not reach the forge"
ship_m jg-mr2; pr2=$PR
out=$(dcard --raised-by jg-mr2); rc=$?
expect_code 0 "$rc" "D4 a design card naming its raising ticket should post: $out"
assert_equals 1 "$(board_items)" "D4 the design card did not reach the board"
out=$(dcard --raised-by jg-mr2); rc=$?
expect_code 0 "$rc" "D4 a repeat post should converge: $out"
tasks_m show "$DCARD" 2>&1 | grep -q 'linked-to: jg-mr2' || fail "D4 the design row is not linked to the ticket that raised it"
out=$(merge jg-mr2 "$pr2" 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "D5 the merge of the ticket that raised an open design card went through: $out"
assert_contains "$out" "$DCARD" "D5 the refusal does not name the open design card"
merged_pr "$pr2" && fail "D5 the refused merge reached the forge"
printf '{"key":"%s","answer":"yes","label":"yes","close":"done","at":"2026-11-06T07:00:00Z"}\n' "$DCARD" >> "$SO/.sign-off/decisions.answers.jsonl"
PATH="$MFAKE:$PATH" JG_HOME="$MH" JG_STATE_OVERRIDE="$MH/state" JG_DATA_OVERRIDE="$MH/data" JG_CONFIG_OVERRIDE="$MH/config" \
  SIGN_OFF_HOME="$SO" JG_SEND_SETTLE=0 "$ROOT/bin/jg-board-answers.sh" check >/dev/null 2>&1
out=$(merge jg-mr2 "$pr2" 2>&1); rc=$?
expect_code 0 "$rc" "D6 the ticket should merge after the recorded pick: $out"
merged_pr "$pr2" || fail "D6 the merge did not reach the forge after the recorded pick"
pass "replay: the ticket that raised an open design card is refused at merge, and merges once the pick is recorded"
