#!/usr/bin/env bash
# Behavior test for core/trunk-verify/same-red.sh (H45): run the real script, with the real quarantine.sh as the one ticket
# filer, over a fixture home. Three different lanes (or verifies) red on one script and one tip get ONE fix ticket and wait
# on it; two lanes do not; a lane's retry is not a second lane; another tip or script is its own count; a lane gates again
# when the ticket closes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SR="$ROOT/core/trunk-verify/same-red.sh"
T=$(jg_test_tmproot jg-same-red); H=$T/home; D=$H/data
mkdir -p "$D/trunk" "$H/state" "$T/fk/core/trunk-landing" "$T/fk/bin"
cp "$ROOT/core/trunk-landing/quarantine.sh" "$T/fk/core/trunk-landing/"
# A backlog fake: add records the ticket, show prints it open until the test closes it.
cat > "$T/fk/bin/jg-backlog.sh" <<'B'
#!/usr/bin/env bash
case $1 in
  show) grep -qx "$2" "$BL/ids" 2>/dev/null || exit 1; grep -qx "$2" "$BL/closed" 2>/dev/null && echo '  closed: "2026-11-13"' || echo '  closed: "-"'; exit 0 ;;
  add) echo "$2" >> "$BL/ids"; printf '%s\n' "$*" >> "$BL/adds" ;;
esac
B
chmod +x "$T/fk/bin/jg-backlog.sh"
export BL=$T JG_SAME_RED_QUARANTINE=$T/fk/core/trunk-landing/quarantine.sh JG_SAME_RED_BACKLOG=$T/fk/bin/jg-backlog.sh
# quarantine.sh files through the backlog beside it
run() { OUT=$(JG_HOME=$H bash "$SR" "$@" 2>&1); RC=$?; }
tickets() { [ -f "$T/ids" ] && wc -l < "$T/ids" | tr -d ' ' || echo 0; }

TIP=aaaa1111; S=tests/jg-foo.test.sh
run record lane-1 $TIP $S; run record lane-2 $TIP $S
run scan
assert_equals 0 "$RC" "a scan of two lanes succeeds"
assert_equals "" "$OUT" "two lanes on one script and tip are not a shared red"
assert_equals 0 "$(tickets)" "two lanes file no ticket"
run waiting lane-1; assert_equals 1 "$RC" "a lane with no shared red does not wait"

run record lane-2 $TIP $S; run scan
assert_equals 0 "$(tickets)" "the same lane failing again is one red, not a third lane"
run record lane-3 $TIP other.test.sh; run record lane-3 bbbb2222 $S; run scan
assert_equals 0 "$(tickets)" "another script or another tip is its own count"

run record verify $TIP $S --source verify; run scan
assert_equals 0 "$RC" "the third failing runner files the shared ticket"
assert_contains "$OUT" "shared $S tip=$TIP lanes=3 ticket=flaky-juggernaut-jg-foo" "the scan names the script, tip, lane count and ticket"
assert_equals 1 "$(tickets)" "three lanes get exactly one fix ticket"
assert_contains "$(cat "$T/adds")" "lane-1,lane-2,verify" "the ticket names the lanes that hit it"

run scan; assert_equals "" "$OUT" "a second scan files nothing for a red already shared"
run record lane-4 $TIP $S; run scan
assert_equals 1 "$(tickets)" "a later lane on the same red joins it and files no second ticket"

for l in lane-1 lane-2 lane-4 verify; do
  run waiting $l
  assert_equals 0 "$RC" "$l waits while the shared ticket is open"
  assert_contains "$OUT" "flaky-juggernaut-jg-foo $S tip=$TIP" "$l is told which ticket it waits on"
done
run waiting lane-3
assert_equals 1 "$RC" "lane-3 failed another script on this tip and a different tip here, so it does not wait on this red"

[ -z "${SAME_RED_SHOW:-}" ] || { printf 'Shared red ledger:\n'; cat "$D/trunk/same-red-juggernaut.tsv"; printf '\nShared marks:\n'; cat "$D/trunk/same-red-shared-juggernaut.tsv"; printf '\nFix tickets filed:\n'; cat "$T/adds"; } > "$SAME_RED_SHOW"
echo flaky-juggernaut-jg-foo >> "$T/closed"
run waiting lane-1; assert_equals 1 "$RC" "the lane gates again once the ticket is closed"
pass "same-red: three lanes on one red get one ticket, wait on it and gate again when it closes"
