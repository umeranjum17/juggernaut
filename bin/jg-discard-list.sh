#!/usr/bin/env bash
# jg-discard-list.sh - show the owner each old lane's unlanded result once, as its own card.
# Usage: jg-discard-list.sh [--dry-run] [--min-age-hours N]
#   JG_HOME picks the home whose task records are read (state/*.meta); run it once per home.
#
# For every ship record whose newest sign of life (status file, else record) is at least
# --min-age-hours old (default 48) and whose copy still exists, it asks the landed-work test
# (bin/jg-teardown-core.sh landed, the one owner of that question) and sorts the lane:
#   landed      The work is on the trunk (patch-equal, or its pull request merged). The lane is
#               cleaned with the ordinary UNFORCED bin/jg-teardown.sh. No word is needed:
#               nothing is discarded, and the teardown still refuses anything unproved.
#   open        Its pull request is still open. Left alone.
#   unlanded    Its pull request closed without a merge, or it has no pull request and its
#               worker stopped. ONE card per lane (bin/jg-question-card.sh, key discard-<id>,
#               category discard-unlanded) with the diff size and the age. Posting the same
#               lane again prints the card that is already open; it never adds a second.
#   left        Too recent, no copy, or the landed-work test could not run. Reported, untouched.
# One line per lane: "<id>  <class>  <what was done or why not>". The last line counts them.
#
# THE TOOL NEVER DISCARDS. It runs no --force and no teardown of unlanded work. After the owner
# says discard for a lane, the lead runs `bin/jg-teardown.sh <id> --force` for that lane alone;
# the card's yes is that word, and a no leaves the lane where it is.
# --dry-run prints the same lines (class "would clean" / "would card") and changes nothing.
# JG_DISCARD_LIST_TEARDOWN / JG_DISCARD_LIST_CARD name another teardown or card command (tests).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-ask-gate-lib.sh
. "$SCRIPT_DIR/jg-ask-gate-lib.sh"

TEARDOWN=${JG_DISCARD_LIST_TEARDOWN:-$SCRIPT_DIR/jg-teardown.sh}
CARD=${JG_DISCARD_LIST_CARD:-$SCRIPT_DIR/jg-question-card.sh}
DRY=0
MIN_AGE_HOURS=48
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --min-age-hours)
      shift
      case "${1:-}" in '' | *[!0-9]*) echo "jg-discard-list: --min-age-hours needs a whole number" >&2; exit 2 ;; esac
      MIN_AGE_HOURS=$1 ;;
    -h | --help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "usage: jg-discard-list.sh [--dry-run] [--min-age-hours N]" >&2; exit 2 ;;
  esac
  shift
done

meta_get() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | tail -1
}

mtime() {  # <file> -> epoch
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# The ref a lane's diff is measured against: the trunk or recorded base, else the default branch.
diff_base() {  # <worktree> <trunk> <base> <default>
  local wt=$1 b
  shift
  for b in "$@"; do
    [ -n "$b" ] || continue
    if git -C "$wt" rev-parse --verify -q "origin/$b^{commit}" >/dev/null 2>&1; then printf 'origin/%s\n' "$b"; return 0; fi
    if git -C "$wt" rev-parse --verify -q "$b^{commit}" >/dev/null 2>&1; then printf '%s\n' "$b"; return 0; fi
  done
  return 1
}

# "3 files, +40 -2 lines, 2 commits, 1 file not saved" - what the owner would lose.
diff_size() {  # <worktree> <base-ref-or-empty>
  local wt=$1 base=$2 files add del commits dirty out
  if [ -z "$base" ]; then
    out="size unknown"
  else
    read -r files add del < <(git -C "$wt" diff --numstat "$base...HEAD" 2>/dev/null | awk '{ f++; a += $1; d += $2 } END { printf "%d %d %d\n", f, a, d }')
    commits=$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)
    out="$files files, +$add -$del lines in $commits commits"
  fi
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" = 0 ] || out="$out, $dirty files not saved"
  printf '%s\n' "$out"
}

# The work's own words for the card: the last commit subject without its ticket prefix, or the
# project when that subject carries a name the owner's board refuses (bin/jg-ask-gate-lib.sh).
card_subject() {  # <worktree> <project-name>
  local s
  s=$(git -C "$1" log -1 --format=%s 2>/dev/null | sed -E 's/^[A-Za-z0-9._-]+: //' | cut -c1-80)
  if [ -z "$s" ] || [ -n "$(jg_ask_card_junk "$s")" ]; then
    printf 'the unfinished work on %s\n' "$2"
  else
    printf '"%s"\n' "$s"
  fi
}

