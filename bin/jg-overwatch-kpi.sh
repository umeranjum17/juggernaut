#!/usr/bin/env bash
# jg-overwatch-kpi.sh - the Overwatch KPI: every captain message is an
# intervention, tagged in the turn it arrives with why he had to come. The
# captain should come only for a major decision only he can take or to file
# new work; feedback and micromanagement (chasing, repeating, asking for state)
# are Overwatch misses, and each one links to a Juggernaut ticket or PR that
# changes code so that kind of message stops.
#
# LEDGER. $DATA/overwatch-kpi.jsonl, one JSON object per line, append-only:
#   {"seq":N,"epoch":N,"text":"..."}                   a captain message (first 200 characters)
#   {"tag":N,"epoch":N,"kind":"<kind>","link":"..."}   a tag of message N; its newest tag wins
#
# WRITERS. The prompt-submit hooks append each captain message: Claude's
# UserPromptSubmit and Cursor's beforeSubmitPrompt, the same surfaces that feed
# bin/jg-host-mirror.sh. A captain message typed at the board's chat has no
# prompt hook to catch it, so bin/jg-chat.sh records it with `record`, through
# the same appender: either way it is one captain message and its tag is asked
# for the same way. The hook is a silent no-op outside a genuine primary
# checkout, and it drops a prompt the operational-input protocol classifies
# (bin/jg-operational-input.sh) and a harness-started <task-notification> turn,
# so only what the captain typed is counted. A leading doorbell line is stripped
# first (bin/jg-operational-input.sh strip-doorbell), so a doorbell left unsent
# in his composer keeps its own line out of the count while the words he
# submitted after it are counted as his message; a prompt that held only a
# doorbell records nothing. A primary with no prompt hook records nothing, so
# nothing there is ever pending. A home whose
# config/overwatch-kpi reads `off` records nothing either; that is for a lab
# whose prompts are scripted rather than typed by a captain.
#
# GUARD. bin/jg-turnend-guard.sh blocks a turn end once per message while the
# newest captain message is untagged (`pending`); one block per message keeps
# every harness bounded, and a message left untagged still counts as a miss.
#
# KINDS. new-work and decision-answer are the captain's job and need no link.
# feedback and micromanagement need <link>: a pull request, merge request, or
# issue URL on a remote of this Juggernaut checkout, or an id in this home's
# backlog (bin/jg-tasks-axi.sh show). A file path, memory file, or note is
# refused, because it changes no code.
#
# SCORECARD. `scorecard` reports the misses per calendar day and per trailing
# week against a target of zero, with the link each one carries, so the captain
# and the dashboard read the KPI as a number instead of a memory. It reads the
# ledger only and never the forge, so a dashboard render stays offline and
# instant; `--landed` adds whether each linked fix has landed (a PR by its
# merged flag, a backlog id by its done state) and is opt-in for that reason.
#
# Usage:
#   jg-overwatch-kpi.sh hook <claude|cursor>   a prompt-submit hook payload on stdin
#   jg-overwatch-kpi.sh tag <kind> [<link>]    tag the newest captain message
#   jg-overwatch-kpi.sh record <text>          record a captain message typed
#                                             outside a harness prompt hook
#   jg-overwatch-kpi.sh pending                print "<seq>\t<text>" when the newest message is untagged
#   jg-overwatch-kpi.sh scorecard [--json] [--landed]
#                                              misses per day and per week, target zero
# hook always exits 0 and prints nothing; tag exits 2 on a refused kind or
# link and 1 when no message is recorded; pending exits 0 when a message is
# pending and 1 otherwise; scorecard exits 0 with its report.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
LEDGER="$DATA/overwatch-kpi.jsonl"
KINDS='new-work decision-answer feedback micromanagement'
SCHEMA='jg-overwatch-kpi-scorecard.v1'

usage() {
  sed -n '/^# Usage:/,/^# hook always/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'jg-overwatch-kpi: %s\n' "$1" >&2
  exit 2
}

utc_day() {  # <epoch> -> YYYY-MM-DD in UTC
  date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F
}

