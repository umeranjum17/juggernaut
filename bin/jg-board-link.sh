#!/usr/bin/env bash
# jg-board-link.sh - command line for the board-link rules in jg-board-link-lib.sh.
#
#   jg-board-link.sh fix     read a message on stdin; print it with every bare board
#                            link given the board access token. Exit 1 with the reason
#                            on stderr (never the token) when a bare link cannot be
#                            fixed: the caller must not send the message.
#
# The Telegram gateway (core/bus) calls this before every send to the owner.
set -u
here=${BASH_SOURCE[0]%/*}
[ "$here" != "${BASH_SOURCE[0]}" ] || here=.
# shellcheck source=bin/jg-board-link-lib.sh
. "$here/jg-board-link-lib.sh"
case "${1:-}" in
  fix)
    text=$(cat; printf .)
    text=${text%.}
    jg_board_link_fix "$text" || exit 1
    printf '%s' "$JG_BOARD_LINK_OUT"
    ;;
  *) echo "usage: jg-board-link.sh fix < message" >&2; exit 2 ;;
esac
