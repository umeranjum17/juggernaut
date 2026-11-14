#!/usr/bin/env bash
# Sourced merge adapters owned by core, so a home's config/merge-gate and
# config/post-merge are honoured whether or not any feature is installed.
# Usage: . bin/jg-merge-gate-lib.sh
#
# Both are no-ops when the home has no such file. jg_dod_merge_gate runs
# config/merge-gate and refuses the merge when it exits nonzero; the two merge
# paths call it before every landing. jg_merge_post_hook runs config/post-merge
# after a recorded merge and never changes that merge's outcome. The merge-card
# feature defines the same two functions for homes that install it; core owning a
# copy is what makes them fire without it. Callers supply jg_dod_meta_value;
# jg_run_timed and jg_timed_out come from bin/jg-timeout-lib.sh, sourced here.
# There is no generic design gate: no size rule, hand-roll approval or first-draft receipt line refuses a merge or a done (pcp-s7).
# An unresolved product choice still blocks through its open decision (jg-captain-hold.sh blocking), and jg_design_fd_check stays for
# bin/jg-design-gate.sh board. jg_dod_demo_gate is the check for TakeOne demo videos, behind the config/takeone-demo switch.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
# The hooks also get FM_HOME (the pre-rename name) because installed feature hooks and done-done's merge-gate still read it; delete with the S10 shim.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
_JG_GATE_LIB_DIR=$(cd "$_jg_d" && pwd)
# shellcheck source=bin/jg-trunk-policy-lib.sh
[ -r "$_jg_d/jg-trunk-policy-lib.sh" ] && . "$_jg_d/jg-trunk-policy-lib.sh"
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
set -u

# shellcheck source=bin/jg-squad-lead-parent-lib.sh
[ ! -r "$_jg_d/jg-squad-lead-parent-lib.sh" ] || . "$_jg_d/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-bypass-record-lib.sh
[ ! -r "$_JG_GATE_LIB_DIR/jg-bypass-record-lib.sh" ] || . "$_JG_GATE_LIB_DIR/jg-bypass-record-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/jg-timeout-lib.sh"

jg_dod_merge_gate() {  # <config-dir> <home> <id> <meta> <candidate-head> <pr-url|->
  local gate=$1/merge-gate worktree out seconds=${JG_MERGE_GATE_TIMEOUT:-600} rc=0
  [ -e "$gate" ] || [ -L "$gate" ] || return 0
  [ -x "$gate" ] || { echo "merge refused: $gate is not executable"; return 1; }
  case $seconds in ''|0*|*[!0-9]*)
    echo "merge refused: JG_MERGE_GATE_TIMEOUT must be a positive number of seconds"; return 1 ;;
  esac
  worktree=$(jg_dod_meta_value "$4" worktree)
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" FM_HOME="$2" "$gate" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -ne 0 ] || return 0
  if jg_timed_out "$rc"; then
    echo "merge refused: merge gate timed out after ${seconds}s or exited $rc"
    return 1
  fi
  echo "merge refused by config/merge-gate (exit $rc)"
  return 1
}

