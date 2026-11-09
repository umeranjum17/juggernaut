#!/usr/bin/env bash
# tests/jg-tmp-sweep.test.sh - bin/jg-tmp-sweep.sh and its bin/jg-sentinel.sh hook.
#
# A scratch folder stands in for /tmp, filled with old, fresh, live, lane-owned,
# symlinked, and off-allowlist entries. The sweep runs through its real command
# line: a dry run must remove nothing and name exactly the stale entries, a real
# run must remove exactly those, and every live or off-allowlist entry and every
# symlink target must survive. The sentinel tick then warns and sweeps once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP=$ROOT/bin/jg-tmp-sweep.sh
T=$(jg_test_tmproot jg-tmp-sweep)
R=$T/tmp
H=$T/home
OUTSIDE=$T/outside
LIVE_PIDS=
mkdir -p "$R" "$H/state" "$OUTSIDE"
printf 'precious\n' >"$OUTSIDE/keep.txt"

stop_live() {
  local pid
  for pid in $LIVE_PIDS; do kill "$pid" 2>/dev/null || true; done
}
trap 'stop_live; jg_test_cleanup' EXIT

OLD=$(( $(date +%s) - 5 * 86400 ))
old() { jg_touch_epoch "$OLD" -h "$@"; }
HOURS3=$(( $(date +%s) - 3 * 3600 ))
HOUR1=$(( $(date +%s) - 3600 ))

# Stale and allowlisted: the sweep must remove these.
mkdir -p "$R/tmp.old/sub" "$R/crewhouse-apply.old" "$R/claude-1000/-slug-gone" "$R/opencode" \
  "$R/claude-1000/-slug-busy/sess-ended" "$R/claude-1000/-slug-busy/sess-live" "$R/claude-1000/-slug-busy/sess-new" \
  "$R/claude-1000/-fake-wt-lane-alpha/sess-ended"
touch "$R/tmp.old/sub/f" "$R/tmp.oldfile" "$R/claude-accounts.old" "$R/claude-1000/old.png" "$R/opencode/old.log"
ln -s "$OUTSIDE" "$R/tmp.old/link-out"
mkdir -p "$R/tmp.old/locked" && touch "$R/tmp.old/locked/hook" && chmod 500 "$R/tmp.old/locked/hook" "$R/tmp.old/locked"
# Kept: fresh, recent inside, live, lane-owned, symlink, and off-allowlist.
mkdir -p "$R/tmp.fresh" "$R/tmp.newinside" "$R/tmp.livecwd" "$R/tmp.livefd" \
  "$R/claude-1000/-fake-wt-lane-alpha" "$R/claude-1000/-slug-fresh" "$R/plan-old"
touch "$R/claude-1000/-slug-busy/sess-ended/f" "$R/claude-1000/-slug-busy/sess-live/f" "$R/claude-1000/-slug-busy/sess-new/f" \
  "$R/claude-1000/-fake-wt-lane-alpha/sess-ended/f"
touch "$R/tmp.newinside/new" "$R/tmp.livefd/held" "$R/plan-old/f"
ln -s "$OUTSIDE" "$R/tmp.oldlink"
printf 'worktree=/fake/wt/lane-alpha\nkind=ship\n' >"$H/state/lane-alpha.meta"

# Browser and render scratch is stale after 2 hours, the other names after a day; a live profile stays.
mkdir -p "$R/com.google.Chrome.old" "$R/com.google.Chrome.fresh" "$R/first-draft-render-old" "$R/org.chromium.Chromium.live" \
  "$R/tmp.threehours"
touch "$R/com.google.Chrome.old/SingletonSocket" "$R/first-draft-render-old/f" "$R/org.chromium.Chromium.live/f" \
  "$R/tmp.threehours/f" "$R/claude-1000/scratch-3h.log"

