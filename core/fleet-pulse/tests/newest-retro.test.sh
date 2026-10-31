#!/usr/bin/env bash
# Fixture homes: older report in main + newer in a sibling -> not due;
# none or all old -> due. Uses disposable treehouse + homes only.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
bin=$root/fleet-pulse/bin
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT

main=$d/main
sib=$d/treehouse/juggernaut-test/1/juggernaut
mkdir -p "$main/data" "$main/state" "$sib/data" "$sib/state"
export HOME=$d/user JG_TREEHOUSE=$d/treehouse
mkdir -p "$HOME"

# Fixed "now": 2026-10-25T12:00:00Z
now=1761393600
old=$((now - 3 * 86400))   # 3 days ago — past the 60 h cadence
fresh=$((now - 3600))      # 1 hour ago — not due

stamp() { # stamp <path> <epoch>
  mkdir -p "$(dirname "$1")"
  : >"$1"
  touch -d "@$2" "$1"
}

fail=0
check() {
  local name=$1 want=$2 got
  shift 2
  got=$("$@" 2>&1) && rc=0 || rc=$?
  if [ "$want" = due ]; then
    if [ "$rc" -eq 0 ] && grep -q '^fleet-retro due:' <<<"$got"; then
      echo "ok $name"
    else
      echo "FAIL $name (want due, rc=$rc got=$(printf %q "$got"))" >&2
      fail=1
    fi
  else
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
      echo "ok $name"
    else
      echo "FAIL $name (want quiet, rc=$rc got=$(printf %q "$got"))" >&2
      fail=1
    fi
  fi
}

# 1) none -> due
rm -f "$main"/state/.fleet-retro.last
check none-due due env JG_RETRO_NOW=$now "$bin/fleet-retro-due.sh" "$main"

# 2) older in main, newer in sibling treehouse home -> not due
stamp "$main/data/jg-retro-old/report.md" "$old"
stamp "$sib/data/ljg-fleet-retro-new/report.md" "$fresh"
rm -f "$main"/state/.fleet-retro.last
got=$("$bin/newest-retro-report.sh" "$main")
[ "$got" = "$sib/data/ljg-fleet-retro-new/report.md" ] && echo ok newest-picks-sibling \
  || { echo "FAIL newest-picks-sibling got=$(printf %q "$got")" >&2; fail=1; }
check newer-elsewhere-quiet quiet env JG_RETRO_NOW=$now "$bin/fleet-retro-due.sh" "$main"

# 3) all old -> due (also via squad_leads.md home, no treehouse hit required)
sib2=$d/other-home
mkdir -p "$sib2/data"
stamp "$sib2/data/jg-retro-also/report.md" "$old"
printf -- '- other - note (home: %s; scope: x)\n' "$sib2" >"$main/data/squad_leads.md"
# Hide treehouse sibling so only main+squad_leads (both old) remain newest.
mv "$d/treehouse" "$d/treehouse.hide"
rm -f "$main"/state/.fleet-retro.last
check all-old-due due env JG_RETRO_NOW=$now "$bin/fleet-retro-due.sh" "$main"
mv "$d/treehouse.hide" "$d/treehouse"

# 4) wake mark suppresses a second due within 12 h
check wake-suppressed quiet env JG_RETRO_NOW=$now "$bin/fleet-retro-due.sh" "$main"

# 5) folder name must contain retro; plain report.md dirs are ignored
rm -f "$sib/data/ljg-fleet-retro-new/report.md"
stamp "$main/data/not-a-match/report.md" "$fresh"
stamp "$sib/data/still-old-retro/report.md" "$old"
rm -f "$main"/state/.fleet-retro.last
# newest among *retro* is still old (not-a-match ignored) -> due
check ignore-non-retro-dir due env JG_RETRO_NOW=$now "$bin/fleet-retro-due.sh" "$main"

# 6) install retargets an old-style pulse check onto fleet-retro-due.sh
mkdir -p "$main/bin" "$main/state"
cat >"$main/state/fleet-pulse.check.sh" <<'EOF'
#!/usr/bin/env bash
set -u
now=$(date +%s)
# Fleet retro every 2-3 days (captain 5 Oct): wake Main once 60 h after the last retro report.
last=$(ls -t /home/you/juggernaut/data/jg-retro-*/report.md 2>/dev/null | head -1)
RM=/home/you/juggernaut/state/.fleet-retro.last
if [ -n "$last" ] && [ $((now - $(stat -c %Y "$last"))) -ge 216000 ] && { [ ! -f "$RM" ] || [ $((now - $(stat -c %Y "$RM"))) -ge 43200 ]; }; then
  touch "$RM"; echo "fleet-retro due: last report $last; spawn the next strong-model fleet retro scout (captain-shared A5)"; exit 0
fi
echo later
EOF
"$root/fleet-pulse/wiring.sh" "$main" >/dev/null
grep -q fleet-retro-due.sh "$main/state/fleet-pulse.check.sh" \
  && ! grep -q 'jg-retro-\*/report\.md' "$main/state/fleet-pulse.check.sh" \
  && echo ok install-retargets-check \
  || { echo FAIL install-retargets-check >&2; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo PASS newest-retro
