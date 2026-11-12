#!/usr/bin/env bash
# Shared fixture for the hold machine suites tests/jg-machine-hold.test.sh and tests/jg-machine-hold-b.test.sh: a throwaway home with a real
# Beads store (no fleet record is copied) and the helpers the two suites read a task's word with. It is sourced, never run.
set -u
export JG_TASK_PRIORITY_CHECK=/nonexistent
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-hold)
HOME_DIR="$T/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
jg_test_beads_home "$HOME_DIR"
: > "$HOME_DIR/config/backlog-intake-loose"
FB=$(jg_fakebin "$HOME_DIR"); jg_fake_exit0 "$FB" tmux treehouse no-mistakes gh gh-axi
export PATH="$FB:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
  JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config"
unset JG_MACHINES_TABLES
hold() { "$ROOT/bin/jg-captain-hold.sh" "$@"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
word_of() {  # the state word `show` found, or the word the observer printed when it found none
  jm show hold "$1"
  if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'
  else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi
}
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
# shellcheck disable=SC2034 # read by the suites that source this file
reason="the owner must choose the sample option"
printf 'Use the first sample option.\n' > "$T/answer.txt"

