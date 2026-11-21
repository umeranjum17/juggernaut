#!/usr/bin/env bash
# jg-answer-route.sh - the one owner of "an answered card's options become work".
#
# Usage:
#   jg-answer-route.sh route <card-key> [--answer <text>] [--at <epoch>] [--dry-run]
#   jg-answer-route.sh show <card-key>
#
# The owner's answer starts no work by itself: the starter (core/auto-dispatch/dispatch.sh)
# needs an approval record and a brief, and nothing used to write either from an answer.
# This command does that, from records that exist at answer time and with no model turn.
#
# route   Read the card (sign-off-axi `list --json`), the option the answer selected, and
#        each selected option's end, then take that end once. It prints one line per end
#        it took and nothing for an answer it already took, so a repeat is a quiet
#        duplicate. `bin/jg-board-answers.sh check` calls it for every answer it reads,
#        which is what makes an answer start work at answer time.
#        --answer and --at come from that caller (its own read of `answers --json`); with
#        neither, route reads the recorded answer itself.
#        --dry-run takes no end and writes nothing; it prints the end each option would get.
#        Exit 0 with every option at an end, 1 on a card or board it cannot read, 2 on
#        usage, 3 when the card's answer selected no option (that is one end too: the
#        answer is reported to the lead, never guessed at).
# show    Print the card's route rows: <answer epoch>\t<option value>\t<end>\t<detail>.
#
# The options are the card's own (sign-off-axi's `options`, each with value, label and
# outcome), so no prose in a ticket body is parsed and no option text is invented.
#
# The end of one option, first rule that fits, is stated here in full and nowhere else:
#   1. no-op          the option's text begins "no", "keep", "leave" or "stay" and holds no
#                     " and " clause: the answer is the status quo, recorded and not routed.
#   2. dated deferral the option's text names a date or a period ("for one week", "until
#                     22 Nov", "for 3 days") and a later decision: one owner ticket filed
#                     and held to that date (bin/jg-captain-hold.sh hold --until), so it is
#                     a work item the lead sees instead of a lost instruction.
#   3. conditional    the option's text says "until <something>" that names no date: a
#     deferral         supervisor step naming the condition, because a condition needs an
#                     owner and a router may not invent one.
#   4. destructive    the option's text discards, forces, deletes or loses work: a supervisor
#                     step carrying the owner's quoted answer, whatever the card's executor
#                     field says, so no irreversible step starts without a supervisor turn.
#   5. supervisor     the card carries no `executor <value>=` field for the option, or it says
#                     supervisor: a supervisor step. A missing field means supervisor, never
#                     worker, so today's cards (which carry none) start nothing by themselves.
#   6. worker         the card says `executor <value>=worker`: file one ticket from the option,
#                     write its brief, and approve it for the dispatch check on this home's
#                     ordinary implementation-plan route. The ticket's title, body and brief
#                     come from the option's own text, the answer line, the source report and
#                     the parent call; a title that cannot be read as plain words is a
#                     supervisor step, never an invented title.
# A supervisor step is one line in this command's output, folded by the caller into the wake
# the lead reads, plus its route row: durable and acted on, with no new alert table entry.
#
# Where the end's records live:
#   the approval record  state/dispatch-approved/<ticket>, written by jg-backlog.sh approve-dispatch
#                        on the route config/crew-dispatch.json gives an approved ordinary plan.
#   the brief            data/<ticket>/brief.md, the scaffold bin/jg-brief.sh writes, whose Task
#                        sections carry the option's text, the answer line, the source report
#                        and the parent call.
#   the route rows       data/answer-route/<card-key>.tsv, one line per option end (value `-`,
#                        end `no-options` for a card that offers none), which is what makes a
#                        repeat a duplicate; the card's answer epoch is the first column, so a
#                        second answer to the same card routes again.
# Nothing here posts a card, answers a question, merges, lands, pushes or starts a worker:
# the dispatch check starts what this command approves.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-record-lib.sh
. "$SCRIPT_DIR/jg-board-record-lib.sh"

ROUTES=$DATA/answer-route
BACKLOG=$SCRIPT_DIR/jg-backlog.sh
BRIEF=$SCRIPT_DIR/jg-brief.sh
PROJECT_MODE=$SCRIPT_DIR/jg-project-mode.sh
HOLD=$SCRIPT_DIR/jg-captain-hold.sh

