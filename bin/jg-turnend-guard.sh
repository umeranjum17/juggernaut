#!/usr/bin/env bash
# Turn-end guard for any juggernaut PRIMARY session: the main home OR a
# squad_lead's own home. A squad_lead runs its own primary juggernaut session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# jg-guard.sh (bin/jg-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes. Cursor calls
# this guard back with --cursor from bin/jg-turnend-guard-cursor.sh and renders
# exit 2 as one bounded follow-up, because exit 2 is a silent no-op on Cursor's
# stop step; without that flag a Cursor-shaped payload is the Claude-settings
# duplicate Cursor also loads, and this guard stands down.
# See docs/turnend-guard.md for the per-harness mechanics, validation evidence,
# and fail-open tradeoffs.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# squad_lead home (treehouse-leased or git-cloned), and any operator/scout task
# worktree spawned to work on juggernaut itself (the recursive "juggernaut
# improving itself" case). A squad_lead home runs its OWN primary juggernaut
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked squad_lead home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Away mode (state/.afk): the away-mode daemon owns supervision and runs the
# watcher one-shot, restarting it after every wake, so the watch lock is
# regularly unheld at a turn boundary with nothing wrong. A live
# identity-matched daemon holding this home, plus a fresh beacon, is what
# proves supervision there - see jg_afk_daemon_owns_supervision in
# bin/jg-wake-lib.sh. The beacon freshness test there uses AFK_GRACE
# (jg_poll_derived_grace, docs/turnend-guard.md "Guard grace and the poll
# cadence"), not the flat $GRACE every other check on this page uses: the
# daemon starts a fresh one-shot watcher only after it finishes handling the
# previous wake, and that handling can legitimately run past a flat 300s
# window under load (a slow registered check, a busy supervisor pane) with the
# daemon perfectly healthy throughout. The strict watcher predicate and $GRACE
# are unchanged everywhere else, including for a dead daemon pid or a beacon
# older than AFK_GRACE, which still block.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/jg-claude-stop-autoarm.sh), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon - or, in away mode, a
#      live identity-matched daemon with a fresh beacon - allows immediately;
#   2. an unhealthy session with a verified live session-lock owner it does not
#      own under the shared ancestry-or-trusted-id verdict exits with a read-only
#      diagnostic instead of blocking a session that cannot repair supervision
#      without stealing ownership;
#   3. otherwise wait briefly (JG_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (a live OPEN generation claim in the
#      state/.claude-autoarm-epoch ledger - jg_autoarm_claim_open - or a legacy
#      build's lock-holding claim under the legacy abandonment proof) or to
#      record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one recovery turn;
#      the first fresh exhausted-failure epoch preserves the bounded progression,
#      while later fresh failed epochs consume it instead of resetting it;
#   4. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to JG_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open only for an already verified failure episode. The budget
#      charges each event epoch once, and it also charges every re-block
#      against an epoch the auto-arm never advanced past the previous
#      re-block (budget_account_current_epoch owns that rule), so an inert
#      hook that leaves the ledger frozen cannot hold the guard in an
#      unbounded re-block loop below that override.
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
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
GRACE=${JG_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/jg-watch.sh"
CLAUDE_MODE=0
CURSOR_MODE=0
SYNC_WAIT_MS=${JG_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${JG_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${JG_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    --cursor) CURSOR_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude|--cursor]" >&2; exit 2 ;;
  esac
done

# A Claude squad_lead's home carries .jg-busy-stop (bin/jg-spawn.sh), and this
# guard is then the only Stop writer of the parent home's busy record for that
# gen: every exit records the Stop's outcome, busy when exit 2 blocks it into a
# continuation and idle otherwise. Claude runs Stop hooks in parallel, so a
# second Stop writer could land after this one and flip the verdict.
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
record_parent_stop_state() {
  local status=$? pointer="$JG_ROOT/.jg-busy-stop" key value writer='' state='' id='' gen='' verdict=idle event=stop
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  # A home launched before the rename carries the pointer under its old name.
  [ -e "$pointer" ] || pointer="$JG_ROOT/.fm-busy-stop"
  [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      writer) writer=$value ;;
      state) state=$value ;;
      id) id=$value ;;
      gen) gen=$value ;;
    esac
  done < "$pointer"
  [ -n "$state" ] && [ -n "$id" ] && [ -n "$gen" ] && [ -x "$writer" ] || return 0
  if [ "$status" -eq 2 ]; then
    verdict=busy
    event=stop-blocked
  fi
  "$writer" apply "$state" "$id" "$verdict" --gen "$gen" --source claude-hook --event "$event" >/dev/null 2>&1 || true
}
trap record_parent_stop_state EXIT

