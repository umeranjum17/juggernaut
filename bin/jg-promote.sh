#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the operator keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so jg-teardown.sh applies the full ship-task teardown protection
# again. Promotion also writes the operator's ship instructions to
# data/<task-id>/ship-instructions.md, appends that same superseding contract to
# data/<task-id>/brief.md for future relaunches, and prints the jg-send.sh command
# that delivers it to the current worker. Those instructions carry the
# scratch-state inventory, the clean
# default-branch base, the immutable ship branch, and - rendered from
# bin/jg-dod-lib.sh, the single owner an ordinary ship brief also uses - the
# mode-specific Definition of done, so a promoted worker receives exactly the same
# delivery contract as a briefed one. The instructions also carry `# Task` with
# `## Captain's intent` preserved from the scout brief and promotion's ship-time
# instructions under `## Juggernaut spec`; the scout-time spec remains context but
# is not relabeled as the ship spec. Promotion refuses leftover `{TASK}` /
# `{JUGGERNAUT_SPEC}` placeholders and a `## Captain's intent` line opening with
# a Captain label or address (bin/jg-dod-lib.sh). A pre-subsection scout
# brief contributes only Task lines explicitly marked as captain words to intent,
# read outside fenced blocks and indented examples so a quoted `Captain:` sample
# never passes the provenance gate as the ask (bin/jg-dod-lib.sh).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode, --yolo, and the ship branch resolved from
# --branch-prefix are written into the meta alongside the kind= flip. Juggernaut resolves all three at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks that posture
# up. The registry IS read for one thing only: the project's forge binding, which
# is a project fact rather than a per-task decision, so promotion takes it from
# there instead of asking juggernaut to remember it.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# A scout spawned on a named base records base_branch= in its meta; promotion
# keeps that base as the ship's starting point and pull-request target, and
# refuses a mode that cannot carry one (bin/jg-dod-lib.sh jg_base_branch_valid).
# There is no --forge flag here: the binding comes from the registry, and for a
# task record naming no project it is none. bin/jg-brief.sh takes --forge instead
# because that script has no registry access at all, and bin/jg-spawn.sh checks
# its value against the registry; bin/jg-project-mode.sh's header owns the
# binding and bin/jg-dod-lib.sh owns what it changes for the worker, including
# the refusal of a forge on local-only.
# Usage: jg-promote.sh <task-id> --mode <direct-PR|local> --yolo <on|off> [--branch-prefix <prefix>] [--upstream-consent <host>/<owner>/<repo>]
# --upstream-consent records the captain's one-off approval for this task to
# publish to juggernaut's own upstream repository; promotion applies the same
# self-repository publication gate as bin/jg-spawn.sh (bin/jg-role-lib.sh), so
# a promoted scout cannot gain authority a fresh ship spawn would be refused.
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
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-role-lib.sh
. "$SCRIPT_DIR/jg-role-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-backlog-lib.sh
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
# shellcheck source=bin/jg-public-followup-lib.sh
. "$SCRIPT_DIR/jg-public-followup-lib.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

MODE=
YOLO=
BRANCH_PREFIX=fm/
MODE_SET=0
YOLO_SET=0
FORGE=none
UPSTREAM_CONSENT=
UPSTREAM_CONSENT_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      branch-prefix) BRANCH_PREFIX=$a ;;
      upstream-consent) UPSTREAM_CONSENT=$a; UPSTREAM_CONSENT_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --branch-prefix) want_value="branch-prefix" ;;
    --branch-prefix=*) BRANCH_PREFIX=${a#--branch-prefix=} ;;
    --upstream-consent) want_value="upstream-consent" ;;
    --upstream-consent=*) UPSTREAM_CONSENT=${a#--upstream-consent=}; UPSTREAM_CONSENT_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: jg-promote.sh <task-id> --mode <direct-PR|local> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <direct-PR|local>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to direct-PR" >&2
    exit 1 ;;
  *) jg_delivery_style_accepts "$MODE" || { echo "error: --mode must be one of $(jg_delivery_style_modes | paste -sd, - | sed 's/,/, /g') (the old words $(jg_delivery_style_aliases | paste -sd, - | sed 's/,/, /g') are read as before; got '$MODE')" >&2; exit 1; } ;;
