# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and squad_lead backlog handoff.
# Usage: . bin/jg-tasks-axi-lib.sh
#
# Compatible means tasks-axi --version reports JG_TASKS_AXI_MIN or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by squad_lead handoffs.
# JG_TASKS_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/jg-bootstrap.sh.
# The feature probes are a separate concern and stay as defense in depth for
# stripped or forked builds that advertise a current version without those flags.
# `config/backlog-backend=manual` opts out of tasks-axi for routine juggernaut
# backlog mutations, but validated squad_lead handoffs always use `tasks-axi mv`.
# `config/backlog-backend=beads` serves backlog reads from this home's bd store,
# named by the absolute BEADS_DIR in `config/beads-dir`; jg_backlog_beads_read
# owns that read, jg_backlog_beads_write owns add, update, done, block, unblock, start,
# reopen, hold, unhold, relink and the stage, take and drop a handoff moves rows with,
# and bin/jg-tasks-axi.sh refuses every other verb on it for now.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
# jg_tasks_axi_backend_resolve owns backend precedence: TASKS_AXI_BACKEND when
# set, then a backend in the working root's .tasks.toml, then one in
# $HOME/.tasks-axi/config.toml, then markdown. Lower-priority sources are read
# only when no earlier source supplies a backend; absent files keep that fallback.
# A detected unreadable or nonregular configuration file, including a dangling
# symlink, returns 2 with a path diagnostic on stderr and no backend on stdout.
# jg_tasks_axi_backend delegates to that resolver and preserves its status;
# callers must check it before selecting backend-specific flags or exemptions.
#
# This file is the single owner of JG_TASKS_AXI_MIN. bin/jg-bootstrap.sh turns a
# failing check into the operator-facing MISSING diagnostic.
#
# COMPATIBILITY VERDICT REUSE. jg_tasks_axi_compatible costs three tasks-axi
# subprocesses, and one session start needs the same verdict twice: once in
# bin/jg-session-start.sh's backlog listing and once in the bin/jg-bootstrap.sh
# child it runs. Two reuse layers collapse that to a single probe:
#   - Within a process the first probe's answer is memoised.
#   - Across ONE process hop, a parent that already holds the verdict passes it
#     in JG_TASKS_AXI_COMPATIBLE=0|1. Sourcing this file CONSUMES that variable
#     (it is unset from the environment and kept only as a private shell
#     variable), so the verdict reaches the child that needs it and never leaks
#     onward into a spawned agent's environment, where it could outlive a
#     tasks-axi upgrade. Any value other than exactly 0 or 1 is ignored and the
#     probe runs normally.
# Both layers are bounded by process lifetime, so a tasks-axi install or upgrade
# is picked up by the next process rather than being cached to disk.

# The pin table (toolchain.versions) owns this floor. The literal below is only the degraded value for a
# copy of this lib running outside the repo, such as a test fixture; the repo's own path always reads the row.
# shellcheck source=bin/jg-pin-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/jg-pin-lib.sh" 2>/dev/null || true
JG_TASKS_AXI_MIN=$(jg_pin_version tasks-axi 2>/dev/null) || JG_TASKS_AXI_MIN=0.2.6

JG_TASKS_AXI_COMPATIBLE_MEMO=${JG_TASKS_AXI_COMPATIBLE:-}
unset JG_TASKS_AXI_COMPATIBLE
case "$JG_TASKS_AXI_COMPATIBLE_MEMO" in
  0|1) ;;
  *) JG_TASKS_AXI_COMPATIBLE_MEMO= ;;
esac

jg_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

jg_tasks_axi_compatible() {
  case "$JG_TASKS_AXI_COMPATIBLE_MEMO" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  if jg_tasks_axi_compatible_probe; then
    JG_TASKS_AXI_COMPATIBLE_MEMO=1
    return 0
  fi
  JG_TASKS_AXI_COMPATIBLE_MEMO=0
  return 1
}

jg_tasks_axi_compatible_probe() {
  local parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(jg_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$JG_TASKS_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  if [ "$major" -gt "$min_major" ] ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -gt "$min_minor" ]; } ||
    { [ "$major" -eq "$min_major" ] && [ "$minor" -eq "$min_minor" ] && [ "$patch" -ge "$min_patch" ]; }; then
    jg_tasks_axi_update_has_archive_body && jg_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

jg_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

jg_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

jg_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Resolve the active tasks-axi backend with the same precedence as tasks-axi.
jg_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    printf '%s\n' "$TASKS_AXI_BACKEND"
    return 0
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(jg_tasks_axi_backend_from_toml "$config"); then
    printf '%s\n' "$backend"
    return 0
  fi
  if [ -n "${HOME:-}" ]; then
    config="$HOME/.tasks-axi/config.toml"
    if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
      { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
      printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
      return 2
    fi
    if backend=$(jg_tasks_axi_backend_from_toml "$config"); then
      printf '%s\n' "$backend"
      return 0
    fi
  fi
  printf '%s\n' markdown
}

jg_tasks_axi_backend() {  # <tasks-axi-working-directory>
  jg_tasks_axi_backend_resolve "$1"
}

