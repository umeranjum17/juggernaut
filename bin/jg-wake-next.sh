#!/usr/bin/env bash
# jg-wake-next.sh - fetch the next wake and its acknowledgement token in one call.
#
# A caller that wants its next wake currently has to drain, scrape the
# WAKE_ACK_REQUIRED line off stderr, and rebuild the --ack-through command by
# hand. This script does all three: it runs jg-wake-drain.sh, relays that
# presentation unchanged, and prints exactly one machine-readable line naming
# the ready-to-run acknowledgement.
#
# Output:
#   - stdout: everything jg-wake-drain.sh prints on stdout, unchanged - the
#     presented rows, their annotations, and every section the drain emits
#     (OPEN DECISIONS, UNREAD STATUS, BRANCH OUTCOMES, and the rest), so one call
#     still reconciles everything a drain would surface.
#   - stderr: the drain's own stderr, unchanged except that its
#     WAKE_ACK_REQUIRED line is consumed here and not relayed.
#   - then, last on stdout, exactly one of:
#       WAKE_NEXT_ACK: bin/jg-wake-drain.sh --ack-through <sequence> --recovery-generation <generation>
#       WAKE_NEXT_ACK: none
#     The first is the exact command that retires the rows this call presented;
#     run it after handling the wake. The second means the drain presented no
#     wake and no recovery episode needs retiring, so there is nothing to
#     acknowledge.
#
# bin/jg-wake-drain.sh stays the single owner of claiming, presenting, and
# acknowledging wake rows: this script never reads or mutates the queue, never
# reclassifies a row, and inherits the drain's per-actor scoping (including a Pi
# supervision branch's granted set) untouched. Its exit status is the drain's,
# so a caller still sees a skipped or failed presentation as a failure and gets
# no acknowledgement to run.
#
# No arguments.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"

case "${1:-}" in
  '') ;;
  *) printf 'usage: jg-wake-next.sh\n' >&2; exit 2 ;;
esac

# Stream the presentation straight to our stdout (fd 3) while capturing the
# drain's stderr, which is where it names the acknowledgement token.
exec 3>&1
drain_err=$("$SCRIPT_DIR/jg-wake-drain.sh" 2>&1 1>&3)
status=$?
exec 3>&-

ack=
if [ -n "$drain_err" ]; then
  ack=$(printf '%s\n' "$drain_err" \
    | sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9][0-9]* --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' \
    | tail -1)
  printf '%s\n' "$drain_err" | grep -v '^WAKE_ACK_REQUIRED:' >&2 || true
fi

if [ -n "$ack" ]; then
  printf 'WAKE_NEXT_ACK: bin/jg-wake-drain.sh %s\n' "$ack"
else
  printf 'WAKE_NEXT_ACK: none\n'
fi
exit "$status"
