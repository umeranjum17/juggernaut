# shellcheck shell=bash
# Backlog store access for every script that reads or writes this home's backlog.
# Usage: . bin/jg-backlog-lib.sh
#
# The backlog is this home's Beads store, named by the absolute BEADS_DIR in
# `config/beads-dir`. jg_backlog_beads_read owns every read, jg_backlog_beads_write owns
# add, update, done, block, unblock, start, reopen, hold, unhold, relink, retag and the
# stage, take and drop a handoff moves rows with, and bin/jg-backlog.sh serves those
# verbs and refuses every other one. There is no other backend and no fallback: a
# home with no store named reports that, and its caller stops.

# Reads through bin/jg-beads.sh, the only way bd runs; bin/jg-beads-view.py owns the
# field mapping. bd's stderr carries routine warnings, so it surfaces only on failure.
# The store path is never derived, because a store inside a home's git clone is refused.
jg_backlog_beads_store() {  # <config_dir>: prints the BEADS_DIR, or refuses.
  local store
  store=$(tr -d '[:space:]' 2>/dev/null < "$1/beads-dir") || store=
  if [ -z "$store" ]; then
    printf 'jg-backlog: the beads backlog needs its store: put an absolute BEADS_DIR in %s/beads-dir\n' "$1" >&2
    return 2
  fi
  printf '%s\n' "$store"
}

# The task id of a ticket: its id with every dot made a dash (jg-x.1 gives jg-x-1, jg-x.1.1 gives jg-x-1-1).
# The ticket is given and the task id is made from it, never the other way; this is the one place that makes it.
jg_backlog_task_id() {  # <ticket-id> [<model>]
  if jg_backlog_model_is_fable "${2:-}"; then
    printf 'fable-%s\n' "${1//./-}"
  else
    printf '%s\n' "${1//./-}"
  fi
}

# A Fable model (claude-fable-5-2, with or without a provider prefix or a context suffix). A Fable worker works
# the ticket itself under the id fable-<task id>, so its trace and its model-guard allow entry name the ticket and
# no twin row exists.
jg_backlog_model_is_fable() {  # <model>
  case "${1##*/}" in *fable*) return 0 ;; *) return 1 ;; esac
}

# Prints the refusal line and returns 1 when <task-id> is not the id the ticket gives under <model>.
jg_backlog_task_id_refusal() {  # <ticket-id> <task-id> [<model>]
  local want
  want=$(jg_backlog_task_id "$1" "${3:-}")
  [ "$2" = "$want" ] && return 0
  if jg_backlog_model_is_fable "${3:-}"; then
    printf 'the task id for ticket %s on a Fable model is %s (fable- then every dot made a dash), not %s\n' "$1" "$want" "$2"
  elif [ "$2" = "fable-$want" ]; then
    printf 'the task id %s is for a Fable model; ticket %s on model %s runs as %s\n' "$2" "$1" "${3:-none}" "$want"
  else
    printf 'the task id for ticket %s is %s (every dot becomes a dash), not %s\n' "$1" "$want" "$2"
  fi
  return 1
}

# The readable-title rule a fresh spawn holds a ticket to: 2 to 7 words, at most 48 characters, no id
# (jg-..., Main<number>, 32 hex), no [tag], no URL or path. Prints the reason and returns 1 when the title fails.
# A row from before the type tag became a label (jg-backlog.sh retag) may still carry the tag at the front of its title,
# so the one leading type tag ([captain-ask], [feature], [design-ux], [security], [blocker]) is not judged with the words after it.
# A plan code is a short letters-and-digits word such as J20d-3, S18c, TC4b or mf-m2. It names a slice of a plan, not
# an outcome, so it goes in the body. Only the first word is judged: a number later in a plain title stays.
jg_backlog_title_starts_with_code() {  # <title>
  local first=${1%%[ :]*}
  [[ $first =~ ^[A-Za-z][A-Za-z0-9]*(-[A-Za-z0-9]+)*$ && $first =~ [0-9] ]]
}

