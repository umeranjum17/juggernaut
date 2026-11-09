#!/usr/bin/env bash
# owner-rules merge-gate e2e: the config/merge-gate that wiring.sh writes, run with the args jg-pr-merge.sh passes.
# Usage: owner-rules/tests/owner-rules-gate.test.sh
# Proves one refusal (no receipt) and one clean pass (a stubbed sealed clean done-done run at the head), plus the
# screen: none exemption, the chained previous gate, and the no-op once uninstalled. No forge, no done-done.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
# shellcheck source=lib/policy-test-env.sh
. "$here/../../lib/policy-test-env.sh"
addons=$(cd "$here/../.." && pwd) || exit 1
work=$(mktemp -d "${TMPDIR:-/tmp}/owner-rules-gate.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
export HOME=$work/user XDG_DATA_HOME=$work/data
fails=0
ok() { printf 'ok - %s\n' "$1"; }
no() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2], want [$3]"; fi; }

home=$work/home; mkdir -p "$home/config" "$home/data/lane/.done-done/runs" "$work/bin" "$work/data/jg-merge-on-green"
printf '#!/bin/sh\nexit 0\n' > "$work/data/jg-merge-on-green/checks-lint.sh"; chmod +x "$work/data/jg-merge-on-green/checks-lint.sh"
pr=https://github.com/umeranjum17/juggernaut/pull/9 head=$(printf 'a%.0s' {1..40})
# gh stub: the PR body is whatever is in $work/body.
printf '#!/bin/sh\ncat "%s/body" 2>/dev/null\n' "$work" > "$work/bin/gh"; chmod +x "$work/bin/gh"
# A previous gate that records it ran.
printf '#!/bin/sh\necho "prev gate ran: $*"\n' > "$home/config/merge-gate"; chmod +x "$home/config/merge-gate"
cat > "$work/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && { jq '{decisions: .items}' "$2"; exit; }
[ "$1" = post ] || exit 2
shift; board=$1; shift
while [ "$1" != --from ]; do shift; done
card=$2
jq --slurpfile c "$card" '.items += [($c[0] + {type:"evidence",filer:"juggernaut-merge"})]' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
STUB
chmod +x "$work/bin/sign-off-axi"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
# shellcheck disable=SC2119,SC2120
gate() { # prints the gate's output and rc=; every output is also kept in $work/hints for the hint check below
  local out
  out=$(PATH=$work/bin:$PATH XDG_DATA_HOME=$work/data JG_HOME=$home JG_FLEET_BOARD=${3:-$work/board.json} "$home/config/merge-gate" lane - "${1:-$head}" "${2:-$pr}" 2>&1; printf 'rc=%s\n' "$?")
  printf '%s\n' "$out" | tee -a "$work/hints"
}
main=$work/main; mkdir -p "$main/config"
gate_inherit() { env -u JG_FLEET_BOARD PATH="$work/bin:$PATH" JG_HOME="$home" JG_MAIN_HOME="$main" "$home/config/merge-gate" lane - "$head" "$pr" 2>&1; printf 'rc=%s\n' "$?"; }
run=$home/data/lane/.done-done/runs/r1.json
seal() { printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","files":["a.png"],"run_id":"%s"}\n' "$1" "${2:-r1}" > "$run"; }
# The saved check approves the capture the sealed run holds at this head: merge-card's receipt cites only approved evidence.
card() { # [home]: that home's own card cites its own capture
  local h=${1:-$home}
  printf '{"head":"%s","verdict":"pass","check":{"claim":"checks passed","evidence":["%s"]}}\n' "$head" "$h/data/lane/a.png" > "$h/data/lane/merge-card.json"
}
card

"$addons/owner-rules/wiring.sh" "$home" >/dev/null
JG_HOME=$home "$addons/owner-rules/bin/jg-owner-rules-gate.sh" init-key >/dev/null
cp "$home/config/owner-rules-proof.pub" "$main/config/owner-rules-proof.pub"
sign_receipt() { JG_HOME=$home "$addons/owner-rules/bin/jg-owner-rules-gate.sh" sign lane "$head" "$pr" >/dev/null; }
is "installed: the home previous gate is kept at config/merge-gate.pre-chain" "$([ -x "$home/config/merge-gate.pre-chain" ] && echo yes)" yes
is "installed: one gate file holds both steps" "$(readlink -f "$home/config/merge-gate.pre-owner-rules")" "$(readlink -f "$home/config/merge-gate")"
"$addons/owner-rules/wiring.sh" "$home" >/dev/null && ok "install is idempotent" || no "second install failed"

REFUSAL="owner-rules: no passed-proof receipt for $pr: seal a clean done-done run at $head with: done-done run -- <the command that proves it> in the copy at $head"
is "refusal: no receipt" "$(gate)" "$REFUSAL
rc=1"
# The exact command that clears it, naming the ship's own copy when the gate has one.
mkdir -p "$work/ship"
with_wt=$(PATH=$work/bin:$PATH XDG_DATA_HOME=$work/data JG_HOME=$home JG_FLEET_BOARD=$work/board.json "$home/config/merge-gate" lane "$work/ship" "$head" "$pr" 2>&1)
is "refusal: no receipt names the copy to seal from" "$with_wt" "owner-rules: no passed-proof receipt for $pr: seal a clean done-done run at $head with: cd '$work/ship' && done-done run -- <the command that proves it>"
seal other; is "refusal: a run at a different head" "$(gate | tail -1)" "rc=1"
seal "$head"; printf '{"schema":1,"exit":0,"dirty":true,"commit":"%s","files":["a"],"run_id":"r1"}\n' "$head" > "$run"
is "refusal: a dirty run" "$(gate | tail -1)" "rc=1"
seal "$head"
unsigned=$(gate)
[[ $unsigned == *"no valid local proof signature"* ]] && ok "refusal: hand-built PASS run without a local signature" || no "unsigned proof was accepted: $unsigned"
sign_receipt
printf 'forged signature\n' > "$home/data/lane/proof-authorizations/$head.sig"
is "refusal: forged signature" "$(gate | grep -F 'local proof signature is invalid' | head -1)" "owner-rules: local proof signature is invalid for $pr at $head; re-run the passed-proof recipe and sign the exact receipt"
sign_receipt
wrong_scope=$(PATH=$work/bin:$PATH XDG_DATA_HOME=$work/data JG_HOME=$home JG_FLEET_BOARD=$work/board.json "$home/config/merge-gate" lane - "$head" 'https://github.com/umeranjum17/juggernaut/pull/10' 2>&1)
[[ $wrong_scope == *"local proof signature is invalid"* ]] && ok "refusal: signature cannot be replayed to another PR" || no "signature replayed across PRs: $wrong_scope"
seal "$head" r2
is "refusal: changed receipt invalidates the signature" "$(gate | grep -F 'local proof signature is invalid' | head -1)" "owner-rules: local proof signature is invalid for $pr at $head; re-run the passed-proof recipe and sign the exact receipt"
seal "$head"
sign_receipt
LINT="owner-rules: no checks-lint PASS for $pr at $head; run JG_HOME=$home $work/data/jg-merge-on-green/checks-lint.sh $pr $home/data/lane then merge again"
is "refusal: signed receipt but no checks-lint row" "$(gate)" "$LINT
rc=1"
log=$home/data/checks-gate.log
printf 't\t%s\tother\tpass\tok\nt\t%s\t%s\tfail\tno\n' "$pr" "$pr" "$head" > "$log"
is "refusal: lint row for another head, or failed" "$(gate | tail -1)" "rc=1"
printf 't\t%s\t%s\tpass\tok\n' "$pr" "$head" >> "$log"
card_refusal=$(gate)
is "refusal: receipt and lint but missing board card" "$(printf '%s\n' "$card_refusal" | tail -1)" "rc=1"
card_command=$(printf '%s\n' "$card_refusal" | sed -n 's|.*; post it with: JG_HOME=[^ ]* \(/[^ ]*\) post .*|\1|p')
[ -n "$card_command" ] && [ -x "$card_command" ] && ok "card hint names an executable absolute path" || no "card hint command is not an executable absolute path: $card_command"
# Every command a refusal tells the operator to run must be a path: a bare feature tool is not on PATH in every home.
# Checked on the hints the gate emitted above (lint, board-card, and receipt refusals), not on source text.
if grep -En '(^|[[:space:]])(merge-card|checks-lint\.sh|jg-[[:alnum:]_-]+\.sh)([[:space:]]|$)' "$work/hints"; then
  no "a gate hint names a bare feature tool"
else
  ok "gate hints name feature tools by path only"
fi
[ -s "$work/hints" ] && grep -q 'post it with' "$work/hints" && grep -q 'checks-lint PASS' "$work/hints" && ok "the hint check saw the card and lint hints" || no "the hint check saw no card or lint hint"
# Main-home fallback, home precedence, then the three-source refusal.
printf '%s\n' "$work/board.json" > "$main/config/fleet-board"
jq --arg h "$head" '.items += [{kind:"evidence",key:"merge-umeranjum17-juggernaut-pull-9",run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: lead without board config inherits main board" "$(gate_inherit)" "prev gate ran: lane - $head $pr
rc=0"
printf '%s\n' "$work/own-board.json" > "$home/config/fleet-board"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/own-board.json"
is "refusal: lead board takes precedence over main board" "$(gate_inherit | tail -1)" "rc=1"
rm -f "$home/config/fleet-board" "$main/config/fleet-board"
expected_board="owner-rules: fleet board is not configured for $pr (set JG_FLEET_BOARD, or write its path with: echo <board.json> > $home/config/fleet-board; the main home's $main/config/fleet-board is the fallback)"
is "refusal: all three board sources missing" "$(gate_inherit | tail -2)" "$expected_board
rc=1"
cardkey=merge-umeranjum17-juggernaut-pull-9
jq --arg k "$cardkey" --arg h "$head" '.items += [{kind:"evidence",type:"evidence",filer:"juggernaut-merge",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: receipt, lint, and card then previous gate" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"
jq --arg k "$cardkey-$head" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "pass: head-suffixed card matches" "$(gate | tail -1)" "rc=0"
jq --arg k "merge-umeranjum17-juggernaut-pull-12-$head" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
is "refusal: similar pull-12 prefix does not match pull-1" "$(gate | tail -1)" "rc=1"
for fields in "{\"run\":{\"commit\":\"$head\"}}" "{\"evidence\":{\"commit\":\"$head\"}}"; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "pass: card commit field $fields" "$(gate | tail -1)" "rc=0"
done
for fields in '{}' '{"run":{"commit":"wrong"}}' '{"evidence":{"commit":"wrong"}}' "{\"run\":{\"commit\":\"$head\"},\"evidence\":{\"commit\":\"wrong\"}}"; do
  jq --argjson fields "$fields" --arg k "$cardkey" '.items = [{kind:"evidence",key:$k} + $fields]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
  is "refusal: invalid card commit fields $fields" "$(gate | tail -1)" "rc=1"
done
jq --arg k "$cardkey" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
# A real fleet board holds hundreds of items (800 KB); one argv string is capped near 128 KB, so the gate must read the board by file.
big=$work/big-board.json
jq -n --arg k "$cardkey" --arg h "$head" '{schema:1,answers_only:false,items:([range(700) | {kind:"decision",key:("filler-\(.)"),title:([range(400) | "x"] | add)}] + [{kind:"evidence",key:$k,run:{commit:$h}}])}' > "$big"
jq '.items |= map(select(.kind == "decision"))' "$big" > "$work/big-board-nocard.json"
[ "$(wc -c < "$work/big-board-nocard.json")" -gt 200000 ] && ok "oversized board fixture is over 200 KB" || no "oversized board fixture is under 200 KB"
is "pass: oversized board with the card" "$(gate "$head" "$pr" "$big")" "prev gate ran: lane - $head $pr
rc=0"
big_missing=$(gate "$head" "$pr" "$work/big-board-nocard.json")
case $big_missing in
  "owner-rules: no passed-proof Evidence card for $pr; post it with: "*"
rc=1") ok "refusal: oversized board without the card names the missing card" ;;
  *) no "oversized board without the card: $big_missing" ;;
