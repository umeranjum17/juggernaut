#!/usr/bin/env bash
# agy (Antigravity CLI) session-open adapter: the RUN tier transport for agy.
#
# Registered in the tracked .agents/hooks.json for agy's `SessionStart` event.
# It is a thin transport around bin/jg-sessionstart-run.sh, which remains the
# single owner of source routing, eligibility, and the digest itself.
#
# agy injects each `injectSteps[].systemMessage` a SessionStart hook prints into
# the conversation before the first model call, so the digest lands before the
# first turn and the helm is taken without model discretion (verified live,
# agy 1.5.11). agy fires SessionStart once per new conversation and its payload
# carries no source field, so the source is always `startup`.
#
# Usage: <agy SessionStart payload on stdin> | jg-sessionstart-agy.sh
#
# Every path exits 0 and prints either nothing or one JSON object, because agy
# treats a failed hook as an error, and a failed session start must reach the
# agent as digest text it can act on, never as a refusal to open the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat >/dev/null 2>&1 || true
DIGEST=$("$SCRIPT_DIR/jg-sessionstart-run.sh" --source startup </dev/null 2>/dev/null || true)
[ -n "$DIGEST" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -n --arg c "$DIGEST" '{injectSteps: [{systemMessage: {systemMessage: $c}}]}' 2>/dev/null || true
exit 0
