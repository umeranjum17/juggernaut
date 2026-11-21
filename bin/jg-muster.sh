#!/usr/bin/env bash
# jg-muster.sh - the board rounds of a muster and the one answer loop that closes them.
#
# Usage:
#   jg-muster.sh round <ticket> --questions <file> [--round <n>] [--doc <vision file>]
#   jg-muster.sh answer <ticket> --card <card-key> [--value <option letter> | --words <text>]
#   jg-muster.sh answer <ticket> --note <chat note id>
#   jg-muster.sh answer <ticket> --default <R<round>Q<k>>
#   jg-muster.sh revise <ticket> <round> --questions <file>
#   jg-muster.sh revise <ticket> <R<round>Q<k>> (--value <option letter> | --words <text>) [--source board|chat]
#   jg-muster.sh round-status <ticket> [--json]
#   jg-muster.sh repair <ticket>
#
# The method and the question standard are owned by .agents/skills/muster/SKILL.md; the frozen formats (the round
# record of section 2) are .agents/skills/muster/formats.md. This script records presentations and answers in
# data/<ticket>/muster/rounds.tsv. jg-muster-council.sh writes the draft questions before presentation.
#
# A ROUND is one ticket (the round ticket) with one card per question, never the yes/no card an armed hold posts.
# `round` reads the questions file, a JSON array of one to five questions:
#   {"question": "<one plain question, 12 words or fewer, ending in ?>", "why": "<the context, 130 characters or fewer>",
#    "options": [{"value": "a", "label": "<name>", "outcome": "<what happens next>"}, ...two to four, a b c d],
#    "recommend": "a", "recommend_reason": "<one line>", "label": "reversible|architecture|irreversible",
#    "default": "a", "default_by": "<ISO UTC time>", "required": true, "must": "plan-approval"}
# Only question, why, options, recommend and recommend_reason are required. An irreversible question takes no default
# and is guarded on the board; a reversible one may carry a default and the time it is taken.
# For each question, in order: the card is posted through bin/jg-question-card.sh post --raised-by <ticket> (so the
# card rules refuse before anything is recorded), then one gate is made with a dated captain-hold (a dated hold posts
# no second, yes/no card), and the gate id the backlog returned is looked up by the exact question text among the
# ticket's open questions. R<round>Q<k> -> gate, the card key, the revision and the question set he saw are appended
# to rounds.tsv. Only the gate id is ever fed to bin/jg-captain-hold.sh answers. Run again with the same file, `round`
# posts only new or draft questions, keeping the council's question ids and leaving its agreed answers settled.
#
# AN ANSWER binds to the presentation it names, never to what happens to be open (formats.md section 2):
#   --card   a board pick names its card; a card of an older revision closes nothing (stale).
#   --note   a chat note names its round with R<round> or R<round>.<revision>, or a question with R<round>Q<k> and an
#            option letter ("R1Q2 b") or free text ("R1Q3: use Rust"); "yes to the rest" then covers that round only,
#            with each question's recommended option. A note that names no round binds only while the ticket has
#            shown one presentation (one round, one revision); once a second one exists it closes nothing, is stored
#            as answer=unbound, and Main asks which round he meant. A note naming two rounds is unbound. Once a round
#            is revised, a round-only prefix and a question id whose words changed bind nothing; a note names the
#            revision (R1.2) or the answer goes on the card. A note naming a revision never shown binds nothing.
#   --default takes a reversible question's default (taken=default); an irreversible one never takes one.
# A repeat of an answer changes nothing; a different answer to an answered gate is refused (a change of mind is a
# `revise`). Free text is kept verbatim (a tab or line break becomes one space). Every close goes through the gate id.
# A late owner answer to a question a default closed is not refused: it is a revision (taken=owner).
#
# `revise <ticket> <round> --questions <file>` shows the round again as the next revision: a question whose words are
# unchanged keeps its gate and card, a changed one gets a new card and gate and its old open gate is closed as
# superseded. `revise <ticket> <qid> --value|--words` records the owner's changed or late answer as the next revision
# of the round, from the owner's own record (the gate itself keeps its first answer). Both rewrite the Decisions line.
#
# THE DOCUMENT. Each answer writes one line in the `## Decisions` section of the round's vision file (given once with
# --doc, kept in data/<ticket>/muster/doc): `- <date> R<round>Q<k>: "<his words>" (revision <n>)`; a default reads
# "default: <option>". The row's doc_rev is the document's sha256 prefix after the write. A worker that stops between
# the saved answer and the written line leaves a row with no doc_rev: `round-status` names it, `repair` redoes it.
#
# `round-status` reads only: per round, each question's gate, revision and state, the rows still owing a document
# line, the unbound notes, and whether the round is complete (no required gate open). `repair` writes.
# Exit: 0 done (a note that binds nothing is recorded, not an error), 1 refused or failed, 2 usage.
export LC_ALL=C
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
export JG_HOME