die() { printf 'jg-answer-route: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}

# --- the card, its options and its executor fields ---------------------------

# The board file this home reads, or nothing when the machine has no board.
board_file() {
  local board
  board=$(jg_question_board)
  [ -n "$board" ] || die "this home reads no board (set SIGN_OFF_HOME, or install the board), so an answer cannot be routed"
  printf '%s\n' "$board"
}

# The card's own record from sign-off-axi's list, as JSON, or empty when the board has no
# such card. The board is read through sign-off-axi, never from a private copy of it.
card_json() {  # <card-key> <board>
  local json
  jg_question_signoff_available || die "sign-off-axi is not on PATH, so the board cannot be read"
  json=$(sign-off-axi list "$2" --json 2>/dev/null) || die "the board could not be read: sign-off-axi list failed"
  printf '%s\n' "$json" | jq -c --arg k "$1" '(.decisions // [])[] | select(.key == $k)' 2>/dev/null | head -n 1
}

# The card's detail field: the listed one, else the last one recorded beside the board, so a
# rebuild that drops the field does not drop an executor the card was posted with.
detail_of() {  # <card-json> <card-key> <board>
  local detail
  detail=$(printf '%s' "$1" | jq -r '.detail // empty' 2>/dev/null | head -n 1)
  [ -n "$detail" ] || detail=$(jg_board_detail_of "$3" "$2")
  printf '%s\n' "$detail"
}

# The executor the card names for one option: worker, supervisor, or nothing when the card
# carries no field for it (which means supervisor).
executor_of() {  # <detail> <option-value>
  printf '%s\n' "$1" | awk -v want="$2" '{
    for (i = 1; i < NF; i++) {
      if ($i != "executor") continue
      split($(i + 1), a, "=")
      if (a[1] == want && (a[2] == "worker" || a[2] == "supervisor")) { print a[2]; exit }
    }
  }'
}

# The answer: the caller's own read, else this home's record of it. One line, empty when the
# card has no answer yet.
recorded_answer() {  # <card-key> <board>
  jg_question_signoff_available || return 0
  sign-off-axi answers "$2" --json 2>/dev/null \
    | jq -r --arg k "$1" '.[$k] // empty | [.answer // "", (.at // "" | tostring)] | join("\u001f")' 2>/dev/null | head -n 1
}

# The option the owner's answer selected: one value per line, none when nothing matched.
# First rule that fits, stated in the header: a value or label the answer names as a whole
# word; else, for an affirmative answer, the card's recommended option; else the card's
# yes option; else nothing.
selected_values() {  # <card-json> <answer-text>
  local card=$1 answer=$2 values matched
  matched=$(printf '%s' "$card" | jq -r --arg a "$answer" '
    def words: [$a | ascii_downcase | scan("[a-z0-9]+")];
    (.options // []) as $o
    | ($o | map(select((.value // "") as $v | words | index($v))))
    | if length > 0 then .[].value else empty end' 2>/dev/null)
  if [ -n "$matched" ]; then printf '%s\n' "$matched"; return 0; fi
  printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' \
    | grep -Eq '(^|[^a-z])(yes|y|ok|okay|approve|approved|agree|go|proceed|do it|do all|do these|do that|ship it|per recommendation|per the recommendation)([^a-z]|$)' \
    || return 0
  printf '%s' "$card" | jq -r '
    (.options // []) as $o
    | ((.recommend_value // empty) | select(. != "")) as $r
    | ($o | map(select(.value == $r))) as $rec
    | if ($rec | length) > 0 then $rec[].value
      else ($o | map(select(.value == "yes" or .value == "y"))) as $y
        | if ($y | length) > 0 then $y[].value
          elif ($o | length) == 1 then $o[].value else empty end end' 2>/dev/null
}

# One option's end by the header's first-rule-that-fits table, or its worker step.
end_of() {  # <option-json> <detail>
  local text kind
  text=$(printf '%s' "$1" | jq -r '(.outcome // .label // "") | ascii_downcase')
  kind=$(kind_of "$text")
  case "$kind" in
    no-op|dated|conditional) printf '%s\n' "$kind"; return 0 ;;
  esac
  case "$text" in
    *discard*|*force*|*delete*|*lose*|*losing*|*drop*) printf 'supervisor\n'; return 0 ;;
  esac
  case "$(executor_of "$2" "$(printf '%s' "$1" | jq -r '.value')")" in
    worker) printf 'worker\n' ;;
    *) printf 'supervisor\n' ;;
  esac
}

# The option's kind from its own text: no-op, dated deferral, conditional deferral, or an act.
kind_of() {  # <lowercased option text>
  local text=$1 has_until=0 has_date=0 has_period=0 has_decide=0
  case "$text" in *until*) has_until=1 ;; esac
  case "$text" in
    *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*|*today*|*tomorrow*|*"next week"*|*"next month"*) has_date=1 ;;
  esac
  case "$text" in
    *"for one week"*|*"for 1 week"*|*"for a week"*|*"for two weeks"*|*"for 2 weeks"*|*"for one month"*|*"for 1 month"*|*"for a month"*|*"for three days"*|*"for 3 days"*|*"for two days"*|*"for 2 days"*|*"for 7 days"*|*"for 24 hours"*)
      has_period=1 ;;
  esac
  case "$text" in
    *"then decide"*|*"then re-decide"*|*"then revisit"*|*"decide from"*|*re-decide*|*revisit*) has_decide=1 ;;
  esac
  if [ "$has_period" = 1 ] || { [ "$has_date" = 1 ] && [ "$has_decide" = 1 ]; }; then
    printf 'dated\n'; return 0
  fi
  if [ "$has_until" = 1 ]; then printf 'conditional\n'; return 0; fi
  case "$text" in
    no\ *|no,\ *|keep\ *|leave\ *|stay\ *)
      case "$text" in *" and "*) ;; *) printf 'no-op\n'; return 0 ;; esac ;;
  esac
  printf 'act\n'
}