landed_flags() {  # <project> <worktree> <pr-url> <base> -> sets LANDED_ARGS
  local project=$1 wt=$2 pr=$3 base=$4 trunk login
  LANDED_ARGS=(landed --worktree "$wt" --branch "$BRANCH" --project "$project")
  [ -z "$pr" ] || LANDED_ARGS+=(--pr-url "$pr")
  [ -z "$base" ] || LANDED_ARGS+=(--base-branch "$base")
  if trunk=$(jg_project_trunk_branch "$project" "$STATE") && [ -n "$trunk" ]; then
    LANDED_ARGS+=(--trunk-branch "$trunk")
  fi
  if [ -n "$pr" ]; then
    ! jg_dod_pr_outside_origin "$wt" "$pr" || LANDED_ARGS+=(--pr-outside-origin)
    if jg_pr_url_parse "$pr" && [ "$JG_PR_PROVIDER" = forgejo ]; then
      LANDED_ARGS+=(--forgejo-host "$JG_PR_HOST" --forgejo-path "$JG_PR_PATH" --forgejo-number "$JG_PR_NUMBER")
      ! login=$(jg_pr_forgejo_login "$JG_PR_HOST") || LANDED_ARGS+=(--forgejo-login "$login")
    fi
  fi
}

cleaned=0 carded=0 left=0 open=0
ERR=$(mktemp "${TMPDIR:-/tmp}/jg-discard-list.XXXXXX") || exit 1
trap 'rm -f -- "$ERR"' EXIT
now=$(date +%s)
shopt -s nullglob
for meta in "$STATE"/*.meta; do
  id=$(basename "$meta" .meta)
  kind=$(meta_get "$meta" kind)
  case "$kind" in squad_lead | scout) continue ;; esac
  wt=$(meta_get "$meta" worktree)
  project=$(meta_get "$meta" project)
  BRANCH=$(meta_get "$meta" branch)
  if [ -z "$wt" ] || [ ! -d "$wt" ] || [ -z "$project" ] || [ -z "$BRANCH" ]; then
    printf '%s\tleft\tno copy or branch is recorded\n' "$id"; left=$((left + 1)); continue
  fi
  stamp=$meta
  [ ! -e "$STATE/$id.status" ] || stamp=$STATE/$id.status
  age_h=$(( (now - $(mtime "$stamp")) / 3600 ))
  if [ "$age_h" -lt "$MIN_AGE_HOURS" ]; then
    printf '%s\tleft\tonly %s hours old (under %s)\n' "$id" "$age_h" "$MIN_AGE_HOURS"; left=$((left + 1)); continue
  fi

  pr=$(meta_get "$meta" pr)
  base=$(meta_get "$meta" base_branch)
  landed_flags "$project" "$wt" "$pr" "$base"
  rc=0
  out=$("$SCRIPT_DIR/jg-teardown-core.sh" "${LANDED_ARGS[@]}" 2>&1) || rc=$?
  gap=$(printf '%s\n' "$out" | sed -n 's/^gap=//p' | head -1)

  case "$rc" in
    0)
      if [ "$DRY" = 1 ]; then
        printf '%s\twould clean\tits work is on the trunk\n' "$id"; cleaned=$((cleaned + 1)); continue
      fi
      if "$TEARDOWN" "$id" >/dev/null 2>"$ERR"; then
        printf '%s\tcleaned\tits work is on the trunk; no word needed\n' "$id"; cleaned=$((cleaned + 1))
      else
        printf '%s\tleft\tlanded, but cleanup refused: %s\n' "$id" "$(tr '\n' ' ' <"$ERR" | cut -c1-160)"; left=$((left + 1))
      fi
      : ;;
    1)
      # The pull request is still open: not a leftover.
      if printf '%s' "$gap" | grep -Eqi ' as open, not merged'; then
        printf '%s\topen\tits pull request is still open\n' "$id"; open=$((open + 1)); continue
      fi
      default=$("$SCRIPT_DIR/jg-teardown-core.sh" default-branch --project "$project" 2>/dev/null || true)
      trunk=$(jg_project_trunk_branch "$project" "$STATE" 2>/dev/null || true)
      size=$(diff_size "$wt" "$(diff_base "$wt" "$trunk" "$base" "$default" || true)")
      if printf '%s' "$gap" | grep -Eqi ' as [a-z]+, not merged'; then
        why="Its pull request was closed without a merge."
      else
        why="It has no merged pull request and its worker has stopped."
      fi
      if [ "$DRY" = 1 ]; then
        printf '%s\twould card\t%s (%s, %s hours old)\n' "$id" "$why" "$size" "$age_h"; carded=$((carded + 1)); continue
      fi
      title="Throw away $(card_subject "$wt" "$(basename "$project")")?"
      key=$("$CARD" post --route main --ask-ref "$id" --key "discard-$id" --must discard-unlanded \
        --title "$title" \
        --why "$why It holds $size. It is $age_h hours old. Its work is not on the trunk." \
        --outcome yes="The work is thrown away for good. Nothing can bring it back." \
        --outcome no="The work stays as it is. The lead lands it or fixes it." 2>/dev/null | tail -1) || key=
      if [ -n "$key" ]; then
        printf '%s\tcarded\tcard %s: %s (%s, %s hours old)\n' "$id" "$key" "$why" "$size" "$age_h"; carded=$((carded + 1))
      else
        printf '%s\tleft\tthe card was refused or not posted; nothing was discarded\n' "$id"; left=$((left + 1))
      fi ;;
    *)
      printf '%s\tleft\tthe landed-work test could not run (exit %s)\n' "$id" "$rc"; left=$((left + 1)) ;;
  esac
done
printf 'cleaned=%s carded=%s open=%s left=%s%s\n' "$cleaned" "$carded" "$open" "$left" "$([ "$DRY" = 1 ] && echo ' (dry run)')"
