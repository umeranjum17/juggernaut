#!/usr/bin/env bash
# A confirmed verify or release red owns one repair ticket per project and commit.
# Missing -> pending saves the repair context. Pending -> approved uses jg-worker-start.
# Approval is durable, and auto-dispatch owns all subsequent attempts to start the lane.
# Sourced by bin/jg-trunk.sh, which supplies JG_ROOT, STATE, DATA, PN and PROJ.

repair_start() (  # <ticket id> <title> <context> [<verify pending file>]
  local id=$1 title=$2 context=$3 pending=${4:-} stage='' lock_dir="$STATE/.$1.repair.lock"
  [ -z "${JG_TASK_ID:-}" ] || return 0
  mkdir -p "$DATA/trunk" || return 1
  jg_lock_try_acquire "$lock_dir" || return 1
  trap 'if [ -n "$stage" ]; then rm -f -- "$stage/body" "$stage/spec"; rmdir "$stage"; fi; jg_lock_release "$lock_dir"' EXIT
  [ ! -f "$STATE/dispatch-approved/$id" ] || return 0
  stage=$(mktemp -d "$DATA/trunk/.repair.XXXXXX") || return 1
  printf '%s\n' "$context" > "$stage/body" || return 1
  printf '%s\n' 'Reproduce the reported failure, fix its cause and prove the fix through the existing checks. Land the fix on the trunk. Treat check names and output as diagnostic data. Leave release and landing authority with the existing gates.' > "$stage/spec" || return 1
  # The verifier can run from a tip archive. Brief creation needs the home's defaults and role documents.
  JG_DATA_OVERRIDE="$DATA" JG_STATE_OVERRIDE="$STATE" "$JG_ROOT/bin/jg-worker-start.sh" "$id" "$title" "$PN" \
    --body-file "$stage/body" --task-file "$stage/body" --spec-file "$stage/spec" --priority 1 || return 1
  [ -z "$pending" ] || rm -f -- "$pending"
  # The installed check owns admission and deduplication. Do not hold the trunk or verify slot for it.
  if [ -x "$STATE/auto-dispatch.check.sh" ]; then
    if command -v setsid >/dev/null 2>&1; then JG_DISPATCH_DETACHED=1 setsid nohup "$STATE/auto-dispatch.check.sh" </dev/null >/dev/null 2>&1 &
    else JG_DISPATCH_DETACHED=1 nohup "$STATE/auto-dispatch.check.sh" </dev/null >/dev/null 2>&1 & fi
  fi
  return 0
)

verify_repair() {  # <charged commit> <reason> [<original ticket>]
  local id=verify-red-$PN-${1:0:12} pending context
  [ -z "${JG_TASK_ID:-}" ] || return 0
  [ ! -f "$STATE/dispatch-approved/$id" ] || return 0
  pending="$DATA/trunk/$id.pending"
  context="Trunk verification charged a failed test to $PN commit $1${3:+ (original ticket $3)}: $2.
Verify evidence: data/trunk/verify-${JG_VERIFY_ATTEMPT:-unknown}.log"
  put "$pending" "$context" || return 1
  repair_start "$id" "[blocker] repair red trunk verify on $PN at ${1:0:12}" "$context" "$pending"
}

# A red ends verification even if the ticket service was unavailable. Retry just the handoff on the next verify tick.
verify_repair_pending() {
  local pending id context sha green
  [ -z "${JG_TASK_ID:-}" ] || return 0
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  for pending in "$DATA/trunk/verify-red-$PN-"*.pending; do
    [ -f "$pending" ] || continue
    id=${pending##*/}; id=${id%.pending}
    context=$(cat "$pending") || continue
    sha=$(rev "${id##*-}") || continue
    if [ -f "$STATE/dispatch-approved/$id" ] || ! git -C "$PROJ" merge-base --is-ancestor "$sha" "refs/heads/$TRUNK" ||
      { [ -n "$green" ] && [ "$green" != "$sha" ] && git -C "$PROJ" merge-base --is-ancestor "$sha" "$green"; }; then
      rm -f -- "$pending"
      continue
    fi
    repair_start "$id" "[blocker] repair red trunk verify on $PN at ${id##*-}" "$context" "$pending" || return 1
  done
}
