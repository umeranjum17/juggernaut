#!/usr/bin/env bash
# jg-report-opening-check.sh - refuse a board report page whose opening is not
# the answer to the owner's ask.
#
# Usage:
#   jg-report-opening-check.sh <report.md> --card <card.json>
#   jg-report-opening-check.sh <report.md> --filer <task-id> [--board <board.json>] [--key <key>]
#
# A Recon writes data/<task-id>/report.md, whose first section is
# "## 1. Answer (five lines)", and posts a sign-off report page. The board
# opens that page with the heading of its picture (`visual.heading`); the
# sign-off skill says that heading is the answer. A page can still put any line
# there, and the owner reads the first sentence as the answer to his ask. This
# check compares the page opening with the first line of the report's Answer
# section and refuses when they are about different things.
#
# Rules, all deterministic:
#   1. report.md has an H2 section named Answer, and it is the first H2.
#   2. The page opening is `visual.heading`; a page with no picture
#      (`layout: document`, or no `visual`) opens with its first section's
#      heading, which must itself be the Answer, else the card title.
#   3. The opening is one short sentence of at most 30 words.
#   4. At least 60% of the opening's content words (lowercase words of three
#      letters or more, minus a short stopword list) occur in the first line
#      of the Answer section. A verbatim copy of that line always passes.
#
# --card checks one card file (a report.json or one board item).
# --filer checks every live report card the task posted on the board and passes
# when it posted none, or when no board can be found: no page, nothing to
# refuse. The board is --board, else JG_PROOF_BOARD, else the `--board` of
# config/post-merge. Exit 0 passes, 1 refuses with the reason on stderr,
# 2 is a usage or input error. Needs jq.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

MAX_WORDS=30
MIN_OVERLAP_PCT=60

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { printf 'jg-report-opening-check: %s\n' "$1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is needed'

REPORT=''; CARD=''; FILER=''; BOARD=''; KEY=''
[ $# -ge 1 ] || usage
case "$1" in -h|--help) usage ;; esac
REPORT=$1; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --card) [ $# -ge 2 ] || usage; CARD=$2; shift 2 ;;
    --filer) [ $# -ge 2 ] || usage; FILER=$2; shift 2 ;;
    --board) [ $# -ge 2 ] || usage; BOARD=$2; shift 2 ;;
    --key) [ $# -ge 2 ] || usage; KEY=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
{ [ -n "$CARD" ] || [ -n "$FILER" ]; } || usage
[ -z "$CARD" ] || [ -z "$FILER" ] || die '--card and --filer are exclusive'

# Content words of a text: lowercase, three letters or more, no stopwords.
content_words() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr -s ' ' '\n' \
    | awk 'length($0) >= 3 && !($0 in s) { if (!($0 ~ /^(the|and|for|that|this|with|from|has|have|had|was|were|are|not|but|you|your|its|into|than|then|them|they|their|will|can|all|any|one|our|out|too|per|via|his|her|she|who|how|why|what|when|where|which|also|each|every|more|most|only|over|such|some|just|about|after|before|been|being|does|did|each|make|made|get|gets|got|use|used|using|new)$/)) print }' \
    | sort -u
}

# The first non-blank line of the report's Answer section, plain text. Prints
# nothing and returns 1 with a reason on stderr when the section is missing or
# is not the first H2.
answer_first_line() {  # <report.md>
  local first
  first=$(grep -m1 -E '^##[[:space:]]' "$1" || true)
  if [ -z "$first" ]; then
    echo "the report has no sections: it needs a first section named Answer ($1)" >&2; return 1
  fi
  if ! printf '%s\n' "$first" | grep -qiE '^##[[:space:]]+(\*{0,2}[0-9]+[.)]?\*{0,2}[[:space:]]*)?\*{0,2}answer\b'; then
    echo "the report's first section is \"$(printf '%s' "$first" | sed -E 's/^##[[:space:]]+//')\", not Answer ($1)" >&2; return 1
  fi
  awk '
    /^##[[:space:]]/ { n++; next }
    n == 1 && NF && $0 !~ /^[[:space:]]*(---+|\*\*\*+|___+)[[:space:]]*$/ { print; exit }
  ' "$1" | sed -E 's/^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]+//; s/\*\*//g; s/`//g; s/__//g'
}