# --- the ends ---------------------------------------------------------------

# One row per option end. The ledger's first column is the answer epoch, so a repeat of the
# same answer finds its rows and writes none.
row_of() {  # <card-key> <at> <value> <end>
  [ -f "$ROUTES/$1.tsv" ] || return 1
  awk -F'\t' -v at="$2" -v v="$3" -v e="$4" '$1 == at && $2 == v && $3 == e { found = 1 } END { exit found ? 0 : 1 }' \
    "$ROUTES/$1.tsv" 2>/dev/null
}

answer_routed() {  # <card-key> <at>: 0 when the ledger already holds a row for this answer
  [ -f "$ROUTES/$1.tsv" ] || return 1
  awk -F'\t' -v at="$2" '$1 == at { found = 1 } END { exit found ? 0 : 1 }' "$ROUTES/$1.tsv" 2>/dev/null
}

put_row() {  # <card-key> <at> <value> <end> <detail>
  mkdir -p "$ROUTES" || die "cannot create $ROUTES"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$ROUTES/$1.tsv" \
    || die "cannot write the route row for $1"
}

# A supervisor step: one line the caller folds into the lead's wake. It names the card, the
# option, the cause and the owner's quoted words, and nothing here acts on the captain.
supervisor_step() {  # <card-key> <value> <cause> <option-text> <answer>
  printf 'supervisor %s [%s]: %s; option "%s"; answer "%s"\n' "$1" "$2" "$3" "$4" "$5"
}

# The plain words of a title a backlog row accepts (bin/jg-backlog-lib.sh owns the rule): the
# option's own words, without a url, path, tag, id or plan code, 2 to 7 words and 48
# characters. Empty when the option's text gives no readable title.
title_of() {  # <option text>
  # shellcheck disable=SC2016  # the backticks are the markdown the option's own text carries, not a substitution
  printf '%s' "$1" | sed -e 's/`[^`]*`//g' -e 's/\[[^]]*\]//g' -e 's/[()]//g' \
    | tr '\n\t' '  ' | tr -s ' ' | tr ' ' '\n' \
    | grep -vE '^$|://|/|[0-9a-f]{8,}|^(jg|fm|Main[0-9])|^[a-z]+-[a-z0-9]+$' \
    | grep -vE '^[A-Z][a-z]*[0-9]+' \
    | head -n 6 | tr '\n' ' ' | sed -E 's/^ +//; s/ +$//' \
    | cut -c1-48 | sed -E 's/ +$//'
}