die() { printf 'jg-muster: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 2; }
backlog_cmd() { "$SCRIPT_DIR/jg-backlog.sh" "$@"; }
# shellcheck source=bin/jg-captain-ask-lib.sh
. "$SCRIPT_DIR/jg-captain-ask-lib.sh"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"

COLS='round revision qid gate presented qset question_sha answer source taken at doc_rev'
# The gate's question text is the one record of a question's words: options, recommendation and label are read back
# from it, so what was hashed and what was shown cannot differ.
# shellcheck disable=SC2016  # jq programs, not shell expansions
JQ_DEFS='
def notes: "\\s*\\((recommended|default|irreversible|architecture|reversible|optional)[^)]*\\)";
def options($q): [ ($q | gsub(notes; "")) | match("(?:^|\\s)([a-d])\\) (.*?)(?=\\s[a-d]\\) |$)"; "g")
  | {v: .captures[0].string, l: .captures[1].string} ];
def recommended($q): ([$q | capture("\\(recommended (?<v>[a-d])\\)") | .v] | first) // null;
def default_of($q): ([$q | capture("\\(default (?<v>[a-d])\\)") | .v] | first) // null;
def irreversible($q): ($q | test("\\(irreversible\\)"));
def optional($q): ($q | test("\\(optional\\)"));
'

sha12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
now() { date +%s; }
today() { date -u +%F; }
tabsafe() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# ---- the round record ---------------------------------------------------------------------------------------------
MDIR='' RFILE='' LOCKDIR=''
TICKET=''
use_ticket() {  # <ticket>
  TICKET=$1
  case "$1" in ''|*[!A-Za-z0-9._-]*) die "the ticket id '$1' is not a plain id" ;; esac
  backlog_cmd show "$1" >/dev/null 2>&1 || die "refused: $1 is not a ticket in this home's backlog"
  MDIR="$DATA/$1/muster"; RFILE="$MDIR/rounds.tsv"; LOCKDIR="$MDIR/.lock"
  mkdir -p "$MDIR" || die "cannot create $MDIR"
}
lock() {
  local n=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -le 100 ] || die "another muster command holds $LOCKDIR; if none runs, remove that folder"
    sleep 0.1
  done
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
}

append_line() { printf '%s\n' "$1" >> "$RFILE" || die "cannot write $RFILE"; }
append_row() {  # round revision qid gate presented qset question_sha answer source taken at doc_rev
  [ "$#" -eq 12 ] || die "internal: a round row has $# fields"
  append_line "$(IFS=$'\t'; printf '%s' "$*")"
}
rowmod() {  # <row> <column number>=<value>...: the row with those columns set (1 round ... 12 doc_rev)
  local row=$1 spec
  shift
  spec=$(printf '%s\n' "$@")
  printf '%s\n' "$row" | SPEC=$spec awk -F'\t' -v OFS='\t' 'BEGIN { n = split(ENVIRON["SPEC"], s, "\n") }
    { for (i = 1; i <= n; i++) { p = index(s[i], "="); $(substr(s[i], 1, p - 1) + 0) = substr(s[i], p + 1) } print }'
}

