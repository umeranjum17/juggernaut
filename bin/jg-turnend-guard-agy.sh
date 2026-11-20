#!/usr/bin/env bash
# agy (Antigravity CLI) Stop-hook adapter for the juggernaut PRIMARY turn-end
# guard.
#
# Registered in the tracked .agents/hooks.json for agy's `Stop` event. The
# shared predicate stays in bin/jg-turnend-guard.sh; this file only adapts agy's
# Stop transport to it (docs/turnend-guard.md "Harness integrations").
#
# agy's Stop contract (verified live, agy 1.5.11): the hook prints
# `{"decision":"continue","reason":"..."}` on stdout to keep the agent going,
# and agy injects the reason as a system message; any other output, or none,
# lets the turn end. A forced continuation's own Stop arrives with
# executionNum > 0. agy documents continuationActive as true there too, but the
# live 1.5.11 payload carried continuationActive=false with executionNum=1, so
# either signal alone marks a continuation and this adapter then allows the
# stop: at most one forced follow-up per turn, never a wedged session.
#
# Usage: <agy Stop payload on stdin> | jg-turnend-guard-agy.sh
#
# Every path exits 0: the decision is the stdout object, never the exit status,
# and an unreadable payload, a missing jq, or a guard that cannot answer lets
# the turn end rather than holding the session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CONTINUATION=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  else ((.continuationActive == true) or (((.executionNum // 0) | numbers) > 0))
  end
' 2>/dev/null) || exit 0
[ "$CONTINUATION" = false ] || exit 0

REASON=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/jg-turnend-guard.sh" 2>&1 >/dev/null)
[ "$?" -eq 2 ] || exit 0
[ -n "$REASON" ] || REASON='TURN WOULD END BLIND - supervision is off. Repair missing watcher supervision according to the session-start operating block before ending the turn.'
jq -n --arg r "$REASON" '{decision: "continue", reason: $r}' 2>/dev/null || true
exit 0
