#!/usr/bin/env bash
# jg-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: jg-tasks-axi.sh [<tasks-axi command> [args...]]
#        jg-tasks-axi.sh --help
#
# Every routine juggernaut backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `jg-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. Arguments reach tasks-axi as given, apart from one
# rewrite that keeps file arguments meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# `show` (including `view`) and `list` decode stored captain-hold reasons
# through bin/jg-hold-reason-lib.sh, which owns the field-only decoding contract.
# Decoded reasons use quoted strings so embedded line breaks remain intact.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/jg-backlog-transition-lib.sh's jg_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so read-only
# task listings use the same home. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is JG_DATA_OVERRIDE, else $JG_HOME/data, else the code
# root's data/ (JG_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - `add` (or its `create` alias) with --start, so neither spelling places a
#     row In flight without the dispatch artifacts bin/jg-spawn.sh creates -
#     the task record, status file, and inbox that go with the row - which such
#     a row would lack, counting as live work nobody is doing that nothing
#     later would notice (`start <id>` stays a documented direct transition);
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/jg-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
#   - `rm`/`delete`, `done`/`close`, or `update`/`edit --title` dropping `[captain-ask]`,
#     unless the row has a merged `pr:` link or a Recon report (see the next entry).
#     A raw `hold` is always refused. Done auto-prune, `prune`, and record-delivery/waive
#     refuse only an unanswered ask an archive would move past keep (`--no-prune` skips
#     the done prune).
#   - the same close without delivery evidence and without `--captain-quote '<his words>'` or
#     `--confirm-card <id>` (a separate board card that names the row and that
#     `bin/jg-captain-hold.sh answered` finds answered): a recorded answer alone
#     no longer closes a ticket the captain asked for, because a rejected option is a reason to redo
#     it, never to cancel. The quote or card is recorded in the ticket note (`done`) and in
#     data/captain-closures.md; both flags are consumed here and never reach tasks-axi.
#   - `add` (or `create`) whose item does not say what kind of work it is and
#     why: the title must start with a type tag, one of [captain-ask],
#     [feature], [design-ux], [security] or [blocker], and the first line of
#     --body or --body-file must be a one-line summary (the captain's own
#     words for [captain-ask]), followed by short Captain, Ask, Why and Done when
#     lines. Anything else - refactors, extra proof, tooling,
#     follow-ups - belongs in a report, not the backlog. The local presence flag
#     config/backlog-intake-loose in this home turns the check off;
#   - `add`/`create` of a [captain-ask] item with a --priority other than 0, or
#     `update`/`edit` that would set one on a [captain-ask] row (or retitle a
#     row to [captain-ask] with one): an owner ask is top priority. Such an add
#     or retitle without --priority gets --priority 0 added;
#   - `add` (or `create`) that the optional task-priority feature check refuses,
#     e.g. no `--priority 0-3`; its message and exit status are returned and
#     nothing runs. The check is ${XDG_DATA_HOME:-~/.local/share}/jg-task-priority/check.sh
#     (JG_TASK_PRIORITY_CHECK overrides the path); when it is not installed this
#     does nothing.
# Ticket keys (bin/jg-ticket-key.sh owns the contract): a key such as JG-101 given where a
# task id goes is resolved to its slug before tasks-axi runs, `show` prints the key under
# the id, `list --keys` puts each row's key first, and a successful `add` keys the new
# ticket when the home has a registered prefix.
# Otherwise the exit status is tasks-axi's own, unless decoding a read fails;
# in that case the decoder's nonzero status is returned.
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
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
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
# shellcheck source=bin/jg-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
# shellcheck source=bin/jg-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'jg-tasks-axi: %s\n' "$*" >&2
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
for arg in "$@"; do
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
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
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
command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/jg-bootstrap.sh for the install command"

JG_BACKLOG_TRANSITION_ERROR=
if ! jg_backlog_tasks_axi_addressing "$DATA"; then
  fail "${JG_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$JG_BACKLOG_AXI_FILE" ]; then
  if [ -L "$JG_BACKLOG_AXI_FILE" ]; then
    fail "$JG_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$JG_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$JG_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $JG_BACKLOG_AXI_ROOT"

tasks_axi() { tasks-axi "$@"; }

