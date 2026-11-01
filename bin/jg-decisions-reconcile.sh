#!/usr/bin/env bash
# jg-decisions-reconcile.sh - clear every board card its own durable records
# already answer, as a standing watcher check on its own hourly interval.
#
# Usage:
#   jg-decisions-reconcile.sh [check|poll] [--dry-run] [--force]
#   jg-decisions-reconcile.sh arm | disarm
#   jg-decisions-reconcile.sh log [<lines>]
#
# Why this exists: a card stays on the captain's Decide page after the records
# already settled it - a card he answered in chat, a card whose task wrote a
# `resolved [key=<card-key>]` line, a merge card whose PR is merged, a card whose
# task is closed. Nothing compared open cards with those records, so the page
# grew and his Waiting count stopped meaning anything.
#
# check   One deterministic pass, no model. Read the open cards through
#         sign-off-axi's own `list --json`, then decide each card from durable
#         records only, in this order, first match wins:
#           own-instruction
#                     the card's hold is the captain's own instruction - its hold
#                     kind is parked, or its reason names a stop order or a branch
#                     we preserved instead of landing (bin/jg-ask-gate-lib.sh owns
#                     the words). The hold path raises no card for such a hold, so
#                     a card that exists is a leftover and is dismissed.
#           answered  an answers log beside the board carries a line for the
#                     card key. A board reached through a symlink keeps one log
#                     beside the link and one beside its target; both are read,
#                     because bin/jg-question-card.sh answer writes the first and
#                     sign-off-axi's own board answers land in the second.
#           resolved  a state/*.status line resolves that exact key.
#           merged    the card's task recorded pr= and a merge record proves it:
#                     state/<id>.pr-poll-merge-notified, or a
#                     `done [key=merged-<id>]` line in that task's status log.
#           closed    the card's task reads done in this home's backlog.
#         A decided card is dismissed with --reason done-elsewhere (the reason
#         bin/jg-board-answers.sh already uses) and one
#         `<key>\t<reason>\t<evidence>` line is appended to
#         state/decisions-reconcile.log.
#         Every other card is KEPT and printed as one `kept <key>: <why>` line.
#         A card whose record cannot be read is kept, never cleared: unreadable
#         evidence is the one thing that must not look like proof. Only a card
#         whose kept reason changed since the last pass is printed, so an
#         unchanged board stays silent instead of waking Main every pass.
#         A card's task comes only from a durable record: a
#         state/board-routes/<key> route, a
#         `jg-<home-digest>-<task-id>-<stamp>` hold-card key, the card's filer
#         when it names a task in this home, or a task whose recorded pr= hashes
#         to the card's merge key (bin/jg-board-link-lib.sh). With none of those
#         the card is kept; no task is guessed from a title.
# --dry-run  Decide and print every line, dismiss and log nothing.
# --force    Ignore the hourly interval for this pass.
# arm     Write state/decisions-reconcile.check.sh, bind it with
#         jg-check-register.sh (the watcher's own timer path for checks), and run
#         one pass. disarm removes the shim and its trust binding.
# log     Print the clear log, oldest first, limited to the last <lines>.
#
# One pass is interval-limited to JG_DECISIONS_RECONCILE_SECS (default 3600) by
# state/.decisions-reconcile-last, so the watcher's faster check sweep still runs
# this hourly, and a watcher restart does not restart the interval.
#
# Output is what the watcher turns into one wake for Main: the summary line and
# any newly changed kept line. Silence means the board did not change.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
ROUTES="$STATE/board-routes"
STAMP="$STATE/.decisions-reconcile-last"
KEPT_RECORD="$STATE/.decisions-reconcile-kept"
LOG="$STATE/decisions-reconcile.log"
SHIM="$STATE/decisions-reconcile.check.sh"
INTERVAL=${JG_DECISIONS_RECONCILE_SECS:-3600}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=3600 ;; esac
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
# shellcheck source=bin/jg-question-lib.sh
. "$SCRIPT_DIR/jg-question-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-tasks-axi-lib.sh
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"

die() { printf 'jg-decisions-reconcile: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() {
  cat <<'EOF'
usage:
  jg-decisions-reconcile.sh [check|poll] [--dry-run] [--force]
  jg-decisions-reconcile.sh arm | disarm
  jg-decisions-reconcile.sh log [<lines>]

  check     one hourly pass: clear each open card a durable record settles
  --dry-run decide and print every line, dismiss and log nothing
  --force   ignore the hourly interval for this pass
  arm       write and register state/decisions-reconcile.check.sh
  disarm    remove that check and its trust binding
  log       print the clear log, oldest first

The header comment owns the evidence classes and the refusal rule.
EOF
}
key_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
say() { printf '%s\n' "${1:0:400}"; }

