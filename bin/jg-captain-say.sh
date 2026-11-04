#!/usr/bin/env bash
# jg-captain-say.sh - Main posts its own turn summary to the captain's chat.
#
# Usage: jg-captain-say.sh [--key <slug>] [--link <url>] <text...>
#        printf '%s\n' "<text>" | jg-captain-say.sh [--key <slug>] [--link <url>]
#
# The summary is published as a captain-facing `summary` event (bin/jg-bus.sh publish), so it takes
# the one captain channel: the record, the bus, the chat gateway's Telegram send and the in-process
# fallback. docs/captain-chat.md owns the chat side. The text is the captain-facing message and
# nothing else, so this script REFUSES (exit 1, the reason on stderr, nothing published) text that:
#   - holds a secret: a bot token, an API key, a bearer token or a private key;
#   - is a raw status line (`working [at=...]: ...`), which is a record and never a message;
#   - fails the message layer of bin/jg-captain-card-lib.sh: an internal id, path or jargon, or a
#     first line that is not one short line of outcome (AGENTS.md section 9 owns the words).
# A URL is a public link and passes, so a PR is named by its full https URL. --key only names the
# event in the record (default main-summary); the chat shows the text and the link, not the key.
# Exit: 0 published (or the channel is off), 1 refused, 2 usage.
set -u
SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-captain-card-lib.sh
. "$SCRIPT_DIR/jg-captain-card-lib.sh"

usage() { printf 'usage: jg-captain-say.sh [--key <slug>] [--link <url>] <text...>   (or the text on stdin)\n' >&2; exit 2; }

KEY=main-summary LINK=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; KEY=$2; shift 2 ;;
    --link) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; LINK=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
if [ "$#" -gt 0 ]; then TEXT=$*; else [ ! -t 0 ] || usage; TEXT=$(cat); fi
TEXT=$(printf '%s' "$TEXT" | sed -e 's/[[:space:]]*$//')
[ -n "$TEXT" ] || { printf 'jg-captain-say: refused: no text to send\n' >&2; exit 1; }

refuse() { printf 'jg-captain-say: refused: %s\n' "$1" >&2; exit 1; }

if printf '%s\n' "$TEXT" | grep -qE '[0-9]{6,}:[A-Za-z0-9_-]{30,}|(^|[^A-Za-z0-9])(sk|ghp|gho|ghs|github_pat|xox[abp]|AKIA)[-_A-Za-z0-9]{16,}|[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY|(token|secret|password|passwd|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]{8,}'; then
  refuse 'the text holds a secret (a token, key or password); say what happened and keep the secret out'
fi
if printf '%s\n' "$TEXT" | grep -qE '^[[:space:]]*(working|done|blocked|paused|failed|needs-decision|resolved)[[:space:]]+\[(at|key)='; then
  refuse 'the text is a raw status line; write the outcome in plain words instead'
fi
if why=$(jg_captain_card_refusal message "$TEXT" 0); then :; else
  refuse "${why#refused: }"
fi

args=(publish summary "$KEY" "$TEXT")
[ -z "$LINK" ] || args+=(--link "$LINK")
exec "$SCRIPT_DIR/jg-bus.sh" "${args[@]}"
