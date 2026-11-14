#!/usr/bin/env bash
# exercise.sh - record that a registered change was exercised at one exact commit, so the delivery observer
# (observers/delivery.sh, proof `exercise`) can call it in-use only for the commit the homes run.
#
# Usage:
#   exercise.sh record <id> <commit> <what>   append one row to data/exercises.tsv: epoch, id, full commit sha, what
#   exercise.sh show <id>                     print the rows of that change
# The commit is resolved to its full sha in the change's project, and a commit that does not exist is refused, so a
# row never names a commit the observer cannot match. An unregistered id is refused. Exit 1 on a refusal, 2 on usage.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
OBS=$here/observers/delivery.sh
die() { printf 'exercise.sh: %s\n' "$*" >&2; exit 1; }
usage() { echo "usage: exercise.sh record <id> <commit> <what> | show <id>" >&2; exit 2; }

case ${1:-} in
  record)
    [ $# -ge 4 ] || usage
    id=$2; commit=$3; shift 3; what=$*
    case $what in *[$'\t\n']*) die "what must be one plain line" ;; esac
    bash "$OBS" ids | grep -qx -- "$id" || die "$id is not a registered change"
    project=$(awk -F'\t' -v i="$id" '$1 !~ /^[[:space:]]*#/ && $1 == i { print $2; exit }' "${JG_DELIVERY_CHANGES:-$here/changes.tsv}")
    repo=$JG_HOME/projects/$project; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || repo=$JG_HOME
    full=$(git -C "$repo" rev-parse --verify --quiet "$commit^{commit}" 2>/dev/null) || die "$commit is not a commit of $project"
    mkdir -p "$DATA" || die "cannot create $DATA"
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$id" "$full" "$what" >> "$DATA/exercises.tsv" || die "cannot write $DATA/exercises.tsv"
    printf 'recorded %s exercised at %s\n' "$id" "$full" ;;
  show) [ $# -eq 2 ] || usage; awk -F'\t' -v i="$2" '$2 == i' "$DATA/exercises.tsv" 2>/dev/null ;;
  *) usage ;;
esac
