#!/usr/bin/env bash
# The chat gateway (core/bus/cmd/jg-bus/gateway*.go), proved by its Go tests, and the speech engine wrapper beside it.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
if ! command -v go >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then printf 'skip: needs go and python3\n'; exit 0; fi
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-bus-gateway.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
(cd "$ROOT/core/bus" && GOCACHE=${GOCACHE:-$lab/gocache} TMPDIR=$lab go test ./cmd/jg-bus/ -run TestGateway -count=1 -v) || exit 1
# The local speech engine's wrapper (bin/jg-chat-transcribe.sh) says plainly that nothing is installed, and prints its usage for no command.
out=$(JG_STATE_OVERRIDE=$lab/state "$ROOT/bin/jg-chat-transcribe.sh" status 2>&1); rc=$?
[ "$rc" -eq 1 ] && [ "$out" = "not installed" ] || { printf 'FAIL: jg-chat-transcribe.sh status: rc=%s out=%s\n' "$rc" "$out"; exit 1; }
"$ROOT/bin/jg-chat-transcribe.sh" >/dev/null 2>&1; [ $? -eq 2 ] || { printf 'FAIL: jg-chat-transcribe.sh with no command should exit 2\n'; exit 1; }
printf 'ok: jg-chat-transcribe.sh reports not installed and usage\n'