esac
# The retired word no-mistakes runs as direct-PR (the worker proves with done-done, no pipeline run starts).
MODE=$(jg_delivery_style_task_mode "$MODE")
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac
if [ "$UPSTREAM_CONSENT_SET" -eq 1 ]; then
  [ -n "$UPSTREAM_CONSENT" ] || { echo "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value" >&2; exit 1; }
  if jg_delivery_style_is "$MODE" local; then
    echo "error: --upstream-consent is meaningless on $MODE, which publishes nothing; drop it" >&2
    exit 1
  fi
  jg_role_scope_valid "$UPSTREAM_CONSENT" || {
    echo "error: --upstream-consent must be <host>/<owner>/<repo> (got '$UPSTREAM_CONSENT')" >&2
    exit 1
  }
  UPSTREAM_CONSENT=$(jg_role_scope_norm "$UPSTREAM_CONSENT")
fi
# A posture this forge cannot carry is refused once the registry binding has been
# read. Merge authority on a Gerrit forge is refused rather than quietly dropped,
# on the captain's decision of 2026-09-15 (bin/jg-project-mode.sh's header carries
# it). The call right below the definition is kept deliberately as a guard on the
# mode and yolo posture; it cannot refuse on the forge, which stays none until the
# registry supplies it after the lock, so the post-registry call is the one that
# fires.
refuse_impossible_forge_posture() {
  jg_forge_valid_for_mode "$FORGE" "$MODE" jg-promote.sh || return 1
  if [ "$FORGE" = gerrit ] && [ "$YOLO" = on ]; then
    echo "error: --yolo on is refused for forge=gerrit: a Code-Review+2 is a positive attributed claim that a named human approved and juggernaut must not manufacture one (captain's decision 2026-09-15); promote with --yolo off and take any landing on a current explicit captain instruction naming that concrete change" >&2
    return 1
  fi
  return 0
}
refuse_impossible_forge_posture || exit 1

ID=${POS[0]}
jg_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
BRANCH="$BRANCH_PREFIX$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: --branch-prefix and task id must form a valid git branch (got '$BRANCH')" >&2
  exit 1
fi
printf -v BRANCH_Q '%q' "$BRANCH"
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
META=
SCOUT_BRIEF=
BRIEF_ORIGINAL=
BRIEF_REPLACEMENT=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$BRIEF_REPLACEMENT" ] || rm -f -- "$BRIEF_REPLACEMENT" 2>/dev/null || true
  if [ -n "$BRIEF_ORIGINAL" ] && [ -e "$BRIEF_ORIGINAL" ]; then
    mv -f -- "$BRIEF_ORIGINAL" "$SCOUT_BRIEF" 2>/dev/null || true
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    jg_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    jg_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
jg_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$JG_ROOT/bin/jg-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(jg_meta_lock_path "$META") || exit 1
jg_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! jg_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: task record for $ID is unsafe or missing ($JG_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

# Unlike the mode and yolo above, the forge is not a per-task decision: it is the
# captain's project binding, so promotion takes it from the registry rather than
# from a flag juggernaut must remember.
PROMOTE_PROJECT=$(sed -n 's/^project=//p' "$META" | head -n 1)
if [ -n "$PROMOTE_PROJECT" ]; then
  PROMOTE_PROJECT_NAME=$(basename "$PROMOTE_PROJECT")
  if ! PROMOTE_STANDING_FORGE=$("$JG_ROOT/bin/jg-project-mode.sh" --forge "$PROMOTE_PROJECT_NAME"); then
    echo "error: $ID cannot promote: the registry entry for $PROMOTE_PROJECT_NAME does not resolve to a delivery posture (see the refusal above); correct data/projects.md and promote again" >&2
    exit 1
  fi
  FORGE=${PROMOTE_STANDING_FORGE:-none}
  refuse_impossible_forge_posture || exit 1
fi
BASE_BRANCH=$(sed -n 's/^base_branch=//p' "$META" | head -n 1)
jg_base_branch_valid "$BASE_BRANCH" "$MODE" "$FORGE" "jg-promote.sh $ID" || exit 1
# The same self-repository publication gate bin/jg-spawn.sh applies to a fresh
# ship spawn runs here on the recorded project: a promoted scout reaches no
# greater upstream authority than the spawn path would grant.
if ! jg_delivery_style_is "$MODE" local && [ -n "$PROMOTE_PROJECT" ]; then
  gate_rc=0
  jg_role_gate_self_publish "$JG_HOME" "$CONFIG" "$PROMOTE_PROJECT" "$JG_ROOT" "$UPSTREAM_CONSENT" || gate_rc=$?
  case $gate_rc in
  0 | 2) ;;
  *)
    echo "error: promotion refused for $ID: $JG_ROLE_PUB_DENIAL" >&2
    echo "error: to let this home publish to ${JG_ROLE_PUB_TARGET:-that repository}, write 'maintainer ${JG_ROLE_PUB_TARGET:-<host>/<owner>/<repo>}' into $CONFIG/juggernaut-role (docs/configuration.md \"Juggernaut role\"), or pass --upstream-consent ${JG_ROLE_PUB_TARGET:-<host>/<owner>/<repo>} for this one task with the captain's explicit approval" >&2
      exit 1
      ;;
  esac
