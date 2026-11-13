#!/usr/bin/env bash
# pr-pager watcher check: every open pull request pages the lead who answers for it until it merges or closes. No model turn.
# Usage: pager.sh check <jg-home>
#
# For each project in <home>/data/projects.md whose clone has a github.com origin, and whose repository THIS home answers
# for (bin/jg-pr-owner.sh mine: Main's data/pr-owners.tsv, a repository with no line belongs to Main), this lists the open
# pull requests. A pull request at least JG_PR_PAGER_FIRST_MIN (15) minutes old gets a page, then one more every
# `pr-page-minutes` (trunk policy, 60) while it stays open. A page is one printed line, which the watcher turns into a check wake in
# this home's queue: the address, the age and commit count, the next step read from bin/jg-pr-state.sh (the red check by name,
# "green: merge it", "conflict: rebase", "draft: mark ready", "no checks: push"), and the page number.
# After 6 pages in a row with the same next step a lead home also appends one `note` line to its parent channel, so
# Main hears of a pull request its lead has not moved. A page never calls bin/jg-captain-say.sh: the owner is not paged.
# A local-trunk project whose release is due (release-after-commits unreleased commits, or the oldest one past release-after-hours: the rule of `jg-trunk.sh due` plus the count) and which has no
# open pull request from its trunk branch is paged the same way, as the episode `release`.
# Each pull request keeps one episode, state/.pr-pager/<owner__repo>/<number|release>: `since pages same last mainpaged step`.
# It ends, with no further page, when the pull request is no longer in the open list. A forge failure keeps the
# episodes and is retried next sweep. JG_PR_PAGER_GH names the gh-axi binary and JG_PR_PAGER_STATE the pr-state command (tests use stubs).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: pager.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
MEM=$STATE/.pr-pager
GH=${JG_PR_PAGER_GH:-gh-axi}
PRSTATE=${JG_PR_PAGER_STATE:-$FMH/bin/jg-pr-state.sh}
OWNER=$FMH/bin/jg-pr-owner.sh
umask 077
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
NOW=${JG_PR_PAGER_NOW:-$(date +%s)} # JG_PR_PAGER_NOW: tests move the clock
LIMIT=${JG_PR_PAGER_LIMIT:-$(( NOW + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))}
FIRST=$(( ${JG_PR_PAGER_FIRST_MIN:-15} * 60 ))
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$FMH/bin/jg-trunk-policy-lib.sh"
PAGE=$(( $(jg_trunk_policy pr-page-minutes) * 60 ))
AFTER_COMMITS=$(jg_trunk_policy release-after-commits)
AFTER_SECS=$(( $(jg_trunk_policy release-after-hours) * 3600 ))
ME=$(cat "$FMH/.jg-squad-lead-home" 2>/dev/null || true)
api() { timeout "$BUDGET" "$GH" api "$1" --jq "$2" 2>/dev/null; } # <path> <jq> -> jq text, nonzero on failure

# step <url> -> the next step in plain words, nonzero when the forge cannot say.
step() {
  local w
  w=$(timeout "$BUDGET" "$PRSTATE" --all --waiting-for "$1" 2>/dev/null | sed -n 's/^juggernaut\/waiting-for: //p' | head -n 1) && [ -n "$w" ] || return 1
  case $w in
    *'check is not passing: '*) printf 'red check "%s": fix its cause and push; never re-run or waive it\n' "${w##*passing: }" ;;
    *conflict*) echo 'conflict: rebase on the base branch and push' ;;
    *draft*) echo 'draft: mark it ready for review' ;;
    *'have not reported'*) echo 'no checks yet: push, or start the checks' ;;
    *'the merge call'*) echo 'green: merge it' ;;
    nothing*) return 1 ;;
    *) printf '%s\n' "$w" ;;
  esac
}

# page <dir> <id> <label> <step> <detail>: one episode, and one page when the first is due or `pr-page-minutes` passed since the last.
age() { if [ "$1" -lt 7200 ]; then echo "$(( $1 / 60 )) min"; else echo "$(( $1 / 3600 ))h"; fi; }
page() {
  local f=$1/$2 since=$NOW pages=0 same=0 last=0 mp=0 old='' n
  if [ -f "$f" ]; then IFS=$'\t' read -r since pages same last mp old < "$f" || :; fi
  case "$since$pages$same$last$mp" in *[!0-9]*|'') since=$NOW pages=0 same=0 last=0 mp=0 old='' ;; esac
  [ "$pages" -eq 0 ] || [ "$(( NOW - last ))" -ge "$PAGE" ] || return 0
  n=$(( pages + 1 ))
  if [ "$old" = "$4" ]; then same=$(( same + 1 )); else same=1 mp=0; fi
  printf 'pr-pager: %s%s: %s; page %s\n' "$3" "$5" "$4" "$n"
  if [ "$same" -ge 6 ] && [ "$mp" -eq 0 ] && [ -n "$ME" ] && report_main "$3: $4 (page $n)"; then mp=1; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$since" "$n" "$same" "$NOW" "$mp" "$4" > "$f.tmp" && mv -f "$f.tmp" "$f"
}

