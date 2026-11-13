#!/usr/bin/env bash
# jg proof [--wait] [--bound <secs>] [-- <command...>]: run done-done in this worktree, in the
# background, with the home and ticket set. With no command: `done-done affected` (which journeys
# the change touches). With a command: `done-done run -- <command>` (the sealed run of the verify
# skill). One run per ticket at a time; a second call reports the running one. --wait returns
# when the run ends or the bound passes (default 900 s). Exit: 0 ran green, 1 ran red, 3 bound.
# The run record is <home>/data/<ticket>/jg-proof.state; its output is jg-proof.log beside it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/wait-lib.sh"
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
  # shellcheck disable=SC2016 # the child shell expands these, not this one
  setsid bash -c '
    printf "running %s %s %s\n" "$(date +%s)" "$$" "$1" > "$2"; shift 2
    "$@" >> "$0" 2>&1; rc=$?
    printf "ended %s %s %s\n" "$(date +%s)" "$rc" "$(git rev-parse HEAD)" > "$(dirname "$0")/jg-proof.state"
  ' "$log" "$head" "$rec" "${run[@]}" </dev/null >/dev/null 2>&1 &
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