# The completion receipt a merge read is a fact on the ticket's trail (a landing records its own in bin/jg-trunk.sh record_proofs).
jg_merge_trace_receipt() {  # <home> <id> <meta> <head|->
  local r=${3%/*}/$2.run-receipt.json verdict ticket
  ticket=$(sed -n 's/^ticket=//p' "$3" 2>/dev/null | tail -n 1)
  [ "$4" != - ] && [ -f "$r" ] && command -v jq >/dev/null 2>&1 || return 0
  verdict=$(jq -r 'select(.head == $h) | .verdict // empty' --arg h "$4" "$r" 2>/dev/null) || return 0
  [ -n "$verdict" ] || return 0
  JG_HOME=$1 "$_JG_GATE_LIB_DIR/jg-backlog.sh" trace record "${ticket:-$2}" used work-id "$2@${4:0:12}" --source jg-receipt \
    --payload "{\"verdict\":\"$verdict\"}" >/dev/null 2>&1 || echo "warning: the receipt of $2 could not be put on its ticket's trail" >&2
}

jg_merge_post_hook() {  # <config-dir> <home> <id> <meta> <head|-> <pr-url|->
  local hook=$1/post-merge worktree out rc=0 seconds=${JG_POST_MERGE_TIMEOUT:-120}
  jg_merge_trace_receipt "$2" "$3" "$4" "$5"
  [ -e "$hook" ] || [ -L "$hook" ] || return 0
  [ -x "$hook" ] || { echo "post-merge hook skipped: $hook is not executable"; return 0; }
  case $seconds in ''|0*|*[!0-9]*) seconds=120 ;; esac
  worktree=$(sed -n 's/^worktree=//p' "$4" 2>/dev/null | tail -1)
  out=$(jg_run_timed "$seconds" env JG_HOME="$2" FM_HOME="$2" "$hook" "$3" "${worktree:--}" "$5" "$6" 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || echo "post-merge hook failed (exit $rc); the merge stands"
  return 0
}

# True when the task's completion receipt binds this head with verdict PASS and its
# evidence carries a `<label>: <ref>` line (the receipts feature's record).
_jg_dod_receipt_line() {  # <state> <id> <head> <label>
  local receipt=$1/$2.run-receipt.json
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1 \
    && jq -se --arg task "$2" --arg head "$3" --arg label "$4" '
      length == 1 and (.[0] | .task == $task and .head == $head and .verdict == "PASS" and
      (.evidence | type == "string" and test("(^|\n)" + $label + ": [^[:space:]]")))
    ' "$receipt" >/dev/null 2>&1
}

# A path in absolute form without realpath: a known directory resolves with pwd -P.
jg_design_path_key() {  # <path>
  local p=$1 d b
  case $p in /*) ;; *) p=$PWD/$p ;; esac
  d=${p%/*}; b=${p##*/}
  [ -n "$d" ] || d=/
  printf '%s/%s\n' "$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "$d")" "$b"
}