report_main() {  # <what>: one line on the parent channel, from the lead home only
  # shellcheck disable=SC2034 # JG_HOME is read by the sourced parent-channel library
  ( JG_HOME=$FMH
    # shellcheck source=bin/jg-parent-channel-lib.sh
    . "$FMH/bin/jg-parent-channel-lib.sh" && jg_parent_channel_report "$FMH" "$STATE" "note: pr-pager: $1; paged 6 times with no change; the lead has not moved it, so settle or reassign it" ) >/dev/null 2>&1
}

repos=$(sed -n 's/^- \(.*\)$/\1/p' "$FMH/data/projects.md" 2>/dev/null | while IFS= read -r line; do
  name=${line%% \[*}; name=${name%% - *}
  url=$(git -C "$FMH/projects/$name" remote get-url origin 2>/dev/null) || continue
  repo=$(printf '%s\n' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//')
  [ -z "$repo" ] || printf '%s\t%s\n' "$repo" "$name"
done | sort -u)

while IFS=$'\t' read -r repo proj; do
  [ -n "$repo" ] || continue
  dir=$MEM/${repo//\//__}
  if ! "$OWNER" mine "$repo" 2>/dev/null; then [ "$?" -ne 1 ] || rm -rf -- "$dir"; continue; fi # another home answers for it: no page, no episode
  [ "$(date +%s)" -lt "$LIMIT" ] || break
  prs=$(api "repos/$repo/pulls?state=open&per_page=100" '.[]|[.number,.html_url,.created_at,.head.ref]|@tsv') || continue
  mkdir -p "$dir"
  open=' '; trunk=''; headrefs=' '
  while IFS=$'\t' read -r num url created head; do
    [ -n "$num" ] || continue
    open="$open$num "; headrefs="$headrefs$head "
    cts=$(date -u -d "$created" +%s 2>/dev/null) || continue
    [ "$(( NOW - cts ))" -ge "$FIRST" ] || continue
    f=$dir/$num
    if [ -f "$f" ]; then IFS=$'\t' read -r _ _ _ last _ < "$f" || last=0; [ "$(( NOW - ${last:-0} ))" -ge "$PAGE" ] || continue; fi
    [ "$(date +%s)" -lt "$LIMIT" ] || break
    s=$(step "$url") || continue
    commits=$(api "repos/$repo/pulls/$num" .commits) || commits=
    page "$dir" "$num" "$url open $(age $(( NOW - cts )))" "$s" "${commits:+, $commits commits}"
  done <<< "$prs"
  for f in "$dir"/*; do [ -f "$f" ] || continue; n=${f##*/}; case "$open" in *" $n "*) ;; release) ;; *.tmp) ;; *) rm -f -- "$f" ;; esac; done
  # A due release with no pull request from the trunk branch.
  trunk=$(jg_project_trunk_branch "$FMH/projects/$proj" "$STATE" 2>/dev/null) || trunk=''
  if [ -z "$trunk" ] || { case "$headrefs" in *" $trunk "*) true ;; *) false ;; esac; }; then rm -f -- "$dir/release"; continue; fi
  released=$(cat "$STATE/trunk-released-$proj" 2>/dev/null) || continue
  count=$(git -C "$FMH/projects/$proj" rev-list --count "$released..refs/heads/$trunk" 2>/dev/null) || continue
  first=$(git -C "$FMH/projects/$proj" log --reverse --format=%ct "$released..refs/heads/$trunk" 2>/dev/null | head -n 1)
  if [ "${count:-0}" -ge "$AFTER_COMMITS" ] || { [ -n "$first" ] && [ "$(( NOW - first ))" -ge "$AFTER_SECS" ]; }; then
    page "$dir" release "release of $repo ($proj)" "release due, $count unreleased commits and no pull request: run bin/jg-trunk.sh release $FMH/projects/$proj" ''
  else
    rm -f -- "$dir/release"
  fi
done <<< "$repos"
exit 0
