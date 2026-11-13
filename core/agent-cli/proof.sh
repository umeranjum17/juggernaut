#!/usr/bin/env bash
# jg proof [--wait] [--bound <secs>] [-- <command...>]: run done-done in this worktree, in the
# background, with the home and ticket set. With no command: `done-done affected` (which journeys
# the change touches). With a command: `done-done run -- <command>` (the sealed run of the verify
# skill). One run per ticket at a time; a second call reports the running one. --wait returns
# when the run ends or the bound passes (default 900 s). Exit: 0 ran green, 1 ran red, 3 bound.
# The run record is <home>/data/<ticket>/jg-proof.state; its output is jg-proof.log beside it.
# Placement (H30d): a run takes one heavy slot of this host (core/lane-scale/fleet.sh) and runs here. When every slot of
# this host is held and a runner has room, the run goes to the runner instead, as `jg-test-run.sh --changed` at this head
# through the shard path (core/runners/run-shard.sh, the same one the gate uses): the runner's result comes back to
# jg-proof.json beside the log, and the record is written here as for a local run. A lost runner is never a red: the run
# stays here. A runner result is not a sealed done-done run, so `jg-trunk.sh proof` still names the seal as a gap.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/wait-lib.sh"
if [ "${1:-}" = --child ]; then  # the detached run: <rec> <log> <head> <top> <local command...>
  rec=$2 log=$3 head=$4 top=$5; shift 5
  JG_CLI_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
  home=${JG_HOME:?} slot=proof-${JG_TASK:-$$}
  fleet=$JG_CLI_TOOLS/core/lane-scale/fleet.sh
  state=${JG_STATE_OVERRIDE:-$home/state}
  printf 'running %s %s %s\n' "$(date +%s)" "$$" "$head" > "$rec"
  # host_full: every heavy slot of this host is held by a live run
  host_full() {
    local n=0 f host
    host=$("$fleet" budget "$home" 2>/dev/null | sed -n 's/.* host=\([0-9]*\).*/\1/p')
    for f in "$state"/heavy-slots/*; do [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1)); done
    [ -n "$host" ] && [ "$n" -ge "$host" ]
  }
  rc=
  if host_full; then
    log() { printf 'proof: %s\n' "$*" >> "$log"; }
    . "$JG_CLI_TOOLS/bin/jg-test-host-lib.sh"
    log "this host's heavy slots are full: the run goes to a runner with room, else stays here"
    # jg_test_host_run_shard runs a lost shard here, as jg-test-run.sh, so the fallback is the same run
    base=$(git -C "$top" rev-parse "$head^" 2>/dev/null) || base=
    if [ -n "$base" ]; then
      (cd "$top" && jg_test_host_run_shard "$home" proof "$head" "$base" "$(dirname "$rec")/jg-proof.json" -- --changed --base "$base") >> "$log" 2>&1
      rc=$?
    fi
  fi
  if [ -z "$rc" ]; then
    "$fleet" slot take "$home" "$slot" $$ >> "$log" 2>&1 || true
    "$@" >> "$log" 2>&1; rc=$?
    "$fleet" slot give "$home" "$slot" || true
  fi
  printf 'ended %s %s %s\n' "$(date +%s)" "$rc" "$(git -C "$top" rev-parse HEAD)" > "$rec"
  exit 0
fi
wait=0 bound=900 cmd=()
while [ $# -gt 0 ]; do
  case $1 in
    --wait) wait=1; shift ;;
    --bound) [ $# -ge 2 ] || jg_cli_die "--bound takes whole seconds. Next: jg help"; bound=$(jg_cli_bound_arg "$2") || exit 2; shift 2 ;;
    --) shift; cmd=("$@"); break ;;
    *) jg_cli_die "unknown argument $1. Next: jg help" ;;
  esac
done
jg_cli_context
top=$(git rev-parse --show-toplevel) || jg_cli_die "not in a git worktree"
head=$(git -C "$top" rev-parse HEAD)
dir=$JG_CLI_HOME/data/$JG_CLI_TASK; rec=$dir/jg-proof.state; log=$dir/jg-proof.log
dd=${JG_DONE_DONE:-done-done}

# state record: `running <epoch> <pid> <head>` or `ended <epoch> <rc> <head>`
proof_line() { cat "$rec" 2>/dev/null || true; }
proof_running() {  # 0 while a run holds the record and its process lives
  local l; l=$(proof_line)
  case $l in running*) kill -0 "$(printf '%s' "$l" | cut -d' ' -f3)" 2>/dev/null ;; *) return 1 ;; esac
}
proof_ended() { case $(proof_line) in ended*) return 0 ;; *) return 1 ;; esac; }

if ! proof_running; then
  [ -z "$(git -C "$top" status --porcelain)" ] || jg_cli_die "the tree is not clean, so a proof would not match one commit. Next: commit your work, then jg proof"
  mkdir -p "$dir"
  if [ ${#cmd[@]} -gt 0 ]; then run=("$dd" run -- "${cmd[@]}"); else run=("$dd" affected); fi
  : > "$log"
  # setsid keeps the run alive after this command returns; the record is written by the run's own wrapper.
  export JG_TASK=$JG_CLI_TASK
  setsid bash "${BASH_SOURCE[0]}" --child "$rec" "$log" "$head" "$top" "${run[@]}" </dev/null >/dev/null 2>&1 &
  jg_cli_wait 10 proof_running || proof_ended || true
fi

if [ "$wait" = 1 ]; then
  jg_cli_wait "$bound" proof_ended || {
    printf 'proof: still running after %s s (%s)\nlog: %s\nNext: jg proof --wait again, or read the log\n' "$bound" "$(proof_line)" "$log"; exit 3; }
fi
l=$(proof_line)
case $l in
  ended*) rc=$(printf '%s' "$l" | cut -d' ' -f3)
    printf 'proof: ended, exit %s, at head %s\nlog: %s\n' "$rc" "$(printf '%s' "$l" | cut -d' ' -f4 | cut -c1-12)" "$log"
    tail -n 5 "$log" | sed 's/^/  /'
    if [ "$rc" = 0 ]; then
      gaps=$("$JG_CLI_TOOLS/bin/jg-trunk.sh" proof "$JG_CLI_TASK" 2>&1) && echo "gaps: none" || { echo gaps:; printf '%s\n' "$gaps" | sed 's/^/  /'; }
      echo "Next: jg land, or fix the gaps above"; exit 0
    fi
    echo "Next: fix what the log shows, commit, jg proof"; exit 1 ;;
  running*) printf 'proof: running (%s)\nlog: %s\nNext: jg proof --wait\n' "$l" "$log" ;;
  *) printf 'proof: not started\nNext: jg proof\n' ;;
esac
