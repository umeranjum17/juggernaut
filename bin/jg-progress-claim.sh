#!/usr/bin/env bash
# jg-progress-claim.sh - the migration progress check the turn-end guard reads: does the
# last message claim a migration part is live when the probe says it is not?
# docs/turnend-guard.md "Migration progress rule" owns the contract.
#
# Usage: jg-progress-claim.sh pending   (the Stop payload on stdin)
#   Print "<sha1 of the message>\t<slug>\t<what the probe measured>" for the first
#   unsupported claim and exit 0; exit 1 when there is none. Exit 2 means the check could
#   not run (no jq), and prints nothing.
#
# A claim is a sentence that names a part (a slug or name from the probe's part table, see
# bin/jg-critical-path.sh parts) and says live, in use, released, switched, landed, shipped, done, running,
# working, "is on" or "turned on". Merged is not live, so a sentence that also says pending,
# not live, not yet, not running, not done, "is not" or n't is not a claim. "Working on" is
# effort and is not a claim. A part is supported only when `jg-critical-path.sh row <slug>`
# says live. A home with no `critical=` in config/migration-card checks nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="$SCRIPT_DIR/jg-critical-path.sh"
CLAIM='(^|[^a-z])(live|in use|released|switched|landed|shipped|done|running|working|(is|are|now|turned|switched) on)([^a-z]|$)'
NEGATED="pending|not in use|not live|not yet|not running|not done|is not|n't|isn.t"

[ "${1:-}" = pending ] || { echo "usage: jg-progress-claim.sh pending (the Stop payload on stdin)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'jg-progress-claim: jq is required to read the turn-end payload\n' >&2; exit 2; }
[ -x "$CP" ] && [ -n "$("$CP" list 2>/dev/null)" ] || exit 1

msg=$(jq -r 'if type == "object" then ((.last_assistant_message // "") | tostring) else "" end' 2>/dev/null) || exit 1
[ -n "$msg" ] || exit 1
sha=$(printf '%s' "$msg" | { sha1sum 2>/dev/null || shasum -a 1; } | cut -d' ' -f1)
parts=$("$CP" parts 2>/dev/null)

while IFS= read -r sentence; do
  s=$(printf '%s' "$sentence" | tr '[:upper:]' '[:lower:]' | sed 's/working on//g')
  printf '%s' "$s" | grep -qE -- "$CLAIM" || continue
  printf '%s' "$s" | grep -qE -- "$NEGATED" && continue
  while IFS=$'\t' read -r slug name _; do
    [ -n "$slug" ] || continue
    name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    case " $s " in
      *[!a-z0-9]"$slug"[!a-z0-9]*|*[!a-z0-9]"$name"[!a-z0-9]*|*[!a-z0-9]"${name%%/*}"[!a-z0-9]*) ;;
      *) continue ;;
    esac
    row=$("$CP" row "$slug" 2>/dev/null)
    case $row in
      "$slug"$'\t'live$'\t'*) continue ;;
    esac
    detail=$(printf '%s' "$row" | cut -f3)
    printf '%s\t%s\t%s\n' "$sha" "$slug" "${detail:-the probe printed nothing}"
    exit 0
  done <<<"$parts"
done < <(printf '%s' "$msg" | tr '\n' ' ' | sed -E 's/([.!?])[[:space:]]+/\1\n/g')
exit 1
