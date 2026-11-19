#!/usr/bin/env bash
# jg-backlog.sh - read and write THIS home's Beads backlog from any working directory.
#
# Usage: jg-backlog.sh [<backlog command> [args...]]
#        jg-backlog.sh --help
#
# Every routine juggernaut backlog read or mutation goes through this command. It serves
# `show`, `view`, `list`, `questions` (the owner's open questions: `--ticket <id>`, `--due`, `--all`, `--json`), `ready`, `ready --spawnable` (the tickets this home can start now, bin/jg-backlog-spawnable.sh, ended at 10 seconds with exit 124), `approve-dispatch`, `markdown`, `homes --json` (every home and its store, `"remote": true` for a lead on another machine, bin/jg-backlog-homes.sh), `tree --homes` (one tree across every home, bin/jg-backlog-tree.py), `add`, `update`, `done`, `block`, `unblock`,
# `start`, `task`, `reopen`, `hold`, `unhold`, `on-report`, `public-followup`, `relink`, `retag` and `compare` (below) from the store that
# `config/beads-dir` names (bin/jg-backlog-lib.sh); any other verb exits 2 with nothing
# run. A relative value of `--to` or any `--*-file` flag (`--body-file`, ...) is made
# absolute against the caller's working directory. Hold reasons are plain text.
#
# The data directory is JG_DATA_OVERRIDE, else $JG_HOME/data, else the code root's data/
# (JG_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - a caller-supplied --file, because this command owns the addressing;
#   - a home with no store named in `config/beads-dir` (bin/jg-backlog-lib.sh owns that diagnostic);
#   - `add` (or its `create` alias) with --start, so neither spelling places a row In
#     flight without the dispatch artifacts bin/jg-spawn.sh creates - the task record,
#     status file, and inbox that go with the row (`start <id>` stays a documented
#     direct transition);
#   - `rm`/`delete` or `done`/`close` of an owner ask (the row with the `captain-ask` label, or an old row whose
#     title still starts with the tag), unless the row has a merged `pr:` link or a Recon report (see the next entry).
#     A raw `hold` is always refused.
#     The type tag is a label, not title text: a title that starts with [captain-ask], [feature], [design-ux],
#     [security] or [blocker] is stored without it and with the label of that name (`-l captain-ask "words"` is the
#     same call), and a kind such as captain is metadata.kind on a task. `show` prints an `ask:` line and `list --fields ask`
#     gives the column: ask, under an ask, or - from the store, the one answer bin/jg-beads-view.py's ask_role gives. `retag` is the one-time
#     pass for a home that has old rows: it labels each row from its own tag, copies captain-ask down every parent edge, makes
#     each row with a child an epic and each decision row a task (or epic) with kind captain, and a rerun changes nothing.
#   - the same close without delivery evidence and without `--captain-quote '<his words>'` or
#     `--confirm-card <id>` (a separate board card that names the row and that
#     `bin/jg-captain-hold.sh answered` finds answered): a recorded answer alone
#     no longer closes a ticket the captain asked for, because a rejected option is a reason to redo
#     it, never to cancel. The quote or card is recorded in the ticket note (`done`) and in
#     data/captain-closures.md; both flags are consumed here and never reach the store.
#   - `add` (or `create`) whose item is not filed as fields: the title must read as plain words
#     (bin/jg-backlog-lib.sh's jg_backlog_title_refusal: 2 to 7 words, at most 48 characters, no id, [tag], URL or
#     path, and no plan code such as J20d-3 or mf-m2 at the front (the code goes in the body; bin/jg-retitle.py renames the old ones); a leading type tag is still taken as input and stored as the label), the call must carry --priority 0 to 3
#     (an owner ask gets 0), and bd checks the body for the sections of lint.sections.task (`jg-beads.sh init` sets
#     Captain, Ask, Why and Done when; bd's own task rule adds Acceptance Criteria) with `create --validate`. The
#     local presence flag config/backlog-intake-loose in this home turns the check off;
#   - `add`/`create` of a [captain-ask] item with a --priority other than 0, or
#     `update`/`edit` that would set one on a [captain-ask] row (or retitle a
#     row to [captain-ask] with one): an owner ask is top priority. Such an add
#     or retitle without --priority gets --priority 0 added;
#   - `add` (or `create`) of a row for another home: `--owner <home>` (or JG_ROW_OWNER, which bin/jg-plan-route.sh
#     sets) names the home that owns the row, and a home files only its own, so the row lives in one store. A
#     home is `main` or the id in its squad-lead marker. The refusal names the owner; the flag never reaches the
#     store. Without it nothing is checked;
#   - `add --release <name>` names the release the ticket belongs to and stores it as metadata.release (`later` when
#     absent); a `release:` line in the body is not read.
# `on-report <ticket-id>` reads the follow-up the ticket's body states ahead, `on-report: triage-build <harness>
# <model> <effort>`, and prints `<harness> <model> <effort>` when the ticket rests on one of the three records of the
# captain's yes (bin/jg-captain-ask-lib.sh's captain_ask_build_basis); it exits 2 for no or a malformed line and 3 for
# a line with no record, and writes nothing. core/recon-ready runs the follow-up when the Recon's report lands.
# `task <ticket-id> [--model <model>]` prints the task id made from the ticket (bin/jg-backlog-lib.sh's jg_backlog_task_id:
# every dot becomes a dash, and a Fable model puts fable- in front, so a Fable worker works the ticket itself) and writes it on the ticket's row as metadata.task, so every script that knows only the task id
# reaches the row. It refuses a ticket with no row and a task id that a different row already answers to.
# Ticket keys (bin/jg-ticket-key.sh owns the contract): a key such as JG-101 given where a
# task id goes is resolved to its slug first, `show` prints the key under the id, `list --keys`
# puts each row's key first, and a successful `add` keys the new ticket when the home has a
# registered prefix.
# One engine (expand phase): when the main home has `config/one-engine`, each successful Beads write of any writer (jg_backlog_beads_write: this command, spawn, teardown, the captain-hold scripts, handoff and receive) is copied into the
# ticket tables of the host's item store (core/item-store/adapters/tickets.py write); a failed copy prints one
# `jg-backlog: one-engine copy: ...` line and never fails the Beads write. `compare` runs `bd export` and lists each
# difference between Beads and that copy, one line each (exit 1 when any). Reads stay on Beads, unless the main home has
# `config/one-engine-read`: then `show`, `view`, `list`, `ready`, `markdown`, `questions` and `tree` answer from those tables
# in the same text, each read also asks Beads, and a different answer opens one `intake` item on Main naming both
# (removing the flag returns every read to Beads). `homes` reads files, not Beads, so it is the same on both paths.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-home-name-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-home-name-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'jg-backlog: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
# shellcheck disable=SC2034  # both are read by guard_captain_ask_close in bin/jg-captain-ask-lib.sh
CAPTAIN_QUOTE=
CONFIRM_CARD=
cap_next=
ROW_OWNER=${JG_ROW_OWNER:-}
owner_next=0
for arg in "$@"; do
  if [ "$owner_next" = 1 ]; then ROW_OWNER=$arg; owner_next=0; continue; fi
  if [ -n "$cap_next" ]; then
    case $cap_next in quote) CAPTAIN_QUOTE=$arg ;; *) CONFIRM_CARD=$arg ;; esac
    cap_next=
    continue
  fi
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog; drop --file"
      ;;
    --owner|--owner=*)
      case "${1:-}" in
        add|create) if [ "$arg" = --owner ]; then owner_next=1; else ROW_OWNER=${arg#--owner=}; fi ;;
        *) ARGS+=("$arg") ;;
      esac
      ;;
    --captain-quote) cap_next=quote ;;
    --captain-quote=*) CAPTAIN_QUOTE=${arg#--captain-quote=} ;;
    --confirm-card) cap_next=card ;;
    --confirm-card=*) CONFIRM_CARD=${arg#--confirm-card=} ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/jg-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

[ -z "$cap_next" ] || fail "--captain-quote and --confirm-card each need a value"
[ "$owner_next" = 0 ] || fail "--owner needs a home name"

# A ticket key names its slug wherever a task id goes; a title or any other value is left alone.
TICKET_KEY="$SCRIPT_DIR/jg-ticket-key.sh"
LIST_KEYS=0
_jg_keyed=()
for _jg_arg in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$_jg_arg" in
    --keys) [ "${1:-}" = list ] && { LIST_KEYS=1; continue; } ;;
    [A-Z][A-Z]-[0-9]*|[A-Z][A-Z][A-Z]-[0-9]*|[A-Z][A-Z][A-Z][A-Z]-[0-9]*)
      case "${1:-}" in add|create) ;; *)
        _jg_slug=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$TICKET_KEY" resolve "$_jg_arg" 2>/dev/null) && _jg_arg=$_jg_slug ;;
      esac ;;
  esac
  _jg_keyed+=("$_jg_arg")
