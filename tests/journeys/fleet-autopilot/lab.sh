#!/usr/bin/env bash
# lab.sh - the private Herdr lab the fleet-autopilot journey runs in (sourced by run.sh and by step scripts).
#
# Every Herdr call goes through bin/jg-herdr-lab.sh: a named jg-lab-* session, private XDG roots, a refuse-default
# check before each destructive call and a default-session tripwire compared before provision and after teardown.
# Nothing here calls herdr directly, and the lab never copies a credential. Every process the lab starts gets a PATH
# whose model CLIs are tripwires that log and exit 97, so "zero model turns" is measured, not assumed.
#
# Needs: ROOT (the checkout under test). Provides: LAB EVID SESSION MODEL_LOG, lab_init, lab_herdr, lab_pane,
# lab_metric, lab_env, lab_cleanup. lab_init installs the ONE EXIT trap: it removes the lab and tears the session down.
# shellcheck shell=bash

FA_MODEL_CLIS="claude codex opencode pi grok kimi cursor-agent omp muse gemini rovo agy devin"

lab_init() {  # [<label>]: make the lab dir, the model tripwires and the Herdr session
  HELPER=$ROOT/bin/jg-herdr-lab.sh
  [ -x "$HELPER" ] || { echo "lab: $HELPER missing" >&2; return 1; }
  # The lab runs as no task and no home of the caller: a worker identity would refuse the captain's word, and a
  # caller's JG_HOME would send a fixture home's scripts to the caller's state.
  local v
  for v in $(compgen -v JG_ BEADS_); do case $v in JG_BEADS_TEST_BD|JG_BEADS_TEST_DOLT) ;; *) unset "$v" ;; esac; done
  # Fixture Git isolation (no host hooks path or signing) and no inherited pane identity (tests/herdr-test-safety.sh).
  # shellcheck source=tests/git-config-helpers.sh
  . "$ROOT/tests/git-config-helpers.sh"
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_KEY_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_0 GIT_CONFIG_VALUE_1 GIT_CONFIG_VALUE_2
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
  export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
  export JG_GATE_REFUSE_BYPASS=1 JG_TEST_SEAM=1 JG_STACK_SKIP=1 JG_AXI_LINK_SKIP=1
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fa-lab.XXXXXX") && LAB=$(cd "$LAB" && pwd -P) || return 1
  EVID=${FA_EVID:-${DONE_DONE_EVIDENCE_ROOT:-$LAB/evidence}}; mkdir -p "$EVID" "$LAB/shims"
  MODEL_LOG=$LAB/model-calls.log; : > "$MODEL_LOG"
  local n
  for n in $FA_MODEL_CLIS; do
    # shellcheck disable=SC2016 # the shim body is written literally and expands when the shim runs
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$*" >> "%s"\nexit 97\n' "$MODEL_LOG" > "$LAB/shims/$n"
    chmod +x "$LAB/shims/$n"
  done
  SESSION=$("$HELPER" name "${1:-fleet-autopilot}") || return 1
  trap lab_cleanup EXIT
  "$HELPER" provision "$SESSION" > "$EVID/herdr-provision.txt" 2>&1 || { cat "$EVID/herdr-provision.txt" >&2; return 1; }
  export FA_LAB=$LAB FA_EVID=$EVID FA_SESSION=$SESSION FA_MODEL_LOG=$MODEL_LOG FA_ROOT=$ROOT
}

# lab_cleanup: the only EXIT trap. Teardown goes through the lab helper (it re-checks refuse-default and the default
# session's state); the lab dir goes last, and only when it is the one lab_init made.
lab_cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "${FA_WATCHDOG:-}" ] || kill "$FA_WATCHDOG" 2>/dev/null
  if [ -n "${SESSION:-}" ] && [ "${SESSION_DOWN:-0}" != 1 ] && ! "$HELPER" teardown "$SESSION" > "$EVID/herdr-teardown.txt" 2>&1; then
    echo "lab: teardown refused or the default-session tripwire changed; see $EVID/herdr-teardown.txt" >&2
    rc=1
  fi
  # A failed run keeps its lab (and evidence) for diagnosis; a passing one removes it unless --keep.
  if [ "$rc" -ne 0 ] || [ "${FA_KEEP:-0}" = 1 ]; then echo "lab kept: $LAB" >&2
  else case $LAB in "${TMPDIR:-/tmp}"/fa-lab.*) rm -rf -- "$LAB" ;; esac
  fi
  exit "$rc"
}

# lab_attach: a step script joins the run's lab from the FA_* variables run.sh exported (no trap, no teardown)
lab_attach() {
  ROOT=$FA_ROOT; LAB=$FA_LAB; EVID=$FA_EVID; SESSION=$FA_SESSION; MODEL_LOG=$FA_MODEL_LOG; HELPER=$ROOT/bin/jg-herdr-lab.sh
}
lab_herdr() { "$HELPER" run "$SESSION" "$@"; }  # the helper adds --session; a lifecycle call is refused there

# lab_workspace <label> <cwd>: prints "<workspace_id> <tab_id> <pane_id>"
lab_workspace() {
  lab_herdr workspace create --cwd "$2" --label "$1" --no-focus \
    | jq -r '.result | "\(.workspace.workspace_id) \(.root_pane.tab_id) \(.root_pane.pane_id)"'
}
# lab_tab <workspace_id> <label> <cwd>: prints "<tab_id> <pane_id>"
lab_tab() {
  lab_herdr tab create --workspace "$1" --cwd "$3" --label "$2" --no-focus \
    | jq -r '.result.root_pane | "\(.tab_id) \(.pane_id)"'
}
lab_pane() { lab_herdr pane run "$1" "$2" > /dev/null; }  # <pane_id> <shell command line>
lab_close_tab() { lab_herdr tab close "$1" > /dev/null 2>&1; }

# lab_env: the environment words every lab process runs with (tripwire PATH, the model log, the checkout under test)
lab_env() { printf 'env PATH=%q FA_MODEL_LOG=%q FA_ROOT=%q' "$LAB/shims:$PATH" "$MODEL_LOG" "$ROOT"; }

# lab_metric <name> <seconds> [key=value ...]: one JSON line in metrics.jsonl
lab_metric() {
  local name=$1 secs=$2 kv extra=
  shift 2
  for kv in "$@"; do extra="$extra,\"${kv%%=*}\":\"${kv#*=}\""; done
  printf '{"metric":"%s","seconds":%s,"model_turns":%s%s}\n' "$name" "$secs" "$(wc -l < "$MODEL_LOG" | tr -d ' ')" "$extra" >> "$EVID/metrics.jsonl"
}