# Refuse a design option first-draft did not make or refine, one line per refusal.
# --ref <ref>[,<ref>...] --root <dir> -- <option>...
jg_design_fd_check() {
  local ref='' root=$PWD rest one rec files keys='' key o rc=0 generated=0 seen=
  local -a OPTS=()
  while [ "$#" -gt 0 ]; do
    case $1 in
      --ref) shift; ref=${1:-} ;;
      --root) shift; root=${1:-$PWD} ;;
      --) shift; while [ "$#" -gt 0 ]; do OPTS+=("$1"); shift; done; break ;;
      *) printf 'jg-design-gate: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done
  if [ -z "$ref" ]; then
    echo "refused: no first-draft receipt was named, so first-draft made no design option"
    return 1
  fi
  rest=$ref
  while [ -n "$rest" ]; do
    one=${rest%%,*}
    case $rest in *,*) rest=${rest#*,} ;; *) rest='' ;; esac
    [ -n "$one" ] || continue
    rec=$one
    case $rec in /*) ;; *) rec=$root/$rec ;; esac
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    seen=1
    files=$(jq -r 'if ((.made.files // []) | length) > 0 or ((.refined.file // "") | length) > 0 then
        ([(.made.files // [])[]? | .file] + [.refined.file // empty])[] | select(type == "string" and length > 0)
      else empty end' "$rec" 2>/dev/null) || continue
    [ -n "$files" ] || continue
    generated=1
    keys="$keys
$(printf '%s\n' "$files" | while IFS= read -r key; do jg_design_path_key "$key"; done)"
  done
  if [ "$generated" != 1 ]; then
    if [ -n "$seen" ]; then
      echo "refused: first-draft receipt '$ref' is a judge-only run: it scored pages and made none, so it proves no design option"
    else
      echo "refused: first-draft receipt '$ref' does not resolve to a run record, so no design option has a make or refine receipt"
    fi
    rc=1
  fi
  for o in ${OPTS[@]+"${OPTS[@]}"}; do
    [ -n "$o" ] || continue
    printf '%s\n' "$keys" | grep -Fxq -- "$(jg_design_path_key "$o")" && continue
    echo "refused: option $o has no first-draft make or refine receipt, so first-draft did not make or refine it"
    rc=1
  done
  return "$rc"
}
# jg_ui_card_done_gate is the picture rule at done: a task recorded ui_change=yes
# (bin/jg-brief.sh --ui-change) reports done only when the board already holds an
# evidence card with pictures for its PR at this head. The lookup is
# bin/jg-proof-attach.sh card, the same one attach uses to reuse the merge card; its
# refusal names the one command that posts the card. ui_change=no, or a record
# with none (an older task), passes untouched.
jg_ui_card_done_gate() {  # <id> <meta> <head> <pr-url|->
  local id=$1 meta=$2 head=$3 pr=${4:--} dir out
  [ -n "$id" ] && [ -f "$meta" ] || return 0
  [ "$(jg_dod_meta_value "$meta" ui_change)" = yes ] || return 0
  dir=${BASH_SOURCE[0]%/*}; [ "$dir" != "${BASH_SOURCE[0]}" ] || dir=.
  [ -x "$dir/jg-proof-attach.sh" ] || return 0
  [ -n "$head" ] || { echo "done refused: $id is a UI change and its head commit could not be read, so its picture card cannot be found"; return 1; }
  out=$(JG_HOME=${JG_HOME:-} "$dir/jg-proof-attach.sh" card "$id" --pr "$pr" --head "$head" 2>&1) && return 0
  printf '%s\n' "$out"
  return 1
}
# jg_dod_demo_gate is the TakeOne demo-video gate both merge paths call. It is off
# until the home creates the presence flag config/takeone-demo (docs/configuration.md),
# and then works like the old design gate: a task recorded demo_call=yes (bin/jg-brief.sh
# --demo-call) merges only when its PASS completion receipt for this head carries a
# `takeone receipt: <ref>` evidence line. demo_call=no passes; a record with no
# demo_call (an older task) warns and counts as no. A shell check decides.
jg_dod_demo_gate() {  # <config-dir> <state> <id> <meta> <candidate-head>
  local config=$1 state=$2 id=$3 meta=$4 head=$5 call
  [ -e "$config/takeone-demo" ] || return 0
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" demo_call)
  case $call in
    no) return 0 ;;
    '') echo "warning: $id has no demo-video call recorded (an older brief); counting it as demo_call=no" >&2; return 0 ;;
    yes) ;;
    *) echo "merge refused: demo-video call for $id is malformed ('$call'); expected yes or no"; return 1 ;;
  esac
  _jg_dod_receipt_line "$state" "$id" "$head" "takeone receipt" && return 0
  echo "merge refused: $id is a product demo-video task (TakeOne: yes) and its completion receipt for this head has no 'takeone receipt: <ref>' evidence line; make the video with TakeOne and republish the receipt"
  return 1
}

# jg_dod_nav_gate is the no-silent-removal gate for a UI change (bin/jg-brief.sh
# --ui-change). A task recorded ui_change=yes merges only when its PR body (or, for a
# local-only landing, its commit messages) carries a `Nav before: a, b, c` line and a
# `Nav after: ...` line, and every item of before is still in after unless a
# `Removed by captain words: <quote>` line is present. ui_change=no passes; a record
# with no ui_change (an older task) warns and counts as no. A shell check decides.
# <where> names the place the lines belong in a refusal: "PR body" (the default) for a PR,
# "commit message" for a local landing, which has no PR body. <fallback> is read only when
# <text> lacks a Nav before or Nav after line; a local landing passes the lane's receipt
# evidence and done line, so a lane already at ready is not sent back for a missing line.
jg_dod_nav_gate() {  # <id> <meta> <text> [<where>] [<fallback text>]
  local id=$1 meta=$2 text=$3 where=${4:-PR body} fallback=${5:-} call before after item removed=''
  [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" ui_change)
  case $call in
    no) return 0 ;;
    '') echo "warning: $id has no UI change recorded (an older brief); counting it as ui_change=no" >&2; return 0 ;;
    yes) ;;
    *) echo "merge refused: UI change for $id is malformed ('$call'); expected yes or no"; return 1 ;;
  esac
  _jg_nav_line() {  # <label>: the last `<label>: <value>` line of the text, value only
    printf '%s\n' "$text" | tr -d '\r' | sed -n -E "s/^[[:space:]]*([-*][[:space:]]+)?$1:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\2/Ip" | tail -1
  }
  before=$(_jg_nav_line 'Nav before'); after=$(_jg_nav_line 'Nav after')
  if { [ -z "$before" ] || [ -z "$after" ]; } && [ -n "$fallback" ]; then
    text=$fallback; before=$(_jg_nav_line 'Nav before'); after=$(_jg_nav_line 'Nav after')
  fi
  if [ -z "$before" ] || [ -z "$after" ]; then
    echo "merge refused: $id is a UI change and its $where has no 'Nav before: <items>' and 'Nav after: <items>' lines listing the menus, tabs and screens"
    return 1
  fi
  _jg_nav_items() { printf '%s\n' "$1" | tr ';,' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d' | tr '[:upper:]' '[:lower:]'; }
  while IFS= read -r item; do
    _jg_nav_items "$after" | grep -qxF -- "$item" || removed="$removed${removed:+, }$item"
  done < <(_jg_nav_items "$before")
  [ -n "$removed" ] || return 0
  if [ -n "$(_jg_nav_line 'Removed by captain words')" ]; then return 0; fi
  echo "merge refused: $id is a UI change and its $where drops from Nav before ($removed) with no 'Removed by captain words: <quote>' line; a UI change never removes an existing menu, tab or screen unless the captain's own words ask for it"
  return 1
}

# Reads the sealed clean done-done run of <id> at <head> (`merge-card capture-json`: a read of the run records, no judge, no model).
# The compare of the account saved at the passed check belongs to the worker's own
# done (<kind> = done); every other reader (the lander, crew state, the lavish guard, a lead on another account) reads the proof as
# the lander does, with the caller's account and proof home cleared, so a proof saved under account A shows under account B.
# Usage: jg_dod_proof_receipt_read <kind> <home> <merge-card> <id> <head>
jg_dod_proof_receipt_read() {
  if [ "$1" = 'done' ]; then JG_HOME=$2 "$3" capture-json "$4" "$5"
  else env -u CLAUDE_CONFIG_DIR -u DONE_DONE_HOME JG_HOME="$2" "$3" capture-json "$4" "$5"; fi
}

# A sealed clean done-done run of <id> that stands for <head>: one at <head> itself, else one at the head of a sealed clean run of the
# lane's own folder that is the same change in <repo> (a rebase with no change). Prints merge-card's reason when the run at <head> was
# refused, and nothing when none exists. Reads the run records only: no judge, no model.
# Usage: jg_dod_sealed_run_for <kind> <home> <merge-card> <id> <head> <repo>
jg_dod_sealed_run_for() {
  local why f c data=${JG_DATA_OVERRIDE:-$2/data}
  jg_dod_proof_receipt_read "$1" "$2" "$3" "$4" "$5" >/dev/null 2>&1 && return 0
  why=$(jg_dod_proof_receipt_read "$1" "$2" "$3" "$4" "$5" 2>&1 >/dev/null)
  for f in "$data/$4/.done-done/runs/"*.json; do
    [ -f "$f" ] || continue
    c=$(jq -r 'select(.exit == 0 and .dirty == false) | .commit // empty' "$f" 2>/dev/null) || continue
    [ -n "$c" ] && [ "$c" != "$5" ] || continue
    "$3" same-change "$6" "$c" "$5" >/dev/null 2>&1 || continue
    jg_dod_proof_receipt_read "$1" "$2" "$3" "$4" "$c" >/dev/null 2>&1 && return 0
  done
  printf '%s\n' "$why"; return 1
}

# The proof a local-trunk lane needs at its exact head, checked once and whole: its completion receipt (PASS, this head, this
# incarnation) and a sealed clean done-done run at this head. A PASS receipt alone is not enough. No model judge is part of it:
# the merge-card check (a model reading the evidence) is an optional report and never a landing input, so a judge that errors or
# times out cannot hold a landing; a missing receipt, a missing or dirty sealed run and a changed head still refuse. Prints one line per
# missing input and returns 1 when any is missing; 0 and no output when all are there. The worker's done and the landing's
# admission both call it, so neither starts on a head whose proof is incomplete.
# A rebase with no change keeps the proof: the receipt and its sealed run count for this head when they are bound to it,
# or to a head that `merge-card same-change` finds is the same change in the lane's project (the
# lander still lints and tests the rebased commit on the tip). A proof bound to another change is named and not kept.
# The owner's bypass of proving (bin/jg-proof-bypass.sh) stands in for all of it: a bypass record for this exact head
# (bin/jg-bypass-record-lib.sh) leaves no gap. The worker's done, which comes before the tick writes that record, passes <done> as the
# sixth word, and a standing bypass that covers the ticket is enough there.
# Usage: jg_dod_trunk_proof_gaps <home> <state> <id> <meta> <head> [done]
jg_dod_trunk_proof_gaps() {
  jg_bypass_record_holds "$1" "$2" "$3" "$5" && return 0
  if [ "${6:-}" = 'done' ] && jg_bypass_standing "$1" "$3" "$(basename "$(sed -n 's/^project=//p' "$4" 2>/dev/null | tail -n 1)")" >/dev/null; then return 0; fi
  local home=$1 state=$2 id=$3 meta=$4 head=$5 r="$2/$3.run-receipt.json" gaps=0 mc why
  local repo rh rnote=''
  mc=$_JG_GATE_LIB_DIR/../core/merge-card/merge-card
  command -v jq >/dev/null 2>&1 || { echo "the proof inputs for $id cannot be checked: jq is required"; return 1; }
  repo=$(sed -n 's/^project=//p' "$meta" 2>/dev/null | tail -n 1)
  rh=$(jq -r '.head // empty' "$r" 2>/dev/null) || rh=''
  if [ -n "$rh" ] && [ "$rh" != "$head" ] && ! rnote=$("$mc" same-change "$repo" "$rh" "$head" 2>&1); then
    rnote="; its receipt is for ${rh:0:12} and not kept: ${rnote#merge-card: }"; rh=$head
  fi
  rh=${rh:-$head}
  if ! { [ -f "$r" ] && jq -e --arg h "$rh" --arg g "$(sed -n 's/^spawn_gen=//p' "$meta" 2>/dev/null | tail -n 1)" \
    '.verdict == "PASS" and .head == $h and (($g == "") or (.spawn_gen == $g))' "$r" >/dev/null 2>&1; }; then
    echo "no completion receipt with verdict PASS for head ${head:0:12} of $id (publish it with core/receipts/bin/jg-run-receipt.sh at this head$rnote)"; gaps=1
  fi
  if ! why=$(jg_dod_sealed_run_for "${6:-}" "$home" "$mc" "$id" "$head" "$repo" 2>&1); then
    why=${why%%$'\n'*}; why=${why#merge-card: }
    if [ -n "$why" ]; then echo "the sealed done-done run at head ${head:0:12} of $id was refused: $why"
    else echo "no sealed clean done-done run at head ${head:0:12} of $id (run the verify suite sealed: done-done run -- <suite command>; commit nothing after)"; fi
    gaps=1
  fi
  [ "$gaps" = 0 ]
}

# The lint the landing runs over a local-trunk lane's changed files (gate-lint, jg_trunk_gate), run at the lane's done so a
# finding reaches the worker in its own lane and not as a landing return. The largest family of gate failures was this one:
# a ShellCheck finding the worker's own narrower lint did not show (jgp-r2-s4). The command is the landing's, read the same
# way, and it runs in the lane's isolated copy, where HEAD^ is the trunk tip a one-commit lane starts on. Prints the tail of
# the output when the lint is red and returns 1. A project with no gate-lint, a copy that is not clean at <head>, or a run
# that timed out prints nothing and returns 0: the landing still runs the lint, so a check that cannot run never refuses.
# Usage: jg_dod_trunk_lint_gap <meta> <worktree> <head>
jg_dod_trunk_lint_gap() {
  local meta=$1 wt=$2 head=$3 proj gate out rc=0
  proj=$(sed -n 's/^project=//p' "$meta" 2>/dev/null | tail -n 1)
  [ -n "$proj" ] && [ -d "$wt" ] || return 0
  [ "$(git -C "$wt" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null)" = "$head" ] || return 0
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 0
  gate=$(jg_trunk_gate gate-lint "$(basename "$proj")" "$proj" "$head") || return 0
  out=$(cd "$wt" && jg_run_timed "${JG_DONE_LINT_SECONDS:-600}" bash -c "$gate" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || return 0
  printf 'the lint the landing runs (%s) is red at head %s (exit %s); fix every finding in this lane, run the sealed proof again and report done again:\n%s\n' "$gate" "${head:0:12}" "$rc" "$(printf '%s\n' "$out" | tail -n 20)"
  return 1
}

# The nav lines a local-landing lane may state outside its commit message: the evidence of its PASS completion receipt for
# this head, then its last done line (the `done [at=..]:` prefix removed; a Nav/Removed label after the first on one line
# starts its own line). Prints nothing when it has neither.
jg_dod_local_nav_fallback() {  # <state> <id> <head>
  local state=$1 id=$2 head=$3 receipt=$1/$2.run-receipt.json
  if [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1; then
    jq -r --arg task "$id" --arg head "$head" 'select(.task == $task and .head == $head and .verdict == "PASS") | .evidence // empty' "$receipt" 2>/dev/null
  fi
  if [ -f "$state/$id.status" ]; then
    grep -E '^done( \[[^]]*\])?:' "$state/$id.status" | tail -1 | sed -E 's/^done( \[[^]]*\])?:[[:space:]]*//; s/[[:space:]|]+(Nav before|Nav after|Removed by captain words):/\n\1:/Ig'
  fi
  return 0
}