fi
PROMOTE_BASE_WORDS='default-branch base'
[ -z "$BASE_BRANCH" ] || PROMOTE_BASE_WORDS="copy of the base branch \`$BASE_BRANCH\`"
# An unbound project keeps the exact wording it always had.
PROMOTE_FORGE_WORDS=
[ "$FORGE" = none ] || PROMOTE_FORGE_WORDS=" forge=$FORGE"
PROMOTE_CONSENT_WORDS=
[ -z "$UPSTREAM_CONSENT" ] || PROMOTE_CONSENT_WORDS=" upstream-consent=$UPSTREAM_CONSENT"

SCOUT_BRIEF="$DATA/$ID/brief.md"
if jg_brief_task_placeholders_present "$SCOUT_BRIEF"; then
  echo "error: $SCOUT_BRIEF still contains {TASK} or {JUGGERNAUT_SPEC}; preserve the original ask in ## Captain's intent and fill the scout-time ## Juggernaut spec; promotion generates a separate ship-time spec" >&2
  exit 1
fi
if ! jg_brief_task_content_valid "$SCOUT_BRIEF"; then
  echo "error: $SCOUT_BRIEF must contain nonempty ## Captain's intent and ## Juggernaut spec subsections (or a nonempty legacy # Task body) before promotion" >&2
  exit 1
fi
if ADDRESS_LINE=$(jg_brief_intent_address_line "$SCOUT_BRIEF"); then
  echo "error: $SCOUT_BRIEF ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before promotion, since the heading already records provenance" >&2
  exit 1
fi
if jg_brief_task_heading_present "$SCOUT_BRIEF" "## Captain's intent"; then
  INTENT_BODY=$(jg_brief_task_heading_body "$SCOUT_BRIEF" "## Captain's intent")
else
  TASK_BODY=$(jg_brief_heading_body "$SCOUT_BRIEF" "# Task")
  INTENT_BODY=$(jg_brief_marked_captain_words "$TASK_BODY")
fi
if [ -z "$(printf '%s' "$INTENT_BODY" | tr -d '[:space:]')" ]; then
  echo "error: $SCOUT_BRIEF has no provenance-marked Captain's intent; add the captain's actual words before promotion" >&2
  exit 1
fi