# The scorecard as one JSON object: the day, the trailing week, and that
# week's misses. Every message with a tag of feedback or micromanagement is a
# miss, its newest tag winning, and the day and week counts come from the same
# array, so the totals cannot disagree with the list.
scorecard_json() {  # <now> <today> <week_start>; the ledger on stdin
  jq -Rrs --arg schema "$SCHEMA" --argjson now "$1" --arg today "$2" --arg week_start "$3" '
    [split("\n")[] | fromjson? | select(type == "object")] as $r
    | [$r[] | select(.seq | numbers)] as $msgs
    | [[$r[] | select(.tag | numbers)] | group_by(.tag) | map(last)[]
       | . as $t
       | ($msgs | map(select(.seq == $t.tag)) | last) as $m
       | select($t.kind == "feedback" or $t.kind == "micromanagement")
       | {seq: $t.tag,
          epoch: ($m.epoch // $t.epoch // 0),
          kind: $t.kind,
          link: ($t.link // "")}
       | . + {date: (.epoch | strftime("%Y-%m-%d"))}] as $all
    | [$all[] | select(.date >= $week_start)] as $week
    | {schema: $schema, generated: $now, target: 0,
       day: {date: $today,
             feedback: ([$all[] | select(.date == $today and .kind == "feedback")] | length),
             micromanagement: ([$all[] | select(.date == $today and .kind == "micromanagement")] | length),
             total: ([$all[] | select(.date == $today)] | length)},
       week: {start: $week_start, end: $today,
              feedback: ([$week[] | select(.kind == "feedback")] | length),
              micromanagement: ([$week[] | select(.kind == "micromanagement")] | length),
              total: ($week | length)},
       misses: ($week | sort_by(.epoch))}'
}

# Whether a miss's linked fix landed. A pull request asks the forge for its
# merged flag; a backlog id is landed when its record is done; anything else
# is unknown, which is an answer rather than a guess.
landed_of() {  # <link>
  local link=$1 out
  case "$link" in
    https://github.com/*/pull/[0-9]*)
      out=$(gh-axi pr view "${link##*/}" 2>/dev/null) || { echo unknown; return; }
      case "$out" in
        *'merged: yes'*) echo yes ;;
        *'merged: no'*) echo no ;;
        *) echo unknown ;;
      esac
      ;;
    ''|*[!A-Za-z0-9._-]*) echo unknown ;;
    *)
      out=$("$SCRIPT_DIR/jg-tasks-axi.sh" show "$link" 2>/dev/null) || { echo unknown; return; }
      case "$out" in *'state: done'*) echo yes ;; *) echo no ;; esac
      ;;
  esac
}

# The newest captain message's seq, or 0.
newest_seq() {
  [ -f "$LEDGER" ] || { echo 0; return; }
  jq -Rn '[inputs | fromjson? | select(type == "object") | .seq | numbers] | max // 0' "$LEDGER" 2>/dev/null
}

# Append one captain message. The prompt hook and a captain message typed at the
# board's chat (bin/jg-chat.sh send) share this writer, so the KPI counts the
# captain's intervention the same way whichever route it took.
record_message() { # <text>
  mkdir -p "$DATA" 2>/dev/null || return 1
  printf '%s' "$1" | jq -cRs --argjson seq "$(( $(newest_seq) + 1 ))" --argjson epoch "$(date +%s)" \
    '{seq: $seq, epoch: $epoch, text: .[0:200]}' >> "$LEDGER" 2>/dev/null
}

# A link counts only when it names code work on this Juggernaut repository.
link_ok() {  # <link>
  local link=$1 repo
  case "$link" in
    https://*/pull/[0-9]*|https://*/issues/[0-9]*|https://*/merge_requests/[0-9]*)
      repo=$(printf '%s\n' "${link//\/-\//\/}" \
        | sed -nE 's#^https://[^/]+/(.*/)?([^/]+/[^/]+)/(pull|issues|merge_requests)/[0-9]+/?$#\2#p')
      [ -n "$repo" ] || return 1
      git -C "$JG_ROOT" remote -v 2>/dev/null | awk '{print $2}' \
        | sed -E 's#\.git$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#' | grep -qixF "$repo"
      ;;
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) "$SCRIPT_DIR/jg-tasks-axi.sh" show "$link" >/dev/null 2>&1 ;;
  esac
}

case "${1:-}" in
  hook|tag|pending|scorecard|record) ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
if ! command -v jq >/dev/null 2>&1; then
  case "$1" in hook) exit 0 ;; pending|scorecard) exit 1 ;; esac
  refuse 'jq is required'
fi