rows_json() {  # every row, question rows and unbound rows, as a JSON array
  [ -f "$RFILE" ] || { printf '[]\n'; return 0; }
  jq -R -s --arg cols "$COLS" '($cols | split(" ")) as $c
    | split("\n") | map(select(length > 0) | split("\t")) | map([$c, .] | transpose | map({(.[0]): (.[1] // "")}) | add)' "$RFILE"
}

gates_json() {  # <ticket>: {"<gate id>": {state, question, sha, words}}, every gate of the ticket
  local raw id state q words out='{}'
  raw=$(backlog_cmd questions --ticket "$1" --all --json 2>/dev/null) || die "cannot read the questions of $1"
  [ -n "$raw" ] || raw='[]'
  while IFS=$'\t' read -r id state q words; do
    [ -n "$id" ] || continue
    q=$(printf '%s' "$q" | base64 -d); words=$(printf '%s' "$words" | base64 -d)
    out=$(jq -c --arg id "$id" --arg s "$state" --arg q "$q" --arg sha "$(sha12 "$q")" --arg w "$words" \
      '.[$id] = {state: $s, question: $q, sha: $sha, words: $w}' <<<"$out")
  done < <(jq -r '.[] | [.id, .state, (.question | @base64), ((.words // "") | @base64)] | @tsv' <<<"$raw")
  printf '%s\n' "$out"
}

latest_row() {  # <qid>: the question's newest row as one TSV line (the last row wins; a repair appends a row)
  [ -f "$RFILE" ] || return 1
  awk -F'\t' -v q="$1" '$3 == q { l = $0 } END { if (l == "") exit 1; print l }' "$RFILE"
}
col() { printf '%s\n' "$2" | cut -f"$1"; }

qset_of() {  # <qid=sha>...: the presentation's question set
  printf '%s\n' "$@" | LC_ALL=C sort | tr -d '\n' | sha256sum | cut -c1-12
}

# ---- the questions file -------------------------------------------------------------------------------------------
# shellcheck disable=SC2016
QJQ='
  type == "array" and length >= 1 and length <= 5 and all(.[];
    (.question | type == "string" and test("\\?$") and (split(" ") | length) <= 12)
    and (.why | type == "string" and length > 0 and length <= 130)
    and (.options | type == "array" and length >= 2 and length <= 4
         and ([.[].value] == (["a","b","c","d"][0:length]))
         and all(.[]; (.label | type == "string" and length > 0 and (test("[?()]") | not))
                      and (.outcome | type == "string" and length > 0 and length <= 120)))
    and (.recommend as $r | .options | map(.value) | index($r) != null)
    and (.recommend_reason | type == "string" and length > 0 and length <= 160)
    and ((.label // "reversible") | IN("reversible", "architecture", "irreversible"))
    and ((.label // "reversible") != "irreversible" or ((.default // null) == null and (.default_by // null) == null))
    and (((.default // null) == null) or ((.default as $d | .options | map(.value) | index($d)) != null))
    and (((.default_by // null) == null) or ((.default // null) != null))
  )'
check_questions() {  # <file>
  [ -f "$1" ] || die "refused: the questions file $1 does not exist"
  jq -e "$QJQ" "$1" >/dev/null 2>&1 \
    || die "refused: $1 is not a list of one to five questions; each needs a question of 12 words or fewer ending in ?, a why of 130 characters or fewer, two to four options a b c d (label with no ? or parentheses, outcome), a recommend that names one, a recommend_reason, and no default on an irreversible one (see the header of bin/jg-muster.sh)"
}
gate_text() {  # <questions file> <index>: the gate's question text, the one record of the words
  jq -r --argjson i "$2" '.[$i] as $q
    | $q.question + " " + ($q.options | map(.value + ") " + .label) | join(" "))
    + " (recommended " + $q.recommend + ")"
    + (if ($q.label // "reversible") == "reversible" then "" else " (" + $q.label + ")" end)
    + (if ($q.default // null) != null then " (default " + $q.default + ")" else "" end)
    + (if $q.required == false then " (optional)" else "" end)' "$1"
}

# ---- gates and cards ----------------------------------------------------------------------------------------------
GATE_ID='' CARD_KEY=''
horizon() { date -u -d '+30 days' +%F 2>/dev/null || date -u -v+30d +%F; }

post_card() {  # <ticket> <questions file> <index> <round> <k> <revision>: sets CARD_KEY
  local ticket=$1 file=$2 i=$3 round=$4 k=$5 rev=$6 key why args=() out must label
  key="muster-$ticket-r${round}q$k-v$rev"
  must=$(jq -r --argjson i "$i" '.[$i].must // "plan-approval"' "$file")
  label=$(jq -r --argjson i "$i" '.[$i].label // "reversible"' "$file")
  why="R${round}Q$k: $(jq -r --argjson i "$i" '.[$i].why' "$file")"
  # Every presentation after the first says how to answer (formats.md section 2).
  { [ "$rev" -gt 1 ] || [ "$round" -gt 1 ]; } && why="$why Reply to this card, or start with R$round.$rev."
  while IFS=$'\t' read -r value lab outc; do
    args+=(--option "$value=$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]'): $lab" --outcome "$value=$outc")
  done < <(jq -r --argjson i "$i" '.[$i].options[] | [.value, .label, .outcome] | @tsv' "$file")
  [ "$label" != irreversible ] || args+=(--guard irreversible)
  jq -e --argjson i "$i" '.[$i].default_by // empty' "$file" >/dev/null 2>&1 \
    && args+=(--silent-by "$(jq -r --argjson i "$i" '.[$i].default_by' "$file")")
  out=$("$SCRIPT_DIR/jg-question-card.sh" post --route main --ask-ref "$ticket" --raised-by "$ticket" --key "$key" \
    --must "$must" --title "$(jq -r --argjson i "$i" '.[$i].question' "$file")" --why "$why" \
    "${args[@]}" --recommend "$(jq -r --argjson i "$i" '.[$i].recommend' "$file")" \
    --recommend-reason "$(jq -r --argjson i "$i" '.[$i].recommend_reason' "$file")" \
    --default "$(jq -r --argjson i "$i" '.[$i].default // .[$i].recommend' "$file")" 2>&1) \
    || die "R${round}Q$k: the card was refused and nothing was recorded for it: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  CARD_KEY=$(printf '%s\n' "$out" | grep -x "$key" | tail -1)
  [ -n "$CARD_KEY" ] || die "R${round}Q$k: the card tool printed no card key: $out"
}

dismiss_card() {  # <key> <not-relevant|replaced>: a card that no longer asks anything must not wait on his board
  local board
  board=$(jg_question_board)
  sign-off-axi dismiss "$1" ${board:+"$board"} --reason "$2" >/dev/null 2>&1 \
    || printf 'jg-muster: the card %s stays on the board; dismiss it by hand\n' "$1" >&2
}
restore_card() {
  local board
  board=$(jg_question_board)
  sign-off-axi restore "$1" ${board:+"$board"} >/dev/null 2>&1 || printf 'jg-muster: restore the card %s by hand\n' "$1" >&2
}

make_gate() {  # <ticket> <text> <must>: sets GATE_ID, the id the backlog returned, looked up by the exact text
  local ticket=$1 text=$2 must=$3 ids n
  ids=$(backlog_cmd questions --ticket "$ticket" --json | jq -r --arg q "$text" '.[] | select(.question == $q) | .id')
  [ -z "$ids" ] || die "refused: $ticket already has an open question with exactly these words; its gate is $(printf '%s' "$ids" | head -1)"
  "$SCRIPT_DIR/jg-captain-hold.sh" hold "$ticket" --reason "$text" --until "$(horizon)" --must "$must" >/dev/null \
    || return 1
  ids=$(backlog_cmd questions --ticket "$ticket" --json | jq -r --arg q "$text" '.[] | select(.question == $q) | .id')
  n=$(printf '%s\n' "$ids" | sed '/^$/d' | wc -l)
  [ "$n" -eq 1 ] || { printf 'jg-muster: %s open questions match the new one exactly, expected one\n' "$n" >&2; return 1; }
  GATE_ID=$ids
}

close_gate() {  # <gate> <value> <label> <provenance>
  local out
  out=$(printf '%s\t%s\t%s\n' "$1" "$2" "$3" | "$SCRIPT_DIR/jg-captain-hold.sh" answers --source "$4" 2>&1) || {
    printf 'jg-muster: the gate %s was not closed: %s\n' "$1" "$(printf '%s' "$out" | tr '\n' ' ')" >&2
    return 1
  }
  printf '%s\n' "$out" | grep -qx "closed: $1" || { printf 'jg-muster: the gate %s did not report closed: %s\n' "$1" "$out" >&2; return 1; }
}

# ---- the document -------------------------------------------------------------------------------------------------
doc_path() { [ -f "$MDIR/doc" ] && cat "$MDIR/doc"; }

write_decision() {  # <doc> <qid> <date> <words> <revision>; prints the document's revision (sha12)
  local doc=$1 qid=$2 date=$3 words=$4 rev=$5 tmp
  words=$(tabsafe "$words" | tr '"' "'")
  [ -f "$doc" ] || die "the document $doc does not exist"
  grep -q '^## Decisions[[:space:]]*$' "$doc" || printf '\n## Decisions\n' >> "$doc"
  tmp=$(mktemp "$doc.XXXXXX") || die "cannot write beside $doc"
  LINE="- $date $qid: \"$words\" (revision $rev)" QID=$qid awk '
    function flush() { if (inside && !done) { print ENVIRON["LINE"]; done = 1 } }
    /^## / { flush(); inside = ($0 ~ /^## Decisions[ \t]*$/); print; next }
    inside && /^- <YYYY-MM-DD>/ { next }
    inside && index($0, "- ") == 1 {
      split($0, p, " "); if (p[3] == ENVIRON["QID"] ":" || p[3] == ENVIRON["QID"]) { if (!done) print ENVIRON["LINE"]; done = 1; next }
    }
    { print }
    END { flush() }' "$doc" > "$tmp" || { rm -f -- "$tmp"; die "cannot rewrite $doc"; }
  mv "$tmp" "$doc" || { rm -f -- "$tmp"; die "cannot rewrite $doc"; }
  sha12 "$(cat "$doc")"
}

words_of() {  # <question text> <answer value>: his words for the line: the option's label, or the free text itself
  jq -rn --arg q "$1" --arg v "$2" "$JQ_DEFS"'
    (options($q) | map(select(.v == $v)) | first | .l) // $v'
}

record_answer() {  # <row> <value> <source> <taken> <words>: append the answered row, write the document, record doc_rev
  local row=$1 value=$2 source=$3 taken=$4 words=$5 doc dr
  row=$(rowmod "$row" "8=$value" "9=$source" "10=$taken" "11=$(now)" "12=")
  append_line "$row"
  doc=$(doc_path) || { append_line "$(rowmod "$row" 12=-)"; return 0; }
  dr=$(write_decision "$doc" "$(col 3 "$row")" "$(today)" "$words" "$(col 2 "$row")") || return 1
  append_line "$(rowmod "$row" "12=$dr")"
}

# ---- round ----------------------------------------------------------------------------------------------------------
cmd_round() {
  local ticket=${1:-} file='' round='' doc='' n i k text qids=() sha qset key rows prior
  [ -n "$ticket" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --questions) shift; file=${1:-} ;;
      --round) shift; round=${1:-} ;;
      --doc) shift; doc=${1:-} ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$file" ] || usage
  use_ticket "$ticket"; check_questions "$file"; lock
  if [ -z "$round" ]; then
    round=$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $1 > m { m = $1 } END { print m + 1 }' "$RFILE" 2>/dev/null); round=${round:-1}
  fi
  case "$round" in ''|*[!0-9]*|0) die "--round must be a number of 1 or more" ;; esac
  if [ -n "$doc" ]; then
    [ -f "$doc" ] || die "refused: the document $doc does not exist"
    printf '%s\n' "$(cd "$(dirname "$doc")" && pwd)/$(basename "$doc")" > "$MDIR/doc"
  fi
  n=$(jq length "$file")
  if [ -f "$RFILE" ] && awk -F'\t' -v r="$round" '$1 == r && $2 > 1 { f = 1 } END { exit !f }' "$RFILE"; then
    die "refused: round $round was revised; show a revision with: jg-muster.sh revise $ticket $round --questions <file>"
  fi
  # The question set he sees is known before anything posts: the words of each question are its gate text.
  for ((i = 0; i < n; i++)); do
    k=$((i + 1)); text=$(gate_text "$file" "$i")
    qids+=("R${round}Q$k=$(sha12 "$text")")
  done
  qset=$(qset_of "${qids[@]}")
  for ((i = 0; i < n; i++)); do
    k=$((i + 1)); text=$(gate_text "$file" "$i"); sha=$(sha12 "$text")
    if prior=$(latest_row "R${round}Q$k"); then
      if [ "$(col 10 "$prior")" = agent ]; then
        printf 'R%sQ%s: agreed by the council, skipped\n' "$round" "$k"
        continue
      fi
      if [ -n "$(col 4 "$prior")" ] || [ -n "$(col 5 "$prior")" ]; then
        [ "$(col 7 "$prior")" = "$sha" ] || die "refused: R${round}Q$k is already shown with other words; revise the round instead"
        printf 'R%sQ%s: already shown, skipped\n' "$round" "$k"
        continue
      fi
    fi
    post_card "$ticket" "$file" "$i" "$round" "$k" 1; key=$CARD_KEY
    if ! make_gate "$ticket" "$text" "$(jq -r --argjson i "$i" '.[$i].must // "plan-approval"' "$file")"; then
      dismiss_card "$key" not-relevant; die "R${round}Q$k: the question could not be held, so its card $key was dismissed; run the same command again"
    fi
    append_row "$round" 1 "R${round}Q$k" "$GATE_ID" "$key" "$qset" "$sha" '' '' '' "$(now)" ''
    printf 'R%sQ%s -> %s (card %s, revision 1)\n' "$round" "$k" "$GATE_ID" "$key"
  done
  rows=$n
  printf 'round %s shown: %s questions, set %s; answer on a card, or in chat as R%sQ1 a; a bare reply binds only while this is the one round shown\n' "$round" "$rows" "$qset" "$round"
}

# ---- the answer loop ----------------------------------------------------------------------------------------------
# shellcheck disable=SC2016
BIND_JQ="$JQ_DEFS"'
. as {$words, $rows, $gates}
| ($rows | map(select(.qid != "-" and .gate != "" and .presented != ""))) as $rs
| ($rs | map([.round, .revision]) | unique) as $pres
| (reduce $rs[] as $r ({}; .[$r.qid] = $r)) as $latest
| (reduce $rs[] as $r ({}; .[$r.qid] = ([(.[$r.qid] // 0), ($r.revision | tonumber)] | max))) as $newest
| (reduce $rs[] as $r ({}; .[$r.round] += [($r.revision | tonumber)]) | map_values(unique)) as $revsOf
| (reduce $rs[] as $r ({}; .[$r.qid] += [$r.question_sha]) | map_values(unique)) as $shasOf
| ($rs | map(.qid + "@" + .revision) | unique) as $shown
| ([$words | scan("\\b(R(\\d+)Q\\d+):\\s*([^;]*[^;\\s])"; "i") | {qid: (.[0] | ascii_upcase), round: .[1], val: .[2]}
    | .kind = (if (.val | test("^[a-z]$"; "i")) then "letter" else "text" end)
    | if .kind == "letter" then .val |= ascii_downcase else . end]
  + [$words | scan("\\b(R(\\d+)Q\\d+)\\s+([a-z])\\b"; "i") | {qid: (.[0] | ascii_upcase), round: .[1], val: (.[2] | ascii_downcase), kind: "letter"}]
  ) as $keyed
| ([$words | capture("^\\s*R(?<r>\\d+)(?:\\.(?<v>\\d+))?\\b(?!Q)"; "i")] | first) as $named
| ($words | test("\\b(yes|recommended|ok) (to|for) (the rest|all|everything)\\b"; "i")) as $group
| ([$keyed[].round] + (if $named then [$named.r] else [] end) | unique) as $rounds
| {closes: [], notes: [], unbound: [], bound: null} as $out
| if ($rounds | length) > 1 then
    $out | .unbound = ["the reply names rounds " + ($rounds | map("R" + .) | join(", ")) + " (nothing closed)"]
  elif ($rounds | length) == 0 and ($pres | length) != 1 then
    $out | .unbound = ["\"" + $words + "\" names no round and the ticket has shown " + ($pres | length | tostring) + " presentations (nothing closed)"]
  else
    (if ($rounds | length) == 1 then $rounds[0] else $pres[0][0] end) as $rnd
    | (if $named and $named.v then ($named.v | tonumber) else null end) as $nrev
    | ($revsOf[$rnd] // []) as $revs
    | if $nrev != null and (($revs | index($nrev)) == null) then
        $out | .unbound = ["the reply names R" + $rnd + "." + ($nrev | tostring) + ", which was never shown (nothing closed)"]
      else
        (if $nrev != null then $nrev elif ($revs | length) == 1 then $revs[0] else null end) as $rev
        | def closable($qid):
            $latest[$qid] as $r | $gates[$r.gate] as $g
            | if $rev != null and (($shown | index($qid + "@" + ($rev | tostring))) == null) then {ok: false, why: ($qid + ": not in R" + $rnd + "." + ($rev | tostring))}
              elif $rev != null and $newest[$qid] > $rev then {ok: false, why: ($qid + ": stale (names revision " + ($rev | tostring) + ", the question is at " + ($newest[$qid] | tostring) + ")")}
              elif ($g.state // "") != "open" then {ok: false, why: ($qid + ": already closed; nothing changes")}
              elif $g.sha != $r.question_sha then {ok: false, why: ($qid + ": its words changed after they were shown; nothing changes"), unsure: true}
              else {ok: true} end;
          reduce $keyed[] as $k ($out | .bound = ("R" + $rnd + (if $rev != null then "." + ($rev | tostring) else "" end));
            if ($latest[$k.qid] // null) == null then .notes += [$k.qid + ": no such question"]
            elif $rev == null and ($shasOf[$k.qid] | length) > 1 then
              .notes += [$k.qid + ": revised since it was first shown and the reply names no revision; nothing closes"] | .unbound += [$k.qid]
            else
              closable($k.qid) as $c
              | if $c.ok | not then .notes += [$c.why] | (if $c.unsure then .unbound += [$k.qid] else . end)
                else
                  ($gates[$latest[$k.qid].gate].question) as $q
                  | if $k.kind == "letter" and ((options($q) | map(.v) | index($k.val)) == null) then .notes += [$k.qid + ": " + $k.val + " is not an option"]
                    else .closes += [{qid: $k.qid, gate: $latest[$k.qid].gate, value: $k.val, kind: $k.kind}] end
                end
            end)
          | if $group and $rev == null then
              .notes += ["the group part: R" + $rnd + " was shown at revisions " + ($revs | map(tostring) | join(", ")) + " and the reply names none; nothing closes"] | .unbound += ["group"]
            elif $group then
              reduce ($latest | to_entries | sort_by(.key)[] | select(.value.round == $rnd) | .key) as $qid (.;
                if ([.closes[].qid] | index($qid)) != null then .
                elif ($gates[$latest[$qid].gate].state // "") != "open" then .
                else closable($qid) as $c
                  | if $c.ok | not then .notes += [$c.why] | (if $c.unsure then .unbound += [$qid] else . end)
                    else (recommended($gates[$latest[$qid].gate].question)) as $v
                      | if $v == null then .notes += [$qid + ": no recommended option"]
                        else .closes += [{qid: $qid, gate: $latest[$qid].gate, value: $v, kind: "letter"}] end
                    end
                end)
            else . end
      end
  end';

unbound_row() {  # <note id>: the reply that bound nothing is kept with the id of the note
  append_row - - - - "$1" '' '' unbound chat owner "$(now)" ''
}

cmd_answer() {
  local ticket=${1:-} card='' value='' words='' note='' dflt=''
  [ -n "$ticket" ] || usage
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --card) shift; card=${1:-} ;;
      --value) shift; value=${1:-} ;;
      --words) shift; words=${1:-} ;;
      --note) shift; note=${1:-} ;;
      --default) shift; dflt=${1:-} ;;
      *) usage ;;
    esac
    shift
  done
  use_ticket "$ticket"; lock
  if [ -n "$card" ]; then answer_card "$ticket" "$card" "$value" "$words"
  elif [ -n "$note" ]; then answer_note "$ticket" "$note"
  elif [ -n "$dflt" ]; then answer_default "$ticket" "$dflt"
  else usage; fi
}

apply_close() {  # <ticket> <row> <value> <kind: letter|text> <source> <taken> <provenance>: close the gate, record, write
  local row=$2 value=$3 kind=$4 source=$5 taken=$6 prov=$7 gate q label words
  gate=$(col 4 "$row")
  q=$(jq -r --arg g "$gate" '.[$g].question' <<<"$GATES")
  if [ "$kind" = letter ]; then
    words=$(words_of "$q" "$value"); label="$value) $words"
  else
    value=$(tabsafe "$value"); words=$value; label=$value
  fi
  close_gate "$gate" "$value" "$label" "$prov" || return 1
  [ "$taken" != default ] || words="default: $words"
  record_answer "$row" "$value" "$source" "$taken" "$words" || return 1
  printf 'closed: %s -> %s (%s)\n' "$(col 3 "$row")" "$value" "$taken"
}

answer_card() {  # <ticket> <card key> <value> <words>
  local ticket=$1 key=$2 value=$3 words=$4 row qid newest kind val state q
  [ -f "$RFILE" ] || die "refused: $ticket has no rounds"
  row=$(awk -F'\t' -v k="$key" '$5 == k && $3 != "-" { l = $0 } END { if (l == "") exit 1; print l }' "$RFILE") \
    || die "refused: no question of $ticket was shown on the card '$key'"
  qid=$(col 3 "$row"); newest=$(latest_row "$qid")
  if [ "$(col 2 "$row")" -lt "$(col 2 "$newest")" ]; then
    printf '%s: stale (the card is revision %s, the question is at %s); nothing closes\n' "$qid" "$(col 2 "$row")" "$(col 2 "$newest")"
    return 0
  fi
  GATES=$(gates_json "$ticket")
  state=$(jq -r --arg g "$(col 4 "$newest")" '.[$g].state // "missing"' <<<"$GATES")
  q=$(jq -r --arg g "$(col 4 "$newest")" '.[$g].question // ""' <<<"$GATES")
  if [ -n "$value" ]; then kind=letter; val=$value
  elif [ -n "$words" ]; then kind=text; val=$words
  else die "answer needs --value <option letter> or --words <text>"; fi
  if [ "$kind" = letter ]; then
    jq -e -n --arg q "$q" --arg v "$val" "$JQ_DEFS"'options($q) | map(.v) | index($v) != null' >/dev/null 2>&1 \
      || die "refused: $val is not an option of $qid"
  fi
  if [ "$state" = open ]; then
    apply_close "$ticket" "$newest" "$val" "$kind" board owner "board card $key"; return $?
  fi
  late_or_repeat "$ticket" "$newest" "$val" "$kind" board "board card $key"
}

# The gate is closed. A repeat of the stored answer changes nothing; a different one is a late owner answer when a
# default (or the agent) took the gate, and refused otherwise.
late_or_repeat() {  # <ticket> <newest row> <value> <kind> <source> <provenance>
  local row=$2 val=$3 kind=$4 source=$5 qid taken stored
  qid=$(col 3 "$row"); taken=$(col 10 "$row"); stored=$(col 8 "$row")
  if [ "$taken" = default ] || [ "$taken" = agent ]; then
    revise_answer "$1" "$qid" "$val" "$kind" "$source"; return $?
  fi
  if [ "$stored" = "$(tabsafe "$val")" ]; then printf '%s: already answered %s; nothing changes\n' "$qid" "$stored"; return 0; fi
  die "refused: $qid was already answered ($stored); a different answer is a correction: jg-muster.sh revise $1 $qid --value|--words"
}

answer_default() {  # <ticket> <qid>
  local ticket=$1 qid=$2 row q v
  row=$(latest_row "$qid") || die "refused: no question $qid on $ticket"
  GATES=$(gates_json "$ticket")
  q=$(jq -r --arg g "$(col 4 "$row")" '.[$g].question // ""' <<<"$GATES")
  [ "$(jq -r --arg g "$(col 4 "$row")" '.[$g].state' <<<"$GATES")" = open ] || { printf '%s: already closed; nothing changes\n' "$qid"; return 0; }
  jq -e -n --arg q "$q" "$JQ_DEFS"'irreversible($q)' >/dev/null 2>&1 \
    && die "refused: $qid is irreversible; an irreversible question never takes a default"
  v=$(jq -rn --arg q "$q" "$JQ_DEFS"'default_of($q) // empty')
  [ -n "$v" ] || die "refused: $qid carries no default"
  apply_close "$ticket" "$row" "$v" letter default default "default for $qid"
}

answer_note() {  # <ticket> <note id>
  local ticket=$1 note=$2 words input res n i bound
  words=$(captain_ask_chat_text "$note" 2>/dev/null | tr -s '\n' ' ' | sed 's/^ *//; s/ *$//') && [ -n "$words" ] \
    || die "refused: $note is not a captain chat note"
  GATES=$(gates_json "$ticket")
  input=$(jq -n --arg w "$words" --argjson r "$(rows_json)" --argjson g "$GATES" '{words: $w, rows: $r, gates: $g}')
  res=$(jq -c "$BIND_JQ" <<<"$input") || die "internal: the binding rule failed on '$words'"
  jq -r '.notes[] | "  " + .' <<<"$res"
  if [ "$(jq '.unbound | length' <<<"$res")" -gt 0 ] && [ "$(jq '.bound' <<<"$res")" = null ]; then
    jq -r '"unbound: " + .unbound[0] + "; Main asks which one he meant"' <<<"$res"
    unbound_row "$note"; return 0
  fi
  n=$(jq '.closes | length' <<<"$res"); bound=$(jq -r '.bound' <<<"$res")
  local closed=()
  for ((i = 0; i < n; i++)); do
    local qid value kind row
    qid=$(jq -r ".closes[$i].qid" <<<"$res"); value=$(jq -r ".closes[$i].value" <<<"$res"); kind=$(jq -r ".closes[$i].kind" <<<"$res")
    row=$(latest_row "$qid")
    if apply_close "$ticket" "$row" "$value" "$kind" chat owner "chat $note" >/dev/null; then closed+=("$qid"); fi
  done
  printf 'bound to %s: closed %s\n' "$bound" "${closed[*]:-nothing}"
  if [ "$(jq '.unbound | length' <<<"$res")" -gt 0 ]; then
    printf 'unbound: part of the reply (%s) does not name one presentation; Main asks which one he meant\n' "$(jq -r '.unbound | join(", ")' <<<"$res")"
    unbound_row "$note"
  fi
  return 0
}

# ---- revise -------------------------------------------------------------------------------------------------------
latest_of_round() {  # <round>: the newest row of each question of the round, in question order
  awk -F'\t' -v r="$1" '$1 == r && $3 != "-" { l[$3] = $0; if (!($3 in o)) { o[$3] = ++n } } END { for (q in l) print o[q] "\t" l[q] }' "$RFILE" \
    | sort -n | cut -f2-
}

revise_answer() {  # <ticket> <qid> <value> <kind> <source>: the owner's late or changed answer, as the next revision
  local ticket=$1 qid=$2 val=$3 kind=$4 source=$5 row round rev q words
  row=$(latest_row "$qid") || die "refused: no question $qid on $ticket"
  round=$(col 1 "$row"); rev=$(( $(col 2 "$row") + 1 ))
  GATES=$(gates_json "$ticket")
  q=$(jq -r --arg g "$(col 4 "$row")" '.[$g].question // ""' <<<"$GATES")
  [ "$(jq -r --arg g "$(col 4 "$row")" '.[$g].state' <<<"$GATES")" != open ] \
    || die "refused: $qid is still open; answer it with: jg-muster.sh answer $ticket"
  if [ "$kind" = letter ]; then words=$(words_of "$q" "$val"); else val=$(tabsafe "$val"); words=$val; fi
  carry_round "$round" "$rev" "$qid" "$val" "$source" owner "$words"
  printf '%s: revision %s, taken=owner; the gate keeps its first answer, the record and the document carry this one\n' "$qid" "$rev"
}

carry_round() {  # <round> <new revision> <override qid> <value> <source> <taken> <words>: every question again at the revision
  local round=$1 rev=$2 oq=$3 val=$4 source=$5 taken=$6 words=$7 qids=() line qset doc dr
  while IFS= read -r line; do qids+=("$(col 3 "$line")=$(col 7 "$line")"); done < <(latest_of_round "$round")
  qset=$(qset_of "${qids[@]}")
  while IFS= read -r line; do
    line=$(rowmod "$line" "2=$rev" "6=$qset")
    if [ "$(col 3 "$line")" = "$oq" ]; then
      line=$(rowmod "$line" "8=$val" "9=$source" "10=$taken" "11=$(now)" "12=")
      append_line "$line"
      doc=$(doc_path) || { append_line "$(rowmod "$line" 12=-)"; continue; }
      dr=$(write_decision "$doc" "$oq" "$(today)" "$words" "$rev") \
        || die "the answer is recorded but the document was not written; run: jg-muster.sh repair ${TICKET:-<ticket>}"
      append_line "$(rowmod "$line" "12=$dr")"
    else
      append_line "$line"
    fi
  done < <(latest_of_round "$round")
}

cmd_revise() {
  local ticket=${1:-} target=${2:-} file='' value='' words='' source=chat
  [ -n "$ticket" ] && [ -n "$target" ] || usage
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --questions) shift; file=${1:-} ;;
      --value) shift; value=${1:-} ;;
      --words) shift; words=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage ;;
    esac
    shift
  done
  use_ticket "$ticket"; lock
  case "$source" in board|chat) ;; *) die "--source is board or chat" ;; esac
  case "$target" in
    R[0-9]*Q[0-9]*)
      if [ -n "$value" ]; then revise_answer "$ticket" "$target" "$value" letter "$source"
      elif [ -n "$words" ]; then revise_answer "$ticket" "$target" "$words" text "$source"
      else usage; fi ;;
    [0-9]*) [ -n "$file" ] || usage; revise_round "$ticket" "$target" "$file" ;;
    *) die "revise names a round number or a question id such as R1Q2, not '$target'" ;;
  esac
}

revise_round() {  # <ticket> <round> <file>
  local ticket=$1 round=$2 file=$3 n i k text sha old rev qids=() qset key oldgate oldkey carried=() c cur
  check_questions "$file"
  cur=$( { [ -f "$RFILE" ] && latest_of_round "$round"; } ) && [ -n "$cur" ] || die "refused: round $round was never shown on $ticket"
  n=$(jq length "$file")
  [ "$(printf '%s\n' "$cur" | wc -l)" -eq "$n" ] || die "refused: round $round has $(printf '%s\n' "$cur" | wc -l) questions and the file has $n; a revision keeps the questions, a new question belongs to the next round"
  rev=$(( $(printf '%s\n' "$cur" | cut -f2 | sort -n | tail -1) + 1 ))
  for ((i = 0; i < n; i++)); do
    k=$((i + 1)); text=$(gate_text "$file" "$i")
    qids+=("R${round}Q$k=$(sha12 "$text")")
  done
  qset=$(qset_of "${qids[@]}")
  GATES=$(gates_json "$ticket")
  for ((i = 0; i < n; i++)); do
    k=$((i + 1)); text=$(gate_text "$file" "$i"); sha=$(sha12 "$text")
    old=$(latest_row "R${round}Q$k"); oldgate=$(col 4 "$old"); oldkey=$(col 5 "$old")
    if [ "$(col 7 "$old")" = "$sha" ]; then
      carried+=("$(rowmod "$old" "2=$rev" "6=$qset")")
      continue
    fi
    # The board refuses a card that repeats an open one, so the old card leaves first and comes back if the new one fails.
    oldopen=$(jq -r --arg g "$oldgate" '.[$g].state' <<<"$GATES")
    [ "$oldopen" != open ] || dismiss_card "$oldkey" replaced
    if ! { post_card "$ticket" "$file" "$i" "$round" "$k" "$rev" && key=$CARD_KEY \
      && make_gate "$ticket" "$text" "$(jq -r --argjson i "$i" '.[$i].must // "plan-approval"' "$file")"; }; then
      [ -z "${key:-}" ] || dismiss_card "$key" not-relevant
      [ "$oldopen" != open ] || restore_card "$oldkey"
      die "R${round}Q$k: the revised question was not shown, so nothing of round $round changed from here on; run the same command again"
    fi
    [ "$oldopen" != open ] || close_gate "$oldgate" superseded "superseded by R$round.$rev" "muster revise R$round.$rev" || true
    carried+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t\t%s\t' "$round" "$rev" "R${round}Q$k" "$GATE_ID" "$key" "$qset" "$sha" "$(now)")")
  done
  for c in "${carried[@]}"; do append_line "$c"; done
  printf 'round %s shown again as revision %s: reply to a card, or start with R%s.%s\n' "$round" "$rev" "$round" "$rev"
}

# ---- status and repair --------------------------------------------------------------------------------------------
status_json() {  # <ticket>
  local gates rows
  gates=$(gates_json "$1"); rows=$(rows_json)
  jq -n --argjson g "$gates" --argjson r "$rows" "$JQ_DEFS"'
    def gate_of($x):
      if $x.taken == "agent" then {state: "closed", question: ""}
      elif $x.gate == "" then {state: "draft", question: ""}
      else $g[$x.gate] // {state: "missing", question: ""} end;
    ($r | map(select(.qid != "-"))) as $rs
    | (reduce $rs[] as $x ({}; .[$x.qid] = $x)) as $latest
    | {rounds: ($latest | to_entries | map(.value) | group_by(.round) | map(
        {round: .[0].round, revision: (map(.revision | tonumber) | max),
         questions: (sort_by(.qid) | map(. as $x | gate_of($x) as $gt
           | {qid: $x.qid, gate: $x.gate, revision: ($x.revision | tonumber), state: $gt.state, answer: $x.answer, taken: $x.taken,
              required: (optional($gt.question) | not), doc_written: ($x.doc_rev != "" or $x.answer == "" or $x.taken == "agent")})),
         complete: (all(.[]; gate_of(.) as $gt | ($gt.state | IN("open", "draft") | not) or optional($gt.question)))})),
       owing_document: [$latest[] | select($g[.gate].state == "closed" and .doc_rev == "")| .qid],
       unbound: [$r[] | select(.answer == "unbound") | .presented]}'
}

cmd_status() {
  local ticket=${1:-} json=0
  [ -n "$ticket" ] || usage
  shift
  [ "${1:-}" != --json ] || json=1
  use_ticket "$ticket"
  if [ "$json" = 1 ]; then status_json "$ticket"; return 0; fi
  status_json "$ticket" | jq -r '
    (.rounds[] | "round " + .round + " (revision " + (.revision | tostring) + "): " + (if .complete then "complete" else "open" end),
      (.questions[] | "  " + .qid + " -> " + .gate + " " + .state + (if .answer != "" then " answer=" + .answer + " taken=" + .taken else "" end)
        + (if .required then "" else " (optional)" end))),
    (if (.owing_document | length) > 0 then "owing a document line: " + (.owing_document | join(", ")) + " (jg-muster.sh repair)" else empty end),
    (if (.unbound | length) > 0 then "unbound replies: " + (.unbound | join(", ")) else empty end)'
}

cmd_repair() {  # <ticket>: redo a row whose gate is closed and whose document line was never written
  local ticket=${1:-} row qid state doc words q answer fixed=0 dr
  [ -n "$ticket" ] || usage
  use_ticket "$ticket"; lock; TICKET=$ticket
  [ -f "$RFILE" ] || { printf 'nothing to repair\n'; return 0; }
  GATES=$(gates_json "$ticket")
  while read -r qid; do
    row=$(latest_row "$qid")
    state=$(jq -r --arg g "$(col 4 "$row")" '.[$g].state // "missing"' <<<"$GATES")
    [ "$state" = closed ] || continue
    q=$(jq -r --arg g "$(col 4 "$row")" '.[$g].question' <<<"$GATES")
    answer=$(col 8 "$row")
    if [ -z "$answer" ]; then  # the gate closed but the row never saw it: take the answer the gate holds
      answer=$(jq -r --arg g "$(col 4 "$row")" '.[$g].words | split("\n") | map(select(startswith("Answer: "))) | (first // "") | sub("^Answer: "; "")' <<<"$GATES")
      { [ -n "$answer" ] && [ "$answer" != superseded ]; } || continue
      row=$(rowmod "$row" "8=$answer" 9=board 10=owner "11=$(now)" 12=)
      append_line "$row"
    fi
    [ -z "$(col 12 "$row")" ] || continue
    if [ -f "$MDIR/doc" ]; then
      words=$(words_of "$q" "$answer"); [ "$(col 10 "$row")" != default ] || words="default: $words"
      dr=$(write_decision "$(doc_path)" "$qid" "$(today)" "$words" "$(col 2 "$row")") || die "cannot write the document"
    else
      dr=-
    fi
    append_line "$(rowmod "$row" "12=$dr")"; fixed=$((fixed + 1)); printf 'repaired: %s\n' "$qid"
  done < <(awk -F'\t' '$3 != "-" { print $3 }' "$RFILE" | sort -u)
  printf 'repaired %s row(s)\n' "$fixed"
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  round) cmd_round "$@" ;;
  answer) cmd_answer "$@" ;;
  revise) cmd_revise "$@" ;;
  round-status) cmd_status "$@" ;;
  repair) cmd_repair "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
