#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u
# An installed task-priority feature must not change unrelated cases.
export JG_TASK_PRIORITY_CHECK=/nonexistent

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$ROOT/bin/jg-timeout-lib.sh"

TEARDOWN="$ROOT/bin/jg-teardown.sh"
BEARINGS="$ROOT/bin/jg-bearings-snapshot.sh"
TMP_ROOT=$(jg_test_tmproot jg-captain-hold)

# The PR merge runs the merge-gate evidence lint itself (#424). These cases
# prove the captain-hold authority record, not the evidence folder, so the lint
# is a stub that passes; tests/jg-pr-merge.test.sh proves the lint refusal.
PASS_LINT="$TMP_ROOT/pass-lint.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "checks-lint: PASS"' > "$PASS_LINT"
chmod +x "$PASS_LINT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  jg_test_beads_home "$home"
  : > "$home/config/backlog-intake-loose"
  fakebin=$(jg_fakebin "$home")
  jg_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json "$@"
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <backlog args...>
  local home=$1 arg start=0 args=()
  shift
  # `add --start` is refused (dispatch owns the In flight move), so add then start.
  for arg in "$@"; do [ "$arg" = --start ] && start=1 || args+=("$arg"); done
  jg_test_backlog "$home" "${args[@]}" || return
  if [ "$start" = 1 ] && [ "${args[0]}" = add ]; then jg_test_backlog "$home" start "${args[1]}" >/dev/null; fi
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
    JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}

# Completes <id>'s captain-call inventory through a separate held task, because
# the origin task is never accepted as its own inventory entry.
complete_through_sibling() {  # <home> <origin-id>
  local home=$1 id=$2
  run_captain "$home" hold "$id-call" --title "Sibling captain call for $id" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    && run_captain "$home" complete "$id" "$id-call"
}

request_reconciles() {  # <home> <source-id> <task-id>...
  local home=$1 source_id=$2 id
  shift 2
  run_captain "$home" bind "$source_id" >/dev/null || return 1
  for id in "$@"; do printf '%s\n' "$id"; done \
    | run_captain "$home" reconcile-requests --source-id "$source_id" \
        --source "captured board result" >/dev/null
}

configure_merged_github() {  # <home>
  local home=$1
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}'
        ;;
      *headRefOid*) printf '%s\n' 1111111111111111111111111111111111111111 ;;
    esac
    ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "api graphql")
    printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main'
    ;;
  "api --paginate")
    case " $* " in
      *merge_queue*) ;;
      *) printf '%s\n' '[]' ;;
    esac
    ;;
  "api repos/"*) printf '%s\n' '{"name":"main","protected":false}' ;;
esac
SH
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/gh-axi"
  : > "$home/gh.log"
  : > "$home/gh-axi.log"
}

run_pr_merge() {  # <home> <id> <url>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_TEST_GH_LOG="$home/gh.log" \
    JG_TEST_GH_AXI_LOG="$home/gh-axi.log" JG_PR_MERGE_CHECKS_LINT="$PASS_LINT" \
    "$ROOT/bin/jg-pr-merge.sh" "$@"
}

wait_for_test_file() {  # <path> <pid>
  local path=$1 pid=$2 i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$path" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.01
    i=$((i + 1))
  done
  return 1
}

install_reused_task_barriers() {  # <home>
  local home=$1
  cat > "$home/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${JG_TEST_REUSE_TEARDOWN:-}" = 1 ] \
    && [ ! -e "${JG_TEST_REUSE_TEARDOWN_ONCE:-}" ]; then
  : > "$JG_TEST_REUSE_TEARDOWN_ONCE"
  : > "$JG_TEST_REUSE_TEARDOWN_READY"
  while [ ! -e "$JG_TEST_REUSE_TEARDOWN_RELEASE" ]; do
    "$JG_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$JG_TEST_REAL_PERL" "$@"
SH
  cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${JG_TEST_REUSE_MERGE:-}" = 1 ] && [ "${1:-}" = 0.1 ] \
    && [ ! -e "${JG_TEST_REUSE_MERGE_ONCE:-}" ]; then
  : > "$JG_TEST_REUSE_MERGE_ONCE"
  : > "$JG_TEST_REUSE_MERGE_READY"
  while [ ! -e "$JG_TEST_REUSE_MERGE_RELEASE" ]; do
    "$JG_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$JG_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$home/fakebin/perl" "$home/fakebin/sleep"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" \
    JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# A hold hands its card to core/signoff, which owns the board and refuses an ask it cannot author;
# the catalog's per-home routing stub is gone with the catalog. core/signoff/tests owns the card
# contract itself, and this suite owns only the hold side: an armed home reaches the feature, and a
# home whose card cannot be raised keeps the hold recorded and says so.
signoff_addon_stub() {  # <stub-dir>: a card script the hold is pointed at
  mkdir -p "$1/signoff/bin"
  cat > "$1/signoff/bin/jg-procevent-signoff.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$1" "$2" "$JG_HOME" "$JG_CODE_ROOT" >> "$SIGNOFF_LOG"
exit "$SIGNOFF_STATUS"
SH
  chmod +x "$1/signoff/bin/jg-procevent-signoff.sh"
}

signoff_hold() {  # <home> <task-id>
  local home=$1 id=$2
  env -u JG_CODE_ROOT PATH="$home/fakebin:$PATH" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-captain-hold.sh" hold "$id" --title "Route the card" \
    --must design-pick --reason "captain must decide" --repo sample
}

test_hold_reaches_the_core_signoff_card_path() {
  local home out id=jg-signoff-core-route
  home=$(make_home signoff-core-route)
  mkdir -p "$home/projects/sample" "$home/state/procevent"
  : > "$home/state/procevent/signoff.source"
  out=$(signoff_hold "$home" "$id" 2>&1) || fail "a hold with no authored ask exited nonzero: $out"
  assert_contains "$out" "no authored owner ask" \
    "an armed hold did not reach the core sign-off card path"
  tasks_in "$home" show "$id" >/dev/null || fail "a hold whose card failed did not stay recorded"
  pass "an armed hold reaches core/signoff and keeps its record and exits 0 when it has no authored ask"
}

# A hold that is the captain's own instruction - his stop order, or a branch we
# preserved instead of landing - records the hold and raises nothing: no card for
# him and no ask for Main. The recorded card his phone showed him is the case; its
# record number is a placeholder, because the repo's owner-details guard forbids
# committing his own number to a public repository.
hold_with_reason() {  # <home> <addons-dir> <log> <task-id> <reason>
  local home=$1 addons=$2 log=$3 id=$4 reason=$5
  env -u JG_CODE_ROOT PATH="$home/fakebin:$PATH" JG_HOME="$home" \
    JG_SIGNOFF_SCRIPT="$addons/signoff/bin/jg-procevent-signoff.sh" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    SIGNOFF_LOG="$log" SIGNOFF_STATUS="${SIGNOFF_STATUS:-0}" \
    "$ROOT/bin/jg-captain-hold.sh" hold "$id" --title "Route the card" --reason "$reason" --repo sample
}

