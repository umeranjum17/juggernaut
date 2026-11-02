#!/usr/bin/env bash
# Publish durable completion evidence for one task's current candidate.
# Usage: JG_HOME=<supervising-home> jg-run-receipt.sh <task-id> PASS|FAIL <evidence-file> [candidate-repo]
# candidate-repo defaults to the current directory. PASS requires a clean tree.
# The evidence file must contain the checks/commands, their outcomes and any
# limitations; it is embedded in the receipt, not stored as a temporary pointer.
# bin/jg-dod-lib.sh owns the schema, compatibility and acceptance contract.
# The existing task control lock serializes publication with guarded landing.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -eu
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
fi
# The fork libraries live in the fork's bin/ (JG_FORK_BIN, else $JG_HOME/bin), not beside this feature script.
SCRIPT_DIR=${JG_FORK_BIN:-${JG_HOME:?explicit supervising JG_HOME required}/bin}
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh
. "$SCRIPT_DIR/jg-backlog-transition-lib.sh"
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ] || ! jg_pr_task_id_valid "$1"; then
  echo "usage: JG_HOME=<home> jg-run-receipt.sh <id> PASS|FAIL <evidence-file> [repo]" >&2
  exit 2
fi
# These adapters do not themselves call Claude; when a pool is configured,
# downstream tools inherit its account rather than an ambient default login.
# shellcheck source=account-pool/bin/jg-pool-claude-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/account-pool/bin/jg-pool-claude-env.sh"
if [ -f "$JG_HOME/config/account-pool" ]; then jg_pool_claude_env || exit 1; fi

ID=$1 VERDICT=$2 EVIDENCE=$3 REPO=${4:-.}
case "$VERDICT" in PASS|FAIL) ;; *) echo 'error: verdict must be PASS or FAIL' >&2; exit 2 ;; esac
: "${JG_HOME:?explicit supervising JG_HOME required}"
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
META="$STATE/$ID.meta"
[ -f "$META" ] && [ -f "$EVIDENCE" ] || { echo 'error: task metadata or evidence missing' >&2; exit 1; }
command -v jq >/dev/null || { echo 'error: jq required for completion receipts' >&2; exit 1; }
LOCK="$STATE/.control-$ID.lock"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  jg_lock_release "$LOCK" || true
}
jg_lock_acquire_wait "$LOCK"
trap cleanup EXIT
if ! jg_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: $JG_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MODE=$(jg_dod_meta_value "$META" mode)
case "$MODE" in local-only|direct-PR|no-mistakes) ;; *) echo 'error: receipt requires a ship delivery mode' >&2; exit 1 ;; esac
HEAD_SHA=$(git -C "$REPO" rev-parse --verify 'HEAD^{commit}')
if [ "$VERDICT" = PASS ] && [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo 'error: PASS requires a clean candidate checkout' >&2
  exit 1
fi
GEN=$JG_BACKLOG_META_SPAWN_GEN
# The receipt names the pull request it covers (the URL carries the repository);
# acceptance compares it with the pr= the merge path recorded and refuses a
# mismatch, so a blank pr is not a harmless default.
# JG_RECEIPT_PR is read from this script's own environment, where an exported
# value and a one-shot command prefix (`JG_RECEIPT_PR=<url> jg-run-receipt.sh`)
# are the same thing; a value set but blank means a pull request was meant to be
# named and went missing, which is refused below instead of recorded empty.
# When the environment names nothing the pull request is read from the forge in
# the order that survives each caller: the candidate's open pull request, the
# open pull request of the task's recorded branch (a disposable worktree sits on
# a detached HEAD, where `gh pr view` cannot resolve a branch), then the pr= the
# task record already holds (the value acceptance compares against).
trim() { local v=${1-}; v=${v#"${v%%[![:space:]]*}"}; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
pr_was_set=false
[ -z "${JG_RECEIPT_PR+x}" ] || pr_was_set=true
PR_URL=$(trim "${JG_RECEIPT_PR-}")
if [ -z "$PR_URL" ] && command -v gh >/dev/null; then
  PR_URL=$(trim "$(cd "$REPO" && gh pr view --json url --jq .url 2>/dev/null || true)")
  BRANCH=$(trim "$(jg_dod_meta_value "$META" branch)")
  if [ -z "$PR_URL" ] && [ -n "$BRANCH" ]; then
    PR_URL=$(trim "$(cd "$REPO" && gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url' 2>/dev/null || true)")
  fi
fi
[ -n "$PR_URL" ] || PR_URL=$(trim "$(jg_dod_meta_value "$META" pr)")
if [ -z "$PR_URL" ] && [ "$pr_was_set" = true ]; then
  echo 'error: no pull request to record: JG_RECEIPT_PR is set but names none, and no pull request could be read for this candidate; set JG_RECEIPT_PR=<PR url>, or leave it unset and publish from the branch whose open pull request gh can read' >&2
  exit 1
fi
umask 077
TMP=$(mktemp "$STATE/.$ID.run-receipt.XXXXXX")
jq -n --arg task "$ID" --arg mode "$MODE" --arg gen "$GEN" \
  --arg head "$HEAD_SHA" --arg pr "$PR_URL" --arg verdict "$VERDICT" --argjson at "$(date +%s)" \
  --rawfile evidence "$EVIDENCE" '
  if ($evidence | test("[^[:space:]]")) then
    {schema:1, task:$task, mode:$mode, spawn_gen:$gen, head:$head, pr:$pr,
     verdict:$verdict, at:$at, evidence:$evidence}
  else error("nonempty evidence required") end
' > "$TMP"
if ! jg_backlog_atomic_transition publish "$TMP" "$STATE/$ID.run-receipt.json" "completion receipt" "$STATE"; then
  echo "error: $JG_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
TMP=
printf 'receipt: %s %s head=%s\n' "$ID" "$VERDICT" "$HEAD_SHA"
