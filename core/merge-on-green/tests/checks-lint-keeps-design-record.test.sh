#!/usr/bin/env bash
# E2E: the merge-time evidence lint republishes the completion receipt, and that republish must not erase the
# `first-draft receipt:` line the design gate reads next from the receipt's evidence (bin/jg-pr-merge.sh runs the
# lint, then jg_dod_design_gate). Real lints (the done-done path and the feature lint), the real receipt
# publisher and the merge path's real acceptance and design-record reader, with a local report file in place of
# a PR (no gh, no network). A lint that fails must still refuse the merge, and a receipt that never held a
# design record must stay without one.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) # the core tree
LINT=$ROOT/merge-on-green/checks-lint.sh
LEGACY=$ROOT/merge-on-green/jg-checks-lint.sh
# shellcheck source=lib/policy-test-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/policy-test-env.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d JG_HOME=$d/fm JG_CORE_DIR=$ROOT
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/fm/state" "$d/fm/data/lane-x/evidence" "$d/wt"
fails=0
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi }

cp -a "$ROOT/../bin" "$ROOT/../core" "$ROOT/../policy" "$d/fm/"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head=$(git -C "$d/wt" rev-parse HEAD)
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\n' "$d/wt" >"$d/fm/state/lane-x.meta"
printf 'frame one\n' >"$d/fm/data/lane-x/evidence/shot.png"
RECEIPT=$d/fm/state/lane-x.run-receipt.json
REPORT=$d/fm/data/lane-x/report.md
DESIGN_LINE='first-draft receipt: runs/make-1.json'

# A stand-in for the pinned done-done CLI: it answers `lint --help` as the pinned release does and logs one
# verdict row per lint, exiting 1 when FAKE_DD_RC says so, so the done-done path of checks-lint.sh runs here.
cat >"$d/dd" <<'DD'
#!/usr/bin/env bash
if [ "$1 $2" = "lint --help" ]; then echo 'checks.generated_paths:'; exit 0; fi
if [ "$1" = lint ]; then
  verdict=pass; [ "${FAKE_DD_RC:-0}" -eq 0 ] || verdict=fail
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$2" fakehead "$verdict" "fake lint $verdict" >>"$DONE_DONE_HOME/lint.log"
  exit "${FAKE_DD_RC:-0}"
fi
exit 2
DD
chmod +x "$d/dd"
export JG_DONE_DONE_BIN=$d/dd

printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' >"$REPORT"
printf 'pr=%s\n' "$REPORT" >>"$d/fm/state/lane-x.meta"

# publish <evidence text>: the lane's own full receipt at the candidate head, as the worker publishes it.
publish() {
  printf '%s\n' "$1" >"$d/ev.txt"
  JG_HOME=$JG_HOME "$ROOT/receipts/bin/jg-run-receipt.sh" lane-x PASS "$d/ev.txt" "$d/wt" >/dev/null
}
has_line() { jq -r '.evidence' "$RECEIPT" | grep -Fxq -- "$DESIGN_LINE"; }
merges() { # the merge path's own acceptance of the receipt for this candidate: 0 only for a PASS at this head
  (
    set -u
    # shellcheck source=/dev/null
    . "$d/fm/bin/jg-dod-lib.sh"
    jg_dod_receipt_accept "$d/fm/state" lane-x "$d/fm/state/lane-x.meta" "$head"
  )
}
design_ref() { # the design gate's own reader of the receipt line
  (
    set -u
    # shellcheck source=/dev/null
    . "$d/fm/bin/jg-merge-gate-lib.sh"
    jg_design_receipt_value "$d/fm/state" lane-x "$head" 'first-draft receipt'
  )
}
run() { # run <lint> <rc>: the merge-time lint for the lane, output printed, status returned. A non-zero <rc>
  # makes both lints fail: the stand-in CLI exits 1 and the report's evidence line lacks its evidence/ prefix.
  if [ "$2" -eq 0 ]; then ln='evidence/shot.png'; else ln='shot.png'; fi
  printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: %s\n' "$ln" >"$REPORT"
  FAKE_DD_RC=$2 JG_HOME=$JG_HOME "$1" "$REPORT" "$d/fm/data/lane-x" 2>&1
}

for lint in "$LINT" "$LEGACY"; do
  name=${lint##*/}
  # 1. A receipt with a design record still has it after a passing lint run, and the lint's verdict is the receipt's.
  publish "$(printf 'ran the suites\n%s\nlimits: none' "$DESIGN_LINE")"
  has_line || bad "$name: setup: the published receipt must hold the design record"
  rm -f "$d/fm/data/checks-gate.hashes"
  out=$(run "$lint" 0) || bad "$name: a passing lint must exit 0: $out"
  is "$name: the passing lint leaves a PASS receipt" "$(jq -r .verdict "$RECEIPT")" PASS
  if has_line; then ok "$name: the design record survives a passing lint"; else bad "$name: the lint erased the design record: $(jq -r .evidence "$RECEIPT")"; fi
  is "$name: the design gate reads the surviving record" "$(design_ref)" "runs/make-1.json"
  case $(jq -r .evidence "$RECEIPT") in *'checks-lint PASS'*) ok "$name: the receipt also carries the lint's own report" ;; *) if [ "$name" = checks-lint.sh ]; then bad "$name: the lint report is missing: $(jq -r .evidence "$RECEIPT")"; fi ;; esac

  # 2. A lint that fails still refuses the merge, whatever the receipt held before.
  publish "$(printf 'ran the suites\n%s' "$DESIGN_LINE")"
  rm -f "$d/fm/data/checks-gate.hashes"
  set +e
  out=$(run "$lint" 1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] && ok "$name: a failing lint exits non-zero" || bad "$name: a failing lint must exit non-zero: $out"
  is "$name: the failing lint left a FAIL receipt" "$(jq -r .verdict "$RECEIPT")" FAIL
  if merges >/dev/null 2>&1; then bad "$name: a FAIL receipt must refuse the merge"; else ok "$name: a FAIL receipt refuses the merge"; fi

  # 3. A receipt with no design record stays without one.
  publish "$(printf 'ran the suites\nlimits: none')"
  rm -f "$d/fm/data/checks-gate.hashes"
  out=$(run "$lint" 0) || true
  if has_line; then bad "$name: the lint invented a design record"; else ok "$name: a receipt with no design record stays without one"; fi
  is "$name: the design gate finds no record" "$(design_ref)" ""

  # 4. A design record from another candidate is not carried onto a new head.
  publish "$(printf 'ran the suites\n%s' "$DESIGN_LINE")"
  git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  rm -f "$d/fm/data/checks-gate.hashes"
  out=$(run "$lint" 0) || true
  if has_line; then bad "$name: a record for an older head was carried to a new head"; else ok "$name: a record for an older head is not carried to a new head"; fi
  git -C "$d/wt" reset -q --hard "$head"
  # 5. A failing lint, then the lane's fix and a passing lint: the record survives both republishes.
  publish "$(printf 'ran the suites\n%s' "$DESIGN_LINE")"
  rm -f "$d/fm/data/checks-gate.hashes"
  out=$(run "$lint" 1) || true
  out=$(run "$lint" 0) || true
  is "$name: the fixed lane holds a PASS receipt" "$(jq -r .verdict "$RECEIPT")" PASS
  if has_line; then ok "$name: the design record survives a FAIL then a PASS"; else bad "$name: the design record was erased by FAIL then PASS"; fi
done

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all ok"