# The gates a local landing passes, in one place so bin/jg-merge-local.sh and bin/jg-trunk.sh
# cannot drift: the captain hold, then receipt, demo, nav, config/merge-gate and the proof card.
# Prints the refusal and returns 1; returns 0 when every gate passes.
# A local-trunk landing (bin/jg-trunk.sh) passes the hold and the demo and nav gates here and has its proof checked
# up front by jg_dod_trunk_proof_gaps (receipt, sealed run); its owner signature never refuses it, so it
# passes `trunk` as <kind>.
# Usage: jg_dod_local_landing_gates <bin-dir> <config-dir> <home> <state> <id> <meta> <project> <base> <candidate> [trunk]
jg_dod_local_landing_gates() {
  local bin=$1 config=$2 home=$3 state=$4 id=$5 meta=$6 proj=$7 base=$8 candidate=$9 kind=${10:-} hold_status=0 proved
  JG_HOME="$home" JG_STATE_OVERRIDE="$state" "$bin/jg-captain-hold.sh" open "$id" --distinguish-absent || hold_status=$?
  case "$hold_status" in
    0) echo "error: task $id is still held for the captain; release it before merging" >&2; return 1 ;;
    1|3) ;;
    *) echo "error: could not determine whether task $id is still held for the captain; refusing to merge" >&2; return 1 ;;
  esac
  if [ "$kind" != trunk ] && declare -F jg_dod_receipt_accept >/dev/null; then jg_dod_receipt_accept "$state" "$id" "$meta" "$candidate" >&2 || return 1; fi
  # A trunk landing lands a rebased candidate, but its completion receipt binds the head the lane proved (jg_dod_trunk_proof_gaps
  # already kept that proof across a no-change rebase), so the receipt-bound demo gate reads it at that head.
  proved=$candidate
  if [ "$kind" = trunk ] && command -v jq >/dev/null 2>&1; then proved=$(jq -r '.head // empty' "$state/$id.run-receipt.json" 2>/dev/null) || proved=''; proved=${proved:-$candidate}; fi
  if declare -F jg_dod_demo_gate >/dev/null; then jg_dod_demo_gate "$config" "$state" "$id" "$meta" "$proved" >&2 || return 1; fi
  if declare -F jg_dod_nav_gate >/dev/null; then jg_dod_nav_gate "$id" "$meta" "$(git -C "$proj" log --format=%B "$base..$candidate")" "commit message" "$(jg_dod_local_nav_fallback "$state" "$id" "$proved")" >&2 || return 1; fi
  [ "$kind" != trunk ] || return 0
  if declare -F jg_dod_merge_gate >/dev/null; then jg_dod_merge_gate "$config" "$home" "$id" "$meta" "$candidate" - >&2 || return 1; fi
  if declare -F jg_dod_proof_gate >/dev/null; then jg_dod_proof_gate "$home" "$id" "$candidate" - >&2 || return 1; fi
  return 0
}

