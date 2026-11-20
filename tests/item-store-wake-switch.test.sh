#!/usr/bin/env bash
# The wake switch (docs/item-store.md): with config/item-store-reads in Main's home the drain stops re-printing status lines and
# presents Main's store pages instead. Real drain, real watcher, real jg-item, temporary homes only.
#   a: 10,000 unread pages and 3 queued records: QUEUED, then at most 200 page lines, no UNREAD STATUS; its one acknowledgement
#      moves the queue and Main's page cursor, so the next drain prints neither the 3 reason lines nor the first pages (Y7).
#   b: 500 queued records: at most 200 reason lines and 32 KiB, then `queued: 500`; the acknowledgement stops at the last line shown.
#   c: an open owner question is under OPEN DECISIONS; a hold set only in today's record is under RECORD DIVERGENCE; a home with
#      no switch keeps the status-line presentation.
#   d: a page and an empty queue ring the watcher once; no page and an empty queue ring nothing.
#   e: jg_wait_is_open answers from the store with the switch, from the fold without it.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ITEM_DIR=$ROOT/core/item-store
LANE=$ITEM_DIR/adapters/lane.py
DRAIN=$ROOT/bin/jg-wake-drain.sh
WATCH=$ROOT/bin/jg-watch.sh
export JG_ITEM_TICK_LEASE_S=0
unset JG_HOME JG_ROOT JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_DATA_OVERRIDE JG_PROJECTS_OVERRIDE JG_ROOT_OVERRIDE JG_TASK_ID
unset JG_WAKE_QUEUE JG_WAKE_QUEUE_LOCK JG_WAKE_ROUTING JG_CAPTAIN_CHANNEL
W=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf -- "$W"' EXIT
export JG_ROOT_OVERRIDE=$W/notgit; mkdir -p "$JG_ROOT_OVERRIDE"      # the guard's worktree-tangle check stays inert
printf 'set mode off\n' > "$W/channel.conf"; export JG_CAPTAIN_CHANNEL=$W/channel.conf
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], want [$3]"; fi; }

mkhome() {   # <dir> [reads]: a main home with the store on, and its reads when asked
  mkdir -p "$1/state" "$1/config" "$1/data"; : > "$1/config/item-store"
  [ "${2:-}" != reads ] || : > "$1/config/item-store-reads"
}
drain() { local h=$1; shift; env JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_CONFIG_OVERRIDE="$h/config" "$DRAIN" "$@"; }
# shellcheck disable=SC2016  # the bash -c scripts expand in the child shell
queue() {   # <home> <kind> <key> <payload>: one record through the production writer
  env JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_CONFIG_OVERRIDE="$1/config" bash -c '. "$1/bin/jg-wake-lib.sh"; jg_wake_append "$2" "$3" "$4"' _ "$ROOT" "$2" "$3" "$4"
}
pages() {   # <home> <count>: that many unread pages for Main, the way an adapter opens them
  python3 -I - "$ITEM_DIR" "$1" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "main")
at = itemdb.stamp(st)
for i in range(int(sys.argv[3])):
    assert st.open(at, "tell:main/p%d" % i, "tell", "main", "p%d" % i, "page text %d" % i, st.me, source="t:%d" % i) == "open"
