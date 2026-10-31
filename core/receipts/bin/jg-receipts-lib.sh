#!/usr/bin/env bash
# Completion-receipt acceptance and brief/meta helpers, sourced by the fork's
# bin/jg-dod-lib.sh, jg-spawn.sh and jg-promote.sh through an optional feature
# source. Needs the fork libs the caller already loaded (jg_dod_meta_value,
# jg_pr_head_valid). Absent feature = kun behavior (callers guard with declare -F).
# bin/jg-run-receipt.sh in this feature is the publisher.

# Completion receipts are task-owned state/<id>.run-receipt.json records.
# schema=1 binds task, mode, spawn_gen and exact candidate head to PASS or FAIL,
# with a nonempty evidence body (commands, outcomes and relevant limitations).
# bin/jg-run-receipt.sh publishes them atomically; evidence is embedded so the
# proof survives deletion of temporary logs and the disposable worktree.
# receipt_required=1 is set only for briefs carrying Completion receipt: required.
# Older records need no absent receipt, but ANY present receipt must validate:
# explicit FAIL, malformed, stale incarnation/head and empty proof all refuse.
# Once the merge path has recorded pr=, the receipt must name that same pull
# request (its URL carries the repository), except when that bound PR has
# already merged - proven by its recorded merge notification, matching
# bin/jg-pr-merge.sh - and the receipt names a different open PR of the same
# repository (the lane's next PR). Only the receipt file counts; a posted
# evidence card or PR comment is never a substitute.
# This is evidence supplied by the worker, not a replacement for forge checks,
# no-mistakes validation or merge authority. Both landing entrypoints consume
# the same gate against the exact head they will submit to the merge command.

# 0 when <receipt-pr> is the lane's next PR after a verifiably merged meta pr=:
# same forge identity (provider/host/path), a different number, meta pr merge-
# notified, and a live forge read showing the receipt PR open and unmerged.
# Runs in a subshell so the caller's JG_PR_* identity is unchanged.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

jg_receipts_next_pr_of_lane_ok() {  # <state> <id> <meta-pr> <receipt-pr>
  local state=$1 id=$2 meta_pr=$3 receipt_pr=$4
  [ -n "$meta_pr" ] && [ -n "$receipt_pr" ] && [ "$meta_pr" != "$receipt_pr" ] || return 1
  (
    m_provider='' m_host='' m_path='' m_number='' state_lc=''
    jg_pr_url_parse "$meta_pr" || exit 1
    m_provider=$JG_PR_PROVIDER
    m_host=$JG_PR_HOST
    m_path=$JG_PR_PATH
    m_number=$JG_PR_NUMBER
    jg_pr_poll_merge_already_notified "$state" "$id" \
      "$m_provider" "$m_host" "$m_path" "$m_number" || exit 1
    jg_pr_url_parse "$receipt_pr" || exit 1
    [ "$JG_PR_PROVIDER" = "$m_provider" ] \
      && [ "$JG_PR_HOST" = "$m_host" ] \
      && [ "$JG_PR_PATH" = "$m_path" ] \
      && [ "$JG_PR_NUMBER" != "$m_number" ] || exit 1
    case "$JG_PR_PROVIDER" in
      github) jg_pr_github_read_record "$JG_PR_OWNER" "$JG_PR_REPO" "$JG_PR_NUMBER" || exit 1 ;;
      gitlab) jg_pr_gitlab_read_record "$JG_PR_HOST" "$JG_PR_PATH" "$JG_PR_NUMBER" || exit 1 ;;
      forgejo) jg_pr_forgejo_read_record "$JG_PR_HOST" "$JG_PR_PATH" "$JG_PR_NUMBER" || exit 1 ;;
      gerrit) jg_pr_gerrit_read_record "$JG_PR_HOST" "$JG_PR_NUMBER" || exit 1 ;;
      *) exit 1 ;;
    esac
    [ "$JG_PR_RECORD_MERGED" = false ] || exit 1
    state_lc=$(printf '%s' "$JG_PR_RECORD_STATE" | tr '[:upper:]' '[:lower:]')
    case "$state_lc" in
      open|opened) exit 0 ;;
      *) exit 1 ;;
    esac
  )
}

