#!/usr/bin/env bash
# jg-project-capacity-lib.sh - how many workers a project admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A project can depend on a machine-local resource that only a few workers can
# use at the same time: a heavy test suite, a local editor stack, a device.
# Juggernaut cannot see which part of a worker's life touches that resource, so
# the captain declares how many workers the project admits on this machine, and
# bin/jg-spawn.sh defers a fresh worker beyond that number instead of launching
# it only to spend full-context turns retrying the resource. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (the task-dispatch skill).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Project capacity"
# is the operator reference, and bin/jg-spawn.sh owns where the check runs.
#
# Declaration: config/project-capacity in the local root Juggernaut home (the home
# bin/jg-wake-lib.sh's jg_juggernaut_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# project:
#   <project-name> <capacity>
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and <capacity> is a positive integer of at most six digits.
# The capacity is the last whitespace-separated field, so the name before it may
# contain spaces. Blank lines are ignored. A line is a comment when it is `#`,
# when `#` is followed by whitespace, or when it starts with `#` and its last
# field is not an integer. A project whose name begins with `#` is declared by
# writing that `#` immediately against the rest of the name and ending the line
# with the capacity, for example `#repo 2`. A name that is `#`, or that begins
# with `#` followed by a space, is the same spelling as a comment and cannot be
# declared. Any other shape, a project named twice, or an unreadable file makes
# the whole declaration unreadable, and bin/jg-spawn.sh then refuses every fresh
# ship or scout spawn from this machine's homes rather than guessing which limit
# was meant.
#
# Occupancy: a place is held by every task record, in any local Juggernaut home on
# this machine (jg_local_juggernaut_state_dirs in bin/jg-wake-lib.sh), that
#   - is not a squad_lead, which is a persistent home rather than a worker,
#   - names the same project identity, meaning its project resolves to the same
#     shared project lock path (jg_treehouse_project_lock_path), which is keyed
#     by the project's resolved origin, so workers in any clone of that origin
#     are counted, and
#   - has no recorded PR handoff: the pr= line bin/jg-pr-check.sh records when a
#     worker's PR is ready, after which the worker waits on review or merge and
#     no longer uses local resources.
# A place therefore frees when a PR-based ship records its ready PR, or when any
# task is cleaned up and its record removed. A local-only ship and a scout have
# no recorded handoff and hold their place until cleanup. A worker that is
# steered back into work after its PR handoff is not counted again.
# The declaration is matched by the spawning clone's directory name, so clones
# of one origin share the cap only when they use that same directory name. A
# clone of that origin under a different directory name finds no declaration
# and is not capped, though its workers still count as holders for a
# same-origin clone that is capped.
# A record whose project directory no longer exists cannot be matched and holds
# no place. Remote homes are never walked, because their workers run on another
# machine.
#
# Race safety: bin/jg-spawn.sh evaluates admission while holding the shared
# project lock and keeps holding it until the new task record is published, so
# two concurrent spawns for one project can never both publish from the same
# count. A spawn on an uncapped project can still publish a holder for a capped
# same-origin clone, so every backend takes that lock whenever the declaration
# caps any project; Orca, which otherwise never takes it, is included. Freeing a
# place needs no lock, because removing a record or adding pr= only ever lowers
# the count.
#
# Requires bin/jg-wake-lib.sh (root home, local homes, project lock path),
# bin/jg-squad-lead-registry-lib.sh (which the local-homes walk reads), and
# bin/jg-backend.sh (jg_meta_get) to be sourced first. No side effects on source.

# shellcheck disable=SC2034 # the JG_PROJECT_CAPACITY_* results are read by bin/jg-spawn.sh after sourcing.
# The config directory holding this machine's declaration (jg_juggernaut_root_dir).
jg_project_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  jg_juggernaut_root_dir "$1" "$2" config
}

