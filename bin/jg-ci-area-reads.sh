#!/usr/bin/env bash
# jg-ci-area-reads.sh - prove an area suite's path scope covers every file the suite reads.
#
#   jg-ci-area-reads.sh --check <bus|shell|evals> -- <command...>
#
# ci.yml runs an area suite (Bus service, Shell syntax, Smoke plus Fast evals) on a
# pull request only when the change touches that suite's area, and bin/jg-ci-scope.sh
# owns what the area is. A scope that misses a file the suite reads lets a change to
# that file skip the suite and report green: the skip incidents on PRs 415 and 418.
# This script closes the gap from the other side. It runs the suite's own command on
# a throwaway copy of the tracked files, records which of them the command read, and
# fails naming any file whose change bin/jg-ci-scope.sh would not send to this area.
#
# How reads are seen: every copied file gets an access time in the year 2000, the
# command runs, and a file whose access time moved was read (by bash, cat, go, node,
# a redirection, a glob: any reader). That needs a filesystem that updates access
# times; a canary read proves it first. On a filesystem that does not, the script
# says so and exits 3 in CI (GITHUB_ACTIONS=true) and 0 with a warning elsewhere, so
# a lane never reports a trace it did not take.
#
# The command runs in the copy, so its result is the lane's result: the command's exit
# status wins when it fails. Files the git tool itself reads in the copy (.gitignore)
# are not the suite's reads and are not judged.
#
# Exit 0 when the command passed and its reads are all in scope, 1 when a read is out of
# scope, the command's own status when it failed, 2 on misuse, 3 when access times
# cannot be trusted in CI.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/.." && pwd -P)
say() { printf 'jg-ci-area-reads: %s\n' "$*" >&2; }

case ${1:-} in
  -h|--help) sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  --check) ;;
  *) say "usage: jg-ci-area-reads.sh --check <bus|shell|evals> -- <command...>"; exit 2 ;;
esac
area=${2:-}
case $area in bus|shell|evals) ;; *) say "unknown area '$area' (bus, shell or evals)"; exit 2 ;; esac
[ "${3:-}" = -- ] && [ "$#" -ge 4 ] || { say "the command to run follows --"; exit 2; }
shift 3

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-ci-area-reads.XXXXXX") || { say "no temp directory"; exit 2; }
trap 'rm -rf -- "$tmp"' EXIT
tree=$tmp/tree
mkdir -p "$tree"
git -C "$ROOT" ls-files -z | tar -C "$ROOT" --null -T - -cf - | tar -C "$tree" -xf - \
  || { say "could not copy the tracked files"; exit 2; }
git -C "$tree" init -q . 2>/dev/null || true

reset_atime() { find "$tree" -type f -not -path "$tree/.git/*" -exec touch -a -d '2000-01-01' {} +; }
reset_atime
canary=$(cd "$tree" && git ls-files | head -1)
cat "$tree/$canary" >/dev/null 2>&1
if [ "$(stat -c %X "$tree/$canary" 2>/dev/null || echo 0)" -lt 1000000000 ]; then
  say "access times do not update on this filesystem, so the reads of the $area suite cannot be traced"
  [ "${GITHUB_ACTIONS:-}" = true ] && exit 3
  say "warning: running the command without the scope check"
  ( cd "$tree" && "$@" )
  exit $?
fi
reset_atime

( cd "$tree" && "$@" )
rc=$?
if [ "$rc" -ne 0 ]; then
  say "the $area suite's command failed (exit $rc); the scope check needs a passing run"
  exit "$rc"
fi

reads=$(cd "$tree" && find . -type f -not -path './.git/*' -printf '%A@ %P\n' \
  | awk '$1 > 1000000000 { sub(/^[^ ]+ /, ""); print }' | LC_ALL=C sort)
total=$(printf '%s\n' "$reads" | sed '/^$/d' | wc -l | tr -d '[:space:]')
missed=''
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case $path in .gitignore) continue ;; esac
  verdict=$(printf '%s\n' "$path" | "$SELF_DIR/jg-ci-scope.sh" | sed -n "s/^$area=//p")
  [ "$verdict" = true ] || missed="$missed
  $path"
done < <(printf '%s\n' "$reads")
if [ -n "$missed" ]; then
  say "the $area suite read $total file(s); a change to these would skip it, because bin/jg-ci-scope.sh does not put them in the $area area:$missed"
  say "Widen the $area area in bin/jg-ci-scope.sh (or stop the suite reading them), then rerun."
  exit 1
fi
say "the $area suite read $total file(s), every one inside its scope"
exit 0