jg_dod_receipt_accept() {  # <state> <id> <meta> <candidate-head>
  local state=$1 id=$2 meta=$3 head=$4 receipt required mode gen count pr receipt_pr
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  receipt="$state/$id.run-receipt.json"
  required=$(jg_dod_meta_value "$meta" receipt_required)
  count=$(awk -F= '$1 == "receipt_required" { n++ } END { print n+0 }' "$meta") || return 1
  if [ "$count" -gt 1 ] || { [ "$count" -eq 1 ] && [ "$required" != 1 ]; }; then
    echo "completion receipt requirement malformed for $id"
    return 1
  fi
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then
    [ "$required" != 1 ] && return 0
    echo "completion receipt missing for $id: publish one with: JG_HOME=${JG_HOME:-${JG_ROOT:-}} ${JG_ADDONS_DIR:-${JG_HOME:-${JG_ROOT:-}}/projects/juggernaut-addons}/receipts/bin/jg-run-receipt.sh $id PASS <evidence-file>"
    return 1
  fi
  mode=$(jg_dod_meta_value "$meta" mode)
  gen=$(jg_dod_meta_value "$meta" spawn_gen)
  pr=$(jg_dod_meta_value "$meta" pr)
  if jg_pr_head_valid "$head" && [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1 \
    && jq -se --arg task "$id" --arg mode "$mode" --arg gen "$gen" --arg head "$head" '
      length == 1 and (.[0] | .schema == 1 and .task == $task and .mode == $mode and
      .spawn_gen == $gen and .head == $head and .verdict == "PASS" and
      (.evidence | type == "string" and test("[^[:space:]]")) and
      (.at | type == "number" and . > 0))
    ' "$receipt" >/dev/null 2>&1; then
    receipt_pr=$(jq -r 'if type == "object" and (.pr | type == "string") then .pr else empty end' "$receipt" 2>/dev/null || true)
    if [ -z "$pr" ] || [ "$receipt_pr" = "$pr" ] \
      || jg_receipts_next_pr_of_lane_ok "$state" "$id" "$pr" "$receipt_pr"; then
      return 0
    fi
  fi
  echo "completion receipt refused for $id: FAIL, mismatched candidate/incarnation, malformed or absent evidence; publish one for this head with: JG_HOME=${JG_HOME:-${JG_ROOT:-}}${pr:+ JG_RECEIPT_PR=$pr} ${JG_ADDONS_DIR:-${JG_HOME:-${JG_ROOT:-}}/projects/juggernaut-addons}/receipts/bin/jg-run-receipt.sh $id PASS <evidence-file>"
  return 1
}


# The brief's receipt contract for ship modes: <task-id>.
jg_receipts_brief() {  # <id>
  local receipt_home_q receipt_tool_q
  receipt_home_q=$(printf '%q' "${JG_HOME:-${JG_ROOT:-}}")
  receipt_tool_q=$(printf '%q' "${JG_ADDONS_DIR:-${JG_HOME:-${JG_ROOT:-}}/projects/juggernaut-addons}/receipts/bin/jg-run-receipt.sh")
  cat <<EOF
Completion receipt: required
Before the final ready report (after validation in no-mistakes mode), write a nonempty evidence file containing commands run, results and limitations, then run \`JG_HOME=$receipt_home_q $receipt_tool_q $1 PASS <evidence-file>\` from the clean candidate checkout.
Use FAIL when verification failed; never label failed or unperformed checks PASS.
The evidence file may be a task-owned temporary file outside your worktree; that write and the helper's completion-receipt write into its supervising state directory are authorized.
Regenerate the receipt after any candidate change, including validation fixes or a rebase.
EOF
}

# Done acceptance for a ship task: picks the candidate head (worktree HEAD, the
# verified forge head, or the recorded pr_head for a named-head or cross-origin
# PR) and refuses when the receipt does not bind it. Called after the core
# decided the done line is gated. Needs the fork libs (jg_dod_*, status_line_note).
jg_receipts_accept_done() {  # <worktree> <mode> <line> <state> <id> <meta> [<forge-head>]
  local wt=$1 mode=$2 line=$3 state=$4 id=$5 meta=$6 forge_head=${7:-} url sha
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || sha=
  if [ -n "$forge_head" ] && jg_pr_head_valid "$forge_head"; then
    sha=$forge_head
  fi
  if [ -f "$meta" ]; then
    url=$(jg_dod_pr_url_from_done_note "$(status_line_note "$line")") || url=
    if [ -n "$url" ] && [ "$(jg_dod_meta_value "$meta" pr)" = "$url" ]; then
      if jg_dod_forge_head_is_named_head "$mode"; then
        if jg_pr_head_valid "$(jg_dod_meta_value "$meta" pr_head)"; then
          sha=$(jg_dod_meta_value "$meta" pr_head)
        fi
      elif [ "$mode" = direct-PR ] && jg_dod_pr_outside_origin "$wt" "$url" \
        && jg_pr_head_valid "$(jg_dod_meta_value "$meta" pr_head)"; then
        sha=$(jg_dod_meta_value "$meta" pr_head)
      fi
    fi
  fi
  jg_dod_receipt_accept "$state" "$id" "$meta" "$sha" || return 1
}

# Meta line for a spawn: prints receipt_required=1 for a ship task (the caller's
# $KIND, default ship) whose brief asks for receipts, or whose relaunch meta
# already carried it.
jg_receipts_inherit() {  # <brief> [<relaunch-meta>]
  [ "${KIND:-ship}" = ship ] || return 0
  if grep -qx 'Completion receipt: required' "$1" \
    || { [ -n "${2:-}" ] && [ -f "$2" ] && grep -qx 'receipt_required=1' "$2"; }; then
    echo 'receipt_required=1'
  fi
}

# Promotion: replace any stale requirement in the temp meta with the live one.
jg_receipts_promote() {  # <meta> <tmp-meta>
  local tmp=$2
  grep -v '^receipt_required=' "$tmp" > "$tmp.rr" || true
  echo 'receipt_required=1' >> "$tmp.rr"
  mv "$tmp.rr" "$tmp"
}

# Receipt candidate for bin/jg-pr-check.sh: the verified forge head when the pull
# request lives outside the worktree's origin repository (the merge binds to that
# head, not the worktree's HEAD), else nothing so the worker HEAD stands. The
# caller refuses any other output. PR_HEAD is empty when the forge head is
# unverified. Needs the fork lib (jg_dod_pr_outside_origin).
jg_receipts_pr_candidate() {  # <worktree> <pr-url> <mode> <meta> <verified-pr-head>
  local wt=$1 url=$2 pr_head=${5:-}
  [ -n "$pr_head" ] || return 0
  if jg_dod_pr_outside_origin "$wt" "$url"; then
    printf '%s' "$pr_head"
  fi
  return 0
}