test_a_hold_that_is_the_captains_own_instruction_raises_no_card() {
  local home addons log out rc=0 id=jg-stop-order-held real=jg-stop-order-real-ask
  home=$(make_home stop-order-held)
  addons="$home/addons"
  log="$home/signoff.log"
  mkdir -p "$home/projects/sample" "$home/state/procevent"
  : > "$home/state/procevent/signoff.source"
  signoff_addon_stub "$addons"
  out=$(hold_with_reason "$home" "$addons" "$log" "$id" \
    "captain stop order Main42 holds this lane; branch preserved unmerged" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a stop-order hold was refused instead of recorded: $out"
  tasks_in "$home" show "$id" >/dev/null || fail "the stop-order hold was not recorded"
  assert_absent "$log" "a stop-order hold raised a card"
  assert_absent "$home/data/overwatch-decisions.md" "a stop-order hold was recorded for Main as a board ask"
  # The counter-case: a real product question still reaches the board.
  hold_with_reason "$home" "$addons" "$log" "$real" \
    "Ship the new sign-in screen this week?" >/dev/null 2>&1 || fail "a real captain ask was refused"
  assert_grep "raise|$real|" "$log" "a real captain ask raised no card"
  pass "a stop-order hold records the hold alone, and a real ask still raises its card"
}

# A hold that is a direction with no question for the captain gets no card, and that
# is a success: the signoff adapter says so with exit 3 and the hold exits 0. Any
# other adapter failure still fails the command, with the hold recorded.
test_a_direction_hold_with_no_card_exits_zero_and_a_real_card_failure_does_not() {
  local home addons log out rc id=jg-direction-held
  home=$(make_home direction-held)
  addons="$home/addons"
  log="$home/signoff.log"
  mkdir -p "$home/projects/sample" "$home/state/procevent"
  : > "$home/state/procevent/signoff.source"
  signoff_addon_stub "$addons"
  rc=0
  out=$(SIGNOFF_STATUS=3 hold_with_reason "$home" "$addons" "$log" "$id" \
    "Keep the release lane parked until the new build lands" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a direction hold with no card exited $rc instead of 0: $out"
  tasks_in "$home" show "$id" >/dev/null || fail "the direction hold was not recorded"
  assert_grep "raise|$id|" "$log" "the direction hold never reached the card path"
  rc=0
  out=$(SIGNOFF_STATUS=1 hold_with_reason "$home" "$addons" "$log" "jg-direction-failed" \
    "Keep the release lane parked until the new build lands" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a real card failure exited 0: $out"
  tasks_in "$home" show "jg-direction-failed" >/dev/null || fail "the hold was not recorded before the card failed"
  pass "a hold with no card to raise exits 0, and a real card failure still exits nonzero"
}

test_a_parked_hold_raises_no_card() {
  local home addons log out rc=0 id=jg-parked-held
  home=$(make_home parked-held)
  addons="$home/addons"
  log="$home/signoff.log"
  mkdir -p "$home/projects/sample" "$home/state/procevent"
  : > "$home/state/procevent/signoff.source"
  signoff_addon_stub "$addons"
  tasks_in "$home" add "$id" "Route the card" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the parked fixture"
  BEADS_DIR=$(cat "$home/config/beads-dir") "$ROOT/bin/jg-beads.sh" update "$id" --status on_hold \
    --set-metadata hold_reason="waiting on a parked lane" --set-metadata hold_kind=parked >/dev/null \
    || fail "could not park the fixture"
  out=$(hold_with_reason "$home" "$addons" "$log" "$id" "who signs off the release" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a parked hold was refused instead of recorded: $out"
  assert_contains "$(tasks_in "$home" show "$id" --full)" "hold_kind: captain" "the parked hold was not re-recorded for the captain"
  assert_absent "$log" "a parked hold raised a card"
  assert_absent "$home/data/overwatch-decisions.md" "a parked hold was recorded for Main as a board ask"
  pass "a hold whose kind is parked records the hold alone and raises no card"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=jg-sample-route-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the uninventoried fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "jg-sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=jg-sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold jg-sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" jg-sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add jg-sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by jg-sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer jg-sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer jg-sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer jg-sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer jg-sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show jg-sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer jg-sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show jg-sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by jg-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer jg-sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer jg-sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show jg-sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "jg-sample-guard-call") | not)
      and (.gates | any(.id == "jg-sample-guard-call") | not)
      and (.landed | any(.id == "jg-sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# A release from a board answer tells the owner what started: one
# `sign-off-axi feedback --reply` on the card, and a feedback failure never
# fails the release.
test_release_posts_its_reply_on_the_card() {
  local home log rc
  home=$(make_home release-reply)
  log="$home/feedback.log"
  cat > "$home/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = feedback ] || exit 0
printf '%s\n' "$*" >> "$FEEDBACK_LOG"
exit "${FEEDBACK_RC:-0}"
SH
  chmod +x "$home/fakebin/sign-off-axi"
  printf 'Go.\n' > "$home/go.txt"
  tasks_in "$home" add reply-widget "Ship the reply widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold reply-widget --reason "captain go needed" >/dev/null
  FEEDBACK_LOG=$log run_captain "$home" answer reply-widget --decision-file "$home/go.txt" --release --card fd-open-calls >/dev/null \
    || fail "answer --release failed"
  assert_grep "feedback fd-open-calls " "$log" "the release did not reply on the answered card"
  assert_grep "--reply Released reply-widget: Ship the reply widget" "$log" \
    "the release reply did not name the task and its outcome"
  tasks_in "$home" add keyed-widget "Ship the keyed widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold keyed-widget --reason "captain go needed" >/dev/null
  printf 'keyed-widget\tgo\t\trelease\n' | FEEDBACK_LOG=$log run_captain "$home" answers --source "reply fixture" >/dev/null \
    || fail "a keyed release failed"
  assert_grep "feedback keyed-widget " "$log" "a keyed release did not reply on its card"
  tasks_in "$home" add broken-widget "Ship the broken widget" --kind ship --repo sample >/dev/null
  run_captain "$home" hold broken-widget --reason "captain go needed" >/dev/null
  rc=0
  FEEDBACK_RC=5 FEEDBACK_LOG=$log run_captain "$home" answer broken-widget --decision-file "$home/go.txt" --release --card broken-card >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "a failing feedback call failed the release"
  assert_contains "$(tasks_in "$home" show broken-widget --full)" "held: no" "a failing feedback call left the hold in place"
  pass "a release replies on its card with what starts, and a feedback failure never fails it"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add jg-sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  JG_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold jg-sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer jg-sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show jg-sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
  run_captain "$home" answer jg-sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer jg-sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show jg-sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add jg-sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold jg-sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'jg-sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: jg-sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show jg-sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  JG_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold jg-sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    JG_PROJECTS_OVERRIDE="$home/projects" JG_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/jg-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "jg-sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer jg-sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show jg-sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" jg-sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer jg-sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show jg-sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# The recorded-answer guard survives an out-of-band close: a bare jg-backlog.sh done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=jg-sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold jg-sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" jg-sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" jg-sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer jg-sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show jg-sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer jg-sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer jg-sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add jg-sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" jg-sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer jg-sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=jg-sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/data/review"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/data/review/jg-sample-board.html"
  run_captain "$home" hold jg-sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" jg-sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "jg-sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=jg-sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("jg-sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open squad_lead
  home=$(make_home stale-terminal-decision)
  id=jg-sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'blocked [key=access]: waiting\ndone: report complete\nnote: cleanup complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/jg-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "the shared fold retained a pre-terminal blocker"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  printf 'blocked [key=access]: reopened\nnote: more cleanup\n' >> "$home/state/$id.status"
  if run_captain "$home" complete "$id" --none > "$home/reopened.out" 2> "$home/reopened.err"; then
    fail "completion accepted a genuinely reopened post-terminal decision"
  fi
  if run_captain "$home" verify "$id" > "$home/reopened-verify.out" 2> "$home/reopened-verify.err"; then
    fail "verification accepted a genuinely reopened post-terminal decision"
  fi
  printf 'resolved [key=access]: answered\nfailed: investigation ended\nnote: final cleanup\n' >> "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null || fail "resolved reopening blocked completion"
  run_captain "$home" verify "$id" >/dev/null || fail "resolved reopening blocked verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  squad_lead=jg-sample-squad-lead
  write_origin_meta "$home" "$squad_lead" squad_lead
  printf 'blocked [key=route]: waiting\ndone: heartbeat complete\nnote: cleanup complete\n' \
    > "$home/state/$squad_lead.status"
  if run_captain "$home" complete "$squad_lead" --none \
    > "$home/squad-lead-terminal.out" 2> "$home/squad-lead-terminal.err"; then
    fail "squad_lead terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_reconcile_retry_after_completed_close_of_a_merged_captain_ask() {
  local parent mate evidence request out
  parent=$(make_home reconcile-ask-parent)
  mate=$(make_home reconcile-ask-mate)
  printf 'reconcile-ask-mate\n' > "$mate/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$mate/.jg-squad-lead-parent"
  evidence="$mate/reconcile-evidence.txt"
  request="$mate/state/reconcile-requests/reconcile-ask.request"
  tasks_in "$mate" add reconcile-ask "[captain-ask] Verify the merged ask" --kind ship --repo sample >/dev/null \
    || fail "could not create the merged captain-ask call"
  tasks_in "$mate" update reconcile-ask --pr https://github.com/o/r/pull/1 >/dev/null \
    || fail "could not link the merged PR to the captain-ask call"
  run_captain "$mate" hold reconcile-ask --reason "verify current release state" >/dev/null \
    || fail "could not hold the merged captain-ask call"
  request_reconciles "$mate" reconcile-board reconcile-ask || fail "could not request the captain-ask reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  printf '%s\n' '#!/bin/sh' 'echo MERGED' > "$mate/fakebin/gh"
  chmod +x "$mate/fakebin/gh"

  chmod 0500 "$mate/state/reconcile-requests"
  out=$(run_captain "$mate" reconcile close reconcile-ask --evidence-file "$evidence" 2>&1) \
    && fail "failed reconcile request retirement reported success: $out"
  chmod 0700 "$mate/state/reconcile-requests"
  assert_contains "$(tasks_in "$mate" show reconcile-ask --full)" "state: done" \
    "request retirement failure reversed the merged captain-ask close"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"

  run_captain "$mate" reconcile close reconcile-ask --evidence-file "$evidence" >/dev/null \
    || fail "the completed reconcile close of a merged captain-ask could not be retried"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
}

test_squad_lead_reconcile_publishes_before_request_retirement() {
  local parent mate channel evidence out show rc request
  parent=$(make_home reconcile-parent-channel)
  mate=$(make_home reconcile-channel-mate)
  printf 'reconcile-channel-mate\n' > "$mate/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.jg-squad-lead-parent"
  channel="$parent/state/reconcile-channel-mate.status"
  evidence="$mate/reconcile-evidence.txt"

  tasks_in "$mate" add reconcile-channel-call "Verify the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the reconcile channel call"
  run_captain "$mate" hold reconcile-channel-call --reason "verify current release state" >/dev/null \
    || fail "could not hold the reconcile channel call"
  request_reconciles "$mate" reconcile-board reconcile-channel-call \
    || fail "could not request the channel reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  request="$mate/state/reconcile-requests/reconcile-channel-call.request"

  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" reconcile close reconcile-channel-call \
    --evidence-file "$evidence" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed reconcile request retirement reported success"
  assert_contains "$out" "reconcile-channel-call" \
    "the reconcile retirement failure did not name its task: $out"
  show=$(tasks_in "$mate" show reconcile-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the reconciled close"
  assert_contains "$show" "Resolution mode: reconciled" \
    "request retirement failure lost the reconciled resolution mode"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the parent resolution was not published before retirement failed: $(cat "$channel")"

  run_captain "$mate" reconcile close reconcile-channel-call --evidence-file "$evidence" >/dev/null \
    || fail "the closed reconciliation could not finish publication and retirement"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the reconciliation retry duplicated or changed its parent resolution: $(cat "$channel")"
  tasks_in "$mate" add answer-channel-call "Answer the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the normal-answer channel call"
  run_captain "$mate" hold answer-channel-call --reason "captain answer needed" >/dev/null \
    || fail "could not hold the normal-answer channel call"
  request_reconciles "$mate" reconcile-board answer-channel-call \
    || fail "could not create the normal-answer retry trigger"
  printf 'Proceed with the release.\n' > "$mate/answer.txt"
  request="$mate/state/reconcile-requests/answer-channel-call.request"
  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed normal-answer request retirement reported success"
  show=$(tasks_in "$mate" show answer-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the captain answer"
  [ -f "$request" ] || fail "the normal-answer retry trigger retired after its forced failure"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal answer did not publish before retirement failed: $(cat "$channel")"
  run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" >/dev/null \
    || fail "the normal-answer retry could not finish request retirement"
  [ ! -e "$request" ] || fail "the normal-answer retry left its request pending"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal-answer retry duplicated its parent resolution: $(cat "$channel")"
  pass "squad_lead resolutions publish before retiring durable retry triggers"
}

# A keyed answer is settled for good only when the intake's exit says so: a batch
# whose every skip is permanent exits 3, while a transient skip exits without 3 so
# the runner keeps the answer for the next round.
test_keyed_answer_exit_status_separates_settled_from_retried() {
  local home out rc
  home=$(make_home keyed-exit-status)
  tasks_in "$home" add jg-sample-closed "Closed call" --repo sample >/dev/null \
    || fail "could not create the closed task"
  tasks_in "$home" "done" jg-sample-closed >/dev/null || fail "could not close the task"
  tasks_in "$home" add jg-sample-free "Free work" --repo sample >/dev/null \
    || fail "could not create the unheld task"

  set +e
  out=$(printf 'jg-sample-closed\tUse it\tLabel\n' | run_captain "$home" answers --source "keyed exit fixture" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an already-closed answer did not exit 3 (rc $rc): $out"

  set +e
  out=$(printf 'jg-sample-free\tUse it\tLabel\n' | run_captain "$home" answers --source "keyed exit fixture" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a not-held answer did not exit 3 (rc $rc): $out"

  set +e
  out=$(printf 'jg-sample-absent\tUse it\tLabel\n' | run_captain "$home" answers --source "keyed exit fixture" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an absent answer did not exit 1 (rc $rc): $out"

  pass "a keyed answer exits 3 only when every skip is settled, and a transient skip keeps it retryable"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
# A reconcile is "go re-check reality", never the captain's answer. The value is
# reserved at the one keyed-answer intake, so no channel and no card-declared
# close mode can turn it into a close or a release, and the obligation to verify
# survives as a durable request instead of evaporating with the wake.
test_reconcile_never_closes_through_the_keyed_answer_intake() {
  local home out rc show list
  home=$(make_home reconcile-intake)
  tasks_in "$home" add jg-sample-reconcile-call "Captain call: still current?" --repo sample >/dev/null \
    || fail "could not create the reconcile call"
  tasks_in "$home" add jg-sample-reconcile-gated "Gated work" --repo sample >/dev/null \
    || fail "could not create the gated work item"
  run_captain "$home" hold jg-sample-reconcile-call --reason "is this still current?" >/dev/null \
    || fail "could not hold the reconcile call"
  run_captain "$home" hold jg-sample-reconcile-gated --reason "waiting on the captain" >/dev/null \
    || fail "could not hold the gated work item"

  set +e
  out=$(printf 'jg-sample-reconcile-call\treconcile\tReconcile\n%s\n' \
    "$(printf 'jg-sample-reconcile-gated\treconcile\tReconcile\trelease')" \
    | run_captain "$home" answers --source "captain chat" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the shared answer intake accepted reconcile as an answer"
  assert_contains "$out" "refused: jg-sample-reconcile-call" \
    "the shared intake did not visibly refuse reconcile: $out"
  case "$out" in
    *"closed: jg-sample-reconcile"*) fail "a reconcile row closed a captain call: $out" ;;
  esac

  show=$(tasks_in "$home" show jg-sample-reconcile-call --full)
  assert_contains "$show" "state: queued" "a reconcile row completed a captain call"
  assert_contains "$show" "held: yes" "a reconcile row released a captain call"
  case "$show" in
    *"Resolution recorded by"*) fail "a reconcile row wrote a resolution record" ;;
  esac
  show=$(tasks_in "$home" show jg-sample-reconcile-gated --full)
  assert_contains "$show" "held: yes" "a release-mode reconcile row lifted a captain hold"

  list=$(run_captain "$home" reconcile list) || fail "could not list the reconcile requests"
  assert_contains "$list" "reconcile-requests: 0" \
    "the shared answer intake created a reconcile request: $list"
  set +e
  out=$(printf 'jg-sample-reconcile-call\n' \
    | run_captain "$home" reconcile-requests --source-id unbound-src --source "captured board" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound captured source created a reconcile request"
  request_reconciles "$home" board-src jg-sample-reconcile-call jg-sample-reconcile-gated \
    || fail "the bound captured source did not create reconcile requests"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "jg-sample-reconcile-call" "the reconcile obligation was not recorded durably: $list"
  assert_contains "$list" "reconcile-requests: 2" "the reconcile requests were not both recorded: $list"

  request_reconciles "$home" board-src jg-sample-reconcile-call \
    || fail "replaying a captured reconcile selection failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 2" "a replayed reconcile selection duplicated the obligation: $list"
  pass "only a bound captured source creates reconcile requests"
}

test_normal_answers_retire_pending_reconcile_requests() {
  local home list id
  home=$(make_home reconcile-normal-answer)
  for id in jg-sample-direct-close jg-sample-direct-release jg-sample-keyed-close; do
    tasks_in "$home" add "$id" "Captain call $id" --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting for the captain" >/dev/null
  done
  request_reconciles "$home" board-src jg-sample-direct-close jg-sample-direct-release jg-sample-keyed-close \
    || fail "could not create reconcile requests before normal answers"

  printf 'Captain said close.\n' > "$home/close.txt"
  printf 'Captain said release.\n' > "$home/release.txt"
  run_captain "$home" answer jg-sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close answer failed"
  run_captain "$home" answer jg-sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release answer failed"
  printf 'jg-sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed normal answer failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "normal answers left stranded reconcile requests: $list"

  run_captain "$home" answer jg-sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close replay failed"
  run_captain "$home" answer jg-sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release replay failed"
  printf 'jg-sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed answer replay failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "an idempotent normal-answer replay restored a reconcile request: $list"
  pass "normal answers and their replays retire reconcile requests"
}

# The two verification outcomes, and the honesty of the record each writes.
test_reconcile_closes_with_evidence_or_keeps_the_call_open() {
  local home show list rc out
  home=$(make_home reconcile-outcomes)
  tasks_in "$home" add jg-sample-moot-call "Captain call: ship 0.1.37?" --repo sample >/dev/null
  tasks_in "$home" add jg-sample-active-call "Captain call: which admission order?" --repo sample >/dev/null
  tasks_in "$home" add jg-sample-mode-call "Captain call: verify replay mode?" --repo sample >/dev/null
  run_captain "$home" hold jg-sample-moot-call --reason "ship 0.1.37?" >/dev/null
  run_captain "$home" hold jg-sample-active-call --reason "which admission order?" >/dev/null
  run_captain "$home" hold jg-sample-mode-call --reason "verify replay mode?" >/dev/null
  printf '0.1.38 was published on 2026-09-05, so the 0.1.37 question is moot.\n' > "$home/evidence.txt"
  printf 'Still open: nothing has shipped and the choice is unchanged.\n' > "$home/note.txt"

  set +e
  out=$(run_captain "$home" reconcile close jg-sample-moot-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile closed a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated close refusal did not name the missing board request: $out"
  set +e
  out=$(run_captain "$home" reconcile note jg-sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile annotated a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated note refusal did not name the missing board request: $out"

  request_reconciles "$home" board-src jg-sample-moot-call jg-sample-active-call jg-sample-mode-call \
    || fail "could not file the reconcile requests"

  set +e
  out=$(run_captain "$home" reconcile close jg-sample-moot-call 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconcile close was accepted with no evidence"
  assert_contains "$out" "evidence" "the refusal did not name the missing evidence: $out"

  cp "$home/state/reconcile-requests/jg-sample-mode-call.request" "$home/mode-request.backup"
  run_captain "$home" answer jg-sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "could not record the normal answer for the mode fixture"
  cp "$home/mode-request.backup" "$home/state/reconcile-requests/jg-sample-mode-call.request"
  set +e
  out=$(run_captain "$home" reconcile close jg-sample-mode-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a normal captain answer replayed as a reconciliation"
  assert_contains "$out" "was not closed by reconciliation" \
    "the reconcile replay refusal did not identify the incompatible resolution mode: $out"
  run_captain "$home" answer jg-sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "the normal answer replay did not retire its restored pending request"

  run_captain "$home" reconcile close jg-sample-moot-call --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "could not close the moot call with evidence"
  show=$(tasks_in "$home" show jg-sample-moot-call --full)
  assert_contains "$show" "state: done" "the moot call did not close"
  assert_contains "$show" "Resolution mode: reconciled" "the moot call did not record how it closed"
  assert_contains "$show" "Reconciliation evidence:" "the moot call did not record the evidence"
  assert_contains "$show" "0.1.38 was published" "the recorded evidence was lost"
  case "$show" in
    *"Captain decision:"*) fail "a reconciled close was recorded as the captain's own words" ;;
  esac
  set +e
  out=$(run_captain "$home" answer jg-sample-moot-call --decision-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconciled resolution replayed as a captain answer"
  assert_contains "$out" "not a captain-answer replay" \
    "the answer replay refusal did not identify the incompatible resolution mode: $out"

  run_captain "$home" reconcile note jg-sample-active-call --note-file "$home/note.txt" >/dev/null \
    || fail "could not annotate the still-active call"
  show=$(tasks_in "$home" show jg-sample-active-call --full)
  assert_contains "$show" "state: queued" "annotating a still-active call closed it"
  assert_contains "$show" "held: yes" "annotating a still-active call released it"
  assert_contains "$show" "Captain hold reconciled:" "the re-check left no dated note"
  assert_contains "$show" "Still open: nothing has shipped" "the note body was lost"
  case "$show" in
    *"Resolution recorded by"*) fail "annotating a still-active call wrote a resolution record" ;;
  esac
  set +e
  out=$(run_captain "$home" reconcile note jg-sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a retired reconcile request appended a duplicate note"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the duplicate-note refusal did not name the retired request: $out"

  printf 'jg-sample-active-call\n' \
    | JG_CAPTAIN_HOLD_NOW=2026-09-07T06:00:00Z run_captain "$home" reconcile-requests \
        --source-id board-src --source "captured board result sequence 2" >/dev/null \
    || fail "could not create the second reconcile request"
  JG_CAPTAIN_HOLD_NOW=2026-09-07T06:01:00Z run_captain "$home" reconcile note jg-sample-active-call \
    --note-file "$home/note.txt" >/dev/null \
    || fail "the second request with the same finding was not recorded"
  show=$(tasks_in "$home" show jg-sample-active-call --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold reconciled:' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a later reconcile request with the same note did not append its own record"
  assert_contains "$show" "Captain hold reconciled: 2026-09-07T06:01:00Z" \
    "the second reconcile request lost its own dated note"

  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "the verified requests were not retired: $list"
  pass "reconcile closes a moot call with evidence and keeps an active one open with a note"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=jg-sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add jg-sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add jg-sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to jg-sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to jg-sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to jg-sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- jg-sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show jg-sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add jg-sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by jg-decision-hold.\nDecision digest: %s\nRouted identities: jg-sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- jg-sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to jg-sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show jg-sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by jg-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show list
  home=$(make_home chat-channel)
  id=jg-sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold jg-sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" hold jg-sample-chat-reconcile --title "Reconcile from chat" \
    --reason "captain chat reconcile pending" --repo sample >/dev/null \
    || fail "could not register the chat reconcile call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" jg-sample-chat-followup \
    jg-sample-chat-reconcile >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$JG_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$home" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_SEND_LOG="$home/send.log" JG_SEND_SETTLE=0 \
    "$ROOT/bin/jg-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides jg-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$home" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_SEND_LOG="$home/send.log" JG_SEND_SETTLE=0 \
    "$ROOT/bin/jg-send.sh" "$id" --resolve-key jg-sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show jg-sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  : > "$home/send.log"
  set +e
  env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$home" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_SEND_LOG="$home/send.log" JG_SEND_SETTLE=0 \
    "$ROOT/bin/jg-send.sh" "$id" --resolve-key jg-sample-chat-reconcile reconcile >/dev/null 2>&1
  set -e
  show=$(tasks_in "$home" show jg-sample-chat-reconcile --full)
  assert_contains "$show" "state: queued" "a chat reconcile answer closed the call"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "a chat reconcile answer created a board request"
  printf 'Chat cannot authorize this closure.\n' > "$home/chat-reconcile.txt"
  if run_captain "$home" reconcile close jg-sample-chat-reconcile \
    --evidence-file "$home/chat-reconcile.txt" >/dev/null 2>&1; then
    fail "a chat reconcile answer authorized evidence-backed closure"
  fi
  run_captain "$home" answer jg-sample-chat-reconcile --decision-file "$home/chat-reconcile.txt" >/dev/null \
    || fail "could not close the chat reconcile fixture normally"

  if env PATH="$fb:$PATH" JG_ROOT_OVERRIDE="$home" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_SEND_LOG="$home/send.log" JG_SEND_SETTLE=0 \
    "$ROOT/bin/jg-send.sh" "$id" --resolve-key jg-sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" \
    JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-wake-drain.sh" 2>/dev/null
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=jg-sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold jg-sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold jg-sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold jg-sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer jg-sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add jg-sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=jg-sample-transfer-call]: choose the retention window
captain-held [key=jg-sample-transfer-call]: tracked by jg-sample-transfer-call
needs-decision [key=jg-sample-open-call]: still open on both sides
needs-decision [key=jg-sample-answered-call]: choose the export format
resolved [key=jg-sample-answered-call]: answered: CSV
needs-decision [key=jg-sample-plain-work]: worker question about the sample fixture
resolved [key=jg-sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold jg-sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'jg-sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=jg-sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=jg-sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=jg-sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

test_retained_row_artifacts_survive_captain_answers() {
  local home retained_id precedence_id rejected_id rejected_local_id report_question_id
  local approved_id released_id local_id answered_id reportless_scout_id legacy_id
  local repo wt
  local local_repo local_wt
  local precedence_pr rejected_pr approved_pr released_pr json show
  home=$(make_home retained-row-artifacts)
  retained_id=jg-sample-retained-report
  mkdir -p "$home/data/$retained_id"
  tasks_in "$home" add "$retained_id" "Investigate retained report evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the retained report fixture"
  write_origin_meta "$home" "$retained_id"
  printf 'done: report complete\n' > "$home/state/$retained_id.status"
  printf '# Retained report\n\nThe captain must choose the follow-up.\n' \
    > "$home/data/$retained_id/report.md"
  run_captain "$home" hold "$retained_id" --reason "captain must choose the report follow-up" \
    >/dev/null || fail "could not hold the retained report"
  complete_through_sibling "$home" "$retained_id" >/dev/null \
    || fail "completion gate failed for the retained report"
  run_teardown "$home" "$retained_id" > "$home/retained-teardown.out" \
    2> "$home/report-teardown.err" \
    || fail "retained report cleanup failed: $(cat "$home/report-teardown.err")"
  printf 'Proceed with the report follow-up.\n' > "$home/report-answer.txt"
  run_captain "$home" answer "$retained_id" --decision-file "$home/report-answer.txt" >/dev/null \
    || fail "could not answer the retained report call"

  precedence_id=jg-sample-retained-report-pr-title
  precedence_pr=https://github.com/sample/sample/pull/21
  mkdir -p "$home/data/$precedence_id"
  tasks_in "$home" add "$precedence_id" "Investigate $precedence_pr regression" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the report precedence fixture"
  write_origin_meta "$home" "$precedence_id"
  printf 'done: report complete\n' > "$home/state/$precedence_id.status"
  printf '# Retained report with pull request context\n' \
    > "$home/data/$precedence_id/report.md"
  run_captain "$home" hold "$precedence_id" \
    --reason "captain must choose the report follow-up" >/dev/null \
    || fail "could not hold the report precedence fixture"
  complete_through_sibling "$home" "$precedence_id" >/dev/null \
    || fail "completion gate failed for the report precedence fixture"
  run_teardown "$home" "$precedence_id" > "$home/precedence-teardown.out" \
    2> "$home/precedence-teardown.err" \
    || fail "report precedence cleanup failed: $(cat "$home/precedence-teardown.err")"
  printf 'Proceed with the pull-request regression report.\n' \
    > "$home/precedence-answer.txt"
  run_captain "$home" answer "$precedence_id" \
    --decision-file "$home/precedence-answer.txt" >/dev/null \
    || fail "could not answer the report precedence call"
  show=$(tasks_in "$home" show "$precedence_id" --full) \
    || fail "the report precedence row disappeared"
  assert_contains "$show" "state: done" "the report precedence answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report precedence row lost its retained-scout evidence"

  rejected_id=jg-sample-rejected-merge
  rejected_pr="https://github.com/sample/sample/pull/22"
  tasks_in "$home" add "$rejected_id" "Decide whether $rejected_pr may merge" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected merge fixture"
  run_captain "$home" hold "$rejected_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the rejected merge"
  printf 'Do not merge this pull request.\n' > "$home/rejected-answer.txt"
  run_captain "$home" answer "$rejected_id" --decision-file "$home/rejected-answer.txt" \
    >/dev/null || fail "could not record the rejected merge"
  show=$(tasks_in "$home" show "$rejected_id" --full) || fail "the rejected merge disappeared"
  assert_contains "$show" "state: done" "the rejected merge answer did not close its call"
  assert_contains "$show" "hold_kind: captain" "the rejected merge lost its non-release evidence"

  rejected_local_id=jg-sample-rejected-local
  tasks_in "$home" add "$rejected_local_id" "Decide whether to land local main" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected local fixture"
  run_captain "$home" hold "$rejected_local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the rejected local merge"
  printf 'Do not land this change locally.\n' > "$home/rejected-local-answer.txt"
  run_captain "$home" answer "$rejected_local_id" \
    --decision-file "$home/rejected-local-answer.txt" >/dev/null \
    || fail "could not record the rejected local merge"
  show=$(tasks_in "$home" show "$rejected_local_id" --full) \
    || fail "the rejected local merge disappeared"
  assert_contains "$show" "state: done" "the rejected local answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the rejected local merge lost its non-release evidence"

  report_question_id=jg-sample-report-path-question
  tasks_in "$home" add "$report_question_id" \
    "Decide whether data/$report_question_id/report.md should be published" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the report-path question fixture"
  run_captain "$home" hold "$report_question_id" \
    --reason "captain report publication decision pending" >/dev/null \
    || fail "could not hold the report-path question"
  printf 'Do not publish this report.\n' > "$home/report-question-answer.txt"
  run_captain "$home" answer "$report_question_id" \
    --decision-file "$home/report-question-answer.txt" >/dev/null \
    || fail "could not record the report-path answer"
  show=$(tasks_in "$home" show "$report_question_id" --full) \
    || fail "the report-path question disappeared"
  assert_contains "$show" "state: done" "the report-path answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report-path question lost its non-release evidence"

  approved_id=jg-sample-approved-merge
  approved_pr="https://github.com/sample/sample/pull/23"
  repo="$home/projects/jg-sample-approved"
  wt="$home/projects/$approved_id"
  jg_git_worktree "$repo" "$wt" fm/approved-merge
  tasks_in "$home" add "$approved_id" "Ship the approved pull request $approved_pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the approved merge fixture"
  jg_write_meta "$home/state/$approved_id.meta" \
    "window=juggernaut:jg-$approved_id" "endpoint_task_id=$approved_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$approved_pr" "spawn_gen=fixture-$approved_id"
  printf 'done: PR %s merged\n' "$approved_pr" > "$home/state/$approved_id.status"
  run_captain "$home" hold "$approved_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the approved merge"
  printf 'Merge the approved pull request.\n' > "$home/approved-answer.txt"
  run_captain "$home" answer "$approved_id" --release \
    --decision-file "$home/approved-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$approved_id" --full) || fail "the approved merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" "merge approval retained its captain hold kind"
  run_teardown "$home" "$approved_id" > "$home/approved-teardown.out" \
    2> "$home/approved-teardown.err" \
    || fail "approved merge cleanup failed: $(cat "$home/approved-teardown.err")"

  local_id=jg-sample-released-local
  local_repo="$home/projects/jg-sample-local"
  local_wt="$home/projects/$local_id"
  jg_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'landed locally\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local delivery'
  tasks_in "$home" add "$local_id" "Land the approved local-only change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released local fixture"
  jg_write_meta "$home/state/$local_id.meta" \
    "window=juggernaut:jg-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$home/state/$local_id.status"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the released local merge"
  printf 'Land the approved change locally.\n' > "$home/local-answer.txt"
  run_captain "$home" answer "$local_id" --release \
    --decision-file "$home/local-answer.txt" >/dev/null \
    || fail "could not release the local merge"
  show=$(tasks_in "$home" show "$local_id" --full) || fail "the released local merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "local merge approval retained its captain hold kind"
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" "$ROOT/bin/jg-merge-local.sh" "$local_id" \
    > "$home/local-merge.out" 2> "$home/local-merge.err" \
    || fail "approved local merge failed: $(cat "$home/local-merge.err")"
  run_teardown "$home" "$local_id" > "$home/local-teardown.out" \
    2> "$home/local-teardown.err" \
    || fail "released local cleanup failed: $(cat "$home/local-teardown.err")"

  released_id=jg-sample-released-report
  released_pr=https://github.com/sample/sample/pull/24
  mkdir -p "$home/data/$released_id"
  tasks_in "$home" add "$released_id" "Investigate $released_pr report evidence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the released report fixture"
  write_origin_meta "$home" "$released_id"
  printf 'done: report complete\n' > "$home/state/$released_id.status"
  printf '# Released report\n' > "$home/data/$released_id/report.md"
  run_captain "$home" hold "$released_id" --reason "captain report release pending" \
    >/dev/null || fail "could not hold the released report"
  complete_through_sibling "$home" "$released_id" >/dev/null \
    || fail "completion gate failed for the released report"
  printf 'Release the completed report.\n' > "$home/released-answer.txt"
  run_captain "$home" answer "$released_id" --release \
    --decision-file "$home/released-answer.txt" >/dev/null \
    || fail "could not release the completed report"
  run_teardown "$home" "$released_id" > "$home/released-teardown.out" \
    2> "$home/released-teardown.err" \
    || fail "released report cleanup failed: $(cat "$home/released-teardown.err")"

  answered_id=jg-sample-artifactless-captain-answer
  tasks_in "$home" add "$answered_id" "Choose the artifactless route" --kind captain \
    --repo sample --start >/dev/null || fail "could not create the artifactless captain call"
  run_captain "$home" hold "$answered_id" --reason "captain route choice pending" \
    >/dev/null || fail "could not hold the artifactless captain call"
  printf 'Continue without a delivery artifact.\n' > "$home/artifactless-answer.txt"
  run_captain "$home" answer "$answered_id" --release \
    --decision-file "$home/artifactless-answer.txt" >/dev/null \
    || fail "could not release the artifactless captain call"
  tasks_in "$home" 'done' "$answered_id" >/dev/null \
    || fail "could not complete the released artifactless captain call"

  decision_local_id=jg-sample-released-local-worded-decision
  tasks_in "$home" add "$decision_local_id" "Land the reviewed change" --kind ship \
    --repo sample --start >/dev/null \
    || fail "could not create the local-worded decision fixture"
  run_captain "$home" hold "$decision_local_id" --reason "captain landing route pending" \
    >/dev/null || fail "could not hold the local-worded decision fixture"
  printf 'local main\n' > "$home/local-worded-answer.txt"
  run_captain "$home" answer "$decision_local_id" --release \
    --decision-file "$home/local-worded-answer.txt" >/dev/null \
    || fail "could not release the local-worded decision fixture"
  tasks_in "$home" 'done' "$decision_local_id" >/dev/null \
    || fail "could not complete the local-worded decision fixture"

  reportless_scout_id=jg-sample-reportless-scout
  tasks_in "$home" add "$reportless_scout_id" "Investigate without a report" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the reportless scout"
  tasks_in "$home" 'done' "$reportless_scout_id" >/dev/null \
    || fail "could not complete the reportless scout"

  legacy_id=jg-sample-kindless-legacy-delivery
  tasks_in "$home" add "$legacy_id" "Complete the legacy work" --repo sample --start \
    >/dev/null || fail "could not create the kindless legacy delivery"
  tasks_in "$home" 'done' "$legacy_id" >/dev/null \
    || fail "could not complete the kindless legacy delivery"

  json=$(run_bearings "$home" --all-landed) \
    || fail "Bearings failed after retained delivery answers"
  printf '%s' "$json" | jq -e \
    --arg retained_id "$retained_id" --arg retained "data/$retained_id/report.md" \
    --arg precedence_id "$precedence_id" \
    --arg precedence "data/$precedence_id/report.md" \
    --arg rejected_id "$rejected_id" --arg rejected_local_id "$rejected_local_id" \
    --arg report_question_id "$report_question_id" \
    --arg approved_id "$approved_id" --arg local_id "$local_id" \
    --arg approved_pr "$approved_pr" --arg released_id "$released_id" \
    --arg answered_id "$answered_id" --arg reportless_scout_id "$reportless_scout_id" \
    --arg legacy_id "$legacy_id" --arg decision_local_id "$decision_local_id" \
    --arg released "data/$released_id/report.md" '
      (.landed | any(.id == $retained_id and .artifact == $retained))
        and (.landed | any(.id == $precedence_id and .artifact == $precedence))
        and (.landed | any(.id == $rejected_id) | not)
        and (.landed | any(.id == $rejected_local_id) | not)
        and (.landed | any(.id == $report_question_id) | not)
        and (.landed | any(.id == $approved_id and .artifact == $approved_pr))
        and (.landed | any(.id == $local_id))
        and (.landed | any(.id == $released_id and .artifact == $released))
        # Without the explicit captain-kind boundary, the artifactless answered
        # call falls through the compatibility path and this assertion fails.
        and (.landed | any(.id == $answered_id) | not)
        # Without the explicit scout-kind boundary, this row is rendered with
        # an empty artifact even though a scout has no delivery without a report.
        and (.landed | any(.id == $reportless_scout_id) | not)
        # Requiring a present non-captain kind would also remove this older
        # artifactless delivery, so the compatibility boundary stays observable.
        and (.landed | any(.id == $legacy_id))
        # The captain worded this decision "local main" and the work closed
        # with no artifact, so reading that prose as a recorded note would
        # publish a local-only landing that never happened.
        and (.landed | any(.id == $decision_local_id and .artifact == "-"))
    ' >/dev/null || fail "released, retained, or rejected deliveries were misclassified: $json"
  pass "release and scout report retention distinguish deliveries from rejected merge answers"
}

# Kill teardown without its EXIT trap so pending-record consumers exercise the
# crash window. Retained data requires a teardown retry before startup may close
# the task; the record still supplies artifacts to answers received in between.
interrupt_teardown_during_treehouse_return() {  # <home>
  local home=$1
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
teardown_pid=$(ps -o ppid= -p "$PPID" | tr -d ' ')
case "$teardown_pid" in ''|*[!0-9]*) exit 1 ;; esac
kill -KILL "$teardown_pid"
kill -TERM "$$"
SH
  chmod +x "$home/fakebin/treehouse"
}

# An interruption preserves the row and its task ownership. Startup cannot
# discard that ownership while retained-data process cleanup is outstanding;
# retrying teardown finishes retention instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=jg-sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  git -C "$home/projects/sample" init -q || fail "could not initialize cleanup-failure project fixture"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  interrupt_teardown_during_treehouse_return "$home"

  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  jg_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1 || true)
  assert_present "$home/state/$id.meta" "startup discarded task ownership before cleanup retry"
  assert_present "$home/state/$id.backlog-close" "startup discarded the pending cleanup record"
  bootstrap=$(PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force 2>&1) \
    || fail "teardown retry failed: $bootstrap"
  assert_absent "$home/state/$id.meta" "teardown retry left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "teardown retry left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "teardown retry erased the captain call"
  assert_not_contains "$show" "state: done" "teardown retry closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "teardown retry did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "teardown retry dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "teardown retry did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and teardown retry retains it"
}

test_answer_before_cleanup_replay_preserves_the_retained_report() {
  local home id wt rc bootstrap json
  home=$(make_home answer-before-cleanup-replay)
  id=jg-sample-answer-before-cleanup-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate answer before cleanup replay" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the answer-before-replay fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Interrupted cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the answer-before-replay fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the answer-before-replay fixture"
  interrupt_teardown_during_treehouse_return "$home"

  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer before cleanup replay"
  jg_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1 || true)
  assert_present "$home/state/$id.meta" "startup discarded task ownership before cleanup retry"
  assert_present "$home/state/$id.backlog-close" "startup discarded the pending cleanup record"
  bootstrap=$(PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force 2>&1) \
    || fail "teardown retry failed: $bootstrap"
  assert_absent "$home/state/$id.meta" "teardown retry left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "teardown retry left the pending record behind"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e \
    --arg id "$id" --arg report "data/$id/report.md" \
    '.landed | any(.id == $id and .artifact == $report)' >/dev/null \
    || fail "the retained report disappeared when the captain answered before replay: $json"
  pass "an answer before cleanup replay preserves the retained report"
}

test_unusable_pending_close_record_names_its_reason() {
  local home id wt rc err marker
  home=$(make_home unusable-pending-close-reason)
  id=jg-sample-unusable-pending-close
  wt="$home/projects/$id"
  marker="$home/state/$id.backlog-close"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample" "$home/elsewhere"
  tasks_in "$home" add "$id" "Investigate the unusable pending close" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the unusable pending-close fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Unusable pending close\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the unusable pending-close fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the unusable pending-close fixture"
  interrupt_teardown_during_treehouse_return "$home"

  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$marker" "the interrupted cleanup lost its retained-artifact record"
  sed "s|^data=.*$|data=$home/elsewhere|" "$marker" > "$marker.rewritten" \
    || fail "could not rewrite the pending-close record"
  mv "$marker.rewritten" "$marker"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  set +e
  err=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the unusable pending-close record was answered as if it were valid"
  assert_contains "$err" "$marker" \
    "the refusal did not name the pending-close record the captain must repair"
  assert_contains "$err" "foreign data directory" \
    "the refusal did not name why the pending-close record could not be used"
  pass "an unusable pending-close record names its reason instead of a bare refusal"
}

test_relocated_report_does_not_wedge_an_answer_before_replay() {
  local home data id wt rc show bootstrap json
  home=$(make_home relocated-answer-before-replay)
  data="$home/données"
  mv "$home/data" "$data"
  id=jg-sample-relocated-answer-before-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data" "$data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate relocated answer replay" --kind scout \
    --repo sample --start >/dev/null \
    || fail "could not create the relocated answer-before-replay fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated interrupted cleanup\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-captain-hold.sh" hold "$id" \
    --reason "captain must choose after relocated interrupted cleanup" >/dev/null \
    || fail "could not hold the relocated answer-before-replay fixture"
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated answer-before-replay fixture"
  interrupt_teardown_during_treehouse_return "$home"

  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "relocated cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted relocated cleanup lost its pending record"

  printf 'Proceed despite the reporting limitation.\n' > "$home/answer.txt"
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    JG_DATA_OVERRIDE="$data" JG_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/jg-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" \
    >/dev/null || fail "the unsupported relocated report wedged the captain's answer"
  show=$(tasks_in "$home" show "$id" --full) \
    || fail "the answered relocated row disappeared"
  assert_contains "$show" "state: done" "the relocated report kept the answered call open"
  assert_contains "$show" "held: no" "the relocated report kept the answered call held"

  jg_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/jg-bootstrap.sh" 2>&1 || true)
  assert_present "$home/state/$id.meta" "startup discarded task ownership before cleanup retry"
  assert_present "$home/state/$id.backlog-close" "startup discarded the pending cleanup record"
  json=$(PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_DATA_OVERRIDE="$data" \
    JG_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings failed after the relocated answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" \
    '.landed | any(.id == $id) | not' >/dev/null \
    || fail "the unsupported relocated report was published as a landed delivery: $json"
  pass "an unsupported relocated report does not wedge the captain's answer"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not JG_HOME/data.
test_pr_merge_entrypoint_refuses_a_captain_held_task() {
  local home pr_id pr repo wt rc
  home=$(make_home held-merge-entrypoints)
  configure_merged_github "$home"

  pr_id=jg-sample-held-pr-entrypoint
  pr=https://github.com/sample/sample/pull/31
  repo="$home/projects/jg-sample-pr"
  wt="$home/projects/$pr_id"
  jg_git_worktree "$repo" "$wt" "fm/$pr_id"
  tasks_in "$home" add "$pr_id" "Ship the held pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held PR fixture"
  jg_write_meta "$home/state/$pr_id.meta" \
    "window=juggernaut:jg-$pr_id" "endpoint_task_id=$pr_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$pr_id"
  run_captain "$home" hold "$pr_id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR entrypoint fixture"

  # Without the entrypoint guard, this run reaches gh and returns success even
  # though the task is still held for the captain.
  set +e
  run_pr_merge "$home" "$pr_id" "$pr" > "$home/pr.out" 2> "$home/pr.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted a still-held task"
  assert_no_grep 'pr merge 31 ' "$home/gh.log" \
    "the PR merge entrypoint reached the irreversible forge call for a held task"
  assert_grep "$pr_id is still held for the captain" "$home/pr.err" \
    "the PR merge refusal did not name the held task"
  assert_absent "$home/state/.control-$pr_id.lock" \
    "the refused PR merge left its task control lock held"
  pass "the PR merge entrypoint refuses a captain-held task before merging"
}

test_local_merge_entrypoint_refuses_a_captain_held_task() {
  local home local_id local_repo local_wt before after rc
  home=$(make_home held-local-merge-entrypoint)
  local_id=jg-sample-held-local-entrypoint
  local_repo="$home/projects/jg-sample-local"
  local_wt="$home/projects/$local_id"
  jg_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'held local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' \
    commit -qm 'held local delivery'
  tasks_in "$home" add "$local_id" "Ship the held local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held local fixture"
  jg_write_meta "$home/state/$local_id.meta" \
    "window=juggernaut:jg-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the local entrypoint fixture"
  before=$(git -C "$local_repo" rev-parse main)

  # Without the entrypoint guard, this run fast-forwards main while the task
  # still carries the captain hold.
  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/jg-merge-local.sh" "$local_id" \
    > "$home/local.out" 2> "$home/local.err"
  rc=$?
  set -e
  after=$(git -C "$local_repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted a still-held task"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main for a held task"
  assert_grep "$local_id is still held for the captain" "$home/local.err" \
    "the local merge refusal did not name the held task"
  assert_absent "$home/state/.control-$local_id.lock" \
    "the refused local merge left its task control lock held"
  pass "the local merge entrypoint refuses a captain-held task before merging"
}

test_merge_entrypoints_validate_identity_and_state_before_locking() {
  local home pr_state local_state bad_id rc
  home=$(make_home invalid-merge-entrypoint-inputs)
  configure_merged_github "$home"

  pr_state="$home/missing-pr-state"
  set +e
  jg_run_timed 2 env PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" \
    JG_HOME="$home" JG_STATE_OVERRIDE="$pr_state" \
    "$ROOT/bin/jg-pr-merge.sh" jg-sample-missing-pr-state \
    https://github.com/sample/sample/pull/41 \
    > "$home/missing-pr-state.out" 2> "$home/missing-pr-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the PR merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the PR merge accepted a missing state directory"
  assert_absent "$pr_state" "the PR merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-pr-state.err" \
    "the PR merge did not identify its missing state directory"

  local_state="$home/missing-local-state"
  set +e
  jg_run_timed 2 env PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" \
    JG_HOME="$home" JG_STATE_OVERRIDE="$local_state" \
    "$ROOT/bin/jg-merge-local.sh" jg-sample-missing-local-state \
    > "$home/missing-local-state.out" 2> "$home/missing-local-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the local merge accepted a missing state directory"
  assert_absent "$local_state" "the local merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-local-state.err" \
    "the local merge did not identify its missing state directory"

  bad_id=sample/bad-local-id
  set +e
  jg_run_timed 2 env PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" \
    JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/jg-merge-local.sh" "$bad_id" \
    > "$home/bad-local-id.out" 2> "$home/bad-local-id.err"
  rc=$?
  set -e
  # Without canonical ID validation, the slash creates a nested lock path whose
  # absent parent makes the blocking acquisition retry until the bound expires.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever on a slash-containing task id"
  [ "$rc" -eq 2 ] || fail "the local merge returned $rc instead of rejecting the unsafe task id"
  assert_grep "invalid local merge request" "$home/bad-local-id.err" \
    "the local merge did not identify the unsafe task id"
  assert_absent "$home/state/.control-sample" \
    "the unsafe task id constructed a nested task control path"
  pass "merge entrypoints reject unsafe identities and absent state before locking"
}

test_merge_entrypoints_refuse_a_reused_task_incarnation() {
  local home id pr old_repo old_wt new_repo new_wt teardown_pid merge_pid
  local teardown_ready teardown_release merge_ready merge_release teardown_rc merge_rc
  local local_home local_id local_old_repo local_old_wt local_new_repo local_new_wt
  local local_teardown_pid local_merge_pid local_teardown_ready local_teardown_release
  local local_merge_ready local_merge_release local_teardown_rc local_merge_rc before after
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)

  home=$(make_home reused-pr-incarnation)
  configure_merged_github "$home"
  install_reused_task_barriers "$home"
  id=jg-sample-reused-pr-incarnation
  pr=https://github.com/sample/sample/pull/42
  old_repo="$home/projects/jg-sample-reused-pr-old"
  old_wt="$home/projects/$id"
  jg_git_worktree "$old_repo" "$old_wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the original pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original PR task"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "endpoint_task_id=$id" "worktree=$old_wt" \
    "project=$old_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=original-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"

  teardown_ready="$home/reuse-teardown-ready"
  teardown_release="$home/reuse-teardown-release"
  merge_ready="$home/reuse-merge-ready"
  merge_release="$home/reuse-merge-release"
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" JG_TEST_REUSE_TEARDOWN=1 \
    JG_TEST_REUSE_TEARDOWN_ONCE="$home/reuse-teardown-once" \
    JG_TEST_REUSE_TEARDOWN_READY="$teardown_ready" \
    JG_TEST_REUSE_TEARDOWN_RELEASE="$teardown_release" \
    JG_TEST_REAL_PERL="$real_perl" JG_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$id" --force > "$home/reuse-teardown.out" \
    2> "$home/reuse-teardown.err" &
  teardown_pid=$!
  if ! wait_for_test_file "$teardown_ready" "$teardown_pid"; then
    : > "$teardown_release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "forced PR cleanup did not reach its task-locked synchronization point"
  fi

  JG_TEST_REUSE_MERGE=1 JG_TEST_REUSE_MERGE_ONCE="$home/reuse-merge-once" \
    JG_TEST_REUSE_MERGE_READY="$merge_ready" JG_TEST_REUSE_MERGE_RELEASE="$merge_release" \
    JG_TEST_REAL_PERL="$real_perl" JG_TEST_REAL_SLEEP="$real_sleep" \
    run_pr_merge "$home" "$id" "$pr" > "$home/reuse-merge.out" \
    2> "$home/reuse-merge.err" &
  merge_pid=$!
  if ! wait_for_test_file "$merge_ready" "$merge_pid"; then
    : > "$teardown_release"
    : > "$merge_release"
    wait "$teardown_pid" 2>/dev/null || true
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not wait behind forced cleanup"
  fi

  : > "$teardown_release"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e
  if [ "$teardown_rc" -ne 0 ]; then
    : > "$merge_release"
    wait "$merge_pid" 2>/dev/null || true
    fail "forced PR cleanup failed before the task could be reused: $(cat "$home/reuse-teardown.err")"
  fi

  new_repo="$home/projects/jg-sample-reused-pr-new"
  new_wt="$home/projects/reused-$id"
  jg_git_worktree "$new_repo" "$new_wt" "fm/$id"
  tasks_in "$home" reopen "$id" >/dev/null || fail "could not reopen the reused PR task"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "endpoint_task_id=$id" "worktree=$new_wt" \
    "project=$new_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=replacement-$id"
  tasks_in "$home" start "$id" >/dev/null || fail "could not start the reused PR task"
  : > "$merge_release"
  set +e
  wait "$merge_pid"
  merge_rc=$?
  set -e

  # Without the pre-wait generation capture and locked comparison, the waiter
  # records and merges pull request 42 against the replacement task record.
  [ "$merge_rc" -ne 0 ] || fail "the PR merge accepted a replacement task incarnation"
  assert_no_grep 'pr merge 42 ' "$home/gh.log" \
    "the PR merge reached the forge for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$home/reuse-merge.err" \
    "the PR merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$id" "$home/state/$id.meta" \
    "the refused PR merge damaged the replacement task record"
  assert_absent "$home/state/.control-$id.lock" \
    "the reused-incarnation PR refusal left its task control lock held"

  local_home=$(make_home reused-local-incarnation)
  install_reused_task_barriers "$local_home"
  local_id=jg-sample-reused-local-incarnation
  local_old_repo="$local_home/projects/jg-sample-reused-local-old"
  local_old_wt="$local_home/projects/$local_id"
  jg_git_worktree "$local_old_repo" "$local_old_wt" "fm/$local_id"
  printf 'original local delivery\n' > "$local_old_wt/original.txt"
  git -C "$local_old_wt" add original.txt
  git -C "$local_old_wt" -c user.name='Juggernaut Tests' \
    -c user.email='tests@example.invalid' commit -qm 'original local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the original local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original local task"
  jg_write_meta "$local_home/state/$local_id.meta" \
    "window=juggernaut:jg-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_old_wt" "project=$local_old_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=original-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"

  local_teardown_ready="$local_home/reuse-teardown-ready"
  local_teardown_release="$local_home/reuse-teardown-release"
  local_merge_ready="$local_home/reuse-merge-ready"
  local_merge_release="$local_home/reuse-merge-release"
  PATH="$local_home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$local_home" \
    JG_STATE_OVERRIDE="$local_home/state" JG_DATA_OVERRIDE="$local_home/data" \
    JG_CONFIG_OVERRIDE="$local_home/config" JG_TEST_REUSE_TEARDOWN=1 \
    JG_TEST_REUSE_TEARDOWN_ONCE="$local_home/reuse-teardown-once" \
    JG_TEST_REUSE_TEARDOWN_READY="$local_teardown_ready" \
    JG_TEST_REUSE_TEARDOWN_RELEASE="$local_teardown_release" \
    JG_TEST_REAL_PERL="$real_perl" JG_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$local_id" --force > "$local_home/reuse-teardown.out" \
    2> "$local_home/reuse-teardown.err" &
  local_teardown_pid=$!
  if ! wait_for_test_file "$local_teardown_ready" "$local_teardown_pid"; then
    : > "$local_teardown_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    fail "forced local cleanup did not reach its task-locked synchronization point"
  fi

  PATH="$local_home/fakebin:$PATH" JG_TEST_REUSE_MERGE=1 \
    JG_TEST_REUSE_MERGE_ONCE="$local_home/reuse-merge-once" \
    JG_TEST_REUSE_MERGE_READY="$local_merge_ready" \
    JG_TEST_REUSE_MERGE_RELEASE="$local_merge_release" \
    JG_TEST_REAL_PERL="$real_perl" JG_TEST_REAL_SLEEP="$real_sleep" \
    JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$local_home" \
    JG_STATE_OVERRIDE="$local_home/state" JG_DATA_OVERRIDE="$local_home/data" \
    JG_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/jg-merge-local.sh" "$local_id" > "$local_home/reuse-merge.out" \
    2> "$local_home/reuse-merge.err" &
  local_merge_pid=$!
  if ! wait_for_test_file "$local_merge_ready" "$local_merge_pid"; then
    : > "$local_teardown_release"
    : > "$local_merge_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    wait "$local_merge_pid" 2>/dev/null || true
    fail "the local merge did not wait behind forced cleanup"
  fi

  : > "$local_teardown_release"
  set +e
  wait "$local_teardown_pid"
  local_teardown_rc=$?
  set -e
  if [ "$local_teardown_rc" -ne 0 ]; then
    : > "$local_merge_release"
    wait "$local_merge_pid" 2>/dev/null || true
    fail "forced local cleanup failed before the task could be reused: $(cat "$local_home/reuse-teardown.err")"
  fi

  local_new_repo="$local_home/projects/jg-sample-reused-local-new"
  local_new_wt="$local_home/projects/reused-$local_id"
  jg_git_worktree "$local_new_repo" "$local_new_wt" "fm/$local_id"
  printf 'replacement local delivery\n' > "$local_new_wt/replacement.txt"
  git -C "$local_new_wt" add replacement.txt
  git -C "$local_new_wt" -c user.name='Juggernaut Tests' \
    -c user.email='tests@example.invalid' commit -qm 'replacement local delivery'
  before=$(git -C "$local_new_repo" rev-parse main)
  tasks_in "$local_home" reopen "$local_id" >/dev/null \
    || fail "could not reopen the reused local task"
  jg_write_meta "$local_home/state/$local_id.meta" \
    "window=juggernaut:jg-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_new_wt" "project=$local_new_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=replacement-$local_id"
  tasks_in "$local_home" start "$local_id" >/dev/null \
    || fail "could not start the reused local task"
  : > "$local_merge_release"
  set +e
  wait "$local_merge_pid"
  local_merge_rc=$?
  set -e
  after=$(git -C "$local_new_repo" rev-parse main)

  # Without the pre-wait generation capture and locked comparison, the waiter
  # fast-forwards the replacement task's branch despite never approving it.
  [ "$local_merge_rc" -ne 0 ] || fail "the local merge accepted a replacement task incarnation"
  [ "$after" = "$before" ] || fail "the local merge moved main for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$local_home/reuse-merge.err" \
    "the local merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$local_id" "$local_home/state/$local_id.meta" \
    "the refused local merge damaged the replacement task record"
  assert_absent "$local_home/state/.control-$local_id.lock" \
    "the reused-incarnation local refusal left its task control lock held"
  pass "merge entrypoints refuse a replacement incarnation after waiting for cleanup"
}

test_merge_entrypoints_serialize_forced_teardown_before_task_reads() {
  local home id pr repo wt ready release merge_pid teardown_rc merge_rc real_grep
  local local_home local_id local_repo local_wt local_ready local_release local_pid
  local local_teardown_rc local_merge_rc real_git before after i

  home=$(make_home teardown-race-pr-entrypoint)
  configure_merged_github "$home"
  id=jg-sample-teardown-race-pr
  pr=https://github.com/sample/sample/pull/33
  repo="$home/projects/jg-sample-pr-race"
  wt="$home/projects/$id"
  jg_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the released pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the PR teardown-race fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR teardown-race fixture"
  printf 'Merge the released pull request.\n' > "$home/race-answer.txt"
  run_captain "$home" answer "$id" --release --decision-file "$home/race-answer.txt" \
    >/dev/null || fail "could not release the PR teardown-race fixture"

  real_grep=$(command -v grep)
  ready="$home/pr-metadata-read-ready"
  release="$home/pr-metadata-read-release"
  cat > "$home/fakebin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -qxF ] && [ "${2:-}" = "pr=${JG_TEST_RACE_PR_URL:-}" ] \
    && [ "${3:-}" = "${JG_TEST_RACE_PR_META:-}" ]; then
  "$JG_TEST_REAL_GREP" "$@" || exit $?
  : > "$JG_TEST_RACE_READY"
  while [ ! -e "$JG_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  exit 0
fi
exec "$JG_TEST_REAL_GREP" "$@"
SH
  chmod +x "$home/fakebin/grep"
  JG_TEST_REAL_GREP="$real_grep" JG_TEST_RACE_PR_URL="$pr" \
    JG_TEST_RACE_PR_META="$home/state/$id.meta" JG_TEST_RACE_READY="$ready" \
    JG_TEST_RACE_RELEASE="$release" run_pr_merge "$home" "$id" "$pr" \
    > "$home/race-pr.out" 2> "$home/race-pr.err" &
  merge_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$ready" ] && break
    kill -0 "$merge_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not reach the post-metadata synchronization point"
  fi
  set +e
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/race-pr-teardown.out" 2> "$home/race-pr-teardown.err"
  teardown_rc=$?
  set -e
  : > "$release"
  wait "$merge_pid"
  merge_rc=$?

  # Without early lock ownership, forced cleanup succeeds after metadata is
  # recorded, and the resumed forge call merges work whose task was retired.
  [ "$teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between PR metadata recording and merge"
  assert_grep "another lifecycle action is already running for task $id" \
    "$home/race-pr-teardown.err" \
    "PR cleanup was not refused by the merge's task control lock"
  [ "$merge_rc" -eq 0 ] || fail "the serialized PR merge failed after cleanup was refused"
  assert_present "$home/state/$id.meta" "the refused PR cleanup removed task metadata"
  assert_grep 'pr merge 33 ' "$home/gh.log" \
    "the serialized PR merge did not reach the forge after cleanup was refused"

  local_home=$(make_home teardown-race-local-entrypoint)
  local_id=jg-sample-teardown-race-local
  local_repo="$local_home/projects/jg-sample-local-race"
  local_wt="$local_home/projects/$local_id"
  jg_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'serialized local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Juggernaut Tests' -c user.email='tests@example.invalid' \
    commit -qm 'serialized local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the released local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the local teardown-race fixture"
  jg_write_meta "$local_home/state/$local_id.meta" \
    "window=juggernaut:jg-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"
  run_captain "$local_home" hold "$local_id" \
    --reason "captain local merge approval pending" >/dev/null \
    || fail "could not hold the local teardown-race fixture"
  printf 'Land the released local change.\n' > "$local_home/race-answer.txt"
  run_captain "$local_home" answer "$local_id" --release \
    --decision-file "$local_home/race-answer.txt" >/dev/null \
    || fail "could not release the local teardown-race fixture"

  real_git=$(command -v git)
  local_ready="$local_home/local-validation-ready"
  local_release="$local_home/local-validation-release"
  cat > "$local_home/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-C ${JG_TEST_RACE_REPO:-} rev-parse --short main" ]; then
  output=$("$JG_TEST_REAL_GIT" "$@") || exit $?
  : > "$JG_TEST_RACE_READY"
  while [ ! -e "$JG_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  printf '%s\n' "$output"
  exit 0
fi
exec "$JG_TEST_REAL_GIT" "$@"
SH
  chmod +x "$local_home/fakebin/git"
  before=$(git -C "$local_repo" rev-parse main)
  PATH="$local_home/fakebin:$PATH" JG_TEST_REAL_GIT="$real_git" \
    JG_TEST_RACE_REPO="$local_repo" JG_TEST_RACE_READY="$local_ready" \
    JG_TEST_RACE_RELEASE="$local_release" JG_ROOT_OVERRIDE="$ROOT" \
    JG_HOME="$local_home" JG_STATE_OVERRIDE="$local_home/state" \
    JG_DATA_OVERRIDE="$local_home/data" JG_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/jg-merge-local.sh" "$local_id" \
    > "$local_home/race-local.out" 2> "$local_home/race-local.err" &
  local_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$local_ready" ] && break
    kill -0 "$local_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$local_ready" ]; then
    : > "$local_release"
    wait "$local_pid" 2>/dev/null || true
    fail "the local merge did not reach the post-validation synchronization point"
  fi
  set +e
  PATH="$local_home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$local_home" \
    JG_STATE_OVERRIDE="$local_home/state" JG_DATA_OVERRIDE="$local_home/data" \
    JG_CONFIG_OVERRIDE="$local_home/config" "$TEARDOWN" "$local_id" --force \
    > "$local_home/race-local-teardown.out" 2> "$local_home/race-local-teardown.err"
  local_teardown_rc=$?
  set -e
  : > "$local_release"
  wait "$local_pid"
  local_merge_rc=$?
  after=$(git -C "$local_repo" rev-parse main)

  # Without early lock ownership, forced cleanup succeeds after validation and
  # the resumed fast-forward lands work whose task was already retired.
  [ "$local_teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between local validation and merge"
  assert_grep "another lifecycle action is already running for task $local_id" \
    "$local_home/race-local-teardown.err" \
    "local cleanup was not refused by the merge's task control lock"
  [ "$local_merge_rc" -eq 0 ] || fail "the serialized local merge failed after cleanup was refused"
  [ "$after" != "$before" ] || fail "the serialized local merge did not fast-forward main"
  assert_present "$local_home/state/$local_id.meta" \
    "the refused local cleanup removed task metadata"
  pass "merge entrypoints own task state before forced cleanup can retire it"
}

# No regression covers a re-hold after a merge lands and before cleanup because
# that accepted window spans two separate lifecycle owners.
# Queued forge merges are also uncovered because they land asynchronously after
# the local merge command and its task control lock have returned.
test_released_merge_passes_the_entrypoint_and_lands() {
  local home id pr repo wt show json
  home=$(make_home released-merge-entrypoint)
  configure_merged_github "$home"
  id=jg-sample-released-merge
  pr=https://github.com/sample/sample/pull/32
  repo="$home/projects/jg-sample-released"
  wt="$home/projects/$id"
  jg_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the approved pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released merge fixture"
  jg_write_meta "$home/state/$id.meta" \
    "window=juggernaut:jg-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the released merge fixture"
  printf 'Merge the approved pull request.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge task disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "the approved merge remained captain-held after its release"
  run_pr_merge "$home" "$id" "$pr" > "$home/merge.out" 2> "$home/merge.err" \
    || fail "the released merge was refused: $(cat "$home/merge.err")"
  PATH="$home/fakebin:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$home" \
    JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" \
    JG_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "the released merge cleanup failed: $(cat "$home/teardown.err")"
  json=$(run_bearings "$home") || fail "Bearings failed after the released merge lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" --arg pr "$pr" \
    '.landed | any(.id == $id and .artifact == $pr)' >/dev/null \
    || fail "the released merge was absent from Recently Landed: $json"
  pass "a released merge passes the guarded entrypoint and remains recently landed"
}

# A shown scalar field is a JSON-encoded bare string, and JSON::PP accepts one
# only when allow_nonref is on. Recent releases default it on, so this case
# forces the older default back off for every perl the command spawns - the same
# rejection a host with JSON::PP 2.27202 produces - then drives both paths that
# read a body back: holding a task for the captain, and the cleanup that retains
# a captain-held row with its deliverable.
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default() {
  local home shim id show probe scout
  home=$(make_home nonref-default)
  shim="$home/no-nonref-default"
  mkdir -p "$shim"
  cat > "$shim/FmNoNonrefDefault.pm" <<'PM'
package FmNoNonrefDefault;
require JSON::PP;
my $new = \&JSON::PP::new;
{
  no warnings 'redefine';
  *JSON::PP::new = sub { my $self = $new->(@_); $self->allow_nonref(0); $self };
}
1;
PM

  # Without this the case would pass on any decode path at all, including the
  # one this regression exists to catch.
  probe=$(printf '%s' '"probe"' | PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    perl -MJSON::PP -e 'local $/; eval { decode_json(<STDIN>) };
      print $@ ? "rejects" : "accepts";')
  [ "$probe" = rejects ] \
    || fail "the simulated older default still accepted a bare scalar"

  id=jg-sample-nonref-body
  tasks_in "$home" add "$id" "Work carrying a body" --kind ship --repo sample \
    --body 'First line of the plan.' >/dev/null \
    || fail "could not create the task carrying a body"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_captain "$home" hold "$id" --reason "captain go needed" >/dev/null \
    || fail "a captain hold failed where allow_nonref is not on by default"
  show=$(tasks_in "$home" show "$id" --full) || fail "the held row disappeared"
  assert_contains "$show" "hold_kind: captain" "the hold lost its captain kind"
  assert_contains "$show" "Captain hold set:" "the hold lost its hold-set stamp"
  assert_contains "$show" "First line of the plan." "the hold lost the original body"

  # Cleanup reads the same body back to append the finished work's deliverable.
  scout=jg-sample-nonref-scout
  mkdir -p "$home/data/$scout"
  tasks_in "$home" add "$scout" "Investigate the sample body decode" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Sample body decode\n\nOne captain choice remains.\n' \
    > "$home/data/$scout/report.md"
  run_captain "$home" hold "$scout" --reason "captain must choose" >/dev/null \
    || fail "could not hold the investigation for the captain"
  complete_through_sibling "$home" "$scout" >/dev/null \
    || fail "the completion gate failed with the origin as its own captain call"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_teardown "$home" "$scout" > "$home/nonref.out" 2> "$home/nonref.err" \
    || fail "cleanup of a captain-held row failed where allow_nonref is not on by default: $(cat "$home/nonref.err")"
  show=$(tasks_in "$home" show "$scout" --full) || fail "the retained row disappeared"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$scout/report.md" \
    "cleanup lost the deliverable it could not decode a body to append to"
  assert_contains "$show" "Captain hold set:" "cleanup lost the hold-set stamp"
  pass "both body-decoding paths work without the allow_nonref default"
}

# Cleanup rewrites a captain-held row's body to append the finished work's
# deliverable, so every byte of that body has to survive the decode. The
# assertions below are on bytes, not characters: a decoder that prints a
# character string to a stream with no :raw layer emits a codepoint at or below
# U+00FF as one latin-1 byte, which is not valid UTF-8, and the comparison of
# decoded strings would not notice.
#
# The two characters go in separate rows on purpose. A string that holds any
# character above U+00FF is printed as UTF-8 whatever the layer, so mixing them
# in one body hides the latin-1 case entirely.

# Take one captain-held row carrying <body> all the way through cleanup, which
# is the path that reads the body back to append the deliverable.
retain_row_with_body() {  # <home> <id> <body>
  local home=$1 id=$2 body=$3
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample body bytes" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the fixture for $id"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample body bytes\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" update "$id" --body "$body" >/dev/null \
    || fail "could not give $id a body carrying non-ASCII characters"
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold $id for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "the completion gate failed for $id"
  run_teardown "$home" "$id" > "$home/$id.out" 2> "$home/$id.err" \
    || fail "cleanup of captain-held $id failed: $(cat "$home/$id.err")"
}

# A refused hold must never read as a recorded one. The gate used to accept the
# origin as its own inventory whenever the origin row looked durable, so a hold
# that failed just before `complete <origin> <origin>` left a satisfied gate
# with no captain call recorded.
test_origin_is_never_its_own_inventory_entry() {
  local home id
  home=$(make_home origin-self-inventory)
  id=jg-sample-self-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample self review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  if run_captain "$home" hold "$id" --reason "" >/dev/null 2> "$home/hold.err"; then
    fail "hold accepted an empty reason"
  fi
  if run_captain "$home" complete "$id" "$id" > "$home/self.out" 2> "$home/self.err"; then
    fail "complete accepted the origin as its own inventory after a failed hold"
  fi
  assert_grep "cannot be its own captain-call inventory entry" "$home/self.err" \
    "the refusal does not say why the origin was rejected"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  # Holding the origin row itself must not let it vouch for itself either.
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold the origin row"
  if run_captain "$home" complete "$id" "$id" > "$home/held.out" 2> "$home/held.err"; then
    fail "complete accepted a held origin row as its own inventory"
  fi
  pass "complete refuses the origin as its own captain-call inventory"
}

# `hold --origin` records which origin a call was held for, and `complete`
# refuses a task held for a different origin. A hold recorded before that
# record existed, or without --origin, still verifies and is flagged.
test_complete_refuses_an_entry_held_for_another_origin() {
  local home id other o out
  home=$(make_home origin-mismatch)
  id=jg-sample-first-review
  other=jg-sample-second-review
  for o in "$id" "$other"; do
    mkdir -p "$home/data/$o"
    tasks_in "$home" add "$o" "Investigate $o" --kind scout --repo sample --start >/dev/null \
      || fail "could not create the $o fixture"
    write_origin_meta "$home" "$o"
    printf 'done: report complete\n' > "$home/state/$o.status"
  done
  run_captain "$home" hold jg-sample-other-call --title "Call for the second review" \
    --reason "captain must decide" --repo sample --origin "$other" >/dev/null \
    || fail "could not hold the call recorded for the second review"
  if run_captain "$home" complete "$id" jg-sample-other-call > "$home/mismatch.out" 2> "$home/mismatch.err"; then
    fail "complete accepted an entry held for a different origin"
  fi
  assert_grep "was held for origin $other, not $id" "$home/mismatch.err" \
    "the refusal does not name both origins"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  run_captain "$home" hold jg-sample-own-call --title "Call for the first review" \
    --reason "captain must decide" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the call recorded for the first review"
  out=$(run_captain "$home" complete "$id" jg-sample-own-call) \
    || fail "complete refused an entry held for its own origin"
  assert_not_contains "$out" "no recorded origin" \
    "an entry with a recorded origin was flagged as unrecorded"

  tasks_in "$home" add jg-sample-old-call "Call held before origins were recorded" --kind captain --repo sample >/dev/null \
    || fail "could not create the older call"
  tasks_in "$home" hold jg-sample-old-call --reason "captain must decide" --kind captain >/dev/null \
    || fail "could not hold the older call"
  out=$(run_captain "$home" complete "$other" jg-sample-old-call) \
    || fail "complete refused an older hold with no recorded origin"
  assert_contains "$out" "no recorded origin on: jg-sample-old-call" \
    "an older hold with no recorded origin was not flagged"
  pass "complete refuses an entry held for another origin and flags one with none recorded"
}

test_historical_self_inventory_has_workable_repair() {
  local home origin=jg-sample-review keep=retained-call replacement=repair-call meta before out
  home=$(make_home historical-self-inventory)
  run_captain "$home" hold "$origin" --title "Old review call" --reason "Choose" >/dev/null \
    || fail "could not create the historical origin"
  write_origin_meta "$home" "$origin"
  for out in "$keep" "$replacement"; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$origin" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$origin.meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$origin" "$keep" >> "$meta"
  before=$(cat "$meta")
  for out in "$replacement" --none; do
    if run_captain "$home" complete "$origin" "$out" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "complete accepted the historical self-inventory"
    fi
    assert_grep "historical decision_keys in $meta still contains $origin" "$home/complete.err" \
      "the historical refusal did not identify the persisted entry"
    assert_grep 'replace only' "$home/complete.err" "the refusal omitted the repair instruction"
  done
  if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify accepted the historical self-inventory"
  fi
  assert_grep "historical decision_keys in $meta still contains $origin" "$home/verify.err" \
    "verify omitted the historical repair instruction"
  assert_equals "$before" "$(cat "$meta")" "refusing a historical inventory changed it"
  sed "s/^decision_keys=$origin,$keep$/decision_keys=$replacement,$keep/" "$meta" > "$meta.repaired"
  mv "$meta.repaired" "$meta"
  run_captain "$home" complete "$origin" "$replacement" >/dev/null \
    || fail "the documented historical repair did not allow completion"
  run_captain "$home" verify "$origin" >/dev/null || fail "the repaired inventory did not verify"
  assert_equals "decision_keys=$replacement,$keep" "$(grep '^decision_keys=' "$meta" | tail -1)" \
    "repair lost a sibling inventory entry"
  if run_captain "$home" complete "$origin" "$origin" >/dev/null 2> "$home/self.err"; then
    fail "repair allowed a new self-inventory"
  fi
  pass "historical self-inventories name a workable repair that preserves sibling entries"
}

test_historical_self_inventory_has_workable_repair
test_origin_is_never_its_own_inventory_entry
test_complete_refuses_an_entry_held_for_another_origin
test_uninventoried_report_decision_refuses_completion
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default
test_answer_records_and_closes
test_release_frees_held_work
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_squad_lead_reconcile_publishes_before_request_retirement
test_reconcile_retry_after_completed_close_of_a_merged_captain_ask
test_reconcile_never_closes_through_the_keyed_answer_intake
test_keyed_answer_exit_status_separates_settled_from_retried
test_normal_answers_retire_pending_reconcile_requests
test_reconcile_closes_with_evidence_or_keeps_the_call_open
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_legitimate_holds_produce_no_divergence_signal
test_teardown_never_closes_a_captain_held_task
test_retained_row_artifacts_survive_captain_answers
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_answer_before_cleanup_replay_preserves_the_retained_report
test_unusable_pending_close_record_names_its_reason
test_relocated_report_does_not_wedge_an_answer_before_replay
test_pr_merge_entrypoint_refuses_a_captain_held_task
test_local_merge_entrypoint_refuses_a_captain_held_task
test_merge_entrypoints_validate_identity_and_state_before_locking
test_merge_entrypoints_refuse_a_reused_task_incarnation
test_merge_entrypoints_serialize_forced_teardown_before_task_reads
test_released_merge_passes_the_entrypoint_and_lands
test_hold_reaches_the_core_signoff_card_path
test_a_hold_that_is_the_captains_own_instruction_raises_no_card
test_a_parked_hold_raises_no_card
test_a_direction_hold_with_no_card_exits_zero_and_a_real_card_failure_does_not
# A created captain row must carry its priority through the installed
# task-priority feature: the hold path calls that feature's add with the new
# task, its title, its kind and the --priority it was given, and a missing
# feature is a no-op. This is the case the release fold left as a bare call.
test_hold_create_honors_the_task_priority_check() {
  local home stub out rc=0 id=hold-create-priority
  home=$(make_home hold-create-priority)
  stub="$home/priority-check.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/priority-calls"
SH
  chmod +x "$stub"
  out=$(JG_TASK_PRIORITY_CHECK="$stub" run_captain "$home" hold "$id" \
    --title "Route the priority" --reason "who signs off the release" --priority 2 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a hold create with an installed task-priority check was refused: $out"
  assert_grep "add $id Route the priority --kind captain --priority 2" "$home/priority-calls" \
    "the installed task-priority check was not told the new task, its kind and its priority"
  pass "hold create honors the task priority check"
}

test_hold_create_honors_the_task_priority_check