# shellcheck source=bin/jg-supervision-lib.sh
. "$SCRIPT_DIR/jg-supervision-lib.sh"
# shellcheck source=bin/jg-primary-scope-lib.sh
. "$SCRIPT_DIR/jg-primary-scope-lib.sh"
# shellcheck source=bin/jg-hook-host-lib.sh
. "$SCRIPT_DIR/jg-hook-host-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/jg-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

# A Cursor primary also loads the tracked Claude settings, and Cursor's own
# registration owns its turn boundary through bin/jg-turnend-guard-cursor.sh,
# which calls this guard back with --cursor. Without that flag a Cursor-delivered
# payload is the Claude-compatibility duplicate and must not create a second
# continuation path (docs/turnend-guard.md "Harness integrations").
if [ "$CURSOR_MODE" -eq 0 ] && jg_hook_payload_is_foreign_host "$PAYLOAD"; then
  exit 0
fi

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked squad_lead home runs its OWN primary juggernaut session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a squad_lead's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: juggernaut hands out operator/scout
# task worktrees as genuine linked `git worktree`s (bin/jg-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real squad_lead home.
jg_primary_scope_matches "$JG_ROOT" "$STATE" || exit 0

# --- the Overwatch KPI rule -------------------------------------------------
# Every captain message is tagged in the turn it arrives; bin/jg-overwatch-kpi.sh
# owns the ledger, the kinds, and the link a miss needs. The block is charged
# once per message (the seq in $STATE/.overwatch-kpi-flagged), which keeps every
# harness bounded; a message left untagged still counts as a miss.
KPI_PENDING=$("$SCRIPT_DIR/jg-overwatch-kpi.sh" pending 2>/dev/null) || KPI_PENDING=
KPI_SEQ=${KPI_PENDING%%$'\t'*}
if [ -n "$KPI_PENDING" ] && [ "$KPI_SEQ" != "$(cat "$STATE/.overwatch-kpi-flagged" 2>/dev/null)" ]; then
  printf '%s\n' "$KPI_SEQ" > "$STATE/.overwatch-kpi-flagged" 2>/dev/null || true
  {
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '●  CAPTAIN MESSAGE NOT TAGGED - OVERWATCH KPI\n'
    printf '●  Tag it now: new-work, decision-answer, feedback, or micromanagement.\n'
    printf '●  Feedback and micromanagement are misses: link a Juggernaut ticket or PR that changes code so it stops.\n'
    printf '●    %s/jg-overwatch-kpi.sh tag <kind> [<ticket id or PR URL>]\n' "$SCRIPT_DIR"
    printf '●  Message: %.120s\n' "${KPI_PENDING#*$'\t'}"
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  } >&2
  exit 2
fi

