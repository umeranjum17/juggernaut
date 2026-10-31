#!/usr/bin/env bash
# Sourced merge adapters owned by core, so a home's config/merge-gate and
# config/post-merge are honoured whether or not any add-on is installed.
# Usage: . bin/jg-merge-gate-lib.sh
#
# Both are no-ops when the home has no such file. jg_dod_merge_gate runs
# config/merge-gate and refuses the merge when it exits nonzero; the two merge
# paths call it before every landing. jg_merge_post_hook runs config/post-merge
# after a recorded merge and never changes that merge's outcome. The merge-card
# add-on defines the same two functions for homes that install it; core owning a
# copy is what makes them fire without it. Callers supply jg_dod_meta_value;
# jg_run_timed and jg_timed_out come from bin/jg-timeout-lib.sh, sourced here.
# jg_dod_design_gate is the first-draft design-call gate both merge paths call:
# a task recorded design_call=yes (bin/jg-brief.sh --design-call) merges only when
# its completion receipt (state/<id>.run-receipt.json, the receipts add-on's record)
# binds the candidate head with verdict PASS and its evidence carries a
# `first-draft receipt: <ref>` line. design_call=no passes; a record with no
# design_call (an older task) warns and counts as no. A task past the small-tweak size
# rule is design work whatever its call, and a smaller UI change needs the lead's or
# Main's hand-roll approval; bin/jg-design-gate.sh owns that contract. The receipt line
# is resolved, never believed: its run record must prove a make or refine and list every
# .html page the change adds, so a judge-only record and hand-authored option HTML are
# refused by name. jg_design_done_gate applies the same rule at done. jg_dod_demo_gate is the same
# check for TakeOne demo videos, behind the config/takeone-demo switch.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
# The hooks also get FM_HOME (the pre-rename name) because installed add-on hooks and done-done's merge-gate still read it; delete with the S10 shim.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
_JG_GATE_LIB_DIR=$(cd "$_jg_d" && pwd)
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
set -u

# shellcheck source=bin/jg-squad-lead-parent-lib.sh
[ ! -r "$_jg_d/jg-squad-lead-parent-lib.sh" ] || . "$_jg_d/jg-squad-lead-parent-lib.sh"
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

