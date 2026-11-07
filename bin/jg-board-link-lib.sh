#!/usr/bin/env bash
# jg-board-link-lib.sh - the one owner of a board item's deep link.
#
# The sign-off board routes by hash: <board-url>?token=<t>#decide/<key>, and
# likewise #reports, #evidence, #designs, #waiting, #answered and #tickets. The board address, token
# included, is the first line of the file the dashboard front already reads:
# $JG_SIGNOFF_URL_FILE, else $JG_HOME/state/signoff-board.url (private state).
#
#   jg_board_link <section> <key>    print the full deep link, or print nothing
#                                    and return 1 when the URL file, the key or
#                                    the section is unusable
#   jg_board_merge_key <pr-url>      the key merge-card gives a PR's evidence card
#   jg_board_file <home>             the board file merge cards go on ($JG_PROOF_BOARD, else
#                                    the --board of <home>/config/post-merge, else the parent
#                                    home's when <home> is a Squad Lead), or return 1
#   jg_board_has_decide_link <text>  return 0 when the text holds a board #decide/<key> link
#   jg_board_link_fix <text>         set JG_BOARD_LINK_OUT to the text with every bare
#                                    board link given the token; return 1 (reason on
#                                    stderr, never the token) when a bare link cannot
#                                    be fixed, so the send is refused
#
# A caller prints the link on its own line and ignores the return code; a missing
# board never fails a caller. The link carries the token, so callers send it only
# to the terminal or to private state, never into a tracked file.
#
# A bare board link is a board-host URL with a #decide/#reports/#designs/#waiting/
# #answered/#tickets fragment and no token. jg_board_link_fix is the one place that rule
# lives; every send to the owner (inbox reply, chat reply, Telegram through
# bin/jg-board-link.sh fix) calls it. A link that already carries token= is left as is.
#
# Sourced by bin/jg-question-card.sh, bin/jg-merge-outcome-lib.sh and the
# merge-card feature. No side effects on source.

jg_board_link() {  # <section> <key>
  local section=${1:-} key=${2:-} file url
  case "$section" in decide|reports|evidence|designs|waiting|answered|tickets) ;; *) return 1 ;; esac
  case "$key" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  file=${JG_SIGNOFF_URL_FILE:-${JG_HOME:-}/state/signoff-board.url}
  [ -f "$file" ] || return 1
  IFS= read -r url < "$file" || [ -n "$url" ]
  case "$url" in http://?*|https://?*) ;; *) return 1 ;; esac
  case "$url" in *[[:space:]]*) return 1 ;; esac
  url=${url%%#*}
  printf '%s#%s/%s\n' "$url" "$section" "$key"
}

jg_board_merge_key() {  # <pr-url>
  local key=${1#*://}
  key=merge-$(printf '%s' "${key#*/}" | tr -c 'A-Za-z0-9._-' -)
  printf '%s\n' "${key:0:128}"
}

jg_board_file() {  # <home>
  local board=${JG_PROOF_BOARD:-} home=${1:-} cfg
  cfg=${JG_CONFIG_OVERRIDE:-$home/config}
  [ -n "$board" ] || board=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$cfg/post-merge" 2>/dev/null | head -n 1)
  # A Squad Lead home with no board of its own files on its parent's, so a lead's merge is not left off the board.
  if [ -z "$board" ] && declare -F jg_compat_parent_marker >/dev/null && declare -F jg_squad_lead_parent_record_parse >/dev/null \
    && jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$home")" && [ -n "$JG_SQUAD_LEAD_PARENT_HOME" ]; then
    board=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$JG_SQUAD_LEAD_PARENT_HOME/config/post-merge" 2>/dev/null | head -n 1)
  fi
  [ -n "$board" ] || return 1
  printf '%s\n' "$board"
}

jg_board_has_decide_link() {  # <text>
  [[ $1 =~ https?://[^][:space:]#\<\>\"\'\(\)]+#decide/[A-Za-z0-9._-]+ ]]
}

# shellcheck disable=SC2034  # JG_BOARD_LINK_OUT is the result the caller reads.
jg_board_link_fix() {  # <text>
  local rest=$1 out='' m pre file board='' auth='' token_ok=0 u ua
  local re='(https?://[^][:space:]#<>"'"'"'()]+)#(decide|reports|designs|waiting|answered|tickets)'
  JG_BOARD_LINK_OUT=$1
  file=${JG_SIGNOFF_URL_FILE:-${JG_HOME:-}/state/signoff-board.url}
  if [ -f "$file" ]; then
    IFS= read -r board < "$file" || [ -n "$board" ]
    case "$board" in http://?*|https://?*) ;; *) board='' ;; esac
    case "$board" in *[[:space:]]*) board='' ;; esac
    board=${board%%#*}
    if [ -n "$board" ]; then
      auth=${board#*://}
      auth=${auth%%[/?]*}
      case "$board" in *\?token=?*|*\&token=?*) token_ok=1 ;; esac
    fi
  fi
  while [[ $rest =~ $re ]]; do
    m=${BASH_REMATCH[0]}
    u=${BASH_REMATCH[1]}
    pre=${rest%%"$m"*}
    rest=${rest#*"$m"}
    case "$u" in
      *token=*) out+=$pre$m; continue ;;
    esac
    ua=${u#*://}
    ua=${ua%%[/?]*}
    if [ -n "$auth" ] && [ "$ua" != "$auth" ]; then
      out+=$pre$m   # another host: not a board link
      continue
    fi
    if [ "$token_ok" -ne 1 ]; then
      echo "board link refused: the message holds a board link without its access token, and this home has no board address with a token to add" >&2
      return 1
    fi
    out+=$pre$board'#'${BASH_REMATCH[2]}
  done
  JG_BOARD_LINK_OUT=$out$rest
}
