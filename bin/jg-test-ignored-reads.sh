#!/usr/bin/env bash
# jg-test-ignored-reads.sh - the one owner of the "a test reads a file the commit does not hold" check.
#
#   jg-test-ignored-reads.sh start <root> <work-dir>
#       List the files of <root> that git ignores and the commit does not hold, and watch them. Prints one line,
#       "watching <n> git-ignored uncommitted files" or "none"; exits 0. When files exist and they cannot be watched
#       (no inotifywait, or the watch is refused) it prints "not ok - <cause>" and exits 1: a run that cannot see reads of such files
#       must not pass as if it had.
#   jg-test-ignored-reads.sh finish <work-dir>
#       Stop the watch and print one "not ok - ... <path>" line for each watched file that was opened for reading, then exit 1;
#       exit 0 when none was read.
#   jg-test-ignored-reads.sh stop <work-dir>
#       Stop the watch and print nothing (a run that ends early).
#
# Why. A test that reads a fixture sitting git-ignored in the author's copy passes there and fails on the trunk, where the file does
# not exist (jg-dt3a9, jg-g05hc). A file the commit holds is never watched, so the same test passes once the file is tracked.
#
# What is watched. Every file `git ls-files --others --ignored --exclude-standard` lists, except what a home keeps there on purpose:
# the top-level operational folders the .gitignore names (data, state, config, projects, .no-mistakes, .tools, .lavish), python
# caches and .DS_Store. A fixture folder named config or state below tests/ is not exempt: it is the case this check exists for.
# A read is a close of a read-only open (close_nowrite) or a read call (access), so an empty file and a program that is run are seen,
# and a file the test writes is not.
set -u

die() { echo "jg-test-ignored-reads: $*" >&2; exit 2; }

watch_pid_file() { printf '%s/ignored-reads.pid\n' "$1"; }

candidates() {  # <root> -> NUL-free relative paths, one per line, the exempt ones removed
  git -C "$1" ls-files -z --others --ignored --exclude-standard 2>/dev/null |
    tr '\0' '\n' |
    grep -v -e '^$' \
      -e '^\(data\|state\|config\|projects\|\.no-mistakes\|\.tools\|\.lavish\)/' \
      -e '\(^\|/\)__pycache__/' -e '\.pyc$' -e '\(^\|/\)\.DS_Store$' || true
}

stop_watch() {  # <work-dir>
  local pf pid
  pf=$(watch_pid_file "$1")
  [ -f "$pf" ] || return 0
  pid=$(cat "$pf" 2>/dev/null)
  rm -f -- "$pf"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  # The watcher is the process this command started; waiting for it flushes what it had read.
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  return 0
}

cmd_start() {
  local root=${1:-} work=${2:-} count i
  [ -n "$root" ] && [ -n "$work" ] || die "usage: start <root> <work-dir>"
  mkdir -p "$work"
  root=$(cd "$root" && pwd -P) || die "no such folder: $1"
  printf '%s\n' "$root" >"$work/ignored-reads.root"
  candidates "$root" >"$work/ignored-reads.rel"
  count=$(wc -l <"$work/ignored-reads.rel" | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    echo none
    return 0
  fi
  if ! command -v inotifywait >/dev/null 2>&1; then
    printf 'not ok - cannot tell whether a test reads the %s git-ignored uncommitted files in this copy: inotifywait (inotify-tools) is not installed\n' "$count"
    return 1
  fi
  sed "s#^#$root/#" "$work/ignored-reads.rel" >"$work/ignored-reads.watch"
  : >"$work/ignored-reads.events"
  : >"$work/ignored-reads.err"
  inotifywait -m -e close_nowrite -e access --format '%w' --fromfile "$work/ignored-reads.watch" \
    >"$work/ignored-reads.events" 2>"$work/ignored-reads.err" </dev/null &
  printf '%s\n' "$!" >"$(watch_pid_file "$work")"
  disown 2>/dev/null || true
  # Watches are in place once inotifywait says so; a test must not start before that.
  i=0
  while ! grep -q 'Watches established' "$work/ignored-reads.err" 2>/dev/null; do
    if ! kill -0 "$(cat "$(watch_pid_file "$work")")" 2>/dev/null || [ "$i" -ge 300 ]; then
      stop_watch "$work"
      printf 'not ok - cannot tell whether a test reads the %s git-ignored uncommitted files in this copy: the watch was not established (%s)\n' \
        "$count" "$(tr '\n' ' ' <"$work/ignored-reads.err")"
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf 'watching %s git-ignored uncommitted files\n' "$count"
}

cmd_finish() {
  local work=${1:-} root rel rc=0
  [ -n "$work" ] || die "usage: finish <work-dir>"
  stop_watch "$work"
  [ -s "$work/ignored-reads.events" ] || return 0
  root=$(cat "$work/ignored-reads.root")
  while IFS= read -r rel; do
    printf 'not ok - a test read the git-ignored file %s, which the commit does not hold: it passes in this copy and fails on the trunk; commit it (git add -f) or stop reading it\n' "${rel#"$root"/}"
    rc=1
  done < <(sort -u "$work/ignored-reads.events")
  return "$rc"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  finish) shift; cmd_finish "$@" ;;
  stop) shift; [ -n "${1:-}" ] || die "usage: stop <work-dir>"; stop_watch "$1" ;;
  *) die "usage: start <root> <work-dir> | finish <work-dir> | stop <work-dir>" ;;
esac
