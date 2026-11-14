#!/usr/bin/env bash
# tests/jg-fleet-budget.test.sh - one budget for the host, and a quota ledger that says when the reader is blind (core/lane-scale/fleet.sh, quota.sh).
# Journey through the real reader (core/claude-accounts/bin/claude-accounts-quota.sh) with a stub quota-axi: each run writes one ledger line for
# each account, a moved reset time writes the unused share, and a reader with no good reading for 30 minutes raises quota-blind once.
# Then the real fleet.sh on fixture process lists: 28 busy of 32 cores stop every lane and name the class; 20 cores of faults do not;
# a blind reader or an unreadable host holds; heavy runs take one of two slots.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/fleet-budget.log")
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-fleet-budget.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
H=$w/home; mkdir -p "$H/state" "$H/config" "$H/core" "$w/bin" "$w/a1"
ln -sn "$here/core/lane-scale" "$H/core/lane-scale"
echo '{"accounts":[{"id":"a1","provider":"claude","name":"One","folder":"'"$w/a1"'"}]}' > "$w/registry.json"
cat > "$w/bin/quota-axi" <<'S'
#!/usr/bin/env bash
[ ! -e "$QDIR/fail" ] || { echo "rate limited" >&2; exit 1; }
echo '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","percentRemaining":50,"resetsAt":"2026-11-01T00:00:00Z"},{"id":"seven_day","percentRemaining":'"$(cat "$QDIR/left")"',"resetsAt":"'"$(cat "$QDIR/reset")"'"}]}]}'
S
chmod +x "$w/bin/quota-axi"
printf '#!/usr/bin/env bash\necho "$*" >> %s/alerts\n' "$w" > "$w/bin/alert"; chmod +x "$w/bin/alert"
fails=0; is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
read_quota() { env -i QDIR="$w" PATH="$w/bin:$PATH" HOME="$w" TMPDIR="$w" JG_HOME="$H" JG_CLAUDE_ACCOUNTS_REGISTRY="$w/registry.json" JG_LANE_SCALE_NOW="$1" \
  bash "$here/core/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null 2>&1; }
L=$H/state/quota-ledger.tsv
echo 40 > "$w/left"; echo 2026-11-08T00:00:00Z > "$w/reset"
read_quota 1000
echo 25 > "$w/left"; read_quota 1060
echo 90 > "$w/left"; echo 2026-11-15T00:00:00Z > "$w/reset"; read_quota 1120
is "one reading line for each run" "$(grep -c "	reading	" "$L")" 3
is "a reading line holds the account, both shares and ok" "$(awk -F'\t' '$2=="reading" && $1==1060 {print $4, $5, $6, $7}' "$L")" "a1 50 25 ok"
is "the reset line holds the unused share of the old window" "$(awk -F'\t' '$2=="reset" {print $1, $4, $5, $6}' "$L")" "1120 a1 seven_day 25"

export JG_QUOTA_ALERT=$w/bin/alert
blind() { JG_LANE_SCALE_NOW=$1 "$here/core/lane-scale/quota.sh" blind "$H"; }
blind 1500; is "a reading 6 minutes old: not blind" "$?" 1
touch "$w/fail"; read_quota 1900
is "a failed reading is a ledger line, marked stale" "$(awk -F'\t' '$1==1900 {print $7}' "$L")" stale
blind 2921; is "31 minutes after the last good reading: blind" "$?" 0
blind 3000; is "still blind" "$?" 0
is "the alert raised once for the spell" "$(grep -c 'capacity quota-blind' "$w/alerts")" 1
rm "$w/fail"; read_quota 3100; blind 3101; is "a good reading ends the blind spell" "$?" 1

# fleet.sh on fixture host numbers.
printf 'heavy_slots=2\n' > "$H/config/lane-scale"
printf 'MemAvailable:   33554432 kB\n' > "$w/meminfo"
export JG_FLEET_CORES=32 JG_FLEET_MEMINFO=$w/meminfo
mkps() { : > "$w/ps"; for spec in "$@"; do IFS=: read -r n cpu cmd <<<"$spec"; for _ in $(seq 1 "$n"); do echo "$cpu $cmd" >> "$w/ps"; done; done; }
export JG_FLEET_PS="cat $w/ps"
verdict() { JG_LANE_SCALE_NOW=3200 "$here/core/lane-scale/fleet.sh" verdict "$H"; }
rm -f "$L"
mkps 14:100:/usr/bin/claude 14:100:bash\ /x/done-done\ run; is "28 busy of 32: stop, and the heavy-or-lane class is named" "$(verdict | cut -c1-40)" "stop 28 of 32 busy cores are lane and he"
is "no lane starts: the record says stop" "$(sed -n 's/^verdict=//p' "$H/state/fleet-budget.rec")" stop
mkps 4:100:/usr/bin/claude 20:100:node\ loop.js; is "20 cores of faults: go, the lane limit does not fall" "$(verdict)" go
is "the fault class is counted apart" "$(sed -n 's/^fault=//p' "$H/state/fleet-budget.rec")" 2000
mkps 12:100:/usr/bin/codex; is "12 busy cores: go" "$(verdict)" go
printf 'MemAvailable:   2097152 kB\n' > "$w/meminfo"; is "free memory under the floor: stop" "$(verdict | cut -c1-4)" stop
printf 'MemAvailable:   33554432 kB\n' > "$w/meminfo"
export JG_FLEET_PS=false; is "an unreadable process list holds" "$(verdict | cut -c1-4)" hold
export JG_FLEET_PS="cat $w/ps"
printf '3000\treading\tclaude\ta1\t50\t5\tok\n' > "$L"; is "every account past its stop share: stop" "$(JG_LANE_SCALE_NOW=3100 verdict | cut -c1-4)" stop
printf '1000\treading\tclaude\ta1\t50\t80\tok\n' > "$L"; is "a blind reader holds the limit" "$(verdict | cut -c1-4)" hold

slot() { "$here/core/lane-scale/fleet.sh" slot "$@" 2>/dev/null; }
sleep 30 & p=$!
slot take "$H" g1 $p; is "the first heavy run takes a slot" "$?" 0
slot take "$H" g2 $p; is "the second takes the last" "$?" 0
slot take "$H" g3 $p; is "a third waits: both slots are taken" "$?" 1
slot give "$H" g1; slot take "$H" g3 $p; is "a given slot is taken again" "$?" 0
kill "$p"; wait "$p" 2>/dev/null; slot take "$H" g4 $$; is "slots of runs that ended are free" "$?" 0
# One fleet budget (H30c): heavy slots are this host's plus every usable runner's; a paid runner counts only inside the daily ledger cap.
rm -f "$H"/state/heavy-slots/*; kill "$p" 2>/dev/null
mkdir -p "$H/config" "$H/state"
printf 'own1 ssh=a root=/r home=/h arch=x86_64 cores=8 mem_gb=16 slots=3 cost_per_hour=0 private_ok=yes\ncloud1 ssh=b root=/r home=/h arch=x86_64 cores=4 mem_gb=8 slots=4 cost_per_hour=0.4 private_ok=no\n' > "$H/config/runners"
printf '1\town1\tok\t4\tx\n1\tcloud1\tok\t4\tx\n' | sed 's/^1\t/'"$(date +%s)"'\t/' > "$H/state/runner-health.tsv"
budget() { "$here/core/lane-scale/fleet.sh" budget "$H"; }
is "the budget adds the own runner's slots; a paid runner at cap 0 stays out" "$(budget)" "5 host=2 own1=3 cloud1=capped"
printf 'paid_minutes_day=60\n' > "$H/config/fleet-scale"
is "a raised cap lets the paid runner in" "$(budget)" "9 host=2 own1=3 cloud1=4"
"$here/core/runners/ledger.sh" record "$H" cloud1 60
is "a spent cap takes the paid runner out again" "$(budget)" "5 host=2 own1=3 cloud1=capped"
sleep 30 & p=$!
for i in 1 2 3 4 5; do slot take "$H" f$i $p; done; slot take "$H" f6 $p; is "the sixth heavy run waits: five fleet slots are taken" "$?" 1
kill "$p"; wait "$p" 2>/dev/null
[ "$fails" -eq 0 ] && echo "PASS fleet-budget" || exit 1