PY
}
ackcmd() { sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/jg-wake-drain.sh //p' "$1"; }

# ------------------------------------------------------------------ a: 10,000 pages, 3 queued records
A=$W/a; mkhome "$A" reads; pages "$A" 10000
queue "$A" stale jg-7 'stale: jg-7 waits on a permission prompt'
queue "$A" check ready-work 'check: ready work: 2 tickets, 1 free lane'
queue "$A" heartbeat heartbeat 'heartbeat: fleet review'
drain "$A" > "$W/a1.out" 2> "$W/a1.err"; rc=$?
eq a1-drain-exits-0 "$rc" 0
eq a2-the-3-reason-lines-under-QUEUED "$(sed -n '/^QUEUED/,/^queued:/p' "$W/a1.out" | grep -c -e '^stale: jg-7 waits on a permission prompt' -e '^check: ready work: 2 tickets, 1 free lane$' -e '^heartbeat: fleet review$')" 3
eq a3-queued-count "$(grep -c '^queued: 3$' "$W/a1.out")" 1
n=$(grep -cE '^[0-9]+	tell:main/p' "$W/a1.out")
if [ "$n" -gt 0 ] && [ "$n" -le 200 ]; then ok "a4-at-most-200-page-lines ($n)"; else bad a4-at-most-200-page-lines "$n"; fi
eq a5-the-count-line "$(grep -c '^pages: 200 listed, 0 closed since paged, [0-9]* more after ack; ack=[0-9]*$' "$W/a1.out")" 1
eq a6-no-UNREAD-STATUS "$(grep -c 'UNREAD STATUS' "$W/a1.out")" 0
first=$(grep -E '^[0-9]+	tell:main/p' "$W/a1.out" | head -n 1 | cut -f1)
cmd=$(ackcmd "$W/a1.err")
case $cmd in *"--pages-ack "*) ok a7-the-ack-command-carries-the-page-cursor ;; *) bad a7-the-ack-command-carries-the-page-cursor "[$cmd]" ;; esac
# shellcheck disable=SC2086
drain "$A" $cmd > "$W/a-ack.out" 2> "$W/a-ack.err"; rc=$?
eq a8-ack-exits-0 "$rc" 0
drain "$A" > "$W/a2.out" 2> "$W/a2.err"
eq a9-next-drain-prints-none-of-the-3-reason-lines "$(grep -c -e 'permission prompt' -e 'ready work' -e 'fleet review' -e '^QUEUED' "$W/a2.out")" 0
eq a10-next-drain-does-not-print-the-first-page-again "$(grep -cE "^$first	" "$W/a2.out")" 0
eq a11-next-drain-prints-the-next-pages "$(grep -c '^pages: 200 listed' "$W/a2.out")" 1
# shellcheck disable=SC2086
drain "$A" $cmd >/dev/null 2>&1; eq a12-the-same-ack-run-twice-still-exits-0 "$?" 0
drain "$A" --open-decisions > "$W/a-od.out"; eq a13-open-decisions-all-reads-the-store "$(cat "$W/a-od.out")" "OPEN DECISIONS: none"

# a page-only drain (empty queue) asks for the page acknowledgement alone
B=$W/b0; mkhome "$B" reads; pages "$B" 3
drain "$B" > "$W/b0.out" 2> "$W/b0.err"
eq a14-empty-queue-still-lists-the-pages "$(grep -cE '^[0-9]+	tell:main/p' "$W/b0.out")" 3
cmd=$(ackcmd "$W/b0.err"); case $cmd in "--ack-through 0 --recovery-generation none --pages-ack "*) ok a15-empty-queue-ack-is-pages-only ;; *) bad a15-empty-queue-ack-is-pages-only "[$cmd]" ;; esac
# shellcheck disable=SC2086
drain "$B" $cmd >/dev/null 2>&1; drain "$B" > "$W/b0b.out" 2> "$W/b0b.err"
eq a16-after-the-ack-a-quiet-drain-prints-nothing-and-asks-nothing "$(cat "$W/b0b.out" "$W/b0b.err" | grep -c -e PAGES -e WAKE_ACK_REQUIRED -e tell:main)" 0