jg_merge_post_hook() {  # <config-dir> <home> <id> <meta> <head|-> <pr-url|->
  local hook=$1/post-merge worktree out rc=0 seconds=${JG_POST_MERGE_TIMEOUT:-120}
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
# evidence carries a `<label>: <ref>` line (the receipts add-on's record).
_jg_dod_receipt_line() {  # <state> <id> <head> <label>
  local receipt=$1/$2.run-receipt.json
  [ -f "$receipt" ] && [ ! -L "$receipt" ] && command -v jq >/dev/null 2>&1 \
    && jq -se --arg task "$2" --arg head "$3" --arg label "$4" '
      length == 1 and (.[0] | .task == $task and .head == $head and .verdict == "PASS" and
      (.evidence | type == "string" and test("(^|\n)" + $label + ": [^[:space:]]")))
    ' "$receipt" >/dev/null 2>&1
}

# The size rule (bin/jg-design-gate.sh owns it): UI files are matched by name, and a
# change is a small tweak when they change at most 40 lines and none is new.
JG_DESIGN_UI_RE='[.](html?|css|scss|sass|less|svg|jsx|tsx|vue|svelte|astro)$'
JG_DESIGN_TWEAK_LINES=40

# The captain's rule (30 Oct 2026): a design option first-draft did not make or refine is
# not a design option. `make` and `refine` print one run record naming the page they made, a
# `judge` record names only what it scored, and hand-authored HTML has none, so the receipt
# line is resolved and read. A reference is absolute or worktree-relative.
JG_DESIGN_RECEIPT_LABEL='first-draft receipt'

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

# The `<label>: <value>` values of a completion receipt bound to <head> with PASS,
# comma-joined; empty otherwise. bin/jg-design-gate.sh board takes the same list.
jg_design_receipt_value() {  # <state> <id> <head> <label>
  _jg_dod_receipt_line "$1" "$2" "$3" "$4" || return 1
  jq -r '.evidence // ""' "$1/$2.run-receipt.json" \
    | sed -n -E "s/^$4: ([^[:space:]].*[^[:space:]])[[:space:]]*\$/\1/p" | paste -sd, -
}

# The .html pages a change adds: the options it presents.
# ponytail: added pages only, so a design task that rewrites an existing page stays under
# the size rule; widen this if a rewritten option ever needs the receipt too.
jg_design_added_pages() {  # <worktree> <base-branch> <head>
  local wt=$1 base=${2:-main} head=$3 ref mb
  [ -d "$wt" ] && git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null || return 1
  ref=origin/$base
  git -C "$wt" rev-parse -q --verify "$ref^{commit}" >/dev/null || ref=$base
  mb=$(git -C "$wt" merge-base "$ref" "$head" 2>/dev/null) || return 1
  git -C "$wt" diff --name-only --no-renames --diff-filter=A "$mb" "$head" | grep -iE '[.]html?$'
}

# 0 when a design task's receipt names a record that made or refined every page it adds.
jg_design_first_draft_ok() {  # <state> <id> <meta> <head>
  local state=$1 id=$2 meta=$3 head=$4 ref wt page
  local -a OPTS=()
  wt=$(jg_dod_meta_value "$meta" worktree)
  ref=$(jg_design_receipt_value "$state" "$id" "$head" "$JG_DESIGN_RECEIPT_LABEL") || ref=''
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    while IFS= read -r page; do [ -n "$page" ] && OPTS+=("$wt/$page"); done \
      < <(jg_design_added_pages "$wt" "$(jg_dod_meta_value "$meta" base_branch)" "$head")
  fi
  jg_design_fd_check --ref "$ref" --root "${wt:-$PWD}" -- ${OPTS[@]+"${OPTS[@]}"}
}

# 0 for a task that is not design work, and for design work proved by first-draft; 1
# with the refusal printed when an option it presents has no make or refine record.
jg_design_done_gate() {  # <state> <id> <meta> <head>
  local state=$1 id=$2 meta=$3 head=$4 call size
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" design_call)
  size=$(jg_design_size "$(jg_dod_meta_value "$meta" worktree)" "$(jg_dod_meta_value "$meta" base_branch)" "$head") || size=''
  [ "$call" = yes ] || [ "${size%% *}" = design ] || return 0
  jg_design_first_draft_ok "$state" "$id" "$meta" "$head"
}

jg_design_size() {  # <worktree> <base-branch> <head>: prints `design|tweak <ui-lines> <new-ui-files>`
  local wt=$1 base=${2:-main} head=$3 ref mb lines new
  [ -d "$wt" ] && git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null || return 2
  ref=origin/$base
  git -C "$wt" rev-parse -q --verify "$ref^{commit}" >/dev/null || ref=$base
  mb=$(git -C "$wt" merge-base "$ref" "$head" 2>/dev/null) || return 2
  lines=$(git -C "$wt" diff --numstat --no-renames "$mb" "$head" \
    | awk -F'\t' -v re="$JG_DESIGN_UI_RE" 'tolower($3) ~ re && $1 != "-" { n += $1 + $2 } END { print n + 0 }')
  new=$(git -C "$wt" diff --name-only --no-renames --diff-filter=A "$mb" "$head" | grep -ciE "$JG_DESIGN_UI_RE")
  if [ "$new" -gt 0 ] || [ "$lines" -gt "$JG_DESIGN_TWEAK_LINES" ]; then echo "design $lines $new"; else echo "tweak $lines $new"; fi
}

jg_design_main_home() {  # <home>: the main home it reports to, following local squad lead parents
  local h=$1 depth=0
  while [ "$depth" -lt 8 ]; do
    [ -e "$(jg_compat_marker "$h")" ] || { printf '%s\n' "$h"; return 0; }
    declare -F jg_squad_lead_parent_record_parse >/dev/null || return 1
    jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$h")" && [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ] || return 1
    h=$JG_SQUAD_LEAD_PARENT_HOME
    depth=$((depth + 1))
  done
  return 1
}

jg_design_handroll_ok() {  # <state> <id>: the lead or Main approved hand-rolling this small UI change
  local f=$1/design-approvals/$2.handroll.json
  [ -f "$f" ] && [ ! -L "$f" ] && jq -e --arg id "$2" '.schema == 1 and .task == $id and (.by | type == "string" and length > 0)' "$f" >/dev/null 2>&1
}

jg_dod_design_gate() {  # <state> <id> <meta> <candidate-head>
  local state=$1 id=$2 meta=$3 head=$4 call size
  [ -n "$state" ] && [ -n "$id" ] && [ -f "$meta" ] || return 0
  call=$(jg_dod_meta_value "$meta" design_call)
  case $call in
    no|yes) ;;
    '') echo "warning: $id has no design call recorded (an older brief); counting it as design_call=no" >&2 ;;
    *) echo "merge refused: design call for $id is malformed ('$call'); expected yes or no"; return 1 ;;
  esac
  size=$(jg_design_size "$(jg_dod_meta_value "$meta" worktree)" "$(jg_dod_meta_value "$meta" base_branch)" "$head") \
    || { [ "$call" = yes ] || echo "warning: cannot measure the UI change of $id at $head; using its design call" >&2; }
  if [ "$call" != yes ] && [ "${size%% *}" != design ]; then
    case $size in ''|'tweak 0 0') return 0 ;; esac
    jg_design_handroll_ok "$state" "$id" && return 0
    echo "merge refused: $id hand-rolls a small UI change (${size#tweak }: UI lines, new UI files) with no hand-roll approval; its lead or Main runs bin/jg-design-gate.sh handroll $id"
    return 1
  fi
  if _jg_dod_receipt_line "$state" "$id" "$head" "$JG_DESIGN_RECEIPT_LABEL"; then
    jg_design_first_draft_ok "$state" "$id" "$meta" "$head" && return 0
    return 1
  fi
  if [ "$call" = yes ]; then
    echo "merge refused: $id is a design task (first-draft: yes) and its completion receipt for this head has no 'first-draft receipt: <ref>' evidence line; produce the design with first-draft and republish the receipt"
  else
    echo "merge refused: $id changes ${size#design } (UI lines, new UI files), past the small-tweak size, and its completion receipt for this head has no 'first-draft receipt: <ref>' evidence line; produce the design with first-draft and republish the receipt"
  fi
  return 1
}