case "$1" in
  hook)
    [ "$#" -eq 2 ] || exit 0
    PAYLOAD=$(cat 2>/dev/null || true)
    [ -n "$PAYLOAD" ] || exit 0
    # shellcheck source=bin/jg-primary-scope-lib.sh
    . "$SCRIPT_DIR/jg-primary-scope-lib.sh"
    jg_primary_root_matches "$JG_ROOT" || exit 0
    [ "$(cat "$CONFIG/overwatch-kpi" 2>/dev/null)" != off ] || exit 0
    if [ "$2" = claude ]; then
      # shellcheck source=bin/jg-hook-host-lib.sh
      . "$SCRIPT_DIR/jg-hook-host-lib.sh"
      # Cursor loads the tracked Claude settings too; its own entry records it.
      jg_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
    fi
    TEXT=$(printf '%s' "$PAYLOAD" | jq -r 'select(type == "object")
      | select(.hook_event_name == "UserPromptSubmit" or .hook_event_name == "beforeSubmitPrompt")
      | (.prompt // "") | tostring' 2>/dev/null) || exit 0
    case "${TEXT#"${TEXT%%[![:space:]]*}"}" in ''|'<task-notification>'*) exit 0 ;; esac
    # A doorbell left unsent in the captain's composer is submitted glued to his
    # own next sentence (captured in a real primary's message box). The text that follows it is
    # what he actually said, so strip the doorbell lines and count the rest;
    # only a prompt that was nothing but doorbell records no message at all.
    TEXT=$(printf '%s' "$TEXT" | "$SCRIPT_DIR/jg-operational-input.sh" strip-doorbell 2>/dev/null) || true
    case "${TEXT#"${TEXT%%[![:space:]]*}"}" in ''|'<task-notification>'*) exit 0 ;; esac
    printf '%s' "$TEXT" | "$SCRIPT_DIR/jg-operational-input.sh" classify >/dev/null 2>&1 && exit 0
    record_message "$TEXT" || true
    exit 0
    ;;
  record)
    [ "$#" -ge 2 ] || usage
    shift
    [ -n "${*//[[:space:]]/}" ] || usage
    [ "$(cat "$CONFIG/overwatch-kpi" 2>/dev/null)" != off ] || exit 0
    record_message "$*" || { printf 'jg-overwatch-kpi: cannot record the message\n' >&2; exit 1; }
    ;;
  pending)
    [ "$#" -eq 1 ] || usage
    [ -f "$LEDGER" ] || exit 1
    OUT=$(jq -Rrs '[split("\n")[] | fromjson? | select(type == "object")] as $r
      | ([$r[] | select(.seq | numbers)] | last) as $m
      | if $m == null or any($r[]; .tag == $m.seq) then empty else "\($m.seq)\t\($m.text | gsub("\\s+"; " "))" end' "$LEDGER" 2>/dev/null)
    [ -n "$OUT" ] || exit 1
    printf '%s\n' "$OUT"
    ;;
  scorecard)
    shift
    WANT_JSON=0 WANT_LANDED=0
    for arg in "$@"; do
      case "$arg" in
        --json) WANT_JSON=1 ;;
        --landed) WANT_LANDED=1 ;;
        *) usage ;;
      esac
    done
    NOW=$(date +%s)
    TODAY=$(utc_day "$NOW")
    WEEK_START=$(utc_day $((NOW - 6 * 86400)))
    if [ -f "$LEDGER" ]; then
      REPORT=$(scorecard_json "$NOW" "$TODAY" "$WEEK_START" < "$LEDGER")
    else
      REPORT=$(scorecard_json "$NOW" "$TODAY" "$WEEK_START" < /dev/null)
    fi
    [ -n "$REPORT" ] || { printf 'jg-overwatch-kpi: cannot read %s\n' "$LEDGER" >&2; exit 1; }
    if [ "$WANT_LANDED" -eq 1 ] && [ "$(printf '%s' "$REPORT" | jq '.misses | length')" -gt 0 ]; then
      LANDED=$(printf '%s' "$REPORT" | jq -r '.misses[] | [.seq, .link] | @tsv' \
        | while IFS=$'\t' read -r seq link; do printf '%s\t%s\n' "$seq" "$(landed_of "$link")"; done \
        | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
      REPORT=$(printf '%s' "$REPORT" | jq --argjson landed "$LANDED" \
        '.misses |= map(. + {landed: ($landed[.seq | tostring] // "unknown")})')
    fi
    if [ "$WANT_JSON" -eq 1 ]; then
      printf '%s\n' "$REPORT" | jq .
    else
      printf '%s' "$REPORT" | jq -r '
        "overwatch kpi, target \(.target) missed captain message",
        "day  \(.day.date)  feedback \(.day.feedback)  micromanagement \(.day.micromanagement)",
        "week \(.week.start)..\(.week.end)  feedback \(.week.feedback)  micromanagement \(.week.micromanagement)",
        (.misses[] | "miss \(.seq)  \(.date)  \(.kind)  \(if .link == "" then "-" else .link end)\(if .landed then "  landed: \(.landed)" else "" end)")'
    fi
    ;;
  tag)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage
    KIND=$2
    LINK=${3:-}
    case " $KINDS " in *" $KIND "*) ;; *) refuse "unknown kind '$KIND' (one of: $KINDS)" ;; esac
    case "$KIND" in
      feedback|micromanagement)
        [ -n "$LINK" ] || refuse "a $KIND message is a miss: link it to a Juggernaut ticket or PR that changes code so it stops"
        link_ok "$LINK" || refuse "'$LINK' is not a pull request, merge request, or issue on this Juggernaut repository, nor a backlog id here; a memory file or note changes no code"
        ;;
    esac
    SEQ=$(newest_seq)
    [ "$SEQ" -gt 0 ] || { printf 'jg-overwatch-kpi: no captain message is recorded to tag\n' >&2; exit 1; }
    jq -cn --argjson tag "$SEQ" --argjson epoch "$(date +%s)" --arg kind "$KIND" --arg link "$LINK" \
      '{tag: $tag, epoch: $epoch, kind: $kind, link: $link}' >> "$LEDGER" || exit 1
    printf 'captain message %s tagged %s\n' "$SEQ" "$KIND"
    ;;
esac
