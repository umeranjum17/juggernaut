#!/usr/bin/env bash
# Alert recipient authority, owned by jg-alert.sh; table rows own class ceilings
# and allowed security producers. An owner gate is read through the backlog owner.
# Fields are inherited by derived alerts, never inferred from note text or facts.

_authority_gate() { # <gate> <ticket> <origin>
  local rows must
  [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
  # shellcheck disable=SC2154 # jg-alert.sh sets its root before sourcing this library.
  rows=$(bash "$_root/bin/jg-backlog.sh" questions --ticket "$2" --json) || return 1
  must=$(jq -er --arg g "$1" --arg t "$2" --arg o "$3" '
    .[] | select(.id == $g and .ticket == $t and .origin == $o and .state == "open"
      and (.question | type == "string" and length > 0)) | .must' <<<"$rows") || return 1
  # shellcheck source=bin/jg-ask-gate-lib.sh
  . "$_root/bin/jg-ask-gate-lib.sh"
  jg_ask_category_ok "$must"
}

_authority_check() { # <class> <gate> <ticket> <origin> <security-source> <source-alert>
  case $1 in
    team-action) [ -z "$2$5" ] ;;
    owner-call) [ -z "$5" ] && _authority_gate "$2" "$3" "$4" ;;
    security-awareness)
      [ "$6" = security ] && [ -z "$2" ] && [ -n "$5" ] \
        && _rows security-source | awk -F'\t' -v s="$5" '$2==s {ok=1} END {exit !ok}' ;;
    *) return 1 ;;
  esac
}

_authority_record() { # <record>; legacy records have team authority only
  local f=$1 source episode
  source=$(_get "$f" source_key)
  if [ -n "$source" ]; then
    episode=$(_get "$f" source_episode)
    source=$(_rec "$source" authority) || return 1
    # shellcheck disable=SC2154 # jg-alert.sh loads the terminal state from its machine table.
    [ -n "$episode" ] && [ "$episode" = "$(_get "$source" episode)" ] \
      && [ "$(_get "$source" state)" != "$s_res" ] || return 1
  fi
  _authority_check "${2:-$(_get "$f" authority_class)}" "$(_get "$f" owner_gate)" \
    "$(_get "$f" ticket)" "$(_get "$f" origin)" "$(_get "$f" security_source)" "$(_get "$f" authority_alert)"
}

_authority_top() { # <record>: invalid/revoked authority retains Main recovery
  local cls; cls=$(_get "$1" authority_class)
  if ! _authority_record "$1"; then cls=team-action; fi
  _rows authority | awk -F'\t' -v c="$cls" '$2==c {print $3}'
}