# ------------------------------------------------------------------ b: 500 queued records
C=$W/c; mkhome "$C" reads
# shellcheck disable=SC2016
seq 0 499 | env JG_HOME="$C" JG_STATE_OVERRIDE="$C/state" JG_CONFIG_OVERRIDE="$C/config" ROOT="$ROOT" xargs -P 8 -I{} bash -c '. "$ROOT/bin/jg-wake-lib.sh"; jg_wake_append check "k{}" "check: record {} padded to a long reason line so the byte cap has work to do ................................"'
drain "$C" > "$W/c1.out" 2> "$W/c1.err"
shown=$(sed -n '/^QUEUED/,/^queued:/p' "$W/c1.out" | grep -c '^check: record ')
bytes=$(sed -n '/^QUEUED/,/^queued:/p' "$W/c1.out" | grep '^check: record ' | wc -c)
if [ "$shown" -le 200 ] && [ "$shown" -gt 0 ] && [ "$bytes" -le 32768 ]; then ok "b1-QUEUED-prints-at-most-200-lines-and-32-KiB ($shown lines, $bytes bytes)"; else bad b1-QUEUED-prints-at-most-200-lines-and-32-KiB "$shown lines, $bytes bytes"; fi
eq b2-queued-500 "$(grep -c '^queued: 500$' "$W/c1.out")" 1
cmd=$(ackcmd "$W/c1.err")
# shellcheck disable=SC2086
drain "$C" $cmd >/dev/null 2>&1
drain "$C" > "$W/c2.out" 2> "$W/c2.err"
eq b3-the-ack-stops-at-the-last-line-shown "$(grep -c "^queued: $((500 - shown))\$" "$W/c2.out")" 1
sed -n '/^QUEUED/,/^queued:/p' "$W/c1.out" | grep '^check: record ' | sort > "$W/c1.lines"
sed -n '/^QUEUED/,/^queued:/p' "$W/c2.out" | grep '^check: record ' | sort > "$W/c2.lines"
eq b4-the-rest-come-next "$(comm -12 "$W/c1.lines" "$W/c2.lines" | grep -c .) $(grep -c . "$W/c2.lines")" "0 $((500 - shown > 200 ? 200 : 500 - shown))"

# ------------------------------------------------------------------ c: open decisions, record divergence, a home with no switch
D=$W/d; mkhome "$D" reads
python3 -I - "$ITEM_DIR" "$D" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "main")
at = itemdb.stamp(st)
assert st.open(at, "question:main/jg-9", "question", "main", "jg-9", "may jg-9 merge?", st.me, source="q:1") == "open"
PY
drain "$D" > "$W/d1.out" 2>&1
eq c1-an-open-owner-question-is-under-OPEN-DECISIONS "$(sed -n '/^OPEN DECISIONS/,$p' "$W/d1.out" | grep -c 'jg-9 \[key=question:main/jg-9\] decision: may jg-9 merge?')" 1
drain "$D" --open-decisions > "$W/d2.out"
eq c2-open-decisions-all-lists-it "$(grep -c 'may jg-9 merge?' "$W/d2.out")" 1
mkdir -p "$D/state/inbox"; printf 'id=1-abc\nsource=text\n--\nhello\n' > "$D/state/inbox/1-abc.note"
drain "$D" > "$W/d3.out" 2>&1
eq c3-a-record-only-in-today-is-under-RECORD-DIVERGENCE "$(sed -n '/^RECORD DIVERGENCE/,$p' "$W/d3.out" | grep -c '^1-abc tell today=waiting store=none$')" 1
E=$W/e; mkhome "$E" reads
printf '%s\n' "$E-store" > "$E/config/beads-dir"   # kept until bin/jg-backlog-lib.sh stops asking for a store path
rm -f "$E/config/item-store"
env JG_HOME="$E" JG_STATE_OVERRIDE="$E/state" JG_DATA_OVERRIDE="$E/data" JG_CONFIG_OVERRIDE="$E/config" "$ROOT/bin/jg-captain-hold.sh" hold jg-a0004 --title "[captain-ask] store off" --reason "set with the store off" --repo e-pr >/dev/null 2>&1
: > "$E/config/item-store"
drain "$E" > "$W/e1.out" 2>&1
eq c4-a-hold-set-only-in-today-is-under-RECORD-DIVERGENCE "$(sed -n '/^RECORD DIVERGENCE/,$p' "$W/e1.out" | grep -c '^jg-a0004 question today=held store=none$')" 1
F=$W/f; mkhome "$F"       # no config/item-store-reads: the status-line presentation stays
printf 'needs-decision [key=k1]: pick one\n' > "$F/state/jg-3.status"
queue "$F" signal jg-3.status 'signal: jg-3.status'
drain "$F" > "$W/f1.out" 2>&1
eq c5-without-the-switch-OPEN-DECISIONS-is-still-folded-from-the-status-log "$(grep -c 'jg-3 \[key=k1\] needs-decision: pick one' "$W/f1.out")" 1
eq c6-without-the-switch-there-is-no-QUEUED-or-PAGES "$(grep -c -e '^QUEUED' -e '^PAGES' "$W/f1.out")" 0

