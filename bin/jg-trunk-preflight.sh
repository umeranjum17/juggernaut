#!/usr/bin/env bash
# The lane-side run of the landing chain: every gate a local-trunk landing passes, in landing order, at the lane's final
# head, with every missing input named in ONE run. No gate is met for the first time at landing.
#
# Usage: jg-trunk-preflight.sh [--landing] [--head <sha>] <task-id>   run the chain at the lane's branch head (or <sha>)
#        jg-trunk-preflight.sh --at-start <task-id>                   print the exact commands for gates 1-5 and the list 6-9; run and write nothing
#
# Exit 0 = PASS, 1 = at least one gate is missing, 2 = usage or an unreadable task.
#
#   0 branch          the ship branch is exactly one commit on the trunk tip (bin/jg-trunk.sh land refuses anything else)
#   1 sealed-run      a clean done-done run at the head, with the steps record (steps.json) done-done sealed into it
#   2 merge-card      merge-card check <id> <worktree> <head> - left a passing record for this head
#   3 receipt         merge-card receipt <id> <head> exits 0
#   4 checks-lint     the newest checks-lint row for the task's Checks file is a PASS (the owner-rules gate's own reading)
#   5 owner-signature the owner's detached signature over this receipt: the SIGNER's step after the lane's ready line.
#                     A lane run lists it as awaiting and still passes; --landing judges it as the lander does.
#   6 local gates     the landing's own gate functions (bin/jg-merge-gate-lib.sh), one by one: captain-hold, receipt-accept,
#                     design, demo, nav, merge-gate (config/merge-gate), proof-card
#   7 owner-guard     the owner-guard pre-push check over the trunk move
#   8 gate-lint       the project's gate-lint command at the head, in a clean clone, as the lander runs it
#   9 gate-tools      every tool the gate-lint and gate commands call, resolved with this PATH, with its version
#
# Gates 4 and 5 come from `jg-owner-rules-gate.sh diagnose`, the same code the merge gate judges with, and gate 6 calls the
# same functions bin/jg-merge-gate-lib.sh `jg_dod_local_landing_gates` calls, in its order. tests/jg-trunk-preflight.test.sh runs
# preflight --landing and `jg-trunk.sh land` over the same lanes so the two cannot drift. config/merge-gate and the proof card
# run only once gates 1-5 hold (they would only restate them). The proof card is posted when missing, as the landing posts it.
#
# On PASS the run writes data/<id>/preflight.<head>.json: the head, the gates, and whether the signature was valid or awaiting.
# A failing run removes any record it finds for that head. Never lands, signs, pushes or changes a lane.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
export JG_HOME JG_CONFIG_OVERRIDE="$CONFIG"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }
die() { echo "error: $*" >&2; exit 2; }