done
ARGS=(${_jg_keyed[@]+"${_jg_keyed[@]}"})
unset _jg_keyed _jg_arg _jg_slug
key_tool() { JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$TICKET_KEY" "$@"; }
# One engine (read phase): with the main home's config/one-engine-read every read verb answers from the ticket tables
# (core/item-store/adapters/tickets.py read), asks Beads too, and a different answer opens one intake item on Main.
one_engine_read() {
  local home=$JG_HOME n=0 parent
  while [ "$n" -lt 8 ]; do
    parent=$(sed -n 's/^parent_home=//p' "$(jg_compat_parent_marker "$home")" 2>/dev/null | head -n 1)
    [ -n "$parent" ] || break
    home=$parent; n=$((n + 1))
  done
  [ -e "$home/config/one-engine-read" ]
}
beads_read() {
  if one_engine_read; then
    JG_HOME="$JG_HOME" python3 "$JG_ROOT/core/item-store/adapters/tickets.py" read ${ARGS[@]+"${ARGS[@]}"} --shadow
  else
    jg_backlog_beads_read "$JG_HOME/config" ${ARGS[@]+"${ARGS[@]}"}
  fi
}
# approve-dispatch <id> --harness <h> --model <m> --effort <e>: the lead's or the owner's yes that the dispatch check
# (core/auto-dispatch) may start this ticket by itself, on that route. It writes state/dispatch-approved/<id>, the only
# record the check trusts: a line typed into a ticket body is not one. A worker session (JG_TASK_ID set) is refused.
approve_dispatch() {
  local id='' harness='' model='' effort='' dir rec
  [ -z "${JG_TASK_ID:-}" ] || fail "approve-dispatch is refused in a worker session: only the lead or the owner approves a start"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness|--model|--effort) [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 needs a value"
        case "$1" in --harness) harness=$2 ;; --model) model=$2 ;; --effort) effort=$2 ;; esac; shift 2 ;;
      -*) fail "approve-dispatch: unknown option $1" ;;
      *) [ -z "$id" ] || fail "approve-dispatch takes one ticket id"; id=$1; shift ;;
    esac
  done
  [ -n "$id" ] && [ -n "$harness" ] && [ -n "$model" ] && [ -n "$effort" ] \
    || fail "usage: approve-dispatch <id> --harness <h> --model <m> --effort <e>"
  case "$id$harness$model$effort" in *[!A-Za-z0-9._:/-]*) fail "approve-dispatch: ids and route values hold letters, digits and . _ : / - only" ;; esac
  jg_backlog_beads_read "$JG_HOME/config" show "$id" >/dev/null 2>&1 || fail "approve-dispatch: no ticket $id in this home's store"
  dir="${JG_STATE_OVERRIDE:-$JG_HOME/state}/dispatch-approved"
  mkdir -p "$dir" || fail "approve-dispatch: cannot create $dir"
  rec=$(mktemp "$dir/.$id.XXXXXX") || fail "approve-dispatch: cannot write in $dir"
  if ! { printf 'approved-by=%s\napproved-at=%s\nharness=%s\nmodel=%s\neffort=%s\n' \
    "$(id -un)" "$(date +%s)" "$harness" "$model" "$effort" > "$rec" && mv -f "$rec" "$dir/$id"; }; then
    rm -f "$rec"; fail "approve-dispatch: cannot write $dir/$id"
  fi
  printf 'approved %s for dispatch: %s %s %s\n' "$id" "$harness" "$model" "$effort"
}

