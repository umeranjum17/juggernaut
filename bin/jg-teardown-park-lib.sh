#!/usr/bin/env bash
# shellcheck shell=bash
# jg-teardown-park-lib.sh - the parking of a lane for `bin/jg-teardown.sh <id> --park`.
#
# A parked lane keeps its branch and one small record (state/<id>.parked); its copy and its pane are given back.
# Parking is not a cleanup: the work is not landed, so the ship's landed-work test does not apply. Its place is taken
# by this one rule, and nothing else may return a parked lane's copy:
#
#   a copy is given back only when it is clean and its HEAD is the tip of the lane's branch.
#
# Clean is the same test the cleanup uses (nothing uncommitted; the untracked files the fleet's own hooks leave are
# exempt, core/teardown/cmd/jg-teardown/safety.go). The branch is the one the lane's record names, else the one the
# copy has checked out. The branch lives in the project's shared repository, so returning the copy never touches it,
# and the head is then on the branch by name and by commit.
#
# A park that stopped after the copy was returned is finished by the same command: with no copy there is nothing to
# lose, and the rule only asks that the branch still exist.
#
# The park record is key=value lines, written whole or not at all:
#   task, kind, project, mode, branch, head (the branch tip at the park), backend, pr (when one was recorded), parked_at
# The lane's status log, its steering inbox and data/<id>/ stay as they are, so the lead that parks a lane can steer it
# again and a later spawn finds its brief.
#
# This file defines functions only. The caller (bin/jg-teardown.sh) owns the locks, the endpoint close, the return of
# the copy and the record removal, and has these names set: ID STATE WT PROJ KIND MODE BACKEND PR_URL META.

# Exempt untracked paths: the same two shapes as exemptDirt in core/teardown/cmd/jg-teardown/safety.go.
TEARDOWN_PARK_EXEMPT_DIRT='^\?\? (\.claude/|\.jg-(grok|kimi)-turnend$)'
# Set by teardown_park_gate: the branch and the commit the record will name.
TEARDOWN_PARK_BRANCH=
TEARDOWN_PARK_HEAD=

# teardown_park_refuse <sentence>...: print a refusal that changed nothing.
teardown_park_refuse() {
  local line
  for line in "$@"; do echo "REFUSED: $line" >&2; done
  echo "Nothing was changed. Commit or discard the work in the copy, or land the lane, then park it again." >&2
  return 1
}

# teardown_park_kind_check: only a ship lane is parked; a Recon copy is scratch and a Squad Lead home is not a lane.
teardown_park_kind_check() {
  [ "$KIND" = ship ] && return 0
  teardown_park_refuse "$ID is a $KIND, and only a ship lane can be parked."
}

# teardown_park_gate [branch-only]: 0 when the copy may be given back. Sets TEARDOWN_PARK_BRANCH and TEARDOWN_PARK_HEAD.
# With `branch-only` the copy is not read, because it is gone or is no longer this lane's (a slot another task holds).
teardown_park_gate() {
  local recorded current repo dirty line kept tip head copy=1
  recorded=$(jg_meta_get "$META" branch)
  repo=$WT
  { [ "${1:-}" != branch-only ] && [ -d "$WT" ]; } || copy=0
  if [ "$copy" = 0 ]; then
    # The copy is already back (a park that stopped before its record was written): only the branch is left to prove.
    [ -n "$recorded" ] || { teardown_park_refuse "$ID has no copy at ${WT:-<missing>} and its record names no branch."; return 1; }
    repo=$PROJ
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
      || { teardown_park_refuse "$ID has no copy and its project $PROJ is not a readable repository, so its branch cannot be proved."; return 1; }
  else
    git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || { teardown_park_refuse "the copy of $ID at $WT is not a readable git worktree, so it cannot be proved clean."; return 1; }
    dirty=$(git -C "$WT" status --porcelain) \
      || { teardown_park_refuse "the copy of $ID at $WT cannot be read for uncommitted changes."; return 1; }
    kept=
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line" | grep -Eq "$TEARDOWN_PARK_EXEMPT_DIRT" || kept+="$line"$'\n'
    done <<EOF_DIRT
$dirty
EOF_DIRT
    if [ -n "$kept" ]; then
      printf '%s' "$kept" | head -n 10 | sed 's/^/  /' >&2
      teardown_park_refuse "the copy of $ID at $WT holds uncommitted work (above); returning it would drop that work."
      return 1
    fi
    current=$(git -C "$WT" symbolic-ref -q --short HEAD 2>/dev/null || true)
  fi
  TEARDOWN_PARK_BRANCH=${recorded:-$current}
  [ -n "$TEARDOWN_PARK_BRANCH" ] \
    || { teardown_park_refuse "$ID's copy is on no branch and its record names none, so there is no branch to keep."; return 1; }
  tip=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$TEARDOWN_PARK_BRANCH^{commit}" 2>/dev/null || true)
  [ -n "$tip" ] \
    || { teardown_park_refuse "the branch $TEARDOWN_PARK_BRANCH of $ID does not exist in $PROJ, so there is nothing to keep."; return 1; }
  if [ "$copy" = 1 ]; then
    head=$(git -C "$WT" rev-parse --verify --quiet HEAD 2>/dev/null || true)
    [ "$head" = "$tip" ] \
      || { teardown_park_refuse "the copy of $ID is at ${head:-no commit}, not at the tip ${tip} of its branch $TEARDOWN_PARK_BRANCH; returning it would drop the commits between them."; return 1; }
  fi
  TEARDOWN_PARK_HEAD=$tip
}

# teardown_park_write_record: write state/<id>.parked whole (a temporary file moved into place).
teardown_park_write_record() {
  local out="$STATE/$ID.parked" tmp
  tmp=$(mktemp "$STATE/.$ID.parked.XXXXXX") || return 1
  {
    printf 'task=%s\n' "$ID"
    printf 'kind=%s\n' "$KIND"
    printf 'project=%s\n' "$PROJ"
    printf 'mode=%s\n' "$MODE"
    printf 'branch=%s\n' "$TEARDOWN_PARK_BRANCH"
    printf 'head=%s\n' "$TEARDOWN_PARK_HEAD"
    printf 'backend=%s\n' "$BACKEND"
    [ -z "${PR_URL:-}" ] || printf 'pr=%s\n' "$PR_URL"
    printf 'parked_at=%s\n' "$(date +%s)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$out" || { rm -f -- "$tmp"; return 1; }
}

# teardown_park_runtime_state_retire: remove what belongs to the pane that was closed. The status log, the steering
# inbox and data/<id>/ are kept.
teardown_park_runtime_state_retire() {
  local task_tmp=${1:-}
  [ -z "$task_tmp" ] || rm -rf -- "$task_tmp"
  rm -f -- "$STATE/$ID.turn-ended" "$STATE/$ID.progress" "$STATE/$ID.lane-groups" \
    "$STATE/$ID.pi-ext.ts" "$STATE/$ID.omp-ext.ts" "$STATE/$ID.grok-turnend-token" \
    "$STATE/$ID.kimi-turnend-token" "$STATE/$ID.muse-session" "$STATE/$ID.muse-session-current" \
    "$STATE/$ID.cursor-session" "$STATE/$ID.gemini-settings.json" "$STATE/$ID.claude-settings.json" \
    "$STATE/$ID.devin-config.json" "$STATE/$ID.models"
  chmod u+w "$STATE/$ID.git-hooks" 2>/dev/null || true
  rm -rf -- "$STATE/$ID.git-hooks"
}
