#!/usr/bin/env bash
# E2E: the owner-rules merge gate's decisions on a matrix of homes, driven through the real gate script, the real
# merge-card and a real signature. gate-matrix.jsonl holds, per case, the exit code and the exact output the gate gave
# when its refusal order was shell code; the order now lives in policy/gate/owner_proof.rego and this test holds it
# to those recorded decisions. A case is one choice per dimension: screen-free or not, the sealed done-done run, the
# canary list, its waiver, the local signature, the checks-lint row, the fleet board, and the card writer.
# Usage: tests/gate-matrix.test.sh           check every case against its recorded decision
#        RECORD=1 tests/gate-matrix.test.sh   re-record the decisions (only after a deliberate rule change)
# Needs opa and go (the guard host evaluates the policy); with either absent the test skips.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
GATE=${OWNER_RULES_GATE:-$ROOT/core/owner-rules/bin/jg-owner-rules-gate.sh}
CASES=$here/gate-matrix.jsonl
# shellcheck source=lib/policy-test-env.sh
[ -n "${RECORD:-}" ] || . "$ROOT/core/lib/policy-test-env.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/gate-matrix.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/user"
export HOME=$work/user XDG_DATA_HOME=$work/data
head=$(printf 'a%.0s' {1..40}) pr=https://github.com/o/r/pull/9
printf '#!/bin/sh\ncat "%s/body" 2>/dev/null\n' "$work" > "$work/bin/gh"
cat > "$work/bin/sign-off-axi" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && { jq '{decisions: .items}' "$2"; exit; }
[ "$1" = post ] || exit 2
[ ! -e "$SIGNOFF_FAIL" ] || exit 1
shift; board=$1; shift
while [ "$1" != --from ]; do shift; done
jq --slurpfile c "$2" '.items += [($c[0] + {type:"evidence",filer:"juggernaut-merge"})]' "$board" > "$board.tmp" && mv "$board.tmp" "$board"
STUB
chmod +x "$work/bin/gh" "$work/bin/sign-off-axi"

