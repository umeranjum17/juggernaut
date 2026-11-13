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
# repository (the lane's next PR), or when the bound PR was closed unmerged and the receipt names an open PR of the
# same repository that carries a patch-equivalent of every commit it had (a rebased copy). Only the receipt file counts; a posted
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

# 0 when the meta pr was closed without merging and every commit it carried has a patch-equivalent in <candidate-head>
# (git cherry shows no "+" line, at least one commit): a rebased or cherry-picked copy of the same work. The objects
# are fetched into a throwaway repo that borrows the project clone's objects, so the clone is never written.
# A predecessor with no commit of its own, an unreadable ref, or one commit the candidate does not carry refuses.
jg_receipts_superseded_copy_ok() {  # <meta> <candidate-head>
  local meta=$1 cand=$2 project base pred url t limit out rc=1
  project=$(jg_dod_meta_value "$meta" project)
  base=$(jg_dod_meta_value "$meta" base_branch)
  pred=$(jg_dod_meta_value "$meta" pr_head)
  [ -n "$project" ] && [ -n "$base" ] && [ -n "$cand" ] && jg_pr_head_valid "$pred" || return 1
  url=$(git -C "$project" remote get-url origin 2>/dev/null) || return 1
  t=$(mktemp -d "${TMPDIR:-/tmp}/jg-supersede.XXXXXX") || return 1
  git init -q --bare "$t" 2>/dev/null \
    && printf '%s/objects\n' "$(git -C "$project" rev-parse --absolute-git-dir)" > "$t/objects/info/alternates" \
    && git -C "$t" fetch -q "$url" "+refs/heads/$base:refs/jg/base" "$pred" "$cand" 2>/dev/null \
    && git -C "$t" update-ref refs/jg/cand "$cand" && git -C "$t" update-ref refs/jg/pred "$pred" \
    && limit=$(git -C "$t" merge-base refs/jg/pred refs/jg/base 2>/dev/null) && [ -n "$limit" ] \
    && out=$(git -C "$t" cherry refs/jg/cand refs/jg/pred "$limit" 2>/dev/null) && [ -n "$out" ] \
    && ! printf '%s\n' "$out" | grep -q '^+' && rc=0
  rm -rf -- "$t"
  return $rc
}

# 0 when <receipt-pr> may stand for <meta-pr>: the lane's next open PR after the meta pr merged, or, given the
# candidate head, a patch-equivalent copy of a meta pr that was closed unmerged.
jg_receipts_next_pr_of_lane_ok() {  # <state> <id> <meta-pr> <receipt-pr> [<meta> <candidate-head>]
  local state=$1 id=$2 meta_pr=$3 receipt_pr=$4 meta=${5:-} cand=${6:-}
  [ -n "$meta_pr" ] && [ -n "$receipt_pr" ] && [ "$meta_pr" != "$receipt_pr" ] || return 1
  (
    m_provider='' m_host='' m_path='' m_number='' state_lc=''
    _jg_receipts_read() {
      case "$JG_PR_PROVIDER" in
        github) jg_pr_github_read_record "$JG_PR_OWNER" "$JG_PR_REPO" "$JG_PR_NUMBER" ;;
        gitlab) jg_pr_gitlab_read_record "$JG_PR_HOST" "$JG_PR_PATH" "$JG_PR_NUMBER" ;;
        forgejo) jg_pr_forgejo_read_record "$JG_PR_HOST" "$JG_PR_PATH" "$JG_PR_NUMBER" ;;
        gerrit) jg_pr_gerrit_read_record "$JG_PR_HOST" "$JG_PR_NUMBER" ;;
        *) return 1 ;;
      esac
    }
    jg_pr_url_parse "$meta_pr" || exit 1
    m_provider=$JG_PR_PROVIDER
    m_host=$JG_PR_HOST
    m_path=$JG_PR_PATH
    m_number=$JG_PR_NUMBER
    if ! jg_pr_poll_merge_already_notified "$state" "$id" \
      "$m_provider" "$m_host" "$m_path" "$m_number"; then
      # Not merged: only a closed, never-merged predecessor whose every commit the candidate carries.
      [ -n "$meta" ] || exit 1
      _jg_receipts_read || exit 1
      [ "$JG_PR_RECORD_MERGED" = false ] || exit 1
      state_lc=$(printf '%s' "$JG_PR_RECORD_STATE" | tr '[:upper:]' '[:lower:]')
      case "$state_lc" in closed) ;; *) exit 1 ;; esac
      jg_receipts_superseded_copy_ok "$meta" "$cand" || exit 1
    fi
    jg_pr_url_parse "$receipt_pr" || exit 1
    [ "$JG_PR_PROVIDER" = "$m_provider" ] \
      && [ "$JG_PR_HOST" = "$m_host" ] \
      && [ "$JG_PR_PATH" = "$m_path" ] \
      && [ "$JG_PR_NUMBER" != "$m_number" ] || exit 1
    _jg_receipts_read || exit 1
    [ "$JG_PR_RECORD_MERGED" = false ] || exit 1
    state_lc=$(printf '%s' "$JG_PR_RECORD_STATE" | tr '[:upper:]' '[:lower:]')
    case "$state_lc" in
      open|opened) exit 0 ;;
      *) exit 1 ;;
    esac
  )
}