# Age everything stale last, so creating children above cannot refresh a parent.
for p in tmp.old/locked/hook tmp.old/locked tmp.old/sub/f tmp.old/link-out tmp.old/sub tmp.old tmp.oldfile tmp.oldlink crewhouse-apply.old \
  claude-accounts.old claude-1000/old.png claude-1000/-slug-gone claude-1000/-fake-wt-lane-alpha \
  opencode/old.log claude-1000/-slug-busy/sess-ended/f claude-1000/-slug-busy/sess-ended claude-1000/-slug-busy/sess-live/f \
  claude-1000/-slug-busy/sess-live claude-1000/-fake-wt-lane-alpha/sess-ended/f claude-1000/-fake-wt-lane-alpha/sess-ended \
  tmp.livecwd tmp.livefd/held tmp.livefd plan-old/f plan-old; do
  old "$R/$p"
done
old "$R/claude-1000/-slug-busy" "$R/claude-1000" "$R/opencode"
jg_touch_epoch "$HOURS3" -h "$R/com.google.Chrome.old/SingletonSocket" "$R/com.google.Chrome.old" "$R/first-draft-render-old/f" \
  "$R/first-draft-render-old" "$R/org.chromium.Chromium.live/f" "$R/org.chromium.Chromium.live" \
  "$R/tmp.threehours/f" "$R/tmp.threehours" "$R/claude-1000/scratch-3h.log"
jg_touch_epoch "$HOUR1" -h "$R/com.google.Chrome.fresh"
# sess-new is made fresh after aging: a project with a recent session is still entered.
touch "$R/claude-1000/-slug-busy/sess-new/f"

( cd "$R/tmp.livecwd" && exec sleep 600 ) & LIVE_PIDS="$LIVE_PIDS $!"
( exec 9<"$R/tmp.livefd/held"; exec sleep 600 ) & LIVE_PIDS="$LIVE_PIDS $!"
( cd "$R/claude-1000/-slug-busy/sess-live" && exec sleep 600 ) & LIVE_PIDS="$LIVE_PIDS $!"
( cd "$R/org.chromium.Chromium.live" && exec sleep 600 ) & LIVE_PIDS="$LIVE_PIDS $!"
sleep 1

survivors="com.google.Chrome.fresh org.chromium.Chromium.live tmp.threehours tmp.fresh tmp.newinside tmp.livecwd tmp.livefd tmp.oldlink plan-old claude-1000 opencode
claude-1000/-fake-wt-lane-alpha claude-1000/-slug-fresh
claude-1000/-slug-busy claude-1000/-slug-busy/sess-live claude-1000/-slug-busy/sess-new claude-1000/-fake-wt-lane-alpha/sess-ended"
removed="tmp.old tmp.oldfile crewhouse-apply.old claude-accounts.old claude-1000/old.png claude-1000/-slug-gone opencode/old.log claude-1000/-slug-busy/sess-ended
com.google.Chrome.old first-draft-render-old claude-1000/scratch-3h.log"

# --- dry run: lists, removes nothing ---------------------------------------
dry=$(JG_HOME=$H "$SWEEP" sweep --root "$R" 2>&1) || fail "dry run exited nonzero: $dry"
for p in $removed; do
  printf '%s\n' "$dry" | grep -Fx -- "would remove $R/$p" >/dev/null || fail "dry run lists stale $p"
  assert_present "$R/$p" "dry run must not remove $p"
done
assert_contains "$dry" "would remove 11 entries" "dry run counts exactly the eleven stale entries"
for p in $survivors; do
  ! printf '%s\n' "$dry" | grep -Fx -- "would remove $R/$p" >/dev/null || fail "dry run must not list $p"
done
assert_contains "$dry" "not allowlisted, left alone: 1 entries" "dry run reports the off-allowlist entry"
pass "dry run lists exactly the stale entries and removes nothing"

# --- real run ---------------------------------------------------------------
out=$(JG_HOME=$H "$SWEEP" sweep --apply --root "$R" 2>&1) || fail "sweep exited nonzero: $out"
for p in $removed; do assert_absent "$R/$p" "sweep removes stale $p"; done
for p in $survivors; do assert_present "$R/$p" "sweep keeps $p"; done
assert_present "$OUTSIDE/keep.txt" "sweep never follows a symlink out of the root"
assert_contains "$out" "removed 11 entries" "sweep reports what it removed"
assert_contains "$out" "live-process=5" "sweep reports the process-held entries and the live project and session"
assert_contains "$out" "removed by prefix:" "sweep reports the removed count by prefix"
assert_contains "$out" "com=1" "sweep counts the Chrome leftover by prefix"
assert_contains "$out" "first=1" "sweep counts the render leftover by prefix"
assert_contains "$out" "live-lane=1" "sweep reports the lane-owned entry"
pass "sweep removes the stale entries and keeps live, lane-owned, symlinked and off-allowlist ones"