jg_backlog_title_refusal() {  # <title>
  local title=$1 words
  case $title in
    '[captain-ask]'* | '[feature]'* | '[design-ux]'* | '[security]'* | '[blocker]'*) title=${title#*]}; title=${title# } ;;
  esac
  # shellcheck disable=SC2086  # splitting on blanks is the word count
  words=$(set -f; set -- $title; echo $#)
  if [ "$words" -lt 2 ] || [ "$words" -gt 7 ]; then
    printf 'it has %s words, not 2 to 7\n' "$words"
  elif [ "${#title}" -gt 48 ]; then
    printf 'it has %s characters, not 48 or fewer\n' "${#title}"
  elif [[ $title =~ \[[^]]*\] ]]; then
    printf 'it carries a [tag]\n'
  elif jg_backlog_title_starts_with_code "$title"; then
    printf 'it starts with a plan code (%s); the code belongs in the body\n' "${title%%[ :]*}"
  elif [[ $title =~ (^|[^[:alnum:]])(jg-[[:alnum:]]|Main[0-9]|[0-9a-f]{32}) ]]; then
    printf 'it carries an id\n'
  elif [[ $title =~ ://|/ ]]; then
    printf 'it carries a URL or path\n'
  else
    return 0
  fi
  return 1
}

# The backlog as markdown lines, rendered from the store.
jg_backlog_text() {  # <config_dir> [<backlog_file>]
  jg_backlog_beads_read "$1" markdown
}

# The start checks' one line on this home's store: the summary of `jg-beads.sh check`, or why it failed.
jg_backlog_beads_health() {  # <config_dir>
  local bin_dir store out rc=0
  store=$(jg_backlog_beads_store "$1" 2>&1) || { printf '%s\n' "$store"; return 2; }
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  out=$(JG_HOME="${1%/*}" "$bin_dir/jg-beads.sh" check 2>&1) || rc=$?
  printf '%s\n' "${out##*$'\n'}"
  return "$rc"
}

jg_backlog_beads_write() {  # <config_dir> <a verb of bin/jg-beads-write.py> [args...]
  local bin_dir store
  local config=$1 row labels id
  store=$(jg_backlog_beads_store "$config") || return 2
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  case "${1:-}" in
    done|close)
      id=${2:-}
      row=$(jg_backlog_beads_read "$config" show "$id" --full) || { echo "cannot read ticket $id for closure gate" >&2; return 1; }
      labels=$(printf '%s\n' "$row" | sed -n 's/^  labels: //p')
      labels=${labels#\"}; labels=${labels%\"}
      case ",$labels," in
        *,bottleneck-fix,*)
          "$bin_dir/jg-closure-proof.sh" "$id" | python3 "$bin_dir/jg-closure-gate.py" - "$id" || return 1 ;;
      esac ;;
  esac
  BEADS_DIR=$store JG_HOME="${config%/*}" python3 "$bin_dir/jg-beads-write.py" "$@" || return $?
  # Every writer comes through here, so none leaves the copy behind (stage only reads).
  [ "${1:-}" = stage ] || jg_backlog_one_engine_copy "$config" "$@"
}

# The rows a read needs, as bd's JSON. Sets `one` (the id a fast show fetched) and `open` (a listing left its closed rows out) for the caller.
# It leaves its mode in <err_file>.mode (one or open) for the caller, since a command substitution cannot set the caller's variables.
# A show asks bd for its one row and falls back to the whole store for a row it cannot name (a moved row's old name, an unknown id).
# bd hides gate rows from a list, so every list asks for them (--include-gates): the view keeps them out of the work and reads them as questions.
# A plain list asks bd for the open rows only; --all, --state done and every other verb read the whole store.
# JG_BACKLOG_SNAPSHOT names one file per supervision cycle: the first whole read fills it, and every later list or whole read of that cycle reuses it.
jg_backlog_beads_rows() {  # <home> <bin_dir> <err_file> <verb> [args...]: prints rows
  local home=$1 bin_dir=$2 err=$3 verb=${4:-} word id="" snap=${JG_BACKLOG_SNAPSHOT:-} history="" out one open=""
  shift 4
  case "$verb" in
    show|view)
      for word in "$@"; do case "$word" in -*) ;; *) id=$word ;; esac; done
      if [ -n "$id" ] && out=$(JG_HOME=$home "$bin_dir/jg-beads.sh" show "$id" --json 2>>"$err") \
        && one=$(printf '%s' "$out" | python3 "$bin_dir/jg-beads-view.py" --one "$id" 2>/dev/null); then
        printf 'partial' >"$err.mode"
        printf '%s' "$one"
        return 0
      fi ;;
    list|questions)
      case " $* " in *" --all "*|*" --state done "*|*" --state=done "*) history=1 ;; esac
      [ -n "$history" ] || [ -n "$snap" ] || open=1 ;;
  esac
  [ -z "$open" ] || printf 'partial' >"$err.mode"
  if [ -n "$snap" ] && [ -s "$snap" ]; then
    cat -- "$snap"
    return 0
  fi
  if [ -n "$open" ]; then
    JG_HOME=$home "$bin_dir/jg-beads.sh" list --status open,in_progress,on_hold,blocked,deferred --limit 0 --include-gates --json 2>>"$err"
    return
  fi
  out=$(JG_HOME=$home "$bin_dir/jg-beads.sh" list --all --limit 0 --include-gates --json 2>>"$err") || return
  [ -z "$snap" ] || { printf '%s' "$out" >"$snap.$$" && mv -f -- "$snap.$$" "$snap"; } 2>/dev/null
  printf '%s' "$out"
}