jg_backlog_backend_value() {
  jg_backlog_backend_of_file "$1/backlog-backend"
}

# The one rule for reading a backlog-backend value: its trimmed text, tasks-axi when the file is blank or absent.
jg_backlog_backend_of_file() {  # <file>
  local value
  if [ -f "$1" ]; then
    value=$(tr -d '[:space:]' < "$1" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

jg_backlog_backend_manual() {
  local config_dir=$1
  [ "$(jg_backlog_backend_value "$config_dir")" = manual ]
}

jg_backlog_backend_beads() {
  [ "$(jg_backlog_backend_value "$1")" = beads ]
}

# Reads through bin/jg-beads.sh, the only way bd runs; bin/jg-beads-view.py owns the
# field mapping. bd's stderr carries routine warnings, so it surfaces only on failure.
# The store path is never derived, because a store inside a home's git clone is refused.
jg_backlog_beads_store() {  # <config_dir>: prints the BEADS_DIR, or refuses.
  local store
  store=$(tr -d '[:space:]' < "$1/beads-dir" 2>/dev/null) || store=
  if [ -z "$store" ]; then
    printf 'jg-tasks-axi: the beads backlog needs its store: put an absolute BEADS_DIR in %s/beads-dir\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$store"
}

# A reader of the backlog file's lines reads a Beads home the same way: the store, rendered in that layout.
jg_backlog_present() {  # <config_dir> <backlog_file>
  jg_backlog_backend_beads "$1" || [ -f "$2" ]
}

jg_backlog_text() {  # <config_dir> <backlog_file>
  if jg_backlog_backend_beads "$1"; then
    jg_backlog_beads_read "$1" markdown
  else
    cat -- "$2"
  fi
}

# The start checks' one line on this home's store: the summary of `jg-beads.sh check`, or why it failed.
jg_backlog_beads_health() {  # <config_dir>
  local bin_dir store out rc=0
  store=$(jg_backlog_beads_store "$1" 2>&1) || { printf '%s\n' "$store"; return 2; }
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  out=$(BEADS_DIR=$store "$bin_dir/jg-beads.sh" check 2>&1) || rc=$?
  printf '%s\n' "${out##*$'\n'}"
  return "$rc"
}

jg_backlog_beads_write() {  # <config_dir> <a verb of bin/jg-beads-write.py> [args...]
  local bin_dir store
  store=$(jg_backlog_beads_store "$1") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BEADS_DIR=$store python3 "$bin_dir/jg-beads-write.py" "$@"
}

# Beads answers ready and blocked, so the read asks bd for them before it lists the rows:
# `bd ready` first, because that call wakes a dated hold whose day has come and the listing must show it awake.
# A list asks `bd blocked` only when it shows blocked rows or the blocked fields, because the call costs about 0.3 s.
jg_backlog_beads_read() {  # <config_dir> <show|view|list|ready|markdown|links> [args...]
  local bin_dir store err rows rc=0 scratch word repo="" want_ready="" want_blocked=""
  store=$(jg_backlog_beads_store "$1") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  case "${1:-}" in
    ready) want_ready=1 ;;
    show|view) want_blocked=1 ;;
    list) case " $* " in *blocked*) want_blocked=1 ;; esac ;;
  esac
  scratch=$(mktemp -d) || return 2
  err=$scratch/err
  if [ -n "$want_ready" ]; then
    for word in "${@:2}"; do
      case "$word" in --repo=*) repo=${word#--repo=} ;; --repo) repo=- ;; *) [ "$repo" = - ] && repo=$word ;; esac
    done
    [ "$repo" = - ] && repo=""
    BEADS_DIR=$store "$bin_dir/jg-beads.sh" ready --limit 0 --json ${repo:+--label "project:$repo"} >"$scratch/ready" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$want_blocked" ]; then
    BEADS_DIR=$store "$bin_dir/jg-beads.sh" blocked --json >"$scratch/blocked" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rows=$(BEADS_DIR=$store "$bin_dir/jg-beads.sh" list --all --limit 0 --json 2>>"$err") || rc=$?
  fi
  [ "$rc" -eq 0 ] || cat -- "$err" >&2
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$rows" | JG_BEADS_READY=${want_ready:+$scratch/ready} JG_BEADS_BLOCKED=${want_blocked:+$scratch/blocked} \
      python3 "$bin_dir/jg-beads-view.py" "$@" || rc=$?
  fi
  rm -f -- "$scratch/ready" "$scratch/blocked" "$scratch/err"
  rmdir -- "$scratch"
  return "$rc"
}

# One verb, read or write, for bin/jg-backlog-transition-lib.sh's row calls.
jg_backlog_beads_serve() {  # <config_dir> <verb> [args...]
  case "${2:-}" in
    show|view|list|ready|links)
      local config=$1
      shift
      jg_backlog_beads_read "$config" "$@"
      ;;
    *) jg_backlog_beads_write "$@" ;;
  esac
}

jg_tasks_axi_backend_available() {
  local config_dir=$1
  jg_backlog_backend_manual "$config_dir" && return 1
  jg_tasks_axi_compatible
}
