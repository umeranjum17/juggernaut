#!/usr/bin/env bash
# Route durable sign-off Go deeper asks to the matching Juggernaut task inbox.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail

JG_ROOT=${JG_ROOT_OVERRIDE:-${JG_HOME:?set JG_HOME}/}
JG_ROOT=${JG_ROOT%/}
STATE=${JG_STATE_OVERRIDE:-$JG_ROOT/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_ROOT/config}
SIGNOFF=${SIGN_OFF_CLI:-sign-off-axi}
# shellcheck source=/dev/null
. "$JG_ROOT/bin/jg-task-inbox-lib.sh"
usage() { echo 'usage: jg-engage-route.sh dispatch <board.json> | bind <filer> <task-id>' >&2; exit 2; }
finished() { grep -Eq '^(done|failed|cancelled|finished) \[at=[0-9]+\]:' "$STATE/$1.status" 2>/dev/null; }
[ "$#" -ge 1 ] || usage
cmd=$1; shift
case $cmd in
  bind)
    [ "$#" = 2 ] || usage
    [[ $1 =~ ^[A-Za-z0-9._-]{1,128}$ && $2 =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { echo 'filer and task id must be 1-128 safe characters' >&2; exit 2; }
    mkdir -p "$CONFIG"
    file=$CONFIG/engage-owners
    tmp=$(mktemp "$CONFIG/.engage-owners.XXXXXX")
    if [ -f "$file" ]; then awk -F '\t' -v f="$1" '$1 != f' "$file" > "$tmp"; fi
    printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mv "$tmp" "$file"
    ;;
  dispatch)
    [ "$#" = 1 ] && [ -f "$1" ] || usage
    board=$1
    # Read only filer metadata and open requests; this never touches answers or captain holds.
    filers=$("$SIGNOFF" list "$board" --json | jq -r '.decisions[] | .filer // empty' | sort -u)
    while IFS= read -r filer; do
      [ -n "$filer" ] || continue
      [[ $filer =~ ^[A-Za-z0-9._-]{1,128}$ ]] || continue
      task=$filer
      if [ -f "$CONFIG/engage-owners" ]; then
        override=$(awk -F '\t' -v f="$filer" '$1 == f { print $2; exit }' "$CONFIG/engage-owners")
        [ -z "$override" ] || task=$override
      fi
      [[ $task =~ ^[A-Za-z0-9._-]{1,128}$ ]] || { echo "invalid owner task id for filer $filer" >&2; continue; }
      asks=$("$SIGNOFF" deeper "$board" --filer "$filer" --json --all | jq -c '.deeper[]? | select(.done != true)')
      while IFS= read -r ask; do
        [ -n "$ask" ] || continue
        id=$(jq -r '.id' <<<"$ask")
        meta=$STATE/$task.meta
        if [ ! -f "$meta" ]; then
          reason="no owner record for filer $filer"
          finished "$task" && reason="owner task $task is finished"
          printf '%s\tqueued\t%s\n' "$id" "$reason" >> "$STATE/engage-route.log"
          continue
        fi
        if finished "$task"; then
          printf '%s\tqueued\towner task %s is finished\n' "$id" "$task" >> "$STATE/engage-route.log"
          continue
        fi
        message=$(jq -r '"Sign-off engagement request " + .id + " for filer " + .key + " (" + .part + "): " + (.q // "Go deeper")' <<<"$ask")
        handled=$(for existing in "$STATE/$task.inbox/handled/"*.msg; do
          [ -f "$existing" ] || continue
          [ "$(jg_task_inbox_body "$existing")" != "$message" ] || { printf '%s' "$existing"; break; }
        done)
        if [ -n "$handled" ]; then
          printf '%s\towner-ack\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
          continue
        fi
        # The inbox library deduplicates exact request bodies across replay.
        record=$(jg_task_inbox_write_idempotent "$STATE" "$task" "$message")
        backend=$(jg_backend_of_meta "$meta")
        target=$(jg_backend_target_of_meta "$meta")
        [ -n "$target" ] || { echo "no endpoint for owner task $task" >&2; continue; }
        if [[ $record == */handled/* ]]; then
          printf '%s\towner-ack\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
        else
          if ! jg_task_inbox_ring "$backend" "$target" "$record" "jg-$task"; then
            echo "request $id is in the owner inbox, but ringing $task failed: ${JG_TASK_INBOX_RING_REASON:-endpoint unavailable}" >&2
          fi
          printf '%s\tinbox-recorded\t%s\n' "$id" "$task" >> "$STATE/engage-route.log"
        fi
      done <<< "$asks"
    done <<< "$filers"
    ;;
  *) usage ;;
esac
