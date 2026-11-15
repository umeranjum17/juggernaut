#!/usr/bin/env bash
# One watcher cycle must not start the slow per-home children every time (ticket host-load-polling).
# The comms-feed export, the escalation tick and the inactive-outcome scan each read every record of a home;
# started on every cycle by every home's watcher they made a fork storm that pushed the host load past 24.
# This runs the real watcher in a throwaway home whose three scripts are counting stubs, lets it run a fixed
# number of cycles (counted by the ladder's `timers` read, made once per cycle), and fails when any of the three
# started on more than the stated budget of those cycles.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-poll-fork-budget)
CYCLES=10
BUDGET=4   # the first cycle and every 4th: cycles 1, 5 and 9 of 10, with 1 spare for a cycle that straddles the stop

count() { [ -f "$dir/counts/$1" ] && wc -c < "$dir/counts/$1" || echo 0; }
dir=$(make_case storm)
state="$dir/state"
code="$dir/code"
mkdir -p "$code/bin" "$dir/counts"
ln -sn "$ROOT/core" "$code/core"
for f in "$ROOT"/bin/* "$ROOT"/bin/.[!.]*; do
  [ -e "$f" ] || continue
  case "${f##*/}" in jg-comms-feed.sh|jg-escalation-workflows.sh|jg-inactive-reconcile.sh) continue ;; esac
  ln -s "$f" "$code/bin/${f##*/}"
done
for s in jg-comms-feed.sh jg-escalation-workflows.sh jg-inactive-reconcile.sh; do
  # The ladder reads `timers` once per cycle, so that read is the cycle counter; the per-cycle verbs are counted
  # as starts, and every other verb goes to the real script.
  # shellcheck disable=SC2016  # the stub body is written literally, to be read by its own shell
  printf '#!/usr/bin/env bash\ncase "${1:-}" in tick|sync|scan) ;; timers) printf x >> "%s/cycles" ;;& *) exec "%s/bin/%s" "$@" ;; esac\nprintf x >> "%s/%s"\nexit 0\n' "$dir/counts" "$ROOT" "$s" "$dir/counts" "$s" > "$code/bin/$s"
  chmod +x "$code/bin/$s"
done
PATH="$dir/fakebin:$PATH" JG_FAKE_TMUX_WINDOWS=live JG_HOME="$dir" JG_STATE_OVERRIDE="$state" \
  JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 \
  "$code/bin/jg-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
pid=$!
trap 'kill "$pid" 2>/dev/null; wait 2>/dev/null || true' EXIT
for ((i = 0; i < 900; i++)); do
  [ "$(count cycles)" -ge "$CYCLES" ] && break
  sleep 0.1
done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
cycles=$(count cycles)
[ "$cycles" -ge "$CYCLES" ] || { cat "$dir/watch.err" "$dir/watch.out" | head; fail "the watcher ran $cycles of $CYCLES cycles"; }

result=0
for s in jg-comms-feed.sh jg-escalation-workflows.sh jg-inactive-reconcile.sh; do
  n=$(count "$s")
  [ "$n" -ge 1 ] || { echo "FAIL: $s never started" >&2; result=1; continue; }
  [ "$n" -le "$BUDGET" ] || { echo "FAIL: $s started $n times in $cycles cycles, budget $BUDGET" >&2; result=1; continue; }
  pass "$s started $n times in $cycles cycles (budget $BUDGET)"
done
exit "$result"