# The date a dated deferral names, as YYYY-MM-DD: the date in the text, else the answer plus the
# period it names (a week, a month, or its days), so a repeat never moves the date forward.
deferral_date() {  # <lowercased option text> <answer epoch>
  local text=$1 at=$2 date
  # A date the option names wins; a period counts from the answer, never from this run.
  date=$(printf '%s\n' "$text" | grep -oE '20[0-9][0-9]-[01][0-9]-[0-3][0-9]' | head -n 1)
  if [ -n "$date" ]; then printf '%s\n' "$date"; return 0; fi
  plus() {  # <seconds after the answer>
    date -u -d "@$((at + $1))" +%F 2>/dev/null || date -u -r "$((at + $1))" +%F
  }
  case "$text" in
    *"for one week"*|*"for 1 week"*|*"for a week"*|*"for 7 days"*|*"next week"*) plus 604800; return 0 ;;
    *"for two weeks"*|*"for 2 weeks"*) plus 1209600; return 0 ;;
    *"for one month"*|*"for 1 month"*|*"for a month"*|*"next month"*|*"for 30 days"*) plus 2592000; return 0 ;;
    *"for three days"*|*"for 3 days"*) plus 259200; return 0 ;;
    *"for two days"*|*"for 2 days"*) plus 172800; return 0 ;;
    *tomorrow*) plus 86400; return 0 ;;
    *today*) plus 0; return 0 ;;
  esac
  return 1
}

# The ticket body a filed option carries: the owner's answer, the option's own text, its
# source and its parent call, in the sections a backlog row is read by.
write_body() {  # <file> <call> <card-key> <value> <option-text> <answer> <at> <source>
  {
    printf 'Captain: %s\n\n' "$5"
    printf 'Ask: %s\n\n' "$6"
    printf 'Why: the owner answered %s at %s on card %s; the option'"'"'s own text is the requirement.\n\n' \
      "$(date -u -d "@$7" +%Y-%m-%d 2>/dev/null || date -u -r "$7" +%Y-%m-%d)" "$(date -u -d "@$7" +%H:%M 2>/dev/null || date -u -r "$7" +%H:%M)" "$3"
    printf 'Done when: %s\n\n' "$5"
    printf 'Acceptance Criteria: the work the option names is delivered, and its text above is the requirement.\n\n'
    printf 'Sources: %s\n' "${8:-the answer on card $3}"
    printf 'Answers: %s (option %s)\n' "$3" "$4"
    [ -z "$2" ] || [ "$2" = "$3" ] || printf 'parent: %s\n' "$2"
  } > "$1"
}

# The brief's own two Task sections: what the owner asked for, and what to build.
write_task_sections() {  # <task-file> <spec-file> <option-text> <answer> <at> <source> <call> <card-key>
  {
    printf '%s\n\n' "$3"
    printf 'The owner answered "%s" at %s on card %s.\n' "$4" "$(date -u -d "@$5" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$5" +%Y-%m-%dT%H:%M:%SZ)" "$8"
    [ -z "$6" ] || printf 'Source report: %s\n' "$6"
    [ -z "$7" ] || [ "$7" = "$8" ] || printf 'Parent call: %s\n' "$7"
  } > "$1"
  {
    printf 'Build exactly the option the owner answered, and nothing else: its text is the requirement.\n'
    printf 'Read the source report named above, and the parent call when one is named.\n'
    printf 'Do not widen the scope: a new idea or a discovered gap is a follow-up in your report, not this change.\n'
  } > "$2"
}

# Fill the scaffold's placeholders, keeping every other line of the brief as jg-brief.sh wrote it.
fill_brief() {  # <brief> <task-file> <spec-file>
  awk -v tf="$2" -v sf="$3" '
    function slurp(p,   s, l) { s = ""; while ((getline l < p) > 0) s = s l "\n"; close(p); return s }
    $0 == "{TASK}" { printf "%s", slurp(tf); next }
    $0 == "{JUGGERNAUT_SPEC}" { printf "%s", slurp(sf); next }
    { print }
  ' "$1" > "$1.answer-route.tmp" && mv -f -- "$1.answer-route.tmp" "$1"
}