set -o pipefail
# The task id is made here, in the one function that makes it, and handed to the writer with the ticket.
if [ "${1:-}" = task ]; then
  TASK_MODEL=
  if [ "${#ARGS[@]}" -eq 4 ] && [ "${ARGS[2]}" = --model ]; then TASK_MODEL=${ARGS[3]}; ARGS=("${ARGS[@]:0:2}")
  elif [ "${#ARGS[@]}" -ne 2 ]; then fail "usage: jg-backlog.sh task <ticket-id> [--model <model>]"; fi
  ARGS+=("$(jg_backlog_task_id "${ARGS[1]}" "$TASK_MODEL")")
fi
case "${1:-}" in
  approve-dispatch) approve_dispatch "${ARGS[@]:1}"; exit $? ;;
  show|view) beads_read | key_tool annotate-show; exit $? ;;
  list) if [ "$LIST_KEYS" = 1 ]; then beads_read | key_tool annotate; else beads_read; fi; exit $? ;;
  ready)
    if [ "${ARGS[1]:-}" = --spawnable ]; then
      [ "${#ARGS[@]}" -eq 2 ] || fail "ready --spawnable takes no other argument"
      # shellcheck source=bin/jg-timeout-lib.sh disable=SC1091
      . "$SCRIPT_DIR/jg-timeout-lib.sh"
      JG_HOME="$JG_HOME" jg_run_timed "${JG_BACKLOG_SPAWNABLE_LIMIT:-10}" "$SCRIPT_DIR/jg-backlog-spawnable.sh"
      _jg_rc=$?
      [ "$_jg_rc" -ne 124 ] || printf 'jg-backlog: ready --spawnable did not finish in %s seconds\n' "${JG_BACKLOG_SPAWNABLE_LIMIT:-10}" >&2
      exit "$_jg_rc"
    fi
    beads_read; exit $? ;;
  markdown|questions) beads_read; exit $? ;;
  homes) exec "$SCRIPT_DIR/jg-backlog-homes.sh" "${ARGS[@]:1}" ;;
  tree)
    if one_engine_read; then JG_HOME="$JG_HOME" exec python3 "$JG_ROOT/core/item-store/adapters/tickets.py" tree "${ARGS[@]:1}"; fi
    exec python3 "$SCRIPT_DIR/jg-backlog-tree.py" "${ARGS[@]:1}" ;;
  compare)
    [ "${#ARGS[@]}" -eq 1 ] || fail "compare takes no argument"
    _jg_store=$(jg_backlog_beads_store "$JG_HOME/config") || exit 2
    _jg_exp=$(mktemp) || fail "no scratch file"
    if ! BEADS_DIR=$_jg_store "$SCRIPT_DIR/jg-beads.sh" export > "$_jg_exp"; then rm -f -- "$_jg_exp"; fail "bd export failed"; fi
    JG_HOME="$JG_HOME" python3 "$JG_ROOT/core/item-store/adapters/tickets.py" compare "$_jg_exp"; _jg_rc=$?
    rm -f -- "$_jg_exp"; exit "$_jg_rc" ;;
  add|create|update|edit|done|close|block|unblock|start|task|reopen|hold|unhold|on-report|public-followup|relink|retag|moment|wait|ticket-stage|ticket-drift|times|trace|beat|reclaim) ;;
  *) fail "the beads backlog does not serve ${1:-this command}" ;;
