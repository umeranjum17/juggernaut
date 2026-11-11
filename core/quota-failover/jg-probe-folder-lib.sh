# shellcheck shell=bash
# The folder a quota-failover one-line test runs in, and the task that folder names: the one source of truth for
# its name. A test for a task runs in $TMPDIR/jg-probe-<task-id>.XXXXXX, so the fleet pulse's Fable check
# (core/fleet-pulse/bin/fleet-fable.sh) maps the Claude session that test leaves to its task and asks the model
# guard about that task; a route-level test runs in a plain mktemp folder that names no task.
JG_PROBE_FOLDER_PREFIX=jg-probe-

# jg_probe_folder [task-id]: make the test folder and print its path.
jg_probe_folder() {
  if [ -n "${1:-}" ]; then
    mktemp -d -t "$JG_PROBE_FOLDER_PREFIX$1.XXXXXX"
  else
    mktemp -d
  fi
}

# jg_probe_folder_task <folder>: print the task id a test folder names; exit 1 when it names none.
jg_probe_folder_task() {
  local base=${1%/}
  base=${base##*/}
  case $base in "$JG_PROBE_FOLDER_PREFIX"?*.?*) ;; *) return 1 ;; esac
  base=${base#"$JG_PROBE_FOLDER_PREFIX"}
  printf '%s\n' "${base%.*}"
}