# Beads answers ready and blocked, so the read asks bd for them before it lists the rows:
# `bd ready` first, because that call wakes a dated hold whose day has come and the listing must show it awake.
# A list asks `bd blocked` only when it shows blocked rows or the blocked fields, because the call costs about 0.3 s.
jg_backlog_beads_read() {  # <config_dir> <show|view|list|ready|markdown|links|questions> [args...]
  local bin_dir store home err rows rc=0 scratch word repo="" want_ready="" want_blocked="" partial=""
  store=$(jg_backlog_beads_store "$1") || return 2
  home=${1%/*}
  shift
  bin_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  case "${1:-}" in
    ready) want_ready=1 ;;
    show|view) want_blocked=1 ;;
    list) case " $* " in *blocked*) want_blocked=1 ;; esac ;;
  esac
  scratch=$(mktemp -d) || return 2
  err=$scratch/err
  if [ -n "$want_ready" ]; then
    for word in "${@:2}"; do
      case "$word" in --repo=*) repo=${word#--repo=} ;; --repo) repo=- ;; *) [ "$repo" = - ] && repo=$word ;; esac
    done
    [ "$repo" = - ] && repo=""
    JG_HOME=$home "$bin_dir/jg-beads.sh" ready --limit 0 --json ${repo:+--label "project:$repo"} >"$scratch/ready" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -n "$want_blocked" ]; then
    JG_HOME=$home "$bin_dir/jg-beads.sh" blocked --json >"$scratch/blocked" 2>"$err" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    rows=$(jg_backlog_beads_rows "$home" "$bin_dir" "$err" "$@") || rc=$?
    [ ! -e "$err.mode" ] || partial=1
  fi
  [ "$rc" -eq 0 ] || cat -- "$err" >&2
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$rows" | JG_BEADS_READY=${want_ready:+$scratch/ready} JG_BEADS_BLOCKED=${want_blocked:+$scratch/blocked} \
      JG_BEADS_PARTIAL=$partial python3 "$bin_dir/jg-beads-view.py" "$@" || rc=$?
  fi
  rm -f -- "$scratch/ready" "$scratch/blocked" "$scratch/err" "$scratch/err.mode"
  rmdir -- "$scratch"
  return "$rc"
}

# One engine (header of bin/jg-backlog.sh): the write a home just made to Beads, copied into the item store's ticket tables under
# that home's id. Every writer calls this after its own write, so no path leaves the copy behind. A failed copy prints one line and
# never fails the Beads write.
jg_backlog_one_engine_copy() {  # <config_dir> <verb> [args...]
  local config=$1 home root copy
  shift
  home=${config%/*}
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  copy=$(JG_HOME="$home" BEADS_DIR=$(jg_backlog_beads_store "$config") \
    python3 "$root/core/item-store/adapters/tickets.py" write "$@" --source "jg-backlog:$$:$(date +%s%N)" 2>&1) \
    || printf 'jg-backlog: one-engine copy: %s\n' "$(printf '%s' "$copy" | head -n 1)" >&2
  return 0
}

# One verb, read or write, for bin/jg-backlog-transition-lib.sh's row calls (spawn start, teardown close) and the captain-hold scripts.
jg_backlog_beads_serve() {  # <config_dir> <verb> [args...]
  local config=$1
  case "${2:-}" in
    show|view|list|ready|links|questions)
      shift
      jg_backlog_beads_read "$config" "$@"
      ;;
    *) jg_backlog_beads_write "$@" ;;
  esac
}

# A short title for a ticket a script files by itself: 2 to 7 plain words, at most 48 characters, with no [tag], id, URL or path in it.
# The words it was cut from belong in the ticket body. Prints the title built from <text>, or <fallback> when fewer than 2 plain words remain.
jg_backlog_short_title() {  # <text> <fallback>
  local text=$1 fallback=$2 word out='' n=0
  text=$(printf '%s' "${text%%$'\n'*}" | sed -E 's/\[[A-Za-z-]+\]//g')
  for word in $text; do
    case "$word" in */*|jg-*|Main[0-9]*) continue ;; esac
    [[ $word =~ ^[0-9a-f]{32}$ ]] && continue
    [ "$n" -lt 7 ] || break
    [ "${#out}" -eq 0 ] && [ "${#word}" -gt 48 ] && continue
    [ $(( ${#out} + ${#word} + 1 )) -le 48 ] || break
    out=${out:+$out }$word; n=$((n + 1))
  done
  if [ "$n" -ge 2 ]; then printf '%s\n' "$out"; else printf '%s\n' "$fallback"; fi
}
