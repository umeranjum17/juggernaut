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
JG_TASK_FILE_KINDS_RETIRED="probe-at account-probe-at exit check-trust check.sh model-relaunch land-next models"

# jg_task_files_retire <state dir> <task id>: remove every listed kind for the task. Best effort, never fails.
jg_task_files_retire() {
  local state=${1:-} id=${2:-} kind
  [ -d "$state" ] && [ -n "$id" ] || return 0
  for kind in $JG_TASK_FILE_KINDS_RETIRED; do
    rm -f -- "$state/$id.$kind"
  done
  return 0
}
