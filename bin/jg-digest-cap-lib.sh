#!/usr/bin/env bash
# jg-digest-cap-lib.sh - the byte budget of the session-start digest.
#
# A fresh session must start with most of its context free, so bin/jg-session-start.sh
# prints at most JG_DIGEST_CAP bytes (defaults/token-caps `digest-cap`, 40000). This
# file is the one owner of that arithmetic and of the one way a section is cut.
#
#   jg_digest_budget_init <total-cap> <reserve>   start counting; <reserve> bytes stay
#                                                 free for the sections that print last
#   jg_digest_say                                 stdin -> stdout, counted, never cut
#   jg_digest_avail <section-cap>                 the bytes this section may print now:
#                                                 its own cap, or what the whole digest
#                                                 still has left, whichever is smaller
#   jg_digest_clip <budget> <noun> <command>      stdin -> stdout in whole lines, at most
#                                                 <budget> bytes, counted; a cut ends in ONE
#                                                 marker line with the total count and <command>,
#                                                 the command that prints everything
#
# What a section prints first is what survives a cut, so a caller feeds it the
# most urgent and newest lines first (bin/jg-session-start.sh orders them).
# Nothing here deletes anything: a cut prints a count and a pointer, and the
# full list stays where it was.
#
# The counter lives in a file, not a variable, because a section often prints from
# inside a pipeline and a subshell cannot update its parent's variable.

JG_DIGEST_USED_FILE=
JG_DIGEST_TOTAL_CAP=0
JG_DIGEST_RESERVE=0

jg_digest_budget_init() {  # <total-cap> <reserve>
  JG_DIGEST_TOTAL_CAP=$1
  JG_DIGEST_RESERVE=${2:-0}
  JG_DIGEST_USED_FILE=$(mktemp "${TMPDIR:-/tmp}/jg-digest-used.XXXXXX" 2>/dev/null) || JG_DIGEST_USED_FILE=
  [ -z "$JG_DIGEST_USED_FILE" ] || printf '0\n' > "$JG_DIGEST_USED_FILE"
}

jg_digest_budget_close() {
  [ -z "$JG_DIGEST_USED_FILE" ] || rm -f -- "$JG_DIGEST_USED_FILE"
  JG_DIGEST_USED_FILE=
}

jg_digest_account() {  # <bytes>
  [ -n "$JG_DIGEST_USED_FILE" ] || return 0
  printf '%s\n' "$1" >> "$JG_DIGEST_USED_FILE"
}

jg_digest_used() {
  [ -n "$JG_DIGEST_USED_FILE" ] || { printf '0\n'; return 0; }
  awk '{ n += $1 } END { print n + 0 }' "$JG_DIGEST_USED_FILE"
}

# Bytes of a string, not characters: the cap is a byte cap.
jg_digest_bytes() {  # <string>
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

jg_digest_say() {
  local scratch
  scratch=$(mktemp "${TMPDIR:-/tmp}/jg-digest-say.XXXXXX") || { cat; return 0; }
  cat > "$scratch"
  cat "$scratch"
  jg_digest_account "$(wc -c < "$scratch" | tr -d '[:space:]')"
  rm -f -- "$scratch"
}

jg_digest_avail() {  # <section-cap>
  local cap=$1 left
  left=$((JG_DIGEST_TOTAL_CAP - JG_DIGEST_RESERVE - $(jg_digest_used)))
  [ "$left" -gt 0 ] || left=0
  [ "$cap" -le "$left" ] || cap=$left
  printf '%s\n' "$cap"
}

jg_digest_clip() {  # <budget> <noun> <command>
  local budget=$1 noun=$2 command=$3 acct
  acct=$(mktemp "${TMPDIR:-/tmp}/jg-digest-clip.XXXXXX") || return 0
  LC_ALL=C awk -v budget="$budget" -v noun="$noun" -v command="$command" -v acct="$acct" '
    { line[++n] = $0; total += length($0) + 1 }
    END {
      used = 0; keep = n
      if (total > budget) {
        # The marker is paid for out of the budget, so a cut section never overruns it.
        reserve = length(sprintf("[cut: 999999 of %d %s shown; all of them: %s]", n, noun, command)) + 1
        keep = 0
        for (i = 1; i <= n; i++) {
          if (used + length(line[i]) + 1 > budget - reserve) break
          used += length(line[i]) + 1; keep = i
        }
      } else {
        used = total
      }
      for (i = 1; i <= keep; i++) print line[i]
      if (keep < n) {
        marker = sprintf("[cut: %d of %d %s shown; all of them: %s]", keep, n, noun, command)
        print marker; used += length(marker) + 1
      }
      printf "%d\n", used > acct
    }'
  jg_digest_account "$(cat "$acct")"
  rm -f -- "$acct"
}
