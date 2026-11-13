#!/usr/bin/env bash
# A lane's proof set: its affected test scripts plus a sample of the rest.
#   sample.sh <lane> [--percent N] [--affected <file>] [--tests <dir>]
# Prints one test script path per line, sorted and unique: every script listed in --affected (one path per line), then
# every other *.test.sh under --tests (default: tests/ of the repo this script sits in) whose hash with <lane> falls in
# the lowest N percent (default 10; 0 adds none, 100 adds all). The pick depends only on the lane and the script's name,
# so it is fixed for a lane and differs across lanes: a day's lanes cover the whole suite while each pays for a tenth.
# The milestone verify still runs everything; this script only sizes a lane's own proof.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
lane="" percent=10 affected="" tests="$here/tests"
while [ $# -gt 0 ]; do
  case $1 in
    --percent) [ $# -ge 2 ] || { echo "sample: --percent takes a number" >&2; exit 2; }; percent=$2; shift 2 ;;
    --affected) [ $# -ge 2 ] || { echo "sample: --affected takes a file" >&2; exit 2; }; affected=$2; shift 2 ;;
    --tests) [ $# -ge 2 ] || { echo "sample: --tests takes a directory" >&2; exit 2; }; tests=$2; shift 2 ;;
    -*) echo "sample: unknown argument $1" >&2; exit 2 ;;
    *) [ -z "$lane" ] || { echo "sample: one lane only" >&2; exit 2; }; lane=$1; shift ;;
  esac
done
[ -n "$lane" ] || { echo "usage: sample.sh <lane> [--percent N] [--affected <file>] [--tests <dir>]" >&2; exit 2; }
case $percent in ''|*[!0-9]*) echo "sample: --percent must be a whole number 0 to 100, got '$percent'" >&2; exit 2 ;; esac
[ "$percent" -le 100 ] || { echo "sample: --percent must be 0 to 100, got $percent" >&2; exit 2; }
[ -d "$tests" ] || { echo "sample: no test directory $tests" >&2; exit 2; }
[ -z "$affected" ] || [ -r "$affected" ] || { echo "sample: cannot read $affected" >&2; exit 2; }
{
  [ -z "$affected" ] || grep -v '^$' "$affected"
  [ "$percent" -gt 0 ] || exit 0
  find "$tests" -maxdepth 1 -name '*.test.sh' | sort | while IFS= read -r f; do
    h=$(printf '%s %s' "$lane" "${f##*/}" | cksum | cut -d' ' -f1)
    [ $((h % 100)) -lt "$percent" ] && printf '%s\n' "$f"
  done
} | sort -u
