#!/usr/bin/env bash
# lead-sweep watcher check: every beat, clean up the landed lanes of this home, unforced, with no model turn.
# Usage: lead-sweep.sh check <jg-home>
#
# A lane of this home (state/<id>.meta, kind ship or scout) whose latest status line is `done` or `resolved` (an answered
# lane) is swept when it has landed:
#   - ship: its branch head is on the trunk and is not the commit the lane started on (meta base=) (state/trunk-tip-<project> for a local-trunk project, else the default branch
#     of the clone), or its recorded pull request is merged (GitHub only, asked at most every JG_LEAD_SWEEP_PR_MIN
#     minutes, default 10, per lane);
#   - scout (Recon): its report data/<id>/report.md exists.
# The sweep then runs `bin/jg-teardown.sh <id>` and nothing else: no --force, ever. The teardown owns the landed-work test
# and every gate (unlanded or dirty work, the report, captain-call inventory and depth gates), so a lane with unlanded work
# or a failing gate is refused and left alone. A lane a landing is running for (state/.trunk-run-<id>-*.lock) is skipped.
# A `resolved` lane that has not landed is left alone and reported once (`lead-sweep: <id> ended as resolved, left alone: ...`);
# a `done` lane that has not landed is waiting for its landing and prints nothing.
# Output, which becomes a check wake: `lead-sweep: <id> cleaned up (<why>)` once, and `lead-sweep: <id> not cleaned up ...`
# once per lane and reason (data/lead-sweep/<id>.reported); the same refusal on the next beat prints nothing.
# JG_LEAD_SWEEP_TEARDOWN and JG_LEAD_SWEEP_GH name the teardown and gh-axi commands (tests point them at stubs).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: lead-sweep.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state
MEM=$FMH/data/lead-sweep
TEARDOWN=${JG_LEAD_SWEEP_TEARDOWN:-$FMH/bin/jg-teardown.sh}
GH=${JG_LEAD_SWEEP_GH:-gh-axi}
PR_MIN=${JG_LEAD_SWEEP_PR_MIN:-10}; case $PR_MIN in ''|*[!0-9]*) PR_MIN=10 ;; esac
umask 077
mkdir -p "$MEM" || exit 0
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# why_landed <meta> <project> <branch>: prints why the ship lane counts as landed; prints nothing when it does not.
why_landed() {
  local id=${1##*/} head base target tipf pr slug num asked
  id=${id%.meta}
  head=$(git -C "$2" rev-parse --verify --quiet "refs/heads/$3^{commit}") || head=
  # A lane still on the commit it started on holds no work: that head is an ancestor of the trunk, yet nothing landed.
  base=$(mval "$1" base)
  [ -z "$base" ] || [ "$head" != "$base" ] || return 0
  tipf=$STATE/trunk-tip-$(basename "$2")
  if [ -s "$tipf" ]; then target=$(cat "$tipf"); else target=$(git -C "$2" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || target=; fi
  if [ -n "$head" ] && [ -n "$target" ] && git -C "$2" merge-base --is-ancestor "$head" "$target" 2>/dev/null; then
    echo 'its head is on the trunk'; return 0
  fi
  pr=$(mval "$1" pr)
  slug=$(printf '%s\n' "$pr" | sed -n 's#^https://github\.com/\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)/pull/[0-9]*$#\1#p')
  num=${pr##*/}
  [ -n "$slug" ] || return 0
  asked=$MEM/$id.asked
  [ -z "$(find "$asked" -mmin "-$PR_MIN" 2>/dev/null)" ] || return 0
  : > "$asked"
  [ "$(timeout 20 "$GH" api "repos/$slug/pulls/$num" --jq .merged 2>/dev/null)" = true ] && echo 'its pull request is merged'
  return 0
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  kind=$(mval "$meta" kind)
  case $kind in ship|scout) ;; *) continue ;; esac
  case $(tail -n 1 "$STATE/$id.status" 2>/dev/null) in
    done\ *|done:*) ended='done' ;;
    resolved\ *|resolved:*) ended=resolved ;;
    *) continue ;;
  esac
  ls "$STATE"/.trunk-run-"$id"-*.lock >/dev/null 2>&1 && continue
  why=
  if [ "$kind" = scout ]; then
    [ ! -s "$FMH/data/$id/report.md" ] || why='its report exists'
  else
    proj=$(mval "$meta" project); branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
    [ ! -d "$proj" ] || why=$(why_landed "$meta" "$proj" "$branch")
  fi
  if [ -z "$why" ]; then
    # Only an answered lane is reported: nothing else will ever revisit it. A done lane is waiting for its landing.
    if [ "$ended" = resolved ] && [ "$(cat "$MEM/$id.reported" 2>/dev/null)" != unlanded ]; then
      echo unlanded > "$MEM/$id.reported"
      echo "lead-sweep: $id ended as resolved, left alone: its work has not landed on the trunk"
    fi
    continue
  fi
  rc=0
  out=$(JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$TEARDOWN" "$id" 2>&1) || rc=$?
  last=$(printf '%s\n' "$out" | grep -E '^(REFUSED|error)' | tail -n 1)
  [ -n "$last" ] || last=$(printf '%s\n' "$out" | tail -n 1)
  last=$(printf '%s' "$last" | cut -c1-200)
  case $rc in
    0) rm -f -- "$MEM/$id.reported" "$MEM/$id.asked"; echo "lead-sweep: $id cleaned up ($why)" ;;
    4) rm -f -- "$MEM/$id.reported" "$MEM/$id.asked"; echo "lead-sweep: $id cleaned up ($why), but a returned worktree slot was lost: $last" ;;
    *)
      [ "$(cat "$MEM/$id.reported" 2>/dev/null)" != "$last" ] || continue
      printf '%s\n' "$last" > "$MEM/$id.reported"
      echo "lead-sweep: $id ($why) not cleaned up, nothing was forced: ${last:-the cleanup was refused}" ;;
  esac
done
exit 0
