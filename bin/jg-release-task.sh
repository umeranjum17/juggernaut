#!/usr/bin/env bash
# jg-release-task.sh - the one writer of a release task's record, state/<id>.meta.
#
# Usage: jg-release-task.sh create <id> <project-dir>   write kind=release for a record that is not there yet
#        jg-release-task.sh authority <id> [<rule>]     record `merge=approved` and `merge_rule=<rule>`; with no rule remove both
#        jg-release-task.sh head <id> <sha>             record the head the release pushed as pr_head
#
# No worker owns a release, so its record names no window, worktree or branch; bin/jg-trunk.sh decides what a release
# needs and asks this script to write it, and the PR's own fields (pr, pr_head from a worktree) stay with bin/jg-pr-check.sh.
# Each write holds the record's lock, edits a private copy and moves it into place, so a refused write leaves the record
# as it was. create never overwrites; authority and head refuse a record that is not there.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

die() { echo "jg-release-task: $*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# *jg-release-task.sh head/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cmd=${1-}; id=${2-}
case $cmd in -h|--help) usage; exit 0 ;; create|authority|head) ;; *) usage >&2; exit 2 ;; esac
jg_pr_task_id_valid "$id" || die "'$id' is not a valid task id"
meta=$STATE/$id.meta
lock=$(jg_meta_lock_path "$meta") || die "no record lock for $id"
jg_lock_acquire_wait "$lock" || die "could not lock the record of $id"
trap 'jg_lock_release "$lock" || true; rm -f -- "$meta.tmp.$$"' EXIT

# Replace the record with the private copy <tmp> built from it, mode 0600.
publish() { chmod 0600 "$meta.tmp.$$" && mv -f -- "$meta.tmp.$$" "$meta"; }

case $cmd in
  create)
    proj=${3-}; [ -d "$proj" ] || die "create needs the project directory"
    [ ! -e "$meta" ] || die "the record of $id is already there; it is kept"
    proj=$(cd "$proj" && pwd -P)
    (umask 077; printf 'kind=release\nproject=%s\nmode=local-trunk\nyolo=off\n' "$proj" > "$meta.tmp.$$") && publish
    ;;
  authority)
    [ -f "$meta" ] || die "no record of $id"
    grep -v -e '^merge=approved$' -e '^merge_rule=' "$meta" > "$meta.tmp.$$" || [ $? = 1 ]
    [ -z "${3-}" ] || printf 'merge=approved\nmerge_rule=%s\n' "$3" >> "$meta.tmp.$$"
    publish
    ;;
  head)
    [ -f "$meta" ] || die "no record of $id"
    case ${3-} in ''|*[!0-9a-f]*) die "head needs a commit id" ;; esac
    grep -v '^pr_head=' "$meta" > "$meta.tmp.$$" || [ $? = 1 ]
    printf 'pr_head=%s\n' "$3" >> "$meta.tmp.$$"
    publish
    ;;
esac