# --- check, argument and root safety ----------------------------------------
"$SWEEP" check --root "$R" --warn-pct 101 >/dev/null; expect_code 0 $? "check below the threshold"
"$SWEEP" check --root "$R" --warn-pct 0 >/dev/null; expect_code 1 $? "check at or over the threshold"
got=$("$SWEEP" check --root "$R" --warn-pct 101 2>&1)
assert_contains "$got" "space " "check reports space use"
assert_contains "$got" "inodes " "check reports inode use"
"$SWEEP" sweep --root / >/dev/null 2>&1; expect_code 2 $? "root /"
ln -s "$R" "$T/rootlink"
"$SWEEP" sweep --root "$T/rootlink" >/dev/null 2>&1; expect_code 2 $? "symlinked root"
"$SWEEP" sweep --root "relative" >/dev/null 2>&1; expect_code 2 $? "relative root"
"$SWEEP" sweep --min-age-days x --root "$R" >/dev/null 2>&1; expect_code 2 $? "non-numeric age"
pass "check thresholds and unsafe roots"

# --- sentinel tick: warns at the threshold, reports first, then sweeps once a day
mkdir -p "$R/tmp.again" "$R/claude-1000/-slug-busy/sess-again"
touch "$R/claude-1000/-slug-busy/sess-again/f"
old "$R/claude-1000/-slug-busy/sess-again/f" "$R/claude-1000/-slug-busy/sess-again" "$R/tmp.again"
export JG_TMP_ROOT=$R JG_TMP_WARN_PCT=0
JG_HOME=$H "$ROOT/bin/jg-sentinel.sh" tick >/dev/null 2>&1
log=$H/state/.sentinel.log
for _ in $(seq 40); do
  grep -q 'tmp sweep' "$log" 2>/dev/null && break
  sleep 0.5
done
assert_grep "WARNING: " "$log" "tick logs the inode warning"
assert_grep "tmp sweep --dry-run (exit 0)" "$log" "the first tick only reports"
assert_grep "tmp sweep: would remove $R/tmp.again" "$log" "the first tick logs each entry it would remove"
assert_present "$R/tmp.again" "the first tick removes nothing"
assert_present "$R/claude-1000/-slug-busy/sess-again" "the first tick keeps the stale session"
rm -f "$H/state/.sentinel-tmp-sweep"
JG_HOME=$H "$ROOT/bin/jg-sentinel.sh" tick >/dev/null 2>&1
for _ in $(seq 40); do
  grep -q 'tmp sweep --apply' "$log" 2>/dev/null && break
  sleep 0.5
done
assert_grep "tmp sweep --apply (exit 0)" "$log" "the second tick logs the sweep summary"
assert_grep "tmp sweep: remove $R/tmp.again" "$log" "the second tick logs each removal"
assert_grep "tmp sweep: remove $R/claude-1000/-slug-busy/sess-again" "$log" "the second tick logs each removed session"
assert_absent "$R/tmp.again" "tick sweeps the stale entry"
assert_absent "$R/claude-1000/-slug-busy/sess-again" "tick sweeps the stale session"
assert_present "$R/claude-1000/-slug-busy/sess-live" "tick keeps the live session"
assert_present "$R/tmp.fresh" "tick keeps the fresh entry"
before=$(grep -c 'tmp sweep' "$log")
JG_HOME=$H "$ROOT/bin/jg-sentinel.sh" tick >/dev/null 2>&1
sleep 1
assert_equals "$before" "$(grep -c 'tmp sweep' "$log")" "a second tick inside the day does not sweep again"
assert_equals 1 "$(grep -c 'WARNING: ' "$log")" "a second tick inside the re-warn window does not warn again"
pass "sentinel tick warns once and sweeps once a day"
