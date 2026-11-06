#!/usr/bin/env bash
# E2E: the evidence lint republishes the task's completion receipt with its own report, and that must not lose the
# worker's `first-draft receipt: <ref>` line, which the design gate reads from the receipt. Real checks-lint.sh, real
# receipt publisher and the real jg_dod_design_gate in a temporary home; only done-done and gh are stubs (no network). The gate stays as strict: no line, or a line from another head, is still refused.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) # the core tree
LINT=$ROOT/merge-on-green/checks-lint.sh
URL=https://github.com/o/r/pull/7
# shellcheck source=lib/policy-test-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/policy-test-env.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d JG_HOME=$d/fm JG_CORE_DIR=$ROOT
mkdir -p "$d/bin" "$HOME" "$XDG_DATA_HOME" "$d/fm/bin" "$d/fm/state" "$d/fm/data/lane-x/evidence" "$d/wt"
fails=0
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }

cp -a "$ROOT/../bin" "$ROOT/../core" "$ROOT/../policy" "$d/fm/"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cat >"$d/bin/done-done" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  lint) if [ "${2:-}" = --help ]; then echo 'checks.generated_paths:'; else
          printf 't\t%s\thead1\tpass\tok\n' "$2" >>"$DONE_DONE_HOME/lint.log"; fi ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 3\n' >"$d/bin/gh"
chmod +x "$d/bin/done-done" "$d/bin/gh"
export PATH="$d/bin:$PATH" JG_DONE_DONE_BIN="$d/bin/done-done"
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\ndesign_call=yes\npr=%s\n' "$d/wt" "$URL" >"$d/fm/state/lane-x.meta"
printf 'frame one\n' >"$d/fm/data/lane-x/evidence/shot.png"
jq -n '{made:{command:"make",files:[{file:"designs/option-1.html"}]}}' >"$d/fd-0001"
printf 'ran the suite: ok\nfirst-draft receipt: %s\n' "$d/fd-0001" >"$d/with-line.txt"
printf 'ran the suite: ok\n' >"$d/no-line.txt"

# publish <evidence file>: the worker's own completion receipt at the current head
publish() { JG_HOME=$JG_HOME JG_RECEIPT_PR=$URL "$ROOT/receipts/bin/jg-run-receipt.sh" lane-x PASS "$1" "$d/wt" >/dev/null; }
lint() { # the evidence lint: it writes its own report and republishes the receipt
  printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' >"$d/fm/data/lane-x/report.md"
  JG_HOME=$JG_HOME "$LINT" "$URL" "$d/fm/data/lane-x" 2>&1
}
gate() { # the design gate both merge paths run, for the head the receipt binds
  (
    set -u
    # shellcheck disable=SC2317,SC2329 # the sourced merge-gate lib calls this stub
    jg_dod_meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
    # shellcheck source=/dev/null
    . "$d/fm/bin/jg-merge-gate-lib.sh"
    jg_dod_design_gate "$d/fm/state" lane-x "$d/fm/state/lane-x.meta" "$(git -C "$d/wt" rev-parse HEAD)"
  )
}

# 1. The worker's receipt carries the line and the gate passes.
publish "$d/with-line.txt"
if gate >/dev/null 2>&1; then ok 'the worker receipt with a first-draft line passes the gate'; else bad 'the worker receipt must pass the gate'; fi

# 2. The lint republishes the receipt with its own report; the gate still reads the line.
out=$(lint) || bad "the lint must PASS: $out"
case $(jq -r .evidence "$d/fm/state/lane-x.run-receipt.json") in
  *'checks-lint PASS'*) ok "the receipt now holds the lint's own report" ;;
  *) bad 'the lint must have republished the receipt' ;;
esac
if out=$(gate 2>&1); then ok 'the gate still reads the first-draft line after the lint'; else bad "the lint dropped the first-draft line: $out"; fi

# 3. The rule is as strict as before: a task whose receipt never had a line is refused, also after the lint.
rm -f -- "$d/fm/state/lane-x.run-receipt.json"
publish "$d/no-line.txt"
lint >/dev/null || true
if out=$(gate 2>&1); then bad 'a receipt with no first-draft line must still be refused'; else
  case $out in *"no 'first-draft receipt: <ref>' evidence line"*) ok 'no line is still refused' ;; *) bad "wrong refusal: $out" ;; esac
fi

# 4. A line from an older head is not carried to a newer head.
publish "$d/with-line.txt"
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
lint >/dev/null || true
if out=$(gate 2>&1); then bad 'a first-draft line must not carry over to a new head'; else ok 'the line of an older head is not carried to a new head'; fi

if [ "$fails" -eq 0 ]; then
  echo "PASS: the evidence lint keeps the worker's first-draft receipt line"
else
  echo "$fails check(s) failed" >&2
  exit 1
fi