MC=$(cd "$SCRIPT_DIR/../core/merge-card" && pwd -P)/merge-card
OWNER_GATE=$(cd "$SCRIPT_DIR/../core/owner-rules/bin" && pwd -P)/jg-owner-rules-gate.sh
id='' mode=lane landing=0 head_arg=''
while [ $# -gt 0 ]; do
  case $1 in
    --at-start) mode=start ;;
    --landing) landing=1 ;;
    --head) [ $# -ge 2 ] || die "--head needs a commit"; head_arg=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$id" ] || { usage >&2; exit 2; }; id=$1 ;;
  esac
  shift
done
[ -n "$id" ] || { usage >&2; exit 2; }
jg_pr_task_id_valid "$id" || die "invalid task id"
command -v jq >/dev/null 2>&1 || die "jq is required"
META="$STATE/$id.meta"; [ -f "$META" ] || die "no meta for task $id at $META"
PROJ=$(jg_dod_meta_value "$META" project)
git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJ is not a git repository"
PN=$(basename "$PROJ")
pmode=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-project-mode.sh" --raw "$PN" 2>/dev/null | cut -d' ' -f1 || true)
[ "$pmode" = local-trunk ] || die "$PN is registered ${pmode:-as nothing}, not local-trunk; the trunk flow and this preflight apply to local-trunk projects only"
TRUNK=$(jg_trunk_branch "$PN" "$STATE")
branch=$(jg_dod_meta_value "$META" branch); branch=${branch:-fm/$id}
worktree=$(jg_dod_meta_value "$META" worktree)
tip=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$TRUNK^{commit}") || die "trunk branch $TRUNK is missing in $PROJ"
if [ -n "$head_arg" ]; then head=$(git -C "$PROJ" rev-parse --verify --quiet "$head_arg^{commit}") || die "cannot resolve $head_arg"
else head=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || head=''; fi

pol() { jg_trunk_policy "$1" "$PN"; }
lint_tool() {
  local t=${JG_CHECKS_LINT:-${XDG_DATA_HOME:-$HOME/.local/share}/jg-merge-on-green/checks-lint.sh}
  [ -x "$t" ] || t=${JG_MAIN_HOME:-$HOME/juggernaut}/config/jg-checks-lint.sh
  printf '%s\n' "$t"
}
checks_file="$DATA/$id/checks.md"
f_seal="cd '${worktree:-<your worktree>}' && DONE_DONE_EVIDENCE_ROOT='$DATA/$id' done-done run -- <the suite command your verify skill names>   (the run's capture folder must hold steps.json)"
f_card="JG_HOME='$JG_HOME' $MC check $id '${worktree:--}' ${head:-<head>} -"
f_receipt="JG_HOME='$JG_HOME' $MC receipt $id ${head:-<head>}"
f_lint="JG_HOME='$JG_HOME' $(lint_tool) $checks_file $DATA/$id"
f_sign="JG_HOME='$JG_HOME' $OWNER_GATE sign $id ${head:-<head>} -   (the signer runs it after your ready-to-sign line)"

if [ "$mode" = start ]; then
  head='<final-head>'
  f_card="JG_HOME='$JG_HOME' $MC check $id '${worktree:--}' $head -"
  f_receipt="JG_HOME='$JG_HOME' $MC receipt $id $head"
  f_sign="JG_HOME='$JG_HOME' $OWNER_GATE sign $id $head -   (the signer runs it after your ready-to-sign line)"
  echo "preflight --at-start $id (trunk $TRUNK, ${tip:0:12}): run these at the FINAL head, in this order, then run jg-trunk-preflight.sh $id before you say done"
  printf '  1 sealed-run       %s\n' "$f_seal"
  printf '  2 merge-card       %s\n' "$f_card"
  printf '  3 receipt          %s\n' "$f_receipt"
  printf '  4 checks-lint      %s\n' "$f_lint"
  printf '  5 owner-signature  %s\n' "$f_sign"
  echo "  the landing then checks, and a preflight run names any that fails:"
  echo "  6 local gates      captain-hold, receipt-accept, design, demo, nav, merge-gate, proof-card"
  echo "  7 owner-guard      the pre-push scan over the trunk move"
  printf '  8 gate-lint        %s   (in a clean clone at the head)\n' "$(pol gate-lint)"
  printf '  9 gate-tools       every tool of the gate-lint and gate commands must resolve on PATH=%s\n' "$PATH"
  printf '    gate command:    %s\n' "$(if [ "$(pol gate-mode)" = smoke ]; then pol gate-smoke; else pol gate-full; fi)"
  echo "  commit once; any later commit moves the head and voids gates 1-5."
  exit 0
fi

[ -n "$head" ] || die "branch $branch does not exist in $PROJ"

NAMES=() STATUS=() NOTES=() missing=0 sig_state=n/a
# report <n> <name> <ok|MISSING|AWAITING|SKIPPED|n/a> <note> [<fix>]
report() {
  local n=$1 name=$2 st=$3 note=$4 fix=${5:-}
  NAMES+=("$n $name"); STATUS+=("$st"); NOTES+=("$note")
  printf '%s %-16s [%s] %s\n' "$n" "$name" "$st" "$note"
  [ -z "$fix" ] || [ "$st" = ok ] || printf '    fix: %s\n' "$fix"
  [ "$st" != MISSING ] || missing=$((missing + 1))
}
indent() { sed 's/^/    | /'; }

echo "preflight $id at ${head:0:12} on $TRUNK ${tip:0:12}$([ "$landing" = 1 ] && echo ' (landing: the signature must be valid)')"

# 0 branch
n=$(git -C "$PROJ" rev-list --count "$tip..$head" 2>/dev/null || echo '?')
if ! git -C "$PROJ" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
  report 0 branch MISSING "the trunk moved: $branch is not on ${tip:0:12}" "rebase $branch onto $TRUNK, then prove the final head again"
elif [ "$n" != 1 ]; then
  report 0 branch MISSING "one commit per ticket: $branch has $n commits over $TRUNK" "squash $branch to one commit"
else report 0 branch ok "one commit on the trunk tip"; fi

# 1 sealed run with its steps record
rj=$(JG_HOME="$JG_HOME" "$MC" receipt-json "$id" "$head" 2>/dev/null || true)
if [ -z "$rj" ]; then
  report 1 sealed-run MISSING "no clean sealed done-done run at ${head:0:12}" "$f_seal"
else
  rid=$(jq -r '.run_id // ""' <<<"$rj"); rec="$DATA/$id/.done-done/runs/$rid.json"
  if [ -f "$rec" ] && ! jq -e '.steps | type == "object"' "$rec" >/dev/null 2>&1; then
    report 1 sealed-run MISSING "run $rid has no steps record: its capture folder holds no steps.json" "$f_seal"
  else report 1 sealed-run ok "run $rid"; fi
fi

# 2 merge-card check record
mcr="$DATA/$id/merge-card.json"
if [ ! -f "$mcr" ]; then report 2 merge-card MISSING "no check record at $mcr" "$f_card"
elif [ "$(jq -r '.head // ""' "$mcr" 2>/dev/null)" != "$head" ]; then
  report 2 merge-card MISSING "the check record is for $(jq -r '.head // "no head"' "$mcr" 2>/dev/null | cut -c1-12), not ${head:0:12}" "$f_card"
elif [ "$(jq -r '.verdict // ""' "$mcr" 2>/dev/null)" != pass ]; then
  report 2 merge-card MISSING "the check verdict is '$(jq -r '.verdict // "empty"' "$mcr" 2>/dev/null)', not pass" "$f_card"
else report 2 merge-card ok "verdict pass"; fi

# 3 receipt
if JG_HOME="$JG_HOME" "$MC" receipt "$id" "$head" >/dev/null 2>&1; then report 3 receipt ok "merge-card receipt exits 0"
else report 3 receipt MISSING "merge-card receipt $id ${head:0:12} does not exit 0" "$f_receipt"; fi

# 4 and 5 from the owner-rules gate's own evaluation
facts=$(JG_HOME="$JG_HOME" "$OWNER_GATE" diagnose "$id" "${worktree:--}" "$head" - 2>/dev/null || true)
fact() { printf '%s\n' "$facts" | sed -n "s/^$1=//p" | head -1; }
if [ "$facts" = owner-rules=off ] || [ -z "$facts" ]; then
  report 4 checks-lint n/a "owner rules are not enabled in this home"
  report 5 owner-signature n/a "owner rules are not enabled in this home"
else
  case $(fact lint) in
    pass) report 4 checks-lint ok "newest row is a PASS" ;;
    *) report 4 checks-lint MISSING "no PASS row for $checks_file" "$f_lint" ;;
  esac
  sig_state=$(fact signature)
  case $sig_state in
    valid) report 5 owner-signature ok "signature valid over this receipt" ;;
    *)
      if [ "$landing" = 1 ]; then report 5 owner-signature MISSING "signature is $sig_state for ${head:0:12}" "$f_sign"
      else report 5 owner-signature AWAITING "signature is $sig_state: the signer issues it after your ready-to-sign line" "$f_sign"; fi
      sig_state=awaiting ;;
  esac