_JG_RECEIPTS_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# The receipt publisher a refusal tells a worker to run. It lives in this checkout's
# core/receipts/bin; JG_CORE_DIR overrides the publisher only
# when it really holds one, so a stale value never prints a path that does not exist.
jg_receipts_tool() {
  local over=${JG_CORE_DIR:-}/receipts/bin/jg-run-receipt.sh
  if [ -n "${JG_CORE_DIR:-}" ] && [ -x "$over" ]; then printf '%s\n' "$over"; else printf '%s\n' "$_JG_RECEIPTS_LIB_DIR/jg-run-receipt.sh"; fi
}

# The acceptance rules are policy/gate/receipt.rego and policy/gate/rules.json: this reads the task record and the
# receipt file into facts, asks the one evaluator, and prints the message for the reason it gives. The forge read for
# "the lane's next pull request" is made only when the policy asks for it. An evaluator that cannot run refuses.
jg_dod_receipt_accept() {  # <state> <id> <meta> <candidate-head> [<pr-url>]
  local state=$1 id=$2 meta=$3 head=$4 receipt pr file hv=false facts docs verdict count why
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  receipt="$state/$id.run-receipt.json"
  # A lane holds one slot but may land several pull requests: put back the receipt published for this head, if any.
  jg_pr_head_valid "$head" && "$_JG_RECEIPTS_LIB_DIR/jg-receipt-restore.sh" "$state" "$id" "$head" >/dev/null
  # The optional <pr-url> is the pull request being recorded for merge, which a lane with several
  # pull requests holds apart from the pr= its record carried from an earlier one.
  pr=${5:-$(jg_dod_meta_value "$meta" pr)}
  count=$(awk -F= '$1 == "receipt_required" { n++ } END { print n+0 }' "$meta") || return 1
  file=other
  if [ ! -e "$receipt" ] && [ ! -L "$receipt" ]; then file="absent"; elif [ -f "$receipt" ] && [ ! -L "$receipt" ]; then file="file"; fi
  jg_pr_head_valid "$head" && hv=true
  command -v jq >/dev/null 2>&1 || { echo "completion receipt cannot be checked for $id: jq is required"; return 1; }
  [ "$file" = file ] || receipt=/dev/null
  docs=$(jq -sc . "$receipt" 2>/dev/null) || docs=null
  facts=$({ jq -nc --arg task "$id" --arg mode "$(jg_dod_meta_value "$meta" mode)" --arg gen "$(jg_dod_meta_value "$meta" spawn_gen)" \
    --arg head "$head" --argjson hv "$hv" --argjson n "$count" --arg req "$(jg_dod_meta_value "$meta" receipt_required)" \
    --arg pr "$pr" --arg file "$file" '{task: $task, mode: $mode, spawn_gen: $gen, head: $head, head_valid: $hv, required_lines: $n,
      required: $req, pr: $pr, file: $file, next_pr_ok: null}'; printf '%s\n' "$docs"; } | jq -sc '.[0] + {docs: .[1]}')
  if ! verdict=$(printf '%s' "$facts" | "$_JG_RECEIPTS_LIB_DIR/../../../bin/jg-guard-host.sh" eval gate.receipt 2>&1); then
    echo "completion receipt cannot be checked for $id: ${verdict:-no answer}"
    return 1
  fi
  if [ "$(jq -r '.need // ""' <<<"$verdict")" = next_pr ]; then
    local ok=false
    jg_receipts_next_pr_of_lane_ok "$state" "$id" "$pr" "$(jq -r 'if (.docs[0].pr | type) == "string" then .docs[0].pr else "" end' <<<"$facts")" "$meta" "$head" && ok=true
    verdict=$(printf '%s' "$facts" | jq -c --argjson ok "$ok" '.next_pr_ok = $ok' | "$_JG_RECEIPTS_LIB_DIR/../../../bin/jg-guard-host.sh" eval gate.receipt 2>&1) || { echo "completion receipt cannot be checked for $id: ${verdict:-no answer}"; return 1; }
  fi
  [ "$(jq -r '.ok' <<<"$verdict")" != true ] || return 0
  why=$(jq -r '.why' <<<"$verdict")
  case $why in
    malformed) echo "completion receipt requirement malformed for $id" ;;
    missing) echo "completion receipt missing for $id: publish one with: JG_HOME=${JG_HOME:-${JG_ROOT:-}} JG_RECEIPT_PR=${pr:-<PR url>} $(jg_receipts_tool) $id PASS <evidence-file>" ;;
    *) echo "completion receipt refused for $id: FAIL, mismatched candidate/incarnation, malformed or absent evidence; publish one for this head with: JG_HOME=${JG_HOME:-${JG_ROOT:-}} JG_RECEIPT_PR=${pr:-<PR url>} $(jg_receipts_tool) $id PASS <evidence-file>" ;;
  esac
  return 1
}