# --- the owner-correction capture rule --------------------------------------
# The owner's standing rule (data/owner-rules.md): "I don't want these feedbacks
# as one time fix". A captain message that told the fleet to work differently
# must leave something the whole system reads - an owner rule
# (bin/jg-owner-rules.sh add) or, when it cannot be a rule yet, an enforcement
# ticket (bin/jg-tasks-axi.sh add) - in the turn it lands, or the correction dies
# in one conversation and the next session repeats it. bin/jg-owner-correction.sh
# owns the record and the predicate; the KPI rule above has already required the
# tag that record reads. A helper that is missing or cannot answer is never read
# as "nothing pending": this home has not picked the shared check up and says so
# once.
owner_correction_unavailable() {  # <why>
  [ ! -e "$STATE/.owner-correction-unavailable" ] || return 0
  : > "$STATE/.owner-correction-unavailable" 2>/dev/null || true
  {
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '●  THIS HOME HAS NOT PICKED UP OWNER-CORRECTION CAPTURE\n'
    printf '●  %s. No turn is checked for an uncaptured owner correction until the shared check is here.\n' "$1"
    printf '●  Update this home to the shared code, then end the turn again: /resupply\n'
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  } >&2
  exit 2
}

owner_correction_block() {  # <seq> <kind> <text>
  printf '%s\n' "$1" > "$STATE/.owner-correction-flagged" 2>/dev/null || true
  {
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '●  HE CORRECTED THE FLEET, AND NOTHING CAPTURED IT\n'
    printf '●  A correction that stays in this conversation is repeated in the next session.\n'
    printf '●  Write the rule the whole system reads, in his own words, when it is his own taste or authority:\n'
    printf '●    %s/jg-owner-rules.sh add --kind owner --words "<his exact words>" --scope "<where it applies>" --enforce "<script or contract that enforces it>"\n' "$SCRIPT_DIR"
    printf '●  When it is an engineering default every Juggernaut user should get, or cannot be a rule yet, file the ticket instead:\n'
    printf '●    %s/jg-tasks-axi.sh add <id> "[feature] <what changes>" --body "<summary of what changes and why>"\n' "$SCRIPT_DIR"
    printf '●  His message (%s): %.160s\n' "$2" "$3"
    printf '●%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  } >&2
  exit 2
}

if [ ! -x "$SCRIPT_DIR/jg-owner-correction.sh" ]; then
  owner_correction_unavailable 'bin/jg-owner-correction.sh is missing beside bin/jg-turnend-guard.sh'
fi
OWNER_CORRECTION=$("$SCRIPT_DIR/jg-owner-correction.sh" pending 2>/dev/null)
OWNER_CORRECTION_STATUS=$?
case "$OWNER_CORRECTION_STATUS" in
  1) : ;;
  # 0 is a pending correction; anything else means the shared check could not answer.
  0) OWNER_CORRECTION_SEQ=${OWNER_CORRECTION%%$'\t'*}
     if [ "$OWNER_CORRECTION_SEQ" != "$(cat "$STATE/.owner-correction-flagged" 2>/dev/null)" ]; then
       OWNER_CORRECTION_REST=${OWNER_CORRECTION#*$'\t'}
       OWNER_CORRECTION_REST=${OWNER_CORRECTION_REST#*$'\t'}
       owner_correction_block "$OWNER_CORRECTION_SEQ" \
         "${OWNER_CORRECTION_REST%%$'\t'*}" "${OWNER_CORRECTION_REST#*$'\t'}"
     fi ;;
  *) owner_correction_unavailable "bin/jg-owner-correction.sh could not answer (exit $OWNER_CORRECTION_STATUS)" ;;
esac

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
if [ "$CLAUDE_MODE" -eq 1 ]; then
  # shellcheck source=bin/jg-session-lock-lib.sh
  . "$SCRIPT_DIR/jg-session-lock-lib.sh"
fi

BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  jg_lock_try_acquire "$BUDGET_LOCK" || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  jg_lock_release "$BUDGET_LOCK"
}

jg_supervision_status "$STATE" "$GRACE"
if [ "$JG_SUP_NEEDED" = false ]; then
  [ -e "$FAILURE_NOTICE" ] || budget_reset
  exit 0
fi
# One owner of the "supervision is on, let this turn end" exit contract, shared
# by every proof of supervision below.
allow_supervised_stop() {
  [ "$CLAUDE_MODE" -eq 1 ] || exit 0
  jg_failure_episode_reset "$STATE" && exit 0
  exit 2
}