# The promoted worker must receive the same delivery contract an ordinary ship
# brief carries, so the mode-specific Definition of done is rendered from its
# single owner (bin/jg-dod-lib.sh) rather than summarised into a hint line.
INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
IFS= read -r -d '' PROMOTION_SHIP_SPEC <<EOF || true
If these promotion steps were already completed before a relaunch, preserve the existing \`$BRANCH_Q\` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout juggernaut operates from. If either does not resolve to the worktree you were launched in, stop and escalate to juggernaut.
2. Inventory this worktree's scratch state with \`git status\` and \`git log\` before changing anything.
3. Return to a clean $PROMOTE_BASE_WORDS, then create your branch: \`git checkout -b $BRANCH_Q --\`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Juggernaut spec and any unmarked legacy \`# Task\` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.
EOF
promote_delivery_contract() {
  cat <<EOF
# Current delivery mode contract
This task is now kind=ship with mode=$MODE$PROMOTE_FORGE_WORDS$PROMOTE_CONSENT_WORDS.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under \`$DATA/$ID/\` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Register disposable temporary directories outside the Juggernaut home, repository, state and data directories with \`JG_HOME='$JG_HOME' JG_STATE_OVERRIDE='$STATE' JG_DATA_OVERRIDE='$DATA' '$JG_ROOT/bin/jg-scratch.sh' register $ID <dir>\` so cleanup reaps them; keep retained evidence under \`$DATA/$ID/\` unregistered.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
EOF
  jg_ship_rule_one "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH"
  printf '\n'
  jg_dod_block "$MODE" "$ID" "$BRANCH" "$FORGE" "$BASE_BRANCH" "$UPSTREAM_CONSENT"
}
mkdir -p "$DATA/$ID"
[ ! -d "$INSTRUCTIONS" ] || { echo "error: ship instructions path is a directory: $INSTRUCTIONS" >&2; exit 1; }
TMP="$DATA/$ID/.ship-instructions.md.${BASHPID:-$$}"
{
  cat <<EOF
Your scout task has been promoted to a ship task, mode=$MODE. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
EOF
  printf '%s\n' "$INTENT_BODY"
  cat <<EOF

## Juggernaut spec
$PROMOTION_SHIP_SPEC

EOF
  promote_delivery_contract
} > "$TMP" || { echo "error: could not render ship instructions for mode=$MODE" >&2; exit 1; }
mv "$TMP" "$INSTRUCTIONS"
TMP=
[ -f "$INSTRUCTIONS" ] && [ -r "$INSTRUCTIONS" ] || { echo "error: ship instructions were not published as a readable file: $INSTRUCTIONS" >&2; exit 1; }

# The current worker receives the instructions through jg-send, but a replacement
# worker is launched from brief.md. Publish the same explicit precedence contract
# there so a later relaunch cannot revive the original scout delivery rules.
BRIEF_REPLACEMENT="$DATA/$ID/.brief.md.promote.${BASHPID:-$$}"
{
  cat "$SCOUT_BRIEF"
  printf '\n\n'
  printf '# Current ship Juggernaut spec\n%s\n\n' "$PROMOTION_SHIP_SPEC"
  promote_delivery_contract
} > "$BRIEF_REPLACEMENT" || {
  echo "error: could not render the promoted brief for mode=$MODE" >&2
  exit 1
}
BRIEF_ORIGINAL="$DATA/$ID/.brief.md.scout.${BASHPID:-$$}"
mv "$SCOUT_BRIEF" "$BRIEF_ORIGINAL" || {
  echo "error: could not stage the scout brief for promotion: $SCOUT_BRIEF" >&2
  exit 1
}
if ! mv "$BRIEF_REPLACEMENT" "$SCOUT_BRIEF"; then
  if mv "$BRIEF_ORIGINAL" "$SCOUT_BRIEF" 2>/dev/null; then
    BRIEF_ORIGINAL=
  fi
  echo "error: could not publish the promoted brief: $SCOUT_BRIEF" >&2
  exit 1
fi
BRIEF_REPLACEMENT=

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' -e '^branch=' -e '^upstream_consent=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "branch=$BRANCH"
  [ -z "$UPSTREAM_CONSENT" ] || echo "upstream_consent=$UPSTREAM_CONSENT"
} >> "$TMP"
if declare -F jg_receipts_promote >/dev/null && ! jg_receipts_promote "$META" "$TMP"; then
  rm -f -- "$TMP"
  TMP=
  echo "error: completion receipt requirement for $ID could not be carried into the task record" >&2
  exit 1
fi
if ! jg_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  rm -f -- "$TMP"
  TMP=
  echo "error: task record for $ID could not be published ($JG_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
TMP=
rm -f -- "$BRIEF_ORIGINAL" 2>/dev/null || true
BRIEF_ORIGINAL=
jg_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$JG_HOME")
INSTRUCTIONS_Q=$(printf '%q' "$INSTRUCTIONS")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO$PROMOTE_FORGE_WORDS (teardown protection restored)"
echo "wrote ship instructions for mode=$MODE$PROMOTE_FORGE_WORDS: $INSTRUCTIONS"
echo "next: JG_HOME=$HOME_Q bin/jg-send.sh jg-$ID \"\$(cat $INSTRUCTIONS_Q)\""

promote_print_rechain_hint() {
  local consent_home=$1 work_home=$2 task_id=$3 id prefix
  prefix=
  [ "$consent_home" = "$JG_HOME" ] || prefix="JG_HOME=$(printf '%q' "$consent_home") "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(jg_pf_registry_get "$consent_home/state" "$id" state)" = delivered ] || continue
    echo "next: ${prefix}bin/jg-public-followup.sh rechain <new-obligation-id> --from $id --work-home $work_home --work-id $task_id --expected pr-merged"
  done <<EOF
$(jg_pf_registry_ids_for_work "$consent_home/state" "$work_home" "$task_id")
EOF
}

promote_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

promote_resolve_primary_home() {
  local parent=$1 child=$2 mate_id=$3 parent_meta registry meta_home
  jg_pf_home_id_valid "squad_lead:$mate_id" || return 1
  parent=$(promote_canonical_home "$parent") || return 1
  child=$(promote_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$mate_id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fmx_meta_get "$parent_meta" kind)" = squad_lead ] || return 1
  meta_home=$(fmx_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$(jg_compat_pick "$parent/data/squad_leads.md")"
  squad_lead_registry_validate_bindings "$registry" squad_lead_registry_path_key \
    "$mate_id" "$child" || return 1
  printf '%s\n' "$parent"
}

promote_warn_parent_unresolved() {
  echo "warning: could not resolve the consent-holding parent home for squad_lead $1; promotion succeeded, but any open public loop must be inspected and rechained from the parent." >&2
}

if [ -f "$(jg_compat_marker "$JG_HOME")" ]; then
  PROMOTE_MATE_ID=$(sed -n '1p' "$(jg_compat_marker "$JG_HOME")" 2>/dev/null || true)
  PROMOTE_PARENT_RECORD=absent
  PROMOTE_PARENT_ROUTE=
  PROMOTE_DURABLE_PARENT=
  if [ -e "$(jg_compat_parent_marker "$JG_HOME")" ] || [ -L "$(jg_compat_parent_marker "$JG_HOME")" ]; then
    PROMOTE_PARENT_RECORD=invalid
    if jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$JG_HOME")"; then
      PROMOTE_PARENT_RECORD=valid
      PROMOTE_PARENT_ROUTE=$JG_SQUAD_LEAD_PARENT_ROUTE
      PROMOTE_DURABLE_PARENT=$JG_SQUAD_LEAD_PARENT_HOME
    fi
  fi
  if [ "$PROMOTE_PARENT_RECORD" = invalid ]; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  elif [ "$PROMOTE_PARENT_ROUTE" = local ]; then
    PROMOTE_PARENT_CANDIDATE=${JG_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PROMOTE_DURABLE_PARENT}
    PROMOTE_PARENT_BINDINGS_MATCH=1
    if [ -n "${JG_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      PROMOTE_LIVE_PARENT=$(promote_canonical_home "$JG_PUBLIC_FOLLOWUP_PRIMARY_HOME") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      PROMOTE_RECORDED_PARENT=$(promote_canonical_home "$PROMOTE_DURABLE_PARENT") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
          && [ "$PROMOTE_LIVE_PARENT" != "$PROMOTE_RECORDED_PARENT" ]; then
        PROMOTE_PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
        && PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$PROMOTE_PARENT_CANDIDATE" "$JG_HOME" "$PROMOTE_MATE_ID"); then
      if jg_pf_relay_active "$PROMOTE_PARENT"; then
        promote_print_rechain_hint "$PROMOTE_PARENT" "squad_lead:$PROMOTE_MATE_ID" "$ID"
      fi
    else
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ "$PROMOTE_PARENT_ROUTE" = remote ]; then
    PROMOTE_HOME_ENV_TOKEN=
    if [ -f "$JG_HOME/.env" ]; then
      PROMOTE_HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$JG_HOME/.env")
    fi
    if [ -n "$PROMOTE_HOME_ENV_TOKEN" ]; then
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ -n "${JG_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if jg_pf_relay_active "$JG_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      if PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$JG_PUBLIC_FOLLOWUP_PRIMARY_HOME" "$JG_HOME" "$PROMOTE_MATE_ID"); then
        promote_print_rechain_hint "$PROMOTE_PARENT" "squad_lead:$PROMOTE_MATE_ID" "$ID"
      else
        promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
      fi
    fi
  elif jg_pf_relay_active "$JG_HOME"; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  fi
elif jg_pf_relay_active "$JG_HOME"; then
  promote_print_rechain_hint "$JG_HOME" main "$ID"
fi