# The brief's receipt contract for ship modes: <task-id>.
jg_receipts_brief() {  # <id>
  local receipt_home_q receipt_tool_q
  receipt_home_q=$(printf '%q' "${JG_HOME:-${JG_ROOT:-}}")
  receipt_tool_q=$(printf '%q' "$(jg_receipts_tool)")
  cat <<EOF
Completion receipt: required
Before the final ready report (after validation in no-mistakes mode), write a nonempty evidence file containing commands run, results and limitations, then run \`JG_HOME=$receipt_home_q JG_RECEIPT_PR=<PR url> $receipt_tool_q $1 PASS <evidence-file>\` from the clean candidate checkout; a receipt for a PR needs JG_RECEIPT_PR.
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
      elif jg_delivery_style_is "$mode" publishes && jg_dod_pr_outside_origin "$wt" "$url" \
        && jg_pr_head_valid "$(jg_dod_meta_value "$meta" pr_head)"; then
        sha=$(jg_dod_meta_value "$meta" pr_head)
      fi
    fi
  fi
  # At merge time (bin/jg-pr-merge.sh records through bin/jg-pr-check.sh) the receipt must name the
  # pull request being merged, not the one an earlier arm left in the record.
  if [ "${JG_PR_CHECK_MERGE:-}" = 1 ] && [ -n "$forge_head" ]; then
    jg_dod_receipt_accept "$state" "$id" "$meta" "$sha" "${url:-}" || return 1
  else
    jg_dod_receipt_accept "$state" "$id" "$meta" "$sha" || return 1
  fi
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
# request lives outside the worktree's origin repository, or when the merge path
# is recording it (JG_PR_CHECK_MERGE=1: the merge binds to that head, not the
# worktree's HEAD, which is another pull request's head in a lane that holds
# several), else nothing so the worker HEAD stands. The
# caller refuses any other output. PR_HEAD is empty when the forge head is
# unverified. Needs the fork lib (jg_dod_pr_outside_origin).
jg_receipts_pr_candidate() {  # <worktree> <pr-url> <mode> <meta> <verified-pr-head>
  local wt=$1 url=$2 pr_head=${5:-}
  [ -n "$pr_head" ] || return 0
  if [ "${JG_PR_CHECK_MERGE:-}" = 1 ] || jg_dod_pr_outside_origin "$wt" "$url"; then
    printf '%s' "$pr_head"
  fi
  return 0
}
