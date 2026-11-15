#!/usr/bin/env bash
# The unhandled-steer alert (jg_wait_timers_overdue_steers), driven through the real wait-timer tick in a
# scratch home: a steer the worker read and never answered raises one stuck-wait alert to the lead.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME="$d/home" JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_CONFIG_OVERRIDE="$d/config"
mkdir -p "$HOME" "$d/state" "$d/config"
unset JG_TASK_ID
STATE=$d/state
fails=0
ok() { printf 'ok - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*" >&2; fails=$((fails + 1)); }

# One tick of the real wait-timer library, as the watcher loads it.
tick() {
  ( export SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=bin/jg-wake-lib.sh
    . "$ROOT/bin/jg-wake-lib.sh"
    # shellcheck source=core/wait-timers/bin/jg-wait-timers-lib.sh
    . "$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh"
    jg_wait_timers_tick ) >"$d/tick.out" 2>&1 || { cat "$d/tick.out" >&2; return 1; }
}
rewind() { rm -f "$STATE/.overdue-steers.at"; }   # the pass runs once per 300 s
alerts() { "$ROOT/bin/jg-alert.sh" list 2>/dev/null | grep '^stuck-wait--' || true; }
word() { "$ROOT/bin/jg-alert.sh" word "$1" 2>/dev/null || true; }

# lane <task> <kind> <seq> <first-ring-age-seconds> [read]: a steer rung that long ago.
lane() {
  local t=$1 k=$2 n=$3 age=$4 now; now=$(date +%s)
  printf 'kind=%s\n' "$k" > "$STATE/$t.meta"
  mkdir -p "$STATE/$t.inbox/handled"
  printf 'schema=jg-task-inbox.v1\n--\nhello\n' > "$STATE/$t.inbox/handled/$n.msg"
  printf '{"seq":%d,"word":"stored","at":%d}\n{"seq":%d,"word":"rung","at":%d}\n' \
    "$((10#$n))" "$((now - age))" "$((10#$n))" "$((now - age))" >> "$STATE/$t.inbox/.delivery.jsonl"
}

# Watermark: the first run writes it; a steer first signalled before it is legacy.
lane old-lane ship 001 5000
lane lead-lane squad_lead 001 90000
tick
[ -s "$STATE/.overdue-steers.since" ] && ok "the first run writes the watermark" || bad "no watermark"
[ "$(alerts)" = "stuck-wait--overdue-steers-legacy" ] && ok "a steer read before the watermark is one summary alert, not one each" || bad "legacy alert: $(alerts)"
rewind; tick
[ "$(alerts | wc -l)" -eq 1 ] && ok "the summary alert is raised once" || bad "summary repeated: $(alerts)"

# A 25-hour-old record created after the watermark still alerts.
printf '%s\n' "$(($(date +%s) - 200000))" > "$STATE/.overdue-steers.since"
lane day-lane ship 001 90000
lane young-lane ship 001 60
rewind; tick
[ "$(word stuck-wait--day-lane-msg-001)" != "" ] && ok "a 25-hour-old steer after the watermark raises its alert" || bad "no alert for day-lane: $(alerts)"
[ -z "$(word stuck-wait--young-lane-msg-001)" ] && ok "a steer younger than 15 minutes raises none" || bad "young steer alerted"
[ -z "$(word stuck-wait--lead-lane-msg-001)" ] && ok "a squad lead's inbox is never read" || bad "squad lead inbox was read"
grep -q '^rung=2$' "$STATE/alerts/stuck-wait--day-lane-msg-001.rec" && ok "the alert is held by the lead" || bad "alert is not for the lead: $(cat "$STATE/alerts/stuck-wait--day-lane-msg-001.rec")"

# A re-ring does not reset the age.
lane ring-lane ship 001 5000
printf '{"seq":1,"word":"rung","at":%d}\n' "$(date +%s)" >> "$STATE/ring-lane.inbox/.delivery.jsonl"
rewind; tick
[ -n "$(word stuck-wait--ring-lane-msg-001)" ] && ok "a re-ring does not reset the age" || bad "re-ring reset the age"

# A handled steer resolves its alert.
JG_HOME=$d "$ROOT/bin/jg-delivery.sh" handled day-lane 001 --evidence task:day-lane >/dev/null 2>&1
rewind; tick
[ "$(word stuck-wait--day-lane-msg-001)" = resolved ] && ok "a handled steer resolves its alert" || bad "alert not resolved: $(word stuck-wait--day-lane-msg-001)"

# A 3,500-record inbox is read in one pass, well inside 5 s.
big=$STATE/big-lane.inbox; mkdir -p "$big/handled"; printf 'kind=ship\n' > "$STATE/big-lane.meta"
now=$(date +%s); i=1
while [ "$i" -le 3500 ]; do : > "$big/handled/$(printf '%03d' "$i").msg"; i=$((i + 1)); done
awk -v now="$now" 'BEGIN { for (i = 1; i <= 3500; i++) printf "{\"seq\":%d,\"word\":\"stored\",\"at\":%d}\n{\"seq\":%d,\"word\":\"rung\",\"at\":%d}\n", i, now - 2000, i, now - 2000 }' > "$big/.delivery.jsonl"
t0=$(date +%s.%N)
JG_HOME=$d "$ROOT/bin/jg-delivery.sh" overdue big-lane --after 900 --read >"$d/big.out" || true
t1=$(date +%s.%N)
[ "$(wc -l < "$d/big.out")" -eq 3500 ] && ok "the single pass lists all 3500 records" || bad "listed $(wc -l < "$d/big.out")"
awk -v a="$t0" -v b="$t1" 'BEGIN { exit !(b - a < 5) }' && ok "a 3500-record pass took under 5 s" || bad "slow pass"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "overdue-steers e2e: all checks passed"
