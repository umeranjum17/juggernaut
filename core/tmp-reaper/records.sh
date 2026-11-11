#!/usr/bin/env bash
# Remove what a finished task left behind in one juggernaut home: its volatile files and its merged lane branch.
# Usage: records.sh [--dry-run] check|state|landing|branches <jg-home>
#
# A task is finished when it has no record (state/<id>.meta) and no open ticket (`bin/jg-backlog.sh list`).
# Three sweeps, each over NAMED patterns only, so evidence is never touched:
#   state     state/<id>.{status,inbox,exit,turn-ended,busy-state,busy-gen,land-next} of a finished task, once nothing in
#             them changed for JG_RECORDS_AGE_DAYS days (default 7). Never state/<id>.meta, a receipt, or any other name.
#   landing   data/jg-trunk-landing/<id>.<head>.{state,log,reported,refusal,verify.log,post.log,tip,queue-why,seen,...}
#             of a finished task after the same age, and the landing's temporary output (<id>.<head>.request-*.log,
#             <id>.<head>.launch-*.log, batch.launch-*.log) of a finished task after JG_RECORDS_TMP_AGE_DAYS days
#             (default 1): the request log repeats <id>.<head>.log and the launch log only marks the start time.
#             This sweep runs at most once every 10 minutes (trunk-landing.sh check starts it).
#   branches  in each local-trunk project clone (state/trunk-branch-<project>), a local feature/* or fm/* branch that is
#             merged into the trunk, belongs to no task record and has not moved for the same age: `git branch -d`,
#             which refuses an unmerged or checked-out branch. Never a forge branch, never `-D`.
# Never data/<task>/. When the ticket list cannot be read, state and landing remove nothing.
# Each removal is appended to state/records-reaper.log. check runs all three and is the watcher-check form (silent).
set -u
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
case "${1:-}" in check|state|landing|branches) ;; *) echo "usage: records.sh [--dry-run] check|state|landing|branches <jg-home>" >&2; exit 2 ;; esac
[ "$#" -eq 2 ] && [ -d "$2/state" ] || { echo "usage: records.sh [--dry-run] check|state|landing|branches <jg-home>" >&2; exit 2; }
MODE=$1
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
MEM=$FMH/data/jg-trunk-landing
LOG=$STATE/records-reaper.log
ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
HEAD_RE='[0-9a-f]{40,64}'
age_days() { case ${!1:-} in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "${!1}" ;; esac; }
AGE_MIN=$(( $(age_days JG_RECORDS_AGE_DAYS 7) * 1440 ))
TMP_AGE_MIN=$(( $(age_days JG_RECORDS_TMP_AGE_DAYS 1) * 1440 ))
OPEN=$(mktemp "${TMPDIR:-/tmp}/jg-records-open.XXXXXX") || exit 0
trap 'rm -f -- "$OPEN"' EXIT

note() { printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$1" "$2" >> "$LOG"; }
has_record() { [ -e "$STATE/$1.meta" ]; }
# Ids of the open tickets, one per line. A failed read leaves OPEN_OK=0 and nothing that needs it is removed.
OPEN_OK=0
read_open() {
  local out
  out=$(JG_HOME="$FMH" "$FMH/bin/jg-backlog.sh" list 2>/dev/null) || return 0
  printf '%s\n' "$out" | grep -q '^count: ' || return 0
  printf '%s\n' "$out" | awk -F, '/^  [A-Za-z0-9]/ { sub(/^  /, "", $1); print $1 }' > "$OPEN"
  OPEN_OK=1
}
finished() { [[ $1 =~ $ID_RE ]] && [ "$OPEN_OK" = 1 ] && ! has_record "$1" && ! grep -qxF -- "$1" "$OPEN"; }
# Nothing at or under <path> changed within <minutes>.
quiet() { [ -z "$(find "$1" -mmin "-$2" -print -quit 2>/dev/null)" ]; }
remove() {  # <path> <root it must sit directly under>
  [ "$(dirname -- "$1")" = "$2" ] && [ ! -L "$1" ] || return 0
  if [ "$DRY" = 1 ]; then printf 'would remove %s\n' "$1"; return 0; fi
  rm -rf -- "$1" && note removed "$1"
}

sweep_state() {
  local f base sfx id
  for f in "$STATE"/*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    for sfx in status inbox exit turn-ended busy-state busy-gen land-next; do
      case $base in *."$sfx") ;; *) continue ;; esac
      id=${base%."$sfx"}
      finished "$id" && quiet "$f" "$AGE_MIN" && remove "$f" "$STATE"
      break
    done
  done
}

sweep_landing() {
  local f base id tmp stamp=$MEM/.records-reaped
  [ -d "$MEM" ] || return 0
  [ "$DRY" = 1 ] || [ -z "$(find "$stamp" -mmin -10 -print 2>/dev/null)" ] || return 0
  [ "$DRY" = 1 ] || : > "$stamp"
  for f in "$MEM"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base=${f##*/}; tmp=0
    if [[ $base =~ ^batch\.launch-[A-Za-z0-9]+\.log$ ]]; then
      tmp=1; id="batch"
    elif [[ $base =~ ^(.+)\.($HEAD_RE)\.(request|launch)-[A-Za-z0-9]+\.log$ ]]; then
      tmp=1; id=${BASH_REMATCH[1]}
    elif [[ $base =~ ^(.+)\.($HEAD_RE)\.(state|log|reported|refusal|refusal\.noted|verify\.log|post\.log|tip|queue-why|seen|retries)$ ]]; then
      id=${BASH_REMATCH[1]}
    else
      continue
    fi
    if [ "$id" = batch ]; then
      # A stack's launch log names no task: it goes with the age of its landing output.
      [ "$OPEN_OK" = 1 ] && quiet "$f" "$TMP_AGE_MIN" && remove "$f" "$MEM"
      continue
    fi
    if [ "$tmp" = 1 ]; then finished "$id" && quiet "$f" "$TMP_AGE_MIN" && remove "$f" "$MEM"
    else finished "$id" && quiet "$f" "$AGE_MIN" && remove "$f" "$MEM"; fi
  done
}

sweep_branches() {
  local proj pn trunk br id now ts rec
  rec=$(cat "$STATE"/*.meta 2>/dev/null | sed -n 's/^branch=//p')
  for proj in "$FMH"/projects/*; do
    [ -d "$proj" ] || continue
    pn=${proj##*/}
    trunk=$(cat "$STATE/trunk-branch-$pn" 2>/dev/null) || continue
    git -C "$proj" rev-parse --verify --quiet "refs/heads/$trunk^{commit}" >/dev/null || continue
    now=$(date +%s)
    while IFS= read -r br; do
      case $br in feature/*) id=${br#feature/} ;; fm/*) id=${br#fm/} ;; *) continue ;; esac
      [[ $id =~ $ID_RE ]] || continue
      ! has_record "$id" || continue
      printf '%s\n' "$rec" | grep -qxF -- "$br" && continue
      git -C "$proj" merge-base --is-ancestor "refs/heads/$br" "refs/heads/$trunk" || continue
      # The branch ref's last move; a branch just cut from the trunk tip is "merged" too, so it must have rested.
      ts=$(git -C "$proj" log -g -1 --date=unix --format=%gd "refs/heads/$br" 2>/dev/null | sed -n "s/.*@{\([0-9]*\)}.*/\1/p")
      [ -n "$ts" ] || ts=$(git -C "$proj" log -1 --format=%ct "refs/heads/$br")
      [ $(( now - ts )) -gt $(( AGE_MIN * 60 )) ] || continue
      if [ "$DRY" = 1 ]; then printf 'would delete branch %s in %s\n' "$br" "$pn"; continue; fi
      git -C "$proj" branch -d -- "$br" >/dev/null 2>&1 && note "deleted-branch" "$pn:$br"
    done < <(git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads/feature refs/heads/fm 2>/dev/null)
  done
}

case $MODE in state|landing|check) read_open ;; esac
case $MODE in
  state) sweep_state ;;
  landing) sweep_landing ;;
  branches) sweep_branches ;;
  check) sweep_state; sweep_landing; sweep_branches ;;
esac
exit 0
