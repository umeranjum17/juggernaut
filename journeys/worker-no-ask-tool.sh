#!/usr/bin/env bash
# done-done journey: a real Claude worker (Haiku) told to ask the human a question. With the tool flags
# of the worker launch bin/jg-spawn.sh builds it has no ask tool and no dialog opens; the control pane
# launched without them opens the dialog. A print-mode session with the same flags then lists none of
# the denied tools and no MCP server, so none of the account's connectors, while its control does.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
export TMUX_TMPDIR=$T/tmux
mkdir -p "$TMUX_TMPDIR" "$T/work"
trap 'tmux kill-server 2>/dev/null; rm -rf -- "$T"' EXIT
log() { printf '%s\n' "$*" | tee -a "$OUT/replay.txt"; }
fail() { log "FAIL: $*"; exit 1; }
: > "$OUT/replay.txt"
FLAG=$("$REPO/bin/jg-spawn-core.sh" launch-template claude ship | grep -o -e '--disallowedTools=[^ ]* --strict-mcp-config')
case "$FLAG" in --disallowedTools=AskUserQuestion,*) ;; *) fail "the built worker launch carries no ask-tool deny and connector flag: '$FLAG'" ;; esac
case "$FLAG" in *",mcp__claude_ai_* --strict-mcp-config") ;; *) fail "the built worker launch does not deny the account connectors by name: '$FLAG'" ;; esac
log "worker launch tool flags from the built launch: $FLAG"
ASK='Call the AskUserQuestion tool right now with one question: Which color? options Red and Blue. If you have no such tool, reply exactly NO-ASK-TOOL and nothing else.'
tmux new-session -d -s lab -n control -x 150 -y 45 -c "$T/work" \
  "claude --model claude-haiku-5-5 --dangerously-skip-permissions '$ASK'"
tmux new-window -t lab -n worker -c "$T/work" \
  "claude --model claude-haiku-5-5 --dangerously-skip-permissions $FLAG '$ASK'"
for _ in $(seq 1 60); do tmux capture-pane -p -t lab:control | grep -q 'Enter to select' && break; sleep 1; done
# The prompt itself holds NO-ASK-TOOL once, so the worker's reply is a second line naming it.
replied() { [ "$(grep -c 'NO-ASK-TOOL' "${1:--}")" -ge 2 ]; }
for _ in $(seq 1 90); do tmux capture-pane -p -t lab:worker | replied && break; sleep 1; done
tmux capture-pane -p -t lab:control > "$OUT/pane-control.txt"
tmux capture-pane -p -t lab:worker > "$OUT/pane-worker.txt"
grep -q 'Enter to select' "$OUT/pane-control.txt" || fail "the control worker never opened its question dialog"
log "control (no flag): the question dialog opened"
! grep -q 'Enter to select' "$OUT/pane-worker.txt" || fail "the worker with the flag still opened a dialog"
replied "$OUT/pane-worker.txt" || fail "the worker with the flag neither asked nor reported it has no ask tool"
log "worker (flag): no dialog opened and the worker reported it has no ask tool"
# The tools and MCP servers a session is sent, read from its own init event, with and without the flags.
OK='Reply with the single word OK.'
(cd "$T/work" && claude -p --model claude-haiku-5-5 --output-format stream-json --verbose --dangerously-skip-permissions "$OK") > "$OUT/init-control.jsonl" 2>&1
# shellcheck disable=SC2086 # FLAG is two launch words
(cd "$T/work" && claude -p --model claude-haiku-5-5 --output-format stream-json --verbose --dangerously-skip-permissions $FLAG "$OK") > "$OUT/init-worker.jsonl" 2>&1
init() { jq -c 'select(.type=="system" and .subtype=="init")' "$OUT/init-$1.jsonl" | head -1; }
used() { jq -r 'select(.type=="result") | .usage | (.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens)' "$OUT/init-$1.jsonl" | head -1; }
[ -n "$(init control)" ] && [ -n "$(init worker)" ] || fail "a print-mode session wrote no init event"
c_tools=$(init control | jq '.tools | length'); w_tools=$(init worker | jq '.tools | length')
c_mcp=$(init control | jq -r '[.mcp_servers[]?.name] | join(", ")')
log "control (no flags): $c_tools tools; MCP servers: ${c_mcp:-none}; request $(used control) tokens"
denied=$(printf '%s' "${FLAG#--disallowedTools=}" | cut -d' ' -f1 | tr ',' '\n')
held=$(init worker | jq -r '.tools[]' | grep -Fx -e Task -e "$denied" | tr '\n' ' ')
[ -z "$held" ] || fail "the flagged session still lists denied tools: $held"
[ "$(init worker | jq '[.tools[] | select(startswith("mcp__"))] | length')" = 0 ] || fail "the flagged session still lists MCP tools"
[ "$(init worker | jq '.mcp_servers | length')" = 0 ] || fail "the flagged session still loads an MCP server"
[ "$w_tools" -lt "$c_tools" ] || fail "the flagged session lists no fewer tools than its control ($w_tools against $c_tools)"
log "worker (flags): $w_tools tools ($(init worker | jq -r '.tools | join(" ")')); no denied tool, no MCP server; request $(used worker) tokens"
jq -n --arg v "$(claude --version 2>/dev/null | head -1)" '{target:{version:("claude " + $v)},
  start:"a real Claude Haiku worker launched with the worker launch tool flags, and a control launched without them",
  steps:["both workers are told to ask the human a question","the control opens a question dialog","the flagged worker opens no dialog and reports it has no ask tool","a print-mode session with the flags lists no denied tool and no MCP server, while its control lists more tools and the account connectors it has"],
  result:"the worker launched like a Juggernaut worker cannot put a question dialog in front of the human and is sent none of the denied tools or the account connectors"}' > "$OUT/steps.json"
log "PASS"