if jg_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$JG_HOME"; then
  allow_supervised_stop
fi

# Away mode transfers supervision ownership from the watcher to the away-mode
# daemon, which runs the watcher one-shot and starts its replacement after every
# wake (bin/jg-supervise-daemon.sh). A turn boundary regularly lands in that
# hand-off, when no watcher process holds the lock and nothing is wrong, so
# requiring one here alarmed on healthy away-mode supervision. A live
# identity-matched daemon holding this home is the right owner to test for.
# The beacon half of the predicate still applies: a daemon that stops
# restarting its watcher still blocks once the beacon passes grace, and a home
# with no daemon and no watcher blocks exactly as before. It uses AFK_GRACE
# (poll-cadence-derived, see the comment above) instead of the flat $GRACE
# every other check on this page uses, so a daemon that is genuinely still
# cycling - just slower than a fixed 300s window - is not misread as down.
AFK_GRACE=${JG_GUARD_GRACE:-$(jg_poll_derived_grace)}
if [ "$(jg_path_age "$STATE/.last-watcher-beat")" -lt "$AFK_GRACE" ] \
  && jg_afk_daemon_owns_supervision "$STATE"; then
  allow_supervised_stop
fi

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/jg-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$JG_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$JG_SUP_IN_FLIGHT" "$JG_SUP_BEACON_DESC"
    elif [ "$JG_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$JG_SUP_SOURCES" "$JG_SUP_BEACON_DESC"
    elif [ "$JG_SUP_CHECKS" -gt 0 ]; then
      printf '●  %s registered custom check(s), but no live watcher holds this home lock (last beat: %s).\n' "$JG_SUP_CHECKS" "$JG_SUP_BEACON_DESC"
    elif [ "$JG_SUP_READY_WORK" -gt 0 ]; then
      printf '●  %s ready backlog item(s) wait for this idle lead, but no live watcher holds this home lock (last beat: %s).\n' "$JG_SUP_READY_WORK" "$JG_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$JG_SUP_BEACON_DESC"
    fi
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '●  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n'
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

# Another verified live session owns the home lock under the shared
# ancestry-or-trusted-id verdict. This session is read-only and cannot arm or
# repair supervision without
# stealing ownership, so blocking its Stop would create an impossible loop.
# Report the ownership conflict as a diagnostic and let this turn end safely;
# the owning session remains responsible for restoring the watcher.
if [ "$CLAUDE_MODE" -eq 1 ] && jg_session_lock_foreign_owner_live "$STATE"; then
  printf '{"systemMessage":"JUGGERNAUT SUPERVISION IS OWNED BY ANOTHER LIVE SESSION: this read-only session cannot and should not arm or repair the watcher (lock owner pid %s). Allowing this turn to end safely; the owning session must restore supervision."}\n' \
    "$JG_SESSION_LOCK_FOREIGN_OWNER_PID"
  exit 0
fi

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns recovery for this event epoch before consuming one of
# Claude's bounded continuations.
#
# Budget accounting, under the budget lock. Sets COUNT (the session's
# consumed continuations, including this one) and BUDGET_INITIALIZED_FAILURE.
# The ledger's epoch identity is what is charged: a new epoch charges once,
# and an epoch this same invocation already charged is never charged again,
# because the wait loop above can observe one fresh terminal epoch many times
# before the block decision. Across Stops the two callers differ:
#   - observe (the allow paths in autoarm_owns_recovery): seeing an
#     already-charged epoch again is free - it is the same claim, seen again.
#   - block (the re-block path): a re-block against the epoch the previous
#     re-block already charged is a new consumed continuation, because the
#     auto-arm advanced nothing between the two Stops - it did not participate
#     at all, which is exactly the absence this budget bounds. Charging only
#     epoch changes let an inert hook (identity-gated, never fired, or failing
#     before its generation claim) freeze the ledger and the count together,
#     so the guard re-blocked without limit and the attended fail-open below
#     never became reachable.
BUDGET_CHARGED_EPOCH=
budget_account_current_epoch() {  # [observe|block]
  local mode=${1:-observe} current_epoch outcome old_session old_count old_epoch tmp initialized charged
  jg_lock_try_acquire "$BUDGET_LOCK" || return 1
  current_epoch=$(sed -n '1s/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  initialized=0
  charged=0
  COUNT=0
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    if [ "$old_session" = "$SESSION_ID" ]; then
      COUNT=$old_count
      if [ -n "$current_epoch" ] && [ "$old_epoch" = "$current_epoch" ]; then
        if [ "$mode" = block ] && [ "$BUDGET_CHARGED_EPOCH" != "$current_epoch" ]; then
          COUNT=$((COUNT + 1))
          charged=1
        fi
      else
        COUNT=$((COUNT + 1))
        charged=1
      fi
    fi
  fi
  if [ ! -f "$BUDGET_FILE" ] || [ "${old_session:-}" != "$SESSION_ID" ]; then
    charged=1
    case "$outcome" in
      failed|failed-suppressed)
        if [ -e "$FAILURE_NOTICE" ]; then
          initialized=1
          COUNT=0
        else
          COUNT=1
        fi
        ;;
      *) COUNT=1 ;;
    esac
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$current_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    jg_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  [ "$charged" -eq 0 ] || BUDGET_CHARGED_EPOCH=$current_epoch
  BUDGET_INITIALIZED_FAILURE=$initialized
  jg_lock_release "$BUDGET_LOCK"
  return 0
}

