#!/usr/bin/env bash
# tests/jg-supervise-daemon-single.test.sh - one supervise daemon per home.
# A second jg-supervise-daemon started for a home whose daemon lock is held by a live process refuses at
# once, names the holder, and leaves that holder's lock and pid record alone.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/jg-supervise-daemon.sh"
d=$(mktemp -d)
holder=
cleanup() { [ -z "$holder" ] || kill -TERM "$holder" 2>/dev/null; rm -rf -- "$d"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

mkdir -p "$d/state"
# The first daemon is stood in for by a live process of ours that holds the home's daemon lock.
JG_STATE_OVERRIDE="$d/state" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_lock_try_acquire "$STATE/.supervise-daemon.lock" || exit 1; sleep 60' _ "$ROOT" \
  >/dev/null 2>&1 &
holder=$!
i=0
while [ ! -e "$d/state/.supervise-daemon.lock" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -e "$d/state/.supervise-daemon.lock" ] || fail "the stand-in daemon never took the lock"
before=$(cat "$d/state/.supervise-daemon.lock/pid" 2>/dev/null)

rc=0
out=$(JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" timeout 20 "$DAEMON" 2>&1 </dev/null) || rc=$?
[ "$rc" -eq 1 ] || fail "a second daemon for the same home exited $rc, not 1: $out"
case "$out" in *"another jg-supervise-daemon is already running"*) ;; *) fail "the refusal does not say a daemon is already running: $out" ;; esac
[ "$(cat "$d/state/.supervise-daemon.lock/pid" 2>/dev/null)" = "$before" ] || fail "the refused daemon changed the holder's lock"
[ ! -e "$d/state/.supervise-daemon.pid" ] || fail "the refused daemon wrote a pid record"
printf 'ok - a second supervise daemon for one home refuses and leaves the first daemon alone\n'
echo 'PASS one supervise daemon per home'