# jg_dod_demo_gate is the TakeOne demo-video gate both merge paths call. It is off
# until the home creates the presence flag config/takeone-demo (docs/configuration.md),
# and then mirrors jg_dod_design_gate: a task recorded demo_call=yes (bin/jg-brief.sh
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
jg_dod_nav_gate() {  # <id> <meta> <text>
  local id=$1 meta=$2 text=$3 call before after item removed=''
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
  if [ -z "$before" ] || [ -z "$after" ]; then
    echo "merge refused: $id is a UI change and its PR body has no 'Nav before: <items>' and 'Nav after: <items>' lines listing the menus, tabs and screens"
    return 1
  fi
  _jg_nav_items() { printf '%s\n' "$1" | tr ';,' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed '/^$/d' | tr '[:upper:]' '[:lower:]'; }
  while IFS= read -r item; do
    _jg_nav_items "$after" | grep -qxF -- "$item" || removed="$removed${removed:+, }$item"
  done < <(_jg_nav_items "$before")
  [ -n "$removed" ] || return 0
  if [ -n "$(_jg_nav_line 'Removed by captain words')" ]; then return 0; fi
  echo "merge refused: $id is a UI change and its PR body drops from Nav before ($removed) with no 'Removed by captain words: <quote>' line; a UI change never removes an existing menu, tab or screen unless the captain's own words ask for it"
  return 1
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