autoarm_owns_recovery() {
  local pid role outcome age
  jg_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$JG_HOME" && return 0
  # A live OPEN generation claim owns recovery: the ledger names a live,
  # identity-matched owner still arming that is not stuck (jg_autoarm_claim_open
  # in bin/jg-wake-lib.sh owns that predicate). A finished, dead,
  # identity-mismatched, or stuck claim deliberately fails it and falls
  # through, because treating such a claim as ownership is what let a dead
  # watcher go unnoticed for turn after turn; the outcome cases below still
  # cover a claim that finished moments ago, so a genuine handoff is not
  # duplicated, while a stale one now reaches the block.
  if jg_autoarm_claim_open "$STATE" "$GRACE"; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  # Legacy shim: a pre-generation build's claim holds the owner lock with the
  # autoarm role for its whole cycle; defer to it under the legacy abandonment
  # proof so an upgrade mid-session cannot double-arm.
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(jg_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if jg_pid_alive "$pid" && [ "$role" = autoarm ] \
    && ! jg_autoarm_claim_abandoned "$STATE" "$GRACE"; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    rewake)
      age=$(jg_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ]; then
        [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
        return 0
      fi
      ;;
    failed)
      age=$(jg_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        [ "$BUDGET_INITIALIZED_FAILURE" -eq 1 ] && return 0
      fi
      ;;
    failed-suppressed)
      age=$(jg_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        :
      fi
      ;;
  esac
  return 1
}

terminal_fail_open() {
  local pid role old_session old_count
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  failure_episode_verified || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  # A live open generation claim is a concurrent recovery decision to step
  # aside for, exactly like the legacy live-owner case below.
  jg_autoarm_claim_open "$STATE" "$GRACE" && return 2
  if ! jg_lock_try_acquire "$OWNER_LOCK"; then
    pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
    role=$(jg_lock_role "$OWNER_LOCK" 2>/dev/null || true)
    # Same legacy abandonment test as autoarm_owns_recovery: a claim whose
    # ledger entry is already terminal, or whose recorded pid-identity no
    # longer matches the live pid, is not a concurrent owner to step aside
    # for. Stepping aside for one here allows the stop silently, and the
    # episode's one attended alarm would never fire, so clear the abandoned
    # claim and let this decision finish instead. Failing to clear it
    # re-blocks rather than allowing.
    if jg_pid_alive "$pid" && [ "$role" = autoarm ] \
      && ! jg_autoarm_claim_abandoned "$STATE" "$GRACE"; then
      return 2
    fi
    jg_autoarm_release_abandoned "$STATE" "$GRACE" || return 1
    jg_lock_try_acquire "$OWNER_LOCK" || return 1
  fi
  if ! jg_lock_set_role "$OWNER_LOCK" terminal-check; then
    jg_lock_release "$OWNER_LOCK"
    return 1
  fi
  if ! jg_lock_try_acquire "$BUDGET_LOCK"; then
    jg_lock_release "$OWNER_LOCK"
    return 1
  fi
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  role=$(jg_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if [ "$role" != terminal-check ] || [ "$old_session" != "$SESSION_ID" ] \
    || [ "$old_count" -le "$BLOCK_BUDGET" ] || ! failure_episode_verified \
    || [ -e "$FAILURE_ALARM" ]; then
    jg_lock_release "$BUDGET_LOCK"
    jg_lock_release "$OWNER_LOCK"
    return 1
  fi
  if jg_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$JG_HOME"; then
    if ! jg_failure_episode_reset "$STATE" held; then
      jg_lock_release "$BUDGET_LOCK"
      jg_lock_release "$OWNER_LOCK"
      return 1
    fi
    jg_lock_release "$BUDGET_LOCK"
    jg_lock_release "$OWNER_LOCK"
    return 2
  fi
  # Re-check for a live open generation claim now that both locks are held: a
  # claimant that published "arming" between the pre-check above and the lock
  # acquisition is active recovery, and alarming over it would fire the
  # episode's one attended fail-open while a continuation is under way.
  if jg_autoarm_claim_open "$STATE" "$GRACE"; then
    jg_lock_release "$BUDGET_LOCK"
    jg_lock_release "$OWNER_LOCK"
    return 2
  fi
  if ! (set -C; : > "$FAILURE_ALARM") 2>/dev/null; then
    jg_lock_release "$BUDGET_LOCK"
    jg_lock_release "$OWNER_LOCK"
    return 1
  fi
  jg_lock_release "$BUDGET_LOCK"
  jg_lock_release "$OWNER_LOCK"
  return 0
}

failure_episode_verified() {
  local outcome
  [ ! -e "$STATE/.afk" ] || return 1
  [ -e "$FAILURE_NOTICE" ] || return 1
  outcome=$(sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    failed|failed-suppressed) return 0 ;;
    *) return 1 ;;
  esac
}

i=0
while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
  if autoarm_owns_recovery; then
    if jg_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$JG_HOME"; then
      jg_failure_episode_reset "$STATE" || exit 2
    fi
    exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
if autoarm_owns_recovery; then
  if jg_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$JG_HOME"; then
    jg_failure_episode_reset "$STATE" || exit 2
  fi
  exit 0
fi

# The auto-arm genuinely failed to establish: consume the bounded re-block
# budget before considering the verified one-time attended fail-open.
budget_account_current_epoch block || block_stop
terminal_fail_open
terminal_status=$?
if [ "$terminal_status" -eq 0 ]; then
  if [ "$JG_SUP_IN_FLIGHT" -gt 0 ]; then
    NEED_DESC="$JG_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$JG_SUP_SOURCES" -gt 0 ]; then
    NEED_DESC="$JG_SUP_SOURCES process-event source(s) registered"
  elif [ "$JG_SUP_CHECKS" -gt 0 ]; then
    NEED_DESC="$JG_SUP_CHECKS registered custom check(s)"
  elif [ "$JG_SUP_READY_WORK" -gt 0 ]; then
    NEED_DESC="$JG_SUP_READY_WORK ready backlog item(s) waiting for this idle lead"
  else
    NEED_DESC="X-mode relay polling active"
  fi
  printf '{"systemMessage":"JUGGERNAUT SUPERVISION IS GENUINELY DOWN: %s, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."}\n' "$NEED_DESC"
  exit 0
fi
[ "$terminal_status" -eq 2 ] && exit 0
block_stop