# This home's route for an approved ordinary implementation plan: the rule config/crew-
# dispatch.json states, else the config's default, else the one route the fleet reads.
route_of_home() {  # -> "<harness> <model> <effort>", or nothing when the config names none
  local file=$CONFIG/crew-dispatch.json rule
  [ -f "$file" ] || return 0
  rule=$(jq -c '
    ((.rules // []) | map(select((.when // "") | test("approved ordinary implementation plan"; "i")))) as $r
    | if ($r | length) > 0 then $r[0].use else (.default // {}) end' "$file" 2>/dev/null)
  [ -n "$rule" ] || return 0
  printf '%s' "$rule" | jq -r '[.harness // empty, .model // empty, (.effort // "medium")] | join(" ")' 2>/dev/null
}

# The project an option's ticket belongs to: the call ticket's own registry line, else the
# only project this home has. Empty means the router cannot tell, which is a supervisor step.
project_of() {  # <call>
  local repo
  if [ -n "$1" ] && [ -x "$BACKLOG" ]; then
    repo=$(JG_HOME="$JG_HOME" "$BACKLOG" show "$1" 2>/dev/null | sed -n 's/^  repo: //p' | head -n 1)
    case "$repo" in ''|-) ;; *) printf '%s\n' "$repo"; return 0 ;; esac
  fi
}

# Take a worker's end: file the ticket, write its brief, approve it for the dispatch check.
# Prints the command's own line and sets START_DETAIL; every step's refusal is the end's cause,
# never a silent start.
start_worker() {  # <card-key> <value> <option-text> <answer> <at> <source> <call>
  local key=$1 value=$2 text=$3 answer=$4 at=$5 source=$6 call=$7
  local project id title body task spec mode route harness model effort out rc=0
  START_DETAIL=''
  project=$(project_of "$call")
  [ -n "$project" ] || { START_DETAIL="no project to file it against"; return 1; }
  title=$(title_of "$text")
  [ -n "$title" ] || { START_DETAIL="the option's text gives no readable ticket title"; return 1; }
  mode=$("$PROJECT_MODE" "$project" 2>/dev/null | awk '{ print $1 }')
  [ -n "$mode" ] || { START_DETAIL="the project's registered delivery mode could not be read"; return 1; }
  route=$(route_of_home)
  [ -n "$route" ] || { START_DETAIL="this home's dispatch config names no route"; return 1; }
  read -r harness model effort <<< "$route"
  id=$(printf '%s-%s' "$key" "$value" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed -E 's/-+/-/g; s/-+$//' | cut -c1-40)
  body=$(mktemp "${TMPDIR:-/tmp}/jg-answer-route-body.XXXXXX") || { START_DETAIL="cannot stage the ticket body"; return 1; }
  task=$(mktemp "${TMPDIR:-/tmp}/jg-answer-route-task.XXXXXX") \
    || { rm -f -- "$body"; START_DETAIL="cannot stage the brief's task section"; return 1; }
  spec=$(mktemp "${TMPDIR:-/tmp}/jg-answer-route-spec.XXXXXX") \
    || { rm -f -- "$body" "$task"; START_DETAIL="cannot stage the brief's spec section"; return 1; }
  write_body "$body" "$call" "$key" "$value" "$text" "$answer" "$at" "$source"
  if ! out=$(JG_HOME="$JG_HOME" "$BACKLOG" add "$id" "$title" --kind ship --repo "$project" --priority 2 \
    --body-file "$body" 2>&1); then
    START_DETAIL="the ticket was refused: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    rc=1
  elif ! out=$(JG_HOME="$JG_HOME" "$BRIEF" "$id" "$project" --mode "$mode" --ticket "$id" 2>&1); then
    START_DETAIL="the brief was not written: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    rc=1
  elif [ ! -s "$DATA/$id/brief.md" ]; then
    START_DETAIL="the brief was not written at data/$id/brief.md"
    rc=1
  else
    write_task_sections "$task" "$spec" "$text" "$answer" "$at" "$source" "$call" "$key"
    if ! fill_brief "$DATA/$id/brief.md" "$task" "$spec"; then
      START_DETAIL="the brief's Task sections were not filled"
      rc=1
    elif ! out=$(JG_HOME="$JG_HOME" "$BACKLOG" approve-dispatch "$id" --harness "$harness" \
      --model "$model" --effort "$effort" 2>&1); then
      START_DETAIL="the start was not approved: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
      rc=1
    else
      START_DETAIL="$id on $harness $model $effort"
      printf 'start %s [%s]: ticket %s, brief data/%s/brief.md, approved %s %s %s\n' \
        "$key" "$value" "$id" "$id" "$harness" "$model" "$effort"
    fi
  fi
  rm -f -- "$body" "$task" "$spec"
  return "$rc"
}

# A dated deferral's one owner ticket, held to its date: the answer is a work item the lead
# sees, not a lost instruction, and a dated hold posts no card beside it.
defer_to() {  # <key> <value> <text> <answer> <at> <source> <call> <date>
  local key=$1 value=$2 text=$3 answer=$4 at=$5 source=$6 call=$7 until=$8
  local project id title body out rc=0
  START_DETAIL=''
  case "$until" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) START_DETAIL="the option names a deferral but no date it defers to"; return 1 ;;
  esac
  title=$(title_of "$text")
  [ -n "$title" ] || { START_DETAIL="the option's text gives no readable ticket title"; return 1; }
  project=$(project_of "$call")
  id=$(printf '%s-%s-defer' "$key" "$value" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed -E 's/-+/-/g; s/-+$//' | cut -c1-40)
  body=$(mktemp "${TMPDIR:-/tmp}/jg-answer-route-defer.XXXXXX") || { START_DETAIL="cannot stage the ticket body"; return 1; }
  write_body "$body" "$call" "$key" "$value" "$text" "$answer" "$at" "$source"
  if ! out=$(JG_HOME="$JG_HOME" "$BACKLOG" add "$id" "$title" ${project:+--repo "$project"} --priority 2 \
    --body-file "$body" 2>&1); then
    START_DETAIL="the owner ticket was refused: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    rc=1
  elif ! out=$(JG_HOME="$JG_HOME" "$HOLD" hold "$id" --reason "the owner deferred this to $until: $text" \
    --until "$until" 2>&1); then
    START_DETAIL="the ticket $id was filed but not held to $until: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"
    rc=1
  else
    START_DETAIL="$id held to $until"
    printf 'owner-ticket %s [%s]: %s held to %s\n' "$key" "$value" "$id" "$until"
  fi
  rm -f -- "$body"
  return "$rc"
}

# --- the command ------------------------------------------------------------

cmd_route() {
  local key=${1:-} answer='' at='' dry=0 board card detail call source i
  [ "$#" -ge 1 ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --answer) shift; answer=${1:-} ;;
      --at) shift; at=${1:-} ;;
      --dry-run) dry=1 ;;
      *) usage ;;
    esac
    shift
  done
  case "$key" in ''|*[!A-Za-z0-9._-]*) die "route needs a card key (letters, digits and . _ - only)" 2 ;; esac
  # The answer time may arrive as the board records it (an ISO timestamp) or as epoch seconds;
  # one normalizer, so the ledger's first column is always an epoch.
  at_epoch() {  # <value>
    case "$1" in
      ''|*[!0-9]*) date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null ;;
      *) printf '%s\n' "$1" ;;
    esac
  }
  if [ -n "$at" ]; then
    at=$(at_epoch "$at") || at=''
    [ -n "$at" ] || die "--at takes the answer's epoch seconds or its ISO timestamp" 2
    # Cheap first: an answer this card already routed costs no board read.
    [ "$dry" -eq 0 ] && answer_routed "$key" "$at" && return 0
  fi
  board=$(board_file)
  card=$(card_json "$key" "$board")
  # The answer route is the answer-time check's quiet step: a card this board no longer lists
  # (archived, dismissed, another home's) and a card with no options (a report or plan card) have
  # no option to route, so they are quiet, never a wake. A person asking by hand sees why.
  # A card with no options keeps one `-\tno-options` row for the answer, so the check's next pass
  # stops at the ledger instead of reading the whole board again for it.
  if [ -z "$card" ]; then
    [ "$dry" -eq 0 ] || die "no card $key on this home's board"
    return 0
  fi
  if [ "$(printf '%s' "$card" | jq -r '(.options // []) | length' 2>/dev/null)" = 0 ]; then
    [ "$dry" -eq 0 ] || { printf 'no options on %s\n' "$key"; return 0; }
    [ -z "$at" ] || put_row "$key" "$at" - no-options "the card offers no options"
    return 0
  fi
  if [ -z "$answer" ]; then
    local rec
    rec=$(recorded_answer "$key" "$board")
    [ -n "$rec" ] || die "card $key has no answer to route" 3
    answer=${rec%%$'\037'*}
    [ -n "$at" ] || at=${rec#*$'\037'}
  fi
  [ -n "$at" ] || at=$(date +%s)
  at=$(at_epoch "$at") || at=''
  [ -n "$at" ] || die "the card's answer time could not be read" 3
  [ -n "$answer" ] || die "card $key has an empty answer; there is nothing to route" 3
  [ "$dry" -eq 0 ] && answer_routed "$key" "$at" && return 0
  detail=$(detail_of "$card" "$key" "$board")
  call=$(printf '%s' "$card" | jq -r '.ask_ref // .ticket // empty' 2>/dev/null | head -n 1)
  source=$(printf '%s' "$card" | jq -r '.report // empty' 2>/dev/null | head -n 1)
  [ -n "$source" ] || source=''
  local -a values=()
  while IFS= read -r i; do [ -n "$i" ] && values+=("$i"); done < <(selected_values "$card" "$answer")
  if [ "${#values[@]}" -eq 0 ]; then
    printf 'supervisor %s: the answer "%s" names no option of this card; the lead reads it\n' "$key" "$answer"
    [ "$dry" -eq 1 ] || put_row "$key" "$at" - unreadable "the answer names no option"
    return 3
  fi
  local value opt text end until rc=0
  for value in "${values[@]}"; do
    opt=$(printf '%s' "$card" | jq -c --arg v "$value" '(.options // [])[] | select(.value == $v)' 2>/dev/null | head -n 1)
    [ -n "$opt" ] || continue
    text=$(printf '%s' "$opt" | jq -r '.outcome // .label // empty')
    end=$(end_of "$opt" "$detail")
    if [ "$dry" -eq 1 ]; then
      printf '%s\t%s\t%s\n' "$value" "$end" "$text"
      continue
    fi
    row_of "$key" "$at" "$value" "$end" && continue
    START_DETAIL=''
    case "$end" in
      no-op)
        put_row "$key" "$at" "$value" no-op "$text"
        printf 'no-op %s [%s]: %s\n' "$key" "$value" "$text"
        ;;
      dated)
        until=$(deferral_date "$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')" "$at") || until=''
        if defer_to "$key" "$value" "$text" "$answer" "$at" "$source" "$call" "$until"; then
          put_row "$key" "$at" "$value" dated "$START_DETAIL"
        else
          put_row "$key" "$at" "$value" supervisor "$text"
          printf 'supervisor %s [%s]: %s; option "%s"; answer "%s"\n' "$key" "$value" "$START_DETAIL" "$text" "$answer"
          rc=1
        fi
        ;;
      worker)
        if start_worker "$key" "$value" "$text" "$answer" "$at" "$source" "$call"; then
          put_row "$key" "$at" "$value" worker "$START_DETAIL"
        else
          put_row "$key" "$at" "$value" supervisor "$text"
          printf 'supervisor %s [%s]: %s; option "%s"; answer "%s"\n' "$key" "$value" "$START_DETAIL" "$text" "$answer"
          rc=1
        fi
        ;;
      *)  # supervisor, and any end this command does not know: a supervisor step
        put_row "$key" "$at" "$value" supervisor "$text"
        case "$(executor_of "$detail" "$value")" in
          '') supervisor_step "$key" "$value" "the card names no executor for this option, so a supervisor takes it" "$text" "$answer" ;;
          *) supervisor_step "$key" "$value" "the card says a supervisor takes this option, or the option discards work" "$text" "$answer" ;;
        esac
        ;;
    esac
  done
  return "$rc"
}

cmd_show() {
  local key=${1:-}
  [ -n "$key" ] || usage
  [ -f "$ROUTES/$key.tsv" ] || { printf 'no route rows for %s\n' "$key"; return 0; }
  cat "$ROUTES/$key.tsv"
}

[ "$#" -ge 1 ] || usage
case "$1" in
  route) shift; cmd_route "$@" ;;
  show) shift; cmd_show "$@" ;;
  *) usage ;;
esac