esac
case $big_missing in *"jq:"*|*"Argument list too long"*) no "oversized board leaked a tool error: $big_missing" ;; *) ok "oversized board leaks no tool error" ;; esac
# An evaluator that cannot run or answers non-JSON refuses with its real reason, never with the missing-card text.
printf '#!/bin/sh\necho "opa-stub: policy store is corrupt" >&2\nexit 1\n' > "$work/opa-fail"
printf '#!/bin/sh\necho "not json at all"\n' > "$work/opa-text"
chmod +x "$work/opa-fail" "$work/opa-text"
for stub in opa-fail:"opa-stub: policy store is corrupt" opa-text:"not json at all"; do
  failed=$(OPA=$work/${stub%%:*} gate)
  case $failed in
    "owner-rules: cannot evaluate the merge gate for $pr at $head: "*"${stub#*:}"*"
rc=1") ok "refusal: evaluator ${stub%%:*} prints its real reason" ;;
    *) no "evaluator ${stub%%:*}: $failed" ;;
  esac
  case $failed in *"no passed-proof Evidence card"*|*"jq:"*) no "evaluator ${stub%%:*} printed the missing-card text or a tool error: $failed" ;; *) ok "evaluator ${stub%%:*} is not reported as a missing card" ;; esac
done
rm -f "$run"; printf 'screen: none\noutcome: checks passed\nevidence: sealed receipt\n' > "$work/body"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: screen: none without receipt refuses" "$(gate | tail -1)" "rc=1"
seal other; is "refusal: screen: none with a sealed run at another head refuses" "$(gate | tail -1)" "rc=1"
# Canary rollout cannot skip the local signature, even for a screen-free merge with no receipt.
printf '%s\n' "$work/not-this-home" > "$home/config/owner-rules-canary"
skip_card=$(gate)
[[ $skip_card == *"no valid local proof signature"* ]] && ok "screen: none canary still refuses missing local authorization" || no "screen: none canary skipped signature: $skip_card"
rm -f "$home/config/owner-rules-canary"
seal "$head"
card
sign_receipt
jq -n '{schema:1,answers_only:false,items:[]}' > "$work/board.json"
text_card=$(gate)
is "pass: screen: none and receipt auto-posts text card" "$text_card" "owner-rules: $pr declares screen: none, so it takes the text-only Evidence card path; no capture is needed
merge-card: posted text-only $cardkey evidence card
prev gate ran: lane - $head $pr
rc=0"
case $text_card in "owner-rules: $pr declares screen: none, so it takes the text-only Evidence card path; no capture is needed"*) ok "screen: none: the text-only line is the gate's first line" ;; *) no "screen: none: no text-only card line at the top" ;; esac
jq -e --arg k "$cardkey" '.items | any(.[]; .key==$k and .kind=="evidence" and .media==null and .run.commit!=null)' "$work/board.json" >/dev/null && ok "auto-post: text-only receipt card exists" || no "auto-post: text-only receipt card missing"
# A capture is never demanded of a screen-free merge: the card carries no media and no media path is posted.
jq -e --arg k "$cardkey" '.items | any(.[]; .key==$k and (.media // []) == [])' "$work/board.json" >/dev/null && ok "screen: none: the card carries no capture" || no "screen: none: the card names a capture"
# A lead home finds Main's public key from the parent binding it carries; nobody exports JG_MAIN_HOME by hand.
# Main's home is $home here (it holds the key pair); the lead holds only the sealed run and the signature.
lead=$work/lead; mkdir -p "$lead/data" "$lead/config"; cp -r "$home/data/lane" "$lead/data/lane"; cp "$home/data/checks-gate.log" "$lead/data/" 2>/dev/null; card "$lead"
printf '#!/bin/sh\necho "prev gate ran: $*"\n' > "$lead/config/merge-gate"; chmod +x "$lead/config/merge-gate"
"$addons/owner-rules/wiring.sh" "$lead" >/dev/null
lead_gate() { env -u JG_MAIN_HOME PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data" JG_HOME="$lead" JG_FLEET_BOARD="$work/board.json" "$lead/config/merge-gate" lane - "$head" "$pr" 2>&1; printf 'rc=%s\n' "$?"; }
lead_nokey=$(lead_gate)
[[ $lead_nokey == *"no valid local proof signature"* ]] && ok "lead home with no parent binding does not see Main's key" || no "lead without binding: $lead_nokey"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$lead/.jg-squad-lead-parent"
jq --arg k "$cardkey" --arg h "$head" '.items = [{kind:"evidence",key:$k,run:{commit:$h}}]' "$work/board.json" > "$work/board.tmp" && mv "$work/board.tmp" "$work/board.json"
[[ $(lead_gate | tail -1) == rc=0 ]] && ok "lead home: the merge gate finds Main's public key from the parent binding" || no "lead home did not find Main's key: $(lead_gate)"
# A lead home signs with Main's key in place: the key is never copied, and the signature lands in the lead's own data.
rm -rf "$lead/data/lane/proof-authorizations"
[[ $(lead_gate | tail -1) == rc=1 ]] && ok "lead home: without its signature the gate refuses" || no "lead gate passed with no signature"
lead_sign=$(env -u JG_MAIN_HOME PATH="$work/bin:$PATH" XDG_DATA_HOME="$work/data" JG_HOME="$lead" "$addons/owner-rules/bin/jg-owner-rules-gate.sh" sign lane "$head" "$pr" 2>&1)
[[ $lead_sign == *"signed the local receipt"* && -f "$lead/data/lane/proof-authorizations/$head.sig" && ! -e "$lead/config/owner-rules-proof.key" ]] && ok "lead home: signs with Main's key, key not copied" || no "lead sign: $lead_sign"
[[ $(lead_gate | tail -1) == rc=0 ]] && ok "lead home: the gate accepts the lead's own signature" || no "lead signature rejected: $(lead_gate)"
printf 'schema=jg-squad-lead-parent.v1\nroute=remote\n' > "$lead/.jg-squad-lead-parent"
lead_bad=$(lead_gate)
[[ $lead_bad == *"fix: export JG_MAIN_HOME=<absolute path of Main's home>"* && $lead_bad == *rc=1 ]] && ok "lead home: an unusable binding names the exact fix" || no "unusable binding: $lead_bad"
rm -f "$lead/.jg-squad-lead-parent"
printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$work/board.json"
is "refusal: unreadable board refuses" "$(gate "$head" "$pr" "$work/missing-board" | tail -1)" "rc=1"
rm -f "$log"; is "refusal: screen: none still needs lint" "$(gate | tail -1)" "rc=1"
rm -f "$work/body"

"$addons/owner-rules/unwiring.sh" "$home" >/dev/null
is "uninstalled: no receipt is fine again" "$(gate)" "prev gate ran: lane - $head $pr
rc=0"

[ "$fails" -eq 0 ] && echo "PASS owner-rules-gate" || { echo "FAIL owner-rules-gate: $fails"; exit 1; }