esac

_jg_taxi_sl_own="squad_lead:"
_jg_taxi_sl_wire="$(jg_compat_legacy_of squad-lead):"
backlog_cmd() { jg_backlog_beads_read "$JG_HOME/config" "$@"; }
# shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-captain-ask-lib.sh"

if [ "${1:-}" = on-report ]; then
  [ "${#ARGS[@]}" -eq 2 ] || fail "usage: jg-backlog.sh on-report <ticket-id>"
  STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}  # read by bin/jg-captain-ask-lib.sh for the approval key and the chat notes
  CAPTAIN_ASK_SHOW=$(backlog_cmd show "${ARGS[1]}" --full 2>/dev/null) || fail "cannot read ${ARGS[1]}"
  captain_ask_on_report "${ARGS[1]}" "$CAPTAIN_ASK_SHOW"
  exit $?
fi

captain_guard() {  # <backlog args>
  local verb id='' value=0 arg
  local reason='' reason_next=0 reason_given=0
  [ "${1:-}" = task ] && shift
  verb=${1:-}
  [ "$#" -gt 0 ] && shift
  if [ "$verb" = public-followup ]; then shift; fi
  for arg in "$@"; do
    if [ "$arg" = --json ]; then continue; fi
    if [ "$value" = 1 ]; then value=0; continue; fi
    if [ "$reason_next" = 1 ]; then reason_next=0; reason=$arg; reason_given=1; continue; fi
    case "$arg" in
      --reason) reason_next=1 ;;
      --reason=*) reason=${arg#--reason=}; reason_given=1 ;;
      --pr|--report|--note|--until|--kind|--repo|--priority|--body|--body-file|--title|--release) value=1 ;;
      -*) ;;
      *) id=${id:-$arg} ;;
    esac
  done
  case "$verb" in
    done|close) guard_captain_ask_close "$id" ;;
    rm|delete) guard_captain_ask_close "$id" ;;
    hold)
      # A hold without a reason is a hold nobody can read: refuse it here so the
      # ticket the board renders never shows one with nothing beside it.
      if [ "$reason_given" = 1 ] && [ -z "${reason//[[:space:]]/}" ]; then
        fail "a hold needs a non-blank --reason \"<why this waits>\"; nothing was held"
      fi
      guard_captain_ask_hold "$id" ;;
    update|edit)
      # A retitle never drops an ask: the writer moves a leading tag to its label first.
      ;;
  esac
}
# Reads an add/update argument list: ITEM_TITLE (add's title, or update's --title),
# ITEM_PRIORITY, and ITEM_ID (update's id).
item_args() {  # <add|update args...>
  local verb=$1 positional=()
  ITEM_TITLE='' ITEM_PRIORITY='' ITEM_ID='' ITEM_LABELS=' '
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body|--body-file) shift ;;
      --title) ITEM_TITLE=${2-}; shift ;;
      --title=*) ITEM_TITLE=${1#--title=} ;;
      --priority) ITEM_PRIORITY=${2-}; shift ;;
      --priority=*) ITEM_PRIORITY=${1#--priority=} ;;
      --mint) ;;
      --parent) shift ;;
      --parent=*) ;;
      --label|-l) ITEM_LABELS+="${2-} "; shift ;;
      --label=*) ITEM_LABELS+="${1#--label=} " ;;
      --kind|--repo|--blocked-by|--pr|--report|--prefix|--release) shift ;;
      -*) ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  # A word after the id is the title; an add with one word is its title alone and bd names the row (bin/jg-beads-write.py).
  case "$verb" in
    add|create) case ${#positional[@]} in 2) ITEM_TITLE=${positional[1]} ;; *) ITEM_TITLE=${positional[0]-} ;; esac ;;
    *) ITEM_ID=${positional[0]-} ;;
  esac
}
# Strict intake: a new item is filed as fields (see the header), so the backlog reads as plain titles, a priority and
# a release, and bd itself refuses a body without its sections.
intake_check() {
  local why
  [ ! -e "$JG_HOME/config/backlog-intake-loose" ] || return 0
  why=$(jg_backlog_title_refusal "$ITEM_TITLE") \
    || fail "the title is not a readable title: $why; give 2 to 7 plain words (at most 48 characters, no id, [tag], URL or path) and put the detail in --body"
  case "$ITEM_PRIORITY" in
    [0-3]) ;;
    *) fail "a new item needs a priority: pass --priority 0|1|2|3 (0 is most urgent)" ;;
  esac
  JG_BACKLOG_VALIDATE=1; export JG_BACKLOG_VALIDATE
}
# Owner asks come first: a [captain-ask] item sits at priority 0, so `ready`
# offers it before any other work, and nothing lowers it (see the header).
captain_ask_first() {
  local ask=0
  case "$ITEM_TITLE" in '[captain-ask]'*) ask=1 ;; esac
  case "$ITEM_LABELS" in *' captain-ask '*) ask=1 ;; esac
  if [ "$ask" = 0 ] && [ -n "$ITEM_ID" ] && [ -n "$ITEM_PRIORITY" ] && [ "$ITEM_PRIORITY" != 0 ]; then
    captain_ask_row "$ITEM_ID"
    [ -z "$CAPTAIN_ASK_SHOW" ] || ask=1
  fi
  [ "$ask" = 1 ] || return 0
  case "$ITEM_PRIORITY" in
    '') ARGS+=(--priority 0); ITEM_PRIORITY=0 ;;
    0) ;;
    *) fail "a [captain-ask] item is top priority and stays at 0; drop --priority $ITEM_PRIORITY" ;;
  esac
}
# This home's name as the owner of a row: `main`, or the id its squad-lead marker holds.
home_owner_name() {
  local marker
  marker=$(jg_compat_marker "$JG_HOME")
  if [ -r "$marker" ]; then tr -d '[:space:]' < "$marker"; else printf 'main'; fi
}
# A home files only the rows it owns: a row that names another owner is that home's to file.
owner_check() {
  local me
  [ -n "$ROW_OWNER" ] || return 0
  me=$(home_owner_name)
  [ "$ROW_OWNER" = "$me" ] \
    || fail "this row is owned by $ROW_OWNER and this home is $me: file it in $ROW_OWNER's home (bin/jg-plan-route.sh does that for a plan); nothing was filed"
}
# New and edited items: an owner ask is raised to priority 0 first, then strict intake reads the fields.
case "${1:-}" in
  add|create)
    owner_check
    item_args ${ARGS[@]+"${ARGS[@]}"}
    captain_ask_first
    intake_check
    ;;
  update|edit)
    item_args ${ARGS[@]+"${ARGS[@]}"}
    captain_ask_first
    ;;
