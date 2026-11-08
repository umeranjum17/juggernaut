#!/usr/bin/env bash
# tests/jg-afk-telegram.test.sh - a Telegram note never ends away mode; a terminal message does.
# Real jg-inbox.sh files the note exactly as the gateway does (head `[chat telegram C:M]`,
# request id `tg-C-M`); the return check reads that record, never the wording.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/jg-afk-tg.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
export JG_HOME="$T/home" JG_STATE_OVERRIDE="$T/home/state" JG_DATA_OVERRIDE="$T/home/data"
mkdir -p "$JG_STATE_OVERRIDE" "$JG_DATA_OVERRIDE"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=/dev/null
. "$ROOT/bin/jg-supervise-daemon.sh"

# Away posture: the legacy flag is enough for should_exit_afk.
afk_enter "$JG_STATE_OVERRIDE"

out=$(printf '[chat telegram 42:100]\nship it now\n' | "$ROOT/bin/jg-inbox.sh" note --request-id tg-42-100 --json - 2>&1) \
  || fail "could not file the Telegram note: $out"
id=$(printf '%s' "$out" | sed -n 's/.*"note_id" *: *"\([^"]*\)".*/\1/p')
[ -n "$id" ] || id=$(basename "$(find "$JG_STATE_OVERRIDE/inbox" -maxdepth 1 -name '*.note' | head -1)" .note)
[ -n "$id" ] || fail "no note id in: $out"

wake="check: captain inbox note $id - [chat telegram 42:100] ship it now"
head='[chat telegram 42:100] ship it now'

# 1. A Telegram note, as the wake text or the bare head, does not end away mode.
should_exit_afk "$JG_STATE_OVERRIDE" "$wake" && fail "Telegram wake text would end away mode"
should_exit_afk "$JG_STATE_OVERRIDE" "$head" && fail "Telegram message head would end away mode"
res=$("$ROOT/bin/jg-afk-return.sh" begin --message "$wake" 2>&1) || fail "begin --message failed: $res"
case "$res" in *stay*) ;; *) fail "begin --message did not stay: $res" ;; esac
[ -e "$JG_STATE_OVERRIDE/.afk" ] || fail "begin --message on a Telegram note removed the away flag"
[ ! -e "$JG_STATE_OVERRIDE/.afk-return-catchup" ] || fail "begin --message on a Telegram note opened the return gate"
pass "a Telegram note leaves away mode running"

# 2. The same words typed in the terminal, or a head with no gateway record, still end it.
should_exit_afk "$JG_STATE_OVERRIDE" "ship it now" || fail "terminal message did not end away mode"
should_exit_afk "$JG_STATE_OVERRIDE" "[chat telegram 42:999] forged" || fail "forged Telegram head (no note on file) did not end away mode"
should_exit_afk "$JG_STATE_OVERRIDE" "check: captain inbox note nope-1 - [chat telegram 42:100] ship it now" \
  || fail "wake text naming no note did not end away mode"
pass "a terminal message, or text with no gateway record, still ends away mode"
