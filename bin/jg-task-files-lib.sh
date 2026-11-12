#!/usr/bin/env bash
# jg-task-files-lib.sh - the one list of per-task files in state/ that cleanup owns, and the one remover for them.
# The state folder diet (jg8-j19): every kind a task leaves beside its record is either folded into the record
# or named here, so a task that is cleaned up leaves none of them behind. A kind joins this list in the slice
# that gives it its remover; the writer of the kind stays where it is.
# shellcheck shell=bash

# One line per kind: the suffix after state/<id>. and who writes it.
#   probe-at          core/quota-failover/quota-failover   throttle stamp of the pinned-route probe
#   account-probe-at  core/quota-failover/quota-failover   throttle stamp of the account probe
#   exit              bin/jg-control.sh                    epoch the agent was stopped on purpose
#   check-trust       bin/jg-check-register.sh             trust stamp of the custom check
#   check.sh          bin/jg-check-register.sh             the custom check shim
#   model-relaunch    core/sentinel/bin/jg-sentinel.sh     the event a model relaunch was last asked for
#   land-next         bin/jg-trunk.sh                      the mark that lands a lane ahead of the queue
#   models            bin/jg-spawn.sh                      the model history of the task
# Slice 3 (jg8-j19c):
#   pi-ext.ts         bin/jg-spawn.sh                      the pi busy-state extension of the task
#   log               per-task writers                     the task's own log
#   jsonl             per-task writers                     the task's own event lines
#   pr-poll           bin/jg-pr-lib.sh                     the PR poll data of the task
#   scratch           bin/jg-spawn.sh                      the pointer to the task's scratch directories
#   local-suite       bin/jg-local-suite.sh                the local suite proof of the lane
#   pr-poll-registration  bin/jg-pr-lib.sh                 the PR poll registration of the task
#   prelimit-gen      core/quota-failover/quota-failover   the spawn generation a pre-limit relaunch was done for
# Slice 2 (kinds 9 to 16, in the order of the state census by count):
#   turn-ended                  the agent hooks and bin/jg-watch.sh    the wake ping that a turn ended
#   busy-state                  bin/jg-busy-event.sh                   the one-line busy record
#   busy-gen                    bin/jg-spawn.sh                        the token of the busy wiring
#   control-relaunch            bin/jg-control.sh                      the journal of a relaunch in flight
#   control-relaunch.note       bin/jg-control.sh                      the note a relaunch left for the worker
#   control-relaunch.meta-prior bin/jg-control.sh                      the task record before the relaunch
#   control-relaunch.brief-prior bin/jg-control.sh                     the launch brief before the relaunch
#   git-hooks                   bin/jg-spawn.sh                        the directory of commit hooks (a directory)
# Slice 4 (jg8-j19d, kinds 25 to 32):
#   progress              bin/jg-busy-event.sh               the touch that marks work in progress
#   lane-groups           bin/jg-lane-run.sh                 the run tokens of the lane's running commands
#   omp-ext.ts            bin/jg-spawn.sh                    the omp busy-state extension of the task
#   reconcile-nudged      bin/jg-squad-lead-reconcile.sh     the stamp of a reconcile nudge
#   restart-nudged        core/sentinel/bin/jg-sentinel.sh   the stamp of a restart nudge
#   claude-settings.json  bin/jg-spawn.sh                    the claude settings the task was launched with
#   gemini-settings.json  bin/jg-spawn.sh                    the gemini settings of the task
#   devin-config.json     bin/jg-devin-config.sh             the devin config the task was launched with
# Slice 5 (jg8-j19e, kinds 33 to 40):
#   grok-turnend-token        bin/jg-spawn.sh                      the grok turn-end hook token of the task
#   kimi-turnend-token        bin/jg-spawn.sh                      the kimi turn-end hook token of the task
#   muse-session              the muse agent                       the pointer to muse's own session event file
#   muse-session-current      bin/jg-spawn.sh                      the muse session that is current for the task
#   cursor-session            bin/jg-spawn.sh                      the cursor session the task was launched with
#   limit-prompt-gen          core/limit-prompt-move/limit-prompt-move   the spawn generation a usage-limit menu was moved for
#   composer-dialog           bin/jg-control.sh                    the name of the dialog a lifecycle action saw
#   pr-poll-merge-notified.lock  bin/jg-merge-outcome-lib.sh       the lock directory that guards the merge notice (a directory)
JG_TASK_FILE_KINDS_RETIRED="probe-at account-probe-at exit check-trust check.sh model-relaunch land-next models pi-ext.ts log jsonl pr-poll scratch local-suite pr-poll-registration prelimit-gen turn-ended busy-state busy-gen control-relaunch control-relaunch.note control-relaunch.meta-prior control-relaunch.brief-prior progress lane-groups omp-ext.ts reconcile-nudged restart-nudged claude-settings.json gemini-settings.json devin-config.json grok-turnend-token kimi-turnend-token muse-session muse-session-current cursor-session limit-prompt-gen composer-dialog"
# A kind that is a directory: its installer leaves it read-only, so the remover makes it writable first.
JG_TASK_DIR_KINDS_RETIRED="git-hooks pr-poll-merge-notified.lock"

# jg_task_files_retire <state dir> <task id>: remove every listed kind (files and directories) for the task. Best effort, never fails.
jg_task_files_retire() {
  local state=${1:-} id=${2:-} kind
  [ -d "$state" ] && [ -n "$id" ] || return 0
  for kind in $JG_TASK_FILE_KINDS_RETIRED; do
    rm -f -- "$state/$id.$kind"
  done
  for kind in $JG_TASK_DIR_KINDS_RETIRED; do
    chmod u+w -- "$state/$id.$kind" 2>/dev/null || true
    rm -rf -- "${state:?}/${id:?}.$kind"
  done
  return 0
}