# The typed public-followup schema in the pinned tasks-axi spells a squad-lead
# work home with the pre-rename prefix, so this boundary translates in both
# directions and the rest of the repository keeps one spelling (slice S5).
_jg_taxi_sl_own="squad_lead:"
_jg_taxi_sl_wire="$(jg_compat_legacy_of squad-lead):"
jg_taxi_stream_from_wire() {
  sed "s/${_jg_taxi_sl_wire}/${_jg_taxi_sl_own}/g"
}
# shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-captain-ask-lib.sh"
captain_guard() {  # <tasks-axi args>
  local prune_state="done" no_prune=0 keep_arg='' keep_next=0 sub=''
  local verb id='' value=0 title_next=0 state_next=0 has_title=0 new_title='' arg
  local reason='' reason_next=0 reason_given=0
  [ "${1:-}" = task ] && shift
  verb=${1:-}
  [ "$#" -gt 0 ] && shift
  if [ "$verb" = public-followup ]; then sub=${1:-}; [ "$#" -gt 0 ] && shift; fi
  for arg in "$@"; do
    if [ "$arg" = --json ]; then continue; fi
    if [ "$value" = 1 ]; then value=0; continue; fi
    if [ "$reason_next" = 1 ]; then reason_next=0; reason=$arg; reason_given=1; continue; fi
    if [ "$title_next" = 1 ]; then title_next=0; new_title=$arg; continue; fi
    if [ "$state_next" = 1 ]; then state_next=0; prune_state=$arg; continue; fi
    if [ "$keep_next" = 1 ]; then keep_next=0; keep_arg=$arg; continue; fi
    case "$arg" in
      --no-prune) no_prune=1 ;;
      --reason) reason_next=1 ;;
      --reason=*) reason=${arg#--reason=}; reason_given=1 ;;
      --keep) keep_next=1 ;;
      --keep=*) keep_arg=${arg#--keep=} ;;
      --state) state_next=1 ;;
      --state=*) prune_state=${arg#--state=} ;;
      --title) title_next=1; has_title=1 ;;
      --title=*) has_title=1; new_title=${arg#--title=} ;;
      --pr|--report|--note|--until|--kind|--repo|--priority|--body|--body-file) value=1 ;;
      -*) ;;
      *) id=${id:-$arg} ;;
    esac
  done
  case "$verb" in
    prune) guard_captain_ask_archive "$prune_state" "$keep_arg" "" ;;
    done|close)
      guard_captain_ask_close "$id"
      [ "$no_prune" = 1 ] || guard_captain_ask_archive "done" "$keep_arg" "$id"
      ;;
    public-followup)
      case "$sub" in
        record-delivery|waive) guard_captain_ask_archive "done" "" "$id" ;;
      esac
      ;;
    rm|delete) guard_captain_ask_close "$id" ;;
    hold)
      # A hold without a reason is a hold nobody can read: refuse it here so the
      # ticket the board renders never shows one with nothing beside it.
      if [ "$reason_given" = 1 ] && [ -z "${reason//[[:space:]]/}" ]; then
        fail "a hold needs a non-blank --reason \"<why this waits>\"; nothing was held"
      fi
      guard_captain_ask_hold "$id" ;;
    update|edit)
      if [ "$has_title" = 1 ]; then
        case "$new_title" in
          *'[captain-ask]'*) ;;
          *) guard_captain_ask_close "$id" ;;
        esac
      fi
      ;;
  esac
}
# Reads an add/update argument list: ITEM_TITLE (add's title, or update's --title),
# ITEM_BODY, ITEM_PRIORITY, and ITEM_ID (update's id).
item_args() {  # <tasks-axi add|update args...>
  local verb=$1 mint=0 positional=()
  ITEM_TITLE='' ITEM_BODY='' ITEM_PRIORITY='' ITEM_ID=''
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body) ITEM_BODY=${2-}; shift ;;
      --body=*) ITEM_BODY=${1#--body=} ;;
      --body-file) ITEM_BODY=$(cat -- "${2-}" 2>/dev/null); shift ;;
      --body-file=*) ITEM_BODY=$(cat -- "${1#--body-file=}" 2>/dev/null) ;;
      --title) ITEM_TITLE=${2-}; shift ;;
      --title=*) ITEM_TITLE=${1#--title=} ;;
      --priority) ITEM_PRIORITY=${2-}; shift ;;
      --priority=*) ITEM_PRIORITY=${1#--priority=} ;;
      --mint) mint=1 ;;
      --kind|--repo|--blocked-by|--pr|--report|--prefix) shift ;;
      -*) ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  case "$verb" in
    add|create) if [ "$mint" = 1 ]; then ITEM_TITLE=${positional[0]-}; else ITEM_TITLE=${positional[1]-}; fi ;;
    *) ITEM_ID=${positional[0]-} ;;
  esac
}
# Strict intake: a new item names its type and why it is worth doing (see the
# header), so the backlog holds asked-for or user-facing work, not busy work.
intake_check() {
  local body
  [ ! -e "$JG_HOME/config/backlog-intake-loose" ] || return 0
  case "$ITEM_TITLE" in
    '[captain-ask]'*|'[feature]'*|'[design-ux]'*|'[security]'*|'[blocker]'*) ;;
    *) fail "a new item needs a type: start the title with [captain-ask], [feature], [design-ux], [security] or [blocker]; other work goes in a report, not the backlog" ;;
  esac
  body=${ITEM_BODY%%$'\n'*}
  [ -n "${body//[[:space:]]/}" ] \
    || fail "a new item needs a justification: make the first line of --body say why it is worth doing (the captain's words for [captain-ask])"
}
# Owner asks come first: a [captain-ask] item sits at priority 0, so `ready`
# offers it before any other work, and nothing lowers it (see the header).
captain_ask_first() {
  local ask=0
  case "$ITEM_TITLE" in '[captain-ask]'*) ask=1 ;; esac
  if [ "$ask" = 0 ] && [ -n "$ITEM_ID" ] && [ -n "$ITEM_PRIORITY" ] && [ "$ITEM_PRIORITY" != 0 ]; then
    captain_ask_row "$ITEM_ID"
    [ -z "$CAPTAIN_ASK_SHOW" ] || ask=1
  fi
  [ "$ask" = 1 ] || return 0
  case "$ITEM_PRIORITY" in
    '') ARGS+=(--priority 0) ;;
    0) ;;
    *) fail "a [captain-ask] item is top priority and stays at 0; drop --priority $ITEM_PRIORITY" ;;
  esac
}
# New and edited items: strict intake and owner asks first, then the optional
# task-priority feature (a new task must carry a priority; no-op when not installed).
case "${1:-}" in
  add|create)
    item_args ${ARGS[@]+"${ARGS[@]}"}
    intake_check
    captain_ask_first
    PRIORITY_CHECK="${JG_TASK_PRIORITY_CHECK:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/jg-task-priority/check.sh}"
    if [ -x "$PRIORITY_CHECK" ]; then
      "$PRIORITY_CHECK" ${ARGS[@]+"${ARGS[@]}"} >/dev/null || exit $?
    fi
    ;;
  update|edit)
    item_args ${ARGS[@]+"${ARGS[@]}"}
    captain_ask_first
    ;;
