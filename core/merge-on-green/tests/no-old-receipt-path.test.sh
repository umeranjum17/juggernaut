#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# E2E: both lint entry points publish the completion receipt through the receipts feature's publisher
# ($JG_ADDONS_DIR/receipts/bin/jg-run-receipt.sh) and never through the old juggernaut publisher (bin/jg-run-receipt.sh
# in the home or the main home). The feature publisher is a recording stub; the old paths are tripwires that fail the run.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d JG_HOME=$d/fm JG_MAIN_HOME=$d/main JG_ADDONS_DIR=$d/addons CALLS=$d
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/bin" "$JG_HOME"/{bin,state,data/lane-x/evidence} "$JG_MAIN_HOME/bin" "$HOME/juggernaut/bin" "$JG_ADDONS_DIR/receipts/bin" "$d/wt"
fails=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

cat > "$JG_ADDONS_DIR/receipts/bin/jg-run-receipt.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "$2" >> "$CALLS/feature-calls"
STUB
cat > "$d/trip" <<'STUB'
#!/usr/bin/env bash
echo "$0" >> "$CALLS/old-calls"
exit 1
STUB
for old in "$JG_HOME/bin" "$JG_MAIN_HOME/bin" "$HOME/juggernaut/bin"; do cp "$d/trip" "$old/jg-run-receipt.sh"; done
# A done-done that passes the version probe and logs one passing lint row.
cat > "$d/bin/done-done" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  lint) if [ "${2:-}" = --help ]; then echo 'checks.generated_paths:'; else
          printf 't\t%s\thead1\tpass\tok\n' "$2" >> "$DONE_DONE_HOME/lint.log"; fi ;;
esac
STUB
chmod +x "$JG_ADDONS_DIR/receipts/bin/jg-run-receipt.sh" "$JG_HOME/bin/jg-run-receipt.sh" "$JG_MAIN_HOME/bin/jg-run-receipt.sh" "$HOME/juggernaut/bin/jg-run-receipt.sh" "$d/bin/done-done"
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\n' "$d/wt" > "$JG_HOME/state/lane-x.meta"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'frame\n' > "$JG_HOME/data/lane-x/evidence/shot.png"
report="$JG_HOME/data/lane-x/report.md"
printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' > "$report"
printf 'pr=%s\n' "$report" >> "$JG_HOME/state/lane-x.meta"

# 1. jg-checks-lint.sh (the legacy lint, also the fallback of checks-lint.sh).
"$ROOT/merge-on-green/jg-checks-lint.sh" "$report" "$JG_HOME/data/lane-x" >/dev/null 2>&1 || bad "jg-checks-lint.sh must PASS the fixture"
[ "$(cat "$d/feature-calls" 2>/dev/null)" = "lane-x|PASS" ] && ok "jg-checks-lint.sh publishes through the feature publisher" || bad "jg-checks-lint.sh did not publish lane-x PASS through the feature: $(cat "$d/feature-calls" 2>/dev/null)"
[ ! -e "$d/old-calls" ] && ok "jg-checks-lint.sh never calls the old publisher" || bad "jg-checks-lint.sh called the old publisher: $(cat "$d/old-calls")"

# 2. checks-lint.sh on the done-done path.
rm -f "$d/feature-calls"
JG_DONE_DONE_BIN="$d/bin/done-done" "$ROOT/merge-on-green/checks-lint.sh" "$report" "$JG_HOME/data/lane-x" >/dev/null 2>&1 || bad "checks-lint.sh must PASS the fixture"
[ "$(cat "$d/feature-calls" 2>/dev/null)" = "lane-x|PASS" ] && ok "checks-lint.sh publishes through the feature publisher" || bad "checks-lint.sh did not publish lane-x PASS through the feature: $(cat "$d/feature-calls" 2>/dev/null)"
[ ! -e "$d/old-calls" ] && ok "checks-lint.sh never calls the old publisher" || bad "checks-lint.sh called the old publisher: $(cat "$d/old-calls")"

[ "$fails" -eq 0 ] && echo 'PASS: lint publishes receipts only through the receipts feature' || { echo "FAIL: $fails" >&2; exit 1; }