# case_line <none> <run> <canary> <waiver> <sig> <lint> <board> <writer> <pr>
case_line() { printf 'none=%s run=%s canary=%s waiver=%s sig=%s lint=%s board=%s writer=%s pr=%s\n' "$@"; }
gen_cases() {
  local base=(0 ok absent none valid pass card ok url) i v n r c s
  case_line "${base[@]}"
  local dims=("0 1" "ok absent other dirty" "absent other listed" "none future past junk" "valid none bad stale" "pass none fail other" "card unset unreadable empty wrong" "ok fail" "url local")
  for i in 0 1 2 3 4 5 6 7 8; do
    for v in ${dims[$i]}; do
      local c1=("${base[@]}"); c1[i]=$v; case_line "${c1[@]}"
    done
  done
  for n in 0 1; do for r in ok absent; do for c in absent other listed; do for s in valid none; do
    case_line $n $r $c none $s pass empty ok url
  done; done; done; done
  for n in 0 1; do for b in card unset unreadable empty wrong; do for wr in ok fail; do
    case_line $n ok listed none valid pass $b $wr url
  done; done; done
}
setup_and_run() { # <case line>: build the home, run the gate, print "rc=<n>" then the normalized output
  local line=$1 v home b
  declare -A d=()
  for kv in $line; do d[${kv%%=*}]=${kv#*=}; done
  home=$work/home; rm -rf -- "$home" "$work/body" "$work/board.json" "$work/signoff-fail"
  mkdir -p "$home/config" "$home/data/lane/.done-done/runs" "$XDG_DATA_HOME/jg-merge-on-green"
  printf 'on\n' > "$home/config/owner-rules"
  printf '#!/bin/sh\nexit 0\n' > "$XDG_DATA_HOME/jg-merge-on-green/checks-lint.sh"; chmod +x "$XDG_DATA_HOME/jg-merge-on-green/checks-lint.sh"
  [ "${d[none]}" = 0 ] || printf 'screen: none\noutcome: checks passed\nevidence: sealed receipt\n' > "$work/body"
  local url=$pr; [ "${d[pr]}" = url ] || url=-
  seal() { printf '{"schema":1,"exit":0,"dirty":%s,"commit":"%s","files":["%s"],"run_id":"%s"}\n' "$3" "$1" "$2" "${4:-r1}" > "$home/data/lane/.done-done/runs/r1.json"; }
  printf '{"head":"%s","verdict":"pass","check":{"claim":"checks passed","evidence":["%s"]}}\n' "$head" "$home/data/lane/a.png" > "$home/data/lane/merge-card.json"
  seal "$head" a.png false
  JG_HOME=$home "$GATE" init-key >/dev/null
  JG_HOME=$home "$GATE" sign lane "$head" "$url" >/dev/null 2>&1
  case ${d[sig]} in
    none) rm -f "$home/data/lane/proof-authorizations/$head.sig" ;;
    bad) printf 'forged\n' > "$home/data/lane/proof-authorizations/$head.sig" ;;
    stale) seal "$head" a.png false r2 ;;
  esac
  case ${d[run]} in
    ok) [ "${d[sig]}" = stale ] || seal "$head" a.png false ;;
    absent) rm -f "$home/data/lane/.done-done/runs/r1.json" ;;
    other) seal other a.png false ;;
    dirty) seal "$head" a.png true ;;
  esac
  case ${d[canary]} in other) echo "$work/elsewhere" > "$home/config/owner-rules-canary" ;; listed) echo "$home" > "$home/config/owner-rules-canary" ;; esac
  case ${d[waiver]} in future) echo 2999-01-01T00:00Z > "$home/config/owner-rules-canary-waiver" ;; past) echo 2000-01-01T00:00Z > "$home/config/owner-rules-canary-waiver" ;; junk) echo soon > "$home/config/owner-rules-canary-waiver" ;; esac
  src=$url; [ "$url" != - ] || src=$home/data/lane/report.md
  case ${d[lint]} in
    pass) printf 't\t%s\t%s\tpass\tok\n' "$src" "$head" ;;
    fail) printf 't\t%s\t%s\tpass\tok\nt\t%s\t%s\tfail\tno\n' "$src" "$head" "$src" "$head" ;;
    other) printf 't\t%s\tother\tpass\tok\n' "$src" ;;
  esac > "$home/data/checks-gate.log"
  [ "${d[lint]}" != none ] || rm -f "$home/data/checks-gate.log"
  b=$work/board.json
  printf '{"schema":1,"answers_only":false,"items":[]}\n' > "$b"
  case ${d[board]} in
    card) jq --arg h "$head" '.items += [{kind:"evidence",key:"merge-o-r-pull-9",run:{commit:$h}}]' "$b" > "$b.t" && mv "$b.t" "$b" ;;
    wrong) jq '.items += [{kind:"evidence",key:"merge-o-r-pull-9",run:{commit:"wrong"}}]' "$b" > "$b.t" && mv "$b.t" "$b" ;;
    unreadable) b=$work/missing-board.json ;;
    unset) b= ;;
  esac
  [ "${d[writer]}" = ok ] || : > "$work/signoff-fail"
  local out rc
  out=$(env -u JG_FLEET_BOARD ${b:+JG_FLEET_BOARD=$b} SIGNOFF_FAIL="$work/signoff-fail" PATH="$work/bin:$PATH" JG_HOME="$home" "$GATE" lane - "$head" "$url" 2>&1; printf 'rc=%s' "$?")
  rc=${out##*rc=}; out=${out%rc=*}
  out=${out//"$work"/<W>}; out=${out//"$head"/<H>}; out=${out//"$ROOT"/<ROOT>}
  jq -cn --arg case "$line" --argjson rc "$rc" --arg out "$out" '{case: $case, rc: $rc, out: $out}'
}
got=$work/got.jsonl
gen_cases | awk '!seen[$0]++' | while IFS= read -r line; do setup_and_run "$line"; done > "$got"
if [ -n "${RECORD:-}" ]; then cp "$got" "$CASES"; printf 'recorded %s cases\n' "$(wc -l < "$got")"; exit 0; fi
n=$(wc -l < "$CASES") fails=0
[ "$n" -gt 0 ] && [ "$(wc -l < "$got")" -eq "$n" ] || { echo "FAIL: case count differs from the recording"; exit 1; }
while IFS= read -r diff_line; do printf 'FAIL: %s\n' "$diff_line"; fails=$((fails + 1)); done < <(diff <(jq -c . "$CASES") <(jq -c . "$got") | grep '^[<>]')
[ "$fails" -eq 0 ] && printf 'PASS: %s gate cases match their recorded decisions\n' "$n" && exit 0
printf 'FAIL: %s differing lines against %s recorded cases\n' "$fails" "$n"
exit 1