esac
# Public-followup values cross into tasks-axi's own schema; everything else passes
# through untouched.
case "${1:-}" in
  public-followup|task)
    case "${2:-}${1:-}" in
      *public-followup*)
        _jg_wire_args=()
        for _jg_arg in ${ARGS[@]+"${ARGS[@]}"}; do
          case "$_jg_arg" in
            "$_jg_taxi_sl_own"*) _jg_wire_args+=("${_jg_taxi_sl_wire}${_jg_arg#"$_jg_taxi_sl_own"}") ;;
            *) _jg_wire_args+=("$_jg_arg") ;;
          esac
        done
        ARGS=(${_jg_wire_args[@]+"${_jg_wire_args[@]}"})
        unset _jg_wire_args _jg_arg
        ;;
    esac
    ;;
esac
CLOSE_NOTE_ARGS=()
captain_guard ${ARGS[@]+"${ARGS[@]}"}
if [ "${#CLOSE_NOTE_ARGS[@]}" -gt 0 ]; then
  case " ${ARGS[*]} " in *" --note "*) ;; *) ARGS+=("${CLOSE_NOTE_ARGS[@]}") ;; esac
fi
case "${1:-}" in
  show|view|list)
    set -o pipefail
    if [ "${1:-}" = list ] && [ "$LIST_KEYS" = 1 ]; then
      tasks-axi ${ARGS[@]+"${ARGS[@]}"} | jg_hold_reason_decode_stream | jg_taxi_stream_from_wire | key_tool annotate
    elif [ "${1:-}" = list ]; then
      tasks-axi ${ARGS[@]+"${ARGS[@]}"} | jg_hold_reason_decode_stream | jg_taxi_stream_from_wire
    else
      tasks-axi ${ARGS[@]+"${ARGS[@]}"} | jg_hold_reason_decode_stream | jg_taxi_stream_from_wire | key_tool annotate-show
    fi
    exit $?
    ;;
  add|create)
    tasks-axi ${ARGS[@]+"${ARGS[@]}"}
    _jg_rc=$?
    [ "$_jg_rc" -ne 0 ] || key_tool sync >&2 || true
    exit "$_jg_rc"
    ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
