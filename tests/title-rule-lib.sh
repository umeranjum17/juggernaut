# shellcheck shell=bash
# The readable-title rule the suites of the scripts that file a ticket by themselves check a stored title against:
# 2 to 7 words, at most 48 characters, no [tag], no id (jg-..., a Main task number, 32 hex), no URL or path.
# Usage: . tests/title-rule-lib.sh; title_rule_ok "<title>" || fail "..."
title_rule_ok() {  # <title>
  local title=$1 words
  words=$(printf '%s' "$title" | wc -w)
  [ "$words" -ge 2 ] && [ "$words" -le 7 ] && [ "${#title}" -le 48 ] || return 1
  case "$title" in *'['*']'*|*/*|*jg-*|*Main[0-9]*) return 1 ;; esac
  ! printf '%s' "$title" | grep -Eq '[0-9a-f]{32}'
}