# jg_dod_proof_gate is the proof-card gate both merge paths call: a merge lands only
# when its proof card is on the board, so no lead has to remember it. It runs
# bin/jg-proof-attach.sh with --require, which posts the card when it is missing and
# refuses when the proof, the board client or the board is not there. A home with no
# board anywhere (its own config/post-merge, $JG_PROOF_BOARD, or its parent's) has
# nowhere to post and is not gated. A shell check decides.
jg_dod_proof_gate() {  # <home> <id> <candidate-head> <pr-url|->
  local home=$1 id=$2 head=$3 url=${4:--} out rc=0 args=()
  # shellcheck source=bin/jg-board-link-lib.sh
  if ! declare -F jg_board_file >/dev/null; then . "$_JG_GATE_LIB_DIR/jg-board-link-lib.sh" || return 0; fi
  jg_board_file "$home" >/dev/null || return 0
  [ "$url" = - ] || args=(--pr "$url")
  out=$(JG_HOME=$home "$_JG_GATE_LIB_DIR/jg-proof-attach.sh" attach ready "$id" --head "$head" --require 1 "${args[@]+"${args[@]}"}" 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/proof: /' >&2
  [ "$rc" -eq 0 ] && return 0
  echo "merge refused: $id has no proof card on the board; fix what the proof lines above name, then merge again"
  return 1
}