# ------------------------------------------------------------------ d: the watcher's second doorbell
start_watch() {   # <home> -> sets WPID
  mkdir -p "$1/home/config" "$1/tmp"
  env HOME="$1/home" XDG_CONFIG_HOME="$1/home/config" TMPDIR="$1/tmp" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_CONFIG_OVERRIDE="$1/config" \
    JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_FAST_CHECK_INTERVAL=1 JG_POLL=1 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_STALE_ESCALATE_SECS=999999 "$WATCH" > "$1/out" 2> "$1/err" &
  WPID=$!
}
stop_watch() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
G=$W/g; mkhome "$G" reads; pages "$G" 2
start_watch "$G"
i=0; while [ "$i" -lt 60 ] && ! grep -qs 'item-pages' "$G/state/.wake-queue"; do sleep 0.25; i=$((i+1)); done
stop_watch
eq d1-a-page-and-an-empty-queue-raise-one-wake "$(cat "$G/state/.wake-queue" 2>/dev/null | grep -c 'item-pages')" 1
H=$W/h; mkhome "$H" reads; env JG_HOME="$H" "$ITEM_DIR/jg-item" pages main >/dev/null
start_watch "$H"; sleep 6; stop_watch
eq d2-no-page-and-an-empty-queue-raise-none "$(cat "$H/state/.wake-queue" 2>/dev/null | grep -c 'item-pages')" 0
J=$W/j; mkhome "$J"; pages "$J" 2     # a page but no switch: the doorbell stays off
start_watch "$J"; sleep 4; stop_watch
eq d3-without-the-switch-the-doorbell-is-off "$(cat "$J/state/.wake-queue" 2>/dev/null | grep -c 'item-pages')" 0

# ------------------------------------------------------------------ e: jg_wait_is_open
K=$W/k; mkhome "$K"; mkdir -p "$K/projects/alpha"; ln -sn "$ROOT/bin" "$K/bin"; ln -sn "$ROOT/core" "$K/core"
printf 'kind=ship\nproject=%s/projects/alpha\nticket=BG-1\n' "$W" > "$K/state/lane.meta"
python3 -I - "$ITEM_DIR" "$K" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import itemdb
st = itemdb.open_db(sys.argv[2], "owner:registry")
st.set_policy(int(time.time()) - 10, "alpha", "standard", "owner:registry", "import:projects.md:alpha", lanes=16)
PY
printf 'blocked [at=1] [key=kb]: the one wait\n' > "$K/state/lane.status"
python3 -I "$LANE" read "$K/state/lane.status"
# shellcheck source=bin/jg-classify-lib.sh
. "$ROOT/bin/jg-classify-lib.sh"
# shellcheck source=bin/jg-wait-write-lib.sh
. "$ROOT/bin/jg-wait-write-lib.sh"
export JG_HOME=$K
printf 'working [at=2]: the file no longer says the wait\n' > "$K/state/lane.status"
jg_wait_is_open "$K/state/lane.status" kb; eq e1-without-the-switch-the-fold-answers-closed "$?" 1
: > "$K/config/item-store-reads"
jg_wait_is_open "$K/state/lane.status" kb; eq e2-with-the-switch-the-store-answers-open "$?" 0
jg_wait_is_open "$K/state/lane.status" zz; eq e3-with-the-switch-a-wait-the-store-lacks-is-closed "$?" 1
unset JG_HOME

exit "$fail"