fi

# 6 the landing's local gates, in jg_dod_local_landing_gates' order
gate_fn() {  # <n.name> <function> <args...>
  local label=$1 fn=$2 out rc=0; shift 2
  declare -F "$fn" >/dev/null || { report 6 "${label}" n/a "$fn is not defined in this home"; return 0; }
  out=$("$fn" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then report 6 "$label" ok "passes"; else report 6 "$label" MISSING "refused (exit $rc)"; printf '%s\n' "$out" | indent; fi
}
hold_rc=0
JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-captain-hold.sh" open "$id" --distinguish-absent >/dev/null 2>&1 || hold_rc=$?
case $hold_rc in
  0) report 6 captain-hold MISSING "task $id is still held for the captain" "release the hold: bin/jg-captain-hold.sh release $id" ;;
  1|3) report 6 captain-hold ok "not held" ;;
  *) report 6 captain-hold MISSING "could not tell whether $id is held (exit $hold_rc)" ;;
esac
gate_fn receipt-accept jg_dod_receipt_accept "$STATE" "$id" "$META" "$head"
gate_fn design jg_dod_design_gate "$STATE" "$id" "$META" "$head"
gate_fn demo jg_dod_demo_gate "$CONFIG" "$STATE" "$id" "$META" "$head"
nav_text=$(git -C "$PROJ" log --format=%B "$TRUNK..$head" 2>/dev/null || true)
gate_fn nav jg_dod_nav_gate "$id" "$META" "$nav_text"
if [ "$missing" -gt 0 ] || { [ "$landing" = 0 ] && [ "$sig_state" = awaiting ]; }; then
  why='runs once gates 1-5 hold'; [ "$missing" -gt 0 ] || why='runs once the signature is issued'
  report 6 merge-gate SKIPPED "config/merge-gate $why"
  report 6 proof-card SKIPPED "the proof card $why"
else
  gate_fn merge-gate jg_dod_merge_gate "$CONFIG" "$JG_HOME" "$id" "$META" "$head" -
  gate_fn proof-card jg_dod_proof_gate "$JG_HOME" "$id" "$head" -