# Seconds since a file's mtime, or a large number when it is missing.
age_of() {
  local m now
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || { printf '999999\n'; return; }
  now=$(date +%s)
  [ "$m" -le "$now" ] || { printf '999999\n'; return; }
  printf '%s\n' "$(( now - m ))"
}

# Canonical absolute path for $1, or the input unchanged when it cannot be
# resolved. A board named through a symlink keeps its answers log beside the real
# file, which is the one sign-off-axi itself reads.
canonical_path() {  # <path>
  local dir base hops=0 target
  [ -n "$1" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || { printf '%s\n' "$1"; return 0; }
  base=$(basename -- "$1")
  while [ -L "$dir/$base" ] && [ "$hops" -lt 16 ]; do
    target=$(readlink -- "$dir/$base") || break
    case "$target" in
      /*) dir=$(CDPATH='' cd -- "$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
      *)  dir=$(CDPATH='' cd -- "$dir/$(dirname -- "$target")" 2>/dev/null && pwd -P) || break
          base=$(basename -- "$target") ;;
    esac
    hops=$((hops + 1))
  done
  printf '%s\n' "$dir/$base"
}

# One scan of both answers logs: `<card-key>\t<answers-log>` per recorded
# answer. A missing log contributes nothing.
answer_index() {
  local l
  for l in "$answers_log" "$answers_alt"; do
    [ -n "$l" ] && [ -r "$l" ] || continue
    jq -r --arg f "$l" 'select(.key != null and .answer != null) | "\(.key)\t\($f)"' "$l" 2>/dev/null
  done
}

# One awk scan of the append-only status logs: `<key>\t<status-file>` for every
# key a `resolved` line closes. A missing log contributes nothing.
resolved_index() {
  awk '
    /^resolved / && match($0, /\[key=[A-Za-z0-9._-]+\]/) {
      printf "%s\t%s\n", substr($0, RSTART + 5, RLENGTH - 6), FILENAME
    }
  ' "$STATE"/*.status 2>/dev/null
}

# Task ids a card's durable records name, most specific first: an explicit
# board route, a hold-card key (bin/jg-question-lib.sh mints
# `jg-<home-digest>-<task-id>-<stamp>`, so the id sits between two dashes), the
# filer naming a task, and a task whose recorded pr= hashes to the card's merge
# key. The longest id a hold key names wins, so `lane-d` beats `lane`.
card_task() {  # <card-key> <filer>
  local key=$1 filer=${2-} f id url best=''
  if [ -f "$ROUTES/$key" ]; then
    id=$(sed -n 's/^lead=//p' "$ROUTES/$key" 2>/dev/null | tail -1)
    if [ -n "$id" ] && printf '%s\n' "$KNOWN" | grep -qxF -- "$id"; then
      printf '%s\n' "$id"
      return 0
    fi
  fi
  while IFS= read -r id; do
    key_ok "$id" || continue
    case "$key" in
      jg-????????-"$id"-*) [ "${#id}" -gt "${#best}" ] && best=$id ;;
    esac
  done <<EOF
$KNOWN
EOF
  if [ -n "$best" ]; then printf '%s\n' "$best"; return 0; fi
  if [ -n "$filer" ] && printf '%s\n' "$KNOWN" | grep -qxF -- "$filer"; then
    printf '%s\n' "$filer"
    return 0
  fi
  for f in "$STATE"/*.meta; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .meta)
    url=$(sed -n 's/^pr=//p' "$f" 2>/dev/null | tail -1)
    [ -n "$url" ] || continue
    if [ "$(jg_board_merge_key "$url")" = "$key" ]; then printf '%s\n' "$id"; return 0; fi
  done
  return 1
}

# 0 proved (prints the evidence path), 1 absent, 2 present but unreadable.
merge_record() {  # <task-id>
  local id=$1 url marker="$STATE/$1.pr-poll-merge-notified"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
    url=$(sed -n 's/^pr=//p' "$STATE/$id.meta" 2>/dev/null | tail -1)
    [ -n "$url" ] || return 2
    jg_pr_url_parse "$url" || return 2
    jg_pr_poll_merge_already_notified "$STATE" "$id" \
      "$JG_PR_PROVIDER" "$JG_PR_HOST" "$JG_PR_PATH" "$JG_PR_NUMBER" || return 2
    printf '%s\n' "$marker"
    return 0
  fi
  if grep -qsF "done [key=merged-$id]" "$STATE/$id.status"; then
    printf '%s\n' "$STATE/$id.status"
    return 0
  fi
  return 1
}

# The backlog state of one task, from this pass's single row listing (ROWS).
row_state() {  # <task-id>
  [ -n "${ROWS:-}" ] || return 0
  printf '%s\n' "$ROWS" | awk -F, -v id="$1" '
    /^  / { t = $1; sub(/^ +/, "", t); if (t == id) { print $2; exit } }
  '
}

# 0 when the task's hold is the captain's own instruction rather than a question
# back to him, so the card built from it cannot be his to answer. An unreadable
# row answers "no" here, because a record this pass cannot read keeps its card.
hold_own_instruction() {  # <task-id>
  local id=$1 out kind reason
  [ -n "${BACKLOG_DATA:-}" ] || return 1
  out=$(jg_backlog_row_show "$BACKLOG_DATA" "$id") || return 1
  kind=$(printf '%s\n' "$out" | sed -n 's/^  hold_kind: *//p' | sed -n '1p')
  [ "$kind" != parked ] || return 0
  reason=$(printf '%s\n' "$out" | sed -n 's/^  hold_reason: *//p' | sed -n '1p')
  # The stored reason is encoded only for parentheses and line breaks, neither of
  # which any of the words below are spelled with, so it matches as it stands.
  jg_ask_own_instruction "$reason"
}
cmd_check() {
  local dry=$1 json board key filer resolved backlog_data task row due_after BACKLOG_DATA
  local reason evidence rc cleared=0 open_before=0 keep_now='' report='' line logged
  local answer_keys answers answers_log answers_alt
  due_after=$(( INTERVAL - $(age_of "$STAMP") ))
  if [ "$due_after" -gt 0 ]; then
    [ -n "$dry" ] && printf 'reconcile: not due for another %ss; pass --force to run now\n' "$due_after"
    return 0
  fi
  jg_question_signoff_available || { say "board cards cannot be read: sign-off-axi is not on PATH"; return 0; }
  board=$(jg_question_board)
  if [ -n "$board" ]; then
    json=$(sign-off-axi list "$board" --json 2>/dev/null) || json=''
  elif [ -n "${SIGN_OFF_HOME:-}" ]; then
    json=''
  else
    json=$(sign-off-axi list --json 2>/dev/null) || json=''
  fi
  [ -n "$json" ] || { say "board cards cannot be read: sign-off-axi list returned nothing; no card was touched"; return 0; }

  # An unreadable answers log or backlog leaves that whole evidence class
  # unanswered instead of guessing, so no card clears from it.
  answer_keys=''
  answers_log=''
  answers_alt=''
  answers=''
  if [ -n "$board" ]; then
    answers_log=$(jg_question_answers_log "$board")
    answers_alt=$(jg_question_answers_log "$(canonical_path "$board")")
    answers=$(answer_index) || answers=''
    answer_keys=$(printf '%s\n' "$answers" | cut -f1)
  fi
  resolved=$(resolved_index) || resolved=''
  logged=$(cut -f1 "$LOG" 2>/dev/null) || logged=''

  # One backlog read for the whole pass (jg_backlog_row_list is the single owner
  # of backlog reads, and row_state reads this one listing).
  ROWS=''
  BACKLOG_DATA=''
  if backlog_data=$(jg_backlog_data_absolute "$DATA" 2>/dev/null); then
    BACKLOG_DATA=$backlog_data
    ROWS=$(jg_backlog_row_list "$backlog_data" 2>/dev/null) || ROWS=''
  fi
  # Every task id this home knows, from a task record or a backlog row. A card
  # may only be tied to an id on this list, and to none other.
  KNOWN=$({
    for f in "$STATE"/*.meta; do
      [ -e "$f" ] || continue
      basename "$f" .meta
    done
    [ -z "$ROWS" ] || printf '%s\n' "$ROWS" | awk -F, '/^  /{t = $1; sub(/^ +/, "", t); print t}'
  })

  while IFS=$'\037' read -r key filer; do
    key_ok "$key" || continue
    open_before=$(( open_before + 1 ))
    reason='' evidence=''
    task=''
    task=$(card_task "$key" "$filer") || task=''
    if [ -n "$task" ] && hold_own_instruction "$task"; then
      reason=own-instruction
      evidence=$task
    elif [ -n "$answer_keys" ] && printf '%s\n' "$answer_keys" | grep -qxF -- "$key"; then
      reason=answered
      evidence=$(printf '%s\n' "$answers" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')
      [ -n "$evidence" ] || evidence=$answers_log
    elif line=$(printf '%s\n' "$resolved" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }') \
      && [ -n "$line" ]; then
      reason=resolved evidence=$line
    fi
    if [ -z "$reason" ] && [ -n "$task" ]; then
      rc=0
      evidence=$(merge_record "$task") || rc=$?
      if [ "$rc" -eq 0 ]; then
        reason=merged
      elif [ "$rc" -eq 2 ]; then
        keep_now="${keep_now}${key}"$'\t'"its merge record cannot be read"$'\n'
        continue
      elif [ -z "$ROWS" ]; then
        keep_now="${keep_now}${key}"$'\t'"its task $task is not readable in the backlog"$'\n'
        continue
      else
        row=$(row_state "$task")
        if [ "$row" = 'done' ]; then
          evidence=$backlog_data
          [ ! -f "$backlog_data/backlog.md" ] || evidence="$backlog_data/backlog.md"
          reason=closed
        elif [ -z "$row" ]; then
          keep_now="${keep_now}${key}"$'\t'"its task $task has no backlog row"$'\n'
          continue
        fi
      fi
    fi
    if [ -z "$reason" ]; then
      keep_now="${keep_now}${key}"$'\t'"no record settles it"$'\n'
      continue
    fi
    if [ -n "$dry" ]; then
      printf 'clear %s reason=%s evidence=%s\n' "$key" "$reason" "$evidence"
      cleared=$(( cleared + 1 ))
      continue
    fi
    if ! sign-off-axi dismiss "$key" ${board:+"$board"} --reason done-elsewhere >/dev/null 2>&1; then
      keep_now="${keep_now}${key}"$'\t'"sign-off-axi could not dismiss it"$'\n'
      continue
    fi
    # One line per card: a card already in the log is not logged again, so a
    # re-run or a slow dismiss cannot double-count it.
    printf '%s\n' "$logged" | grep -qxF -- "$key" \
      || printf '%s\t%s\t%s\n' "$key" "$reason" "$evidence" >> "$LOG" || die "cannot write $LOG"
    report="${report}cleared $key reason=$reason evidence=$evidence"$'\n'
    cleared=$(( cleared + 1 ))
  done < <(printf '%s\n' "$json" | jq -r '
    (.decisions // [])[] | select(.dismissed != true)
    | [.key, (.filer // "")]
    | map(tostring | gsub("[\n\r\t\u001f]"; " ")) | join("\u001f")' 2>/dev/null)

  # A kept line is printed only when it changed since the last pass, so a steady
  # board stays silent instead of waking Main every hour.
  local changed='' kept_count=0 previous
  previous=$(cat "$KEPT_RECORD" 2>/dev/null)
  while IFS=$'\t' read -r key reason; do
    key_ok "$key" || continue
    kept_count=$(( kept_count + 1 ))
    printf '%s\n' "$previous" | grep -qxF -- "$(printf '%s\t%s' "$key" "$reason")" && continue
    changed="${changed}kept $key: $reason"$'\n'
  done <<EOF
$keep_now
EOF

  if [ -n "$dry" ]; then
    while IFS=$'\t' read -r key reason; do
      key_ok "$key" && printf 'keep %s: %s\n' "$key" "$reason"
    done <<EOF
$keep_now
EOF
  else
    printf '%s' "$keep_now" > "$KEPT_RECORD"
    printf '%s' "$report"
    printf '%s' "$changed"
    : > "$STAMP"
  fi
  if [ -n "$dry" ] || [ "$cleared" -gt 0 ] || [ -n "$changed" ]; then
    printf 'reconcile: open %s -> %s, cleared %s, kept %s\n' \
      "$open_before" "$(( open_before - cleared ))" "$cleared" "$kept_count"
  fi
  return 0
}

cmd_arm() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.jg-decisions-reconcile.XXXXXX") || die "cannot write the check shim"
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check\n' "$JG_HOME" "$SCRIPT_DIR/jg-decisions-reconcile.sh" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$SHIM"; } || { rm -f -- "$tmp"; die "cannot write the check shim"; }
  JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-check-register.sh" decisions-reconcile || die "cannot register the check"
  cmd_check '' > /dev/null
  printf 'armed: decisions-reconcile\n'
}

DRY=''
FORCE=''
case "${1:-check}" in
  check|poll)
    shift || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        *) die "unknown option: $1" 2 ;;
      esac
      shift
    done
    [ -n "$FORCE" ] && rm -f -- "$STAMP"
    cmd_check "$DRY"
    ;;
  arm) cmd_arm ;;
  disarm) rm -f -- "$SHIM" "$STATE/decisions-reconcile.check-trust"; printf 'disarmed: decisions-reconcile\n' ;;
  -h|--help|help) usage ;;
  log)
    shift || true
    if [ "${1:-}" = "" ]; then cat "$LOG" 2>/dev/null; else tail -n "$1" "$LOG" 2>/dev/null; fi
    ;;
  *) die "unknown command: $1" 2 ;;
esac
