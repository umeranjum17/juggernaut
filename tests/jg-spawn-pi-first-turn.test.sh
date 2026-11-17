#!/usr/bin/env bash
# Pi launch contract: session-scoped project trust for fleet copies, and proof
# that the first turn actually started.
#
# Real bin/jg-spawn.sh over a fixture home and a real git worktree; only the
# terminal (a stand-in tmux) and the harness itself are fakes, so the staged
# launch command is the real one and the busy record is the real one.
#
# T1 a Pi WORKER launch whose copy is a managed fleet Treehouse pool slot carries
#    --approve, so Pi's "Trust project folder?" dialog never parks its first turn.
# T2 the same launch outside the fleet pool carries no --approve: the flag is
#    never widened past juggernaut's own copies.
# T3 Pi that does not advertise --approve still launches (older versions stay usable).
# T4 a launch whose busy record never moves past the jg-spawn seed retries the
#    submit once and raises one worker-stopped alert naming the task, and the
#    lane still stays up (one warning, never a silent idle agent).
# T5 a launch whose record is replaced by the adapter's first event needs no
#    retry and raises no alert.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-pi-first-turn-tests)

PI_MODEL=openai-codex/gpt-6-luna

# The stand-in Pi answers --help with the real flag surface, so the spawn's own
# help probe decides what the launch carries.
make_pi_fakebin() {  # <dir> [version]
  local dir=$1 version=${2:-0.84.0} fakebin
  fakebin=$(jg_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = --help ]; then
  case "$version" in
  0.50.0) printf '%s\n' 'Pi 0.50.0' 'Options: --help' ;;
  *) printf '%s\n' 'Pi $version' 'Options: --help --tui-mode <mode> --approve' ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

# The spawn's stand-in terminal logs every bare key it is sent, so the submit
# (and any retried submit) is counted exactly.
patch_key_log() {  # <fakebin>
  sed -i '/^set -u$/a case "$*" in *"send-keys"*) for a in "$@"; do case "$a" in Enter|C-m) printf "%s\\n" "$a" >> "${JG_FAKE_KEY_LOG:-/dev/null}" ;; esac; done ;; esac' "$1/tmux"
}

# make_case <name> [pool] - a home, a project, and one worktree. "pool" places
# the worktree in the managed fleet layout (<pool>/<slot>/<repo>) with the pool's
# own treehouse-state.json, which is what jg_treehouse_pool_slot reads.
make_case() {  # <name> <id> [pool]
  local name=$1 id=$2 pool=${3-} case_dir project worktree
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  if [ "$pool" = pool ]; then
    worktree="$case_dir/pool/1/wt"
    mkdir -p "$case_dir/pool"
    printf '{"worktrees":[]}\n' > "$case_dir/pool/treehouse-state.json"
  else
    worktree="$case_dir/wt"
  fi
  mkdir -p "$case_dir"
  jg_git_worktree "$project" "$worktree" "wt-$name"
  jg_test_spawn_home "$case_dir/home" pi
  printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$case_dir/home/config/host-memory"
  jg_test_spawn_brief "$case_dir/home" "$id"
  printf '%s|%s|%s|%s\n' "$case_dir" "$case_dir/home" "$project" "$worktree"
}

run_case_spawn() {  # <case-record> <id> <fakebin> <launch-log> <key-log>
  local rec=$1 id=$2 fakebin=$3 launchlog=$4 keylog=$5 home project worktree
  IFS='|' read -r _ home project worktree <<<"$rec"
  : > "$launchlog"
  : > "$keylog"
  JG_FAKE_LAUNCH_LOG="$launchlog" JG_FAKE_KEY_LOG="$keylog" \
    JG_FIRST_TURN_POLLS=3 JG_FIRST_TURN_INTERVAL=0 \
    jg_test_run_spawn "$home" "$worktree" "$fakebin" "$id" "$project" \
    --model "$PI_MODEL" --mode direct-PR --yolo off
}

enters() { # <key-log>
  grep -c '^Enter$' "$1" 2>/dev/null || true
}

FAKEBIN=$(make_pi_fakebin "$TMP_ROOT/fake")
patch_key_log "$FAKEBIN"

# T1: the fleet copy is trusted for this run.
rec=$(make_case pool-approve jg-pt-pool pool)
out=$(run_case_spawn "$rec" jg-pt-pool "$FAKEBIN" "$TMP_ROOT/t1-launch.log" "$TMP_ROOT/t1-keys.log") \
  || fail "T1: a Pi worker spawn in a fleet pool slot failed: $out"
launch=$(cat "$TMP_ROOT/t1-launch.log")
assert_contains "$launch" "--tui-mode regular --approve" \
  "T1: a Pi worker in a fleet pool slot must pre-approve project trust"