# Read the declared capacity for one project.
# Sets JG_PROJECT_CAPACITY_FILE to the declaration path, JG_PROJECT_CAPACITY
# to the project's capacity, or to empty when the project declares none, and
# JG_PROJECT_CAPACITY_ANY to 1 when the declaration caps any project at all.
# Returns 1 with JG_PROJECT_CAPACITY_ERROR when the declaration is unreadable.
jg_project_capacity_lookup() {  # <config-dir> <project-name>
  local name=$2 line lineno=0 pname pcap seen='|'
  JG_PROJECT_CAPACITY_FILE="$1/project-capacity"
  JG_PROJECT_CAPACITY=
  JG_PROJECT_CAPACITY_ANY=
  JG_PROJECT_CAPACITY_ERROR=
  if [ ! -e "$JG_PROJECT_CAPACITY_FILE" ] && [ ! -L "$JG_PROJECT_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$JG_PROJECT_CAPACITY_FILE" ] || [ ! -r "$JG_PROJECT_CAPACITY_FILE" ]; then
    JG_PROJECT_CAPACITY_ERROR="$JG_PROJECT_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    # '#' followed by whitespace is always a comment, including one that ends
    # with a number. A line that begins with '#' glued to the rest of a name is
    # a declaration only when its last field is an integer; any other such line
    # stays a comment, so a note does not refuse every spawn.
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    # The capacity is the last field, so the name before it may hold spaces.
    pcap=${line##*[[:space:]]}
    pname=${line%"$pcap"}
    pname=${pname%"${pname##*[![:space:]]}"}
    if [ -z "$pname" ]; then
      JG_PROJECT_CAPACITY_ERROR="$JG_PROJECT_CAPACITY_FILE line $lineno is not '<project-name> <capacity>'"
      JG_PROJECT_CAPACITY=
      return 1
    fi
    case "$pcap" in
      '' | *[!0-9]* | 0*)
        JG_PROJECT_CAPACITY_ERROR="$JG_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity that is not a positive integer"
        JG_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#pcap}" -gt 6 ]; then
      JG_PROJECT_CAPACITY_ERROR="$JG_PROJECT_CAPACITY_FILE line $lineno gives $pname a capacity longer than six digits"
      JG_PROJECT_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$pname|"*)
        JG_PROJECT_CAPACITY_ERROR="$JG_PROJECT_CAPACITY_FILE line $lineno names $pname a second time"
        JG_PROJECT_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$pname|"
    [ "$pname" != "$name" ] || JG_PROJECT_CAPACITY=$pcap
  done < "$JG_PROJECT_CAPACITY_FILE"
  [ "$seen" = '|' ] || JG_PROJECT_CAPACITY_ANY=1
  return 0
}

# Count the task records holding a place in one project's capacity.
# <project-lock> is jg_treehouse_project_lock_path for the project being
# admitted, and <project-dir> is that project's own directory, which matches
# without recomputing its identity. The local homes come from
# jg_local_juggernaut_state_dirs <first-state>. <own-id> is the task being
# admitted; its own record in <first-state> is the one this spawn replaces, so
# it is not counted.
# Sets JG_PROJECT_CAPACITY_OCCUPANTS to the count and
# JG_PROJECT_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# JG_PROJECT_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
jg_project_capacity_occupants() {  # <project-lock> <project-dir> <first-state> <own-id>
  local want=$1 own=$2 first=$3 self=$4 state meta kind project lock id label i
  local -a cache_dirs cache_locks
  JG_PROJECT_CAPACITY_OCCUPANTS=0
  JG_PROJECT_CAPACITY_OCCUPANT_IDS=
  JG_PROJECT_CAPACITY_ERROR=
  jg_local_juggernaut_state_dirs "$first" || {
    JG_PROJECT_CAPACITY_ERROR=$JG_LOCAL_JUGGERNAUT_ERROR
    return 1
  }
  cache_dirs=("$own")
  cache_locks=("$want")
  for state in "${JG_LOCAL_JUGGERNAUT_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      JG_PROJECT_CAPACITY_ERROR="local Juggernaut state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        JG_PROJECT_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(jg_meta_get "$meta" kind)
      [ "$kind" != squad_lead ] || continue
      [ -z "$(jg_meta_get "$meta" pr)" ] || continue
      project=$(jg_meta_get "$meta" project)
      [ -n "$project" ] || continue
      lock=
      i=0
      while [ "$i" -lt "${#cache_dirs[@]}" ]; do
        if [ "${cache_dirs[$i]}" = "$project" ]; then
          lock=${cache_locks[$i]}
          break
        fi
        i=$((i + 1))
      done
      if [ "$i" -ge "${#cache_dirs[@]}" ]; then
        lock=$(jg_treehouse_project_lock_path "$project" 2>/dev/null) || lock=
        cache_dirs+=("$project")
        cache_locks+=("$lock")
      fi
      [ -n "$lock" ] && [ "$lock" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      JG_PROJECT_CAPACITY_OCCUPANTS=$((JG_PROJECT_CAPACITY_OCCUPANTS + 1))
      JG_PROJECT_CAPACITY_OCCUPANT_IDS="${JG_PROJECT_CAPACITY_OCCUPANT_IDS:+$JG_PROJECT_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