esac
CLOSE_NOTE_ARGS=()
captain_guard ${ARGS[@]+"${ARGS[@]}"}
if [ "${#CLOSE_NOTE_ARGS[@]}" -gt 0 ]; then
  case " ${ARGS[*]} " in *" --note "*) ;; *) ARGS+=("${CLOSE_NOTE_ARGS[@]}") ;; esac
fi
JG_BEADS_WIRE_LEAD=$_jg_taxi_sl_wire JG_BEADS_HOME_ID=main
_jg_lead_marker=$(jg_compat_marker "$JG_HOME")
[ ! -r "$_jg_lead_marker" ] || JG_BEADS_HOME_ID=$_jg_taxi_sl_wire$(cat "$_jg_lead_marker")
export JG_BEADS_WIRE_LEAD JG_BEADS_HOME_ID
# The filer is the home: bd's actor (`created_by`, the journal) and the assignee of a row held with no worker are `main` or
# `lead:<id>` unless the caller names an actor.
BEADS_ACTOR=${BEADS_ACTOR:-$(jg_home_actor "$JG_HOME")}
export BEADS_ACTOR
jg_backlog_beads_write "$JG_HOME/config" ${ARGS[@]+"${ARGS[@]}"}
_jg_rc=$?
case "${1:-}" in add|create) [ "$_jg_rc" -ne 0 ] || key_tool sync >&2 || true ;; esac
[ "$_jg_rc" -eq 0 ] || exit "$_jg_rc"
# A write this command performs puts the ticket on the board in the same breath, so the board
# follows the work and never waits for the next tickets-sync poll; the verb map and the writer are
# bin/jg-backlog-transition-lib.sh's own.
case "${ARGS[0]-}" in
  add|create) jg_backlog_ticket_publish "$JG_HOME/data" add "${ARGS[1]-}" ;;
  done|close|start|reopen|hold|park|unhold)
    jg_backlog_ticket_note "$JG_HOME/data" "${ARGS[0]}" "${ARGS[1]-}" ${ARGS[@]+"${ARGS[@]:2}"} ;;
esac
exit 0