# The text a card page opens with, and where it came from.
card_opening() {  # <card json on stdin> -> "<source>\t<text>"
  jq -r '
    def clean: gsub("[\\n\\r\\t]+"; " ");
    if (.layout // "") != "document" and ((.visual.heading // "") | length) > 0
      then "the picture heading\t" + (.visual.heading | clean)
    elif ((.sections[0].heading // "") | length) > 0
      then "the first section heading\t" + (.sections[0].heading | clean)
    else "the title\t" + ((.title // "") | clean) end'
}

check_one() {  # <label> <answer line> <card json>
  local label=$1 answer=$2 card=$3 src text words hw aw hit pct
  IFS=$'\t' read -r src text <<EOF
$(printf '%s' "$card" | card_opening)
EOF
  if [ -z "${text// }" ]; then
    printf 'REFUSED: the page %s has no opening text. Put the report Answer, one short sentence, in the picture heading.\n' "$label" >&2; return 1
  fi
  words=$(printf '%s\n' "$text" | wc -w)
  if [ "$words" -gt "$MAX_WORDS" ]; then
    printf 'REFUSED: the page %s opens with %s words (%s: "%s"). Open with the Answer in one sentence of %s words or fewer.\n' \
      "$label" "$words" "$src" "$text" "$MAX_WORDS" >&2; return 1
  fi
  hw=$(content_words "$text"); aw=$(content_words "$answer")
  hit=0; pct=0
  if [ -n "$hw" ]; then
    hit=$(comm -12 <(printf '%s\n' "$hw") <(printf '%s\n' "$aw") | wc -l)
    pct=$(( hit * 100 / $(printf '%s\n' "$hw" | wc -l) ))
  fi
  if [ "$pct" -lt "$MIN_OVERLAP_PCT" ]; then
    printf 'REFUSED: the page %s does not open with the Answer.\n  It opens with (%s): %s\n  The report Answer says: %s\n  Put the Answer, in plain words, in the picture heading, and put the evidence below it.\n' \
      "$label" "$src" "$text" "$answer" >&2
    return 1
  fi
  printf 'PASS: the page %s opens with the Answer (%s: "%s", %s%% of its words match).\n' "$label" "$src" "$text" "$pct"
}

[ -f "$REPORT" ] || die "no report at $REPORT"

# Compare each card in $1 with the report Answer; the report is read only here,
# so a task with no page never needs an Answer section.
check_cards() {  # <cards, one JSON card per line>
  local card key rc=0 ANSWER
  if ! ANSWER=$(answer_first_line "$REPORT"); then
    printf 'REFUSED: %s\n' 'the report cannot be compared with its page. Start report.md with "## 1. Answer (five lines)".' >&2; return 1
  fi
  [ -n "$ANSWER" ] || { printf 'REFUSED: the Answer section of %s is empty.\n' "$REPORT" >&2; return 1; }
  while IFS= read -r card; do
    key=$(printf '%s' "$card" | jq -r '.key // "(no key)"')
    check_one "$key" "$ANSWER" "$card" || rc=1
  done <<EOF2
$1
EOF2
  return $rc
}

if [ -n "$CARD" ]; then
  [ -f "$CARD" ] || die "no card at $CARD"
  jq -e . "$CARD" >/dev/null 2>&1 || die "$CARD is not JSON"
  check_cards "$(jq -c . "$CARD")"; exit $?
fi

[ -n "$BOARD" ] || BOARD=${JG_PROOF_BOARD:-}
[ -n "$BOARD" ] || BOARD=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$CONFIG/post-merge" 2>/dev/null | head -n 1)
if [ -z "$BOARD" ] || [ ! -f "$BOARD" ]; then
  echo "SKIP: no board file found, so no report page to check."; exit 0
fi
jq -e . "$BOARD" >/dev/null 2>&1 || die "$BOARD is not JSON"
cards=$(jq -c --arg f "$FILER" --arg k "$KEY" '
  [(.items // []), (.decisions // [])] | add | .[]
  | select((.kind // .type // "") == "report" and .filer == $f and (.dismissed // false) != true
           and ($k == "" or .key == $k))' "$BOARD")
if [ -z "$cards" ]; then
  echo "SKIP: task $FILER has no live report page on the board."; exit 0
fi
check_cards "$cards"; exit $?