pass "T1 a Pi worker in a managed fleet pool slot launches with session --approve"

# T2: outside the fleet pool the flag is not juggernaut's to send.
rec=$(make_case plain-no-approve jg-pt-plain)
out=$(run_case_spawn "$rec" jg-pt-plain "$FAKEBIN" "$TMP_ROOT/t2-launch.log" "$TMP_ROOT/t2-keys.log") \
  || fail "T2: a Pi worker spawn outside the pool failed: $out"
launch=$(cat "$TMP_ROOT/t2-launch.log")
assert_contains "$launch" "--tui-mode regular" "T2: the plain worker launch lost its regular TUI"
assert_not_contains "$launch" "--approve" \
  "T2: a Pi worker copy outside the fleet pool must not be trusted with --approve"
pass "T2 a Pi worker outside the fleet pool launches without --approve"

# T3: an older Pi without the flag still launches.
rec=$(make_case old-pi jg-pt-old pool)
OLDFAKEBIN=$(make_pi_fakebin "$TMP_ROOT/fake-old" 0.50.0)
out=$(run_case_spawn "$rec" jg-pt-old "$OLDFAKEBIN" "$TMP_ROOT/t3-launch.log" "$TMP_ROOT/t3-keys.log") \
  || fail "T3: a Pi without --approve failed to launch: $out"
assert_not_contains "$(cat "$TMP_ROOT/t3-launch.log")" "--approve" \
  "T3: --approve was sent to a Pi that does not advertise it"
pass "T3 Pi without the flag still launches"

# T4: the adapter's own first event arrives, so nothing is retried or raised.
# The enter count here is the baseline every Pi launch sends (the pre-launch
# exports and the launch submit); T5 holds it to exactly one more.
rec=$(make_case started jg-pt-started)
IFS='|' read -r _ HOME_DIR _ _ <<<"$rec"
(
  for _ in $(seq 1 400); do
    [ -s "$HOME_DIR/state/jg-pt-started.busy-gen" ] && break
    sleep 0.05
  done
  gen=$(cat "$HOME_DIR/state/jg-pt-started.busy-gen" 2>/dev/null) || exit 0
  [ -n "$gen" ] || exit 0
  "$ROOT/bin/jg-busy-event.sh" apply "$HOME_DIR/state" jg-pt-started busy \
    --gen "$gen" --source pi-ext --event agent-start >/dev/null 2>&1
) &
APPLIER=$!
out=$(run_case_spawn "$rec" jg-pt-started "$FAKEBIN" "$TMP_ROOT/t4-launch.log" "$TMP_ROOT/t4-keys.log") \
  || fail "T4: a spawning lane failed: $out"
wait "$APPLIER" 2>/dev/null || true
BASE_ENTERS=$(enters "$TMP_ROOT/t4-keys.log")
[ "$BASE_ENTERS" -ge 1 ] || fail "T4: the launch sent no submit at all"
[ ! -e "$HOME_DIR/state/alerts/worker-stopped--jg-pt-started.rec" ] \
  || fail "T4: a started first turn raised an alert"
pass "T4 a first turn that starts needs no retry and raises nothing"

# T5: no adapter event ever replaces the launch seed.
rec=$(make_case stuck jg-pt-stuck)
IFS='|' read -r _ HOME_DIR _ _ <<<"$rec"
out=$(run_case_spawn "$rec" jg-pt-stuck "$FAKEBIN" "$TMP_ROOT/t5-launch.log" "$TMP_ROOT/t5-keys.log") \
  || fail "T5: a stuck first turn must not fail the launch: $out"
[ "$(enters "$TMP_ROOT/t5-keys.log")" -eq "$((BASE_ENTERS + 1))" ] \
  || fail "T5: expected one retried submit past the baseline $BASE_ENTERS, saw $(enters "$TMP_ROOT/t5-keys.log") Enter key(s)"
rec_file="$HOME_DIR/state/alerts/worker-stopped--jg-pt-stuck.rec"
[ -f "$rec_file" ] || fail "T5: no worker-stopped alert was recorded for the idle lane"
assert_grep "the agent of jg-pt-stuck was lost while someone waits for it" "$rec_file" \
  "T5: the alert does not name the task and the first-turn cause"
assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" "alert worker-stopped (P1) at rung 3 for main: jg-pt-stuck" \
  "T5: the fleet was not woken about the idle lane"
assert_grep "warning: its first turn never started" "$HOME_DIR/state/jg-pt-stuck.status" \
  "T5: the lane's status record does not carry the finding"
assert_contains "$out" "spawned jg-pt-stuck" "T5: the lane was not left up for recovery"
pass "T5 a first turn that never starts retries the submit once and alerts, naming the task"

jg_test_cleanup