fi

# 7 owner-guard over the trunk move
if out=$(printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$head" "$TRUNK" "$tip" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) 2>&1); then
  report 7 owner-guard ok "passes"
else report 7 owner-guard MISSING "refused the trunk move"; printf '%s\n' "$out" | indent; fi

# 8 gate-lint in a clean clone at the head, as the lander runs it
lint_cmd=$(pol gate-lint); log="$DATA/$id/preflight-lint.${head:0:12}.log"
work=$(mktemp -d "${TMPDIR:-/tmp}/jg-preflight.XXXXXX") || die "cannot make a scratch directory"
trap 'rm -rf -- "$work"' EXIT
if git clone -q --shared --no-checkout "$PROJ" "$work/tree" 2>/dev/null && git -C "$work/tree" checkout -q --detach "$head" 2>/dev/null; then
  mkdir -p "$DATA/$id"; rc=0
  (cd "$work/tree" && env -u JG_TASK_ID bash -c "$lint_cmd") > "$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then report 8 gate-lint ok "'$lint_cmd' passes at ${head:0:12}"
  else report 8 gate-lint MISSING "'$lint_cmd' failed (exit $rc); full log: $log"; tail -n 12 "$log" | indent; fi
else report 8 gate-lint MISSING "cannot check ${head:0:12} out in a clean clone of $PROJ"; fi

# 9 the tools the gate commands call, as this PATH resolves them
if [ "$(pol gate-mode)" = smoke ]; then gate_cmd=$(pol gate-smoke); else gate_cmd=$(pol gate-full); fi
tools=$(printf '%s\n%s\n' "$lint_cmd" "$gate_cmd" | sed -E 's/\$\(/\n/g; s/[();|&]+/\n/g' | awk '
  { sub(/^[[:space:]!"`]+/, ""); t = $1 }
  t == "" || t ~ /[$"=*{}<>\\]/ { next }
  t ~ /^(test|\[|\[\[|true|false|cd|echo|printf|export|set|exit|if|then|else|fi|for|do|done|while|case|esac|read|source|\.|:|-.*)$/ { next }
  !seen[t]++ { print t }')
unresolved='' resolved_json='{}'
while IFS= read -r t; do
  [ -n "$t" ] || continue
  case $t in
    */*) git -C "$PROJ" cat-file -e "$head:$t" 2>/dev/null && continue; p=$(command -v "$t" 2>/dev/null || true) ;;
    *) p=$(command -v "$t" 2>/dev/null || true) ;;
  esac
  if [ -z "$p" ]; then unresolved="$unresolved${unresolved:+, }$t"; continue; fi
  v=$(timeout 5 "$p" --version 2>&1 | head -n 1 | cut -c1-80 || true)
  resolved_json=$(jq -c --arg t "$t" --arg p "$p" --arg v "$v" '. + {($t): {path: $p, version: $v}}' <<<"$resolved_json")
done <<<"$tools"
if [ -n "$unresolved" ]; then report 9 gate-tools MISSING "not on PATH ($PATH): $unresolved" "install it, or put its directory on the PATH the landing check runs with"
else report 9 gate-tools ok "$(jq -r 'keys | join(", ")' <<<"$resolved_json")"; fi

# The record
rec="$DATA/$id/preflight.$head.json"
if [ "$missing" -eq 0 ]; then
  gates=$(for i in "${!NAMES[@]}"; do jq -cn --arg g "${NAMES[$i]}" --arg s "${STATUS[$i]}" --arg n "${NOTES[$i]}" '{gate: $g, status: $s, note: $n}'; done | jq -cs .)
  mkdir -p "$DATA/$id"
  jq -n --arg id "$id" --arg head "$head" --arg tip "$tip" --arg sig "$sig_state" --arg path "$PATH" --argjson at "$(date +%s)" \
    --argjson landing "$([ "$landing" = 1 ] && echo true || echo false)" --argjson gates "$gates" --argjson tools "$resolved_json" \
    '{schema: 1, task: $id, head: $head, trunk_tip: $tip, verdict: "PASS", signature: $sig, landing: $landing, at: $at, path: $path, tools: $tools, gates: $gates}' > "$rec.tmp.$$" \
    && mv -f "$rec.tmp.$$" "$rec"
  echo "PREFLIGHT PASS $id ${head:0:12} (signature: $sig_state); record: $rec"
  exit 0
fi
rm -f -- "$rec"
absent=''; for i in "${!NAMES[@]}"; do [ "${STATUS[$i]}" != MISSING ] || absent="$absent${absent:+, }${NAMES[$i]#* }"; done
echo "PREFLIGHT FAIL $id ${head:0:12}: $missing gate(s) missing: $absent"
exit 1
