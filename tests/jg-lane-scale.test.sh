#!/usr/bin/env bash
# tests/jg-lane-scale.test.sh - the lane limit of a home follows its work (core/lane-scale/scale.sh).
# Journey: a home with 2 working lanes and 7 tickets it can start climbs to 9 lanes in 4 steps of 2, not in one; the real
# dispatch check then reads the limit in place of config/lane-target when the mode is `act`; when the tickets are gone the
# limit holds 300 s and then falls to the working lanes; no lane record is touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/lane-scale.log")
TMP_ROOT=$(jg_test_tmproot jg-lane-scale); TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
SCALE="$ROOT/core/lane-scale/scale.sh"
H=$TMP_ROOT/home
mkdir -p "$H/state/dispatch-approved" "$H/config" "$H/data" "$H/bin"
for w in w1 w2; do
  printf 'kind=ship\n' > "$H/state/$w.meta"; printf 'working [at=1]: on it\n' > "$H/state/$w.status"
done
for i in 1 2 3 4 5 6 7; do
  mkdir -p "$H/data/t$i"; echo brief > "$H/data/t$i/brief.md"; echo harness=x > "$H/state/dispatch-approved/t$i"
done
cat > "$TMP_ROOT/backlog" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "ready --spawnable" ] || exit 1
for i in $(seq 1 "$(cat "$TICKETS")"); do printf 't%s\ttitle\n' "$i"; done
SH
chmod +x "$TMP_ROOT/backlog"
export JG_LANE_SCALE_BACKLOG=$TMP_ROOT/backlog TICKETS=$TMP_ROOT/tickets
echo 7 > "$TICKETS"
printf 'max=20\nmode=report\n' > "$H/config/lane-scale"; echo 4 > "$H/config/lane-target"
fail=0; ok() { echo "ok - $1"; }; bad() { echo "FAIL - $1"; fail=1; }
tick() { JG_LANE_SCALE_NOW=$1 "$SCALE" check "$H"; cat "$H/state/lane-limit"; }
seq_got=$(for t in 100 101 160 220 280 340; do tick $t; done | tr '\n' ' ')
if [ "$seq_got" = "4 4 6 8 9 9 " ]; then ok "2 working + 7 startable reaches 9 in 4 steps of 2 ($seq_got)"; else bad "climb: $seq_got"; fi
if [ "$("$SCALE" target "$H")" = 4 ]; then ok "mode report: the target stays config/lane-target"; else bad "report target"; fi
printf 'max=20\nmode=act\n' > "$H/config/lane-scale"
if [ "$("$SCALE" target "$H")" = 9 ]; then ok "mode act: the target is the limit"; else bad "act target"; fi
# The real caller: the dispatch check reads the limit (9) minus the 2 working lanes, so all 7 tickets would start.
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/bin/hold"; chmod +x "$H/bin/hold"
printf 'h\n' > "$H/bin/noop"; chmod +x "$H/bin/noop"
JG_AUTO_DISPATCH_BACKLOG=$TMP_ROOT/backlog JG_AUTO_DISPATCH_HOLD=$H/bin/hold JG_AUTO_DISPATCH_SCALE=$SCALE \
  JG_AUTO_DISPATCH_ALERT=$H/bin/noop bash "$ROOT/core/auto-dispatch/dispatch.sh" check "$H" >/dev/null 2>&1
for i in 1 2 3 4 5 6 7; do printf 'harness=x\nmodel=m\neffort=e\n' > "$H/state/dispatch-approved/t$i"; done
JG_AUTO_DISPATCH_BACKLOG=$TMP_ROOT/backlog JG_AUTO_DISPATCH_HOLD=$H/bin/hold JG_AUTO_DISPATCH_SCALE=$SCALE \
  JG_AUTO_DISPATCH_ALERT=$H/bin/noop bash "$ROOT/core/auto-dispatch/dispatch.sh" check "$H" >/dev/null 2>&1
n=$(grep -c 'would start' "$H/data/auto-dispatch/rows.tsv" 2>/dev/null); if [ "${n:-0}" = 7 ]; then ok "the dispatch check starts 7 under limit 9 (config/lane-target is 4)"; else bad "dispatch rows: ${n:-none}"; fi
echo 0 > "$TICKETS"
down=$(for t in 400 600 699 701; do tick $t; done | tr '\n' ' ')
if [ "$down" = "9 9 9 2 " ]; then ok "tickets gone: the limit holds 300 s then falls to the working lanes ($down)"; else bad "fall: $down"; fi
if [ "$(cat "$H"/state/w*.status | grep -c working)" = 2 ]; then ok "no lane record touched"; else bad "lane records"; fi
rm -f "$H/state/w1.meta" "$H/state/w2.meta"
if [ "$(tick 1000; tick 1400)" = "$(printf '2\n0')" ]; then ok "no work at all: the limit goes to 0 after the window"; else bad "zero"; fi
if [ "$fail" -eq 0 ]; then echo "PASS lane-scale"; else exit 1; fi
