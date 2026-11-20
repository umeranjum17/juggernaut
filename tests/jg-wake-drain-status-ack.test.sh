#!/usr/bin/env bash
# tests/jg-wake-drain-status-ack.test.sh - the wake drain's status presentation and acknowledgement
# on a home whose per-actor status journal is large (jg-4t5ne-24).
#
# A drain presents every signalled status file, then records the presented endpoint in
# `.wake-status-<actor>.json`; the acknowledgement refuses `status ... changed after presentation`
# when that endpoint is not the file's current end. A real append must still refuse. An unchanged
# file must never refuse. When the journal is big, a presentation that reads it again for every
# signal row outlasts the caller's time bound, is killed before the journal is saved, and the
# recorded endpoint stays behind a file that has not changed: every acknowledgement then refuses.
# These tests drive the real drain; a jq shim counts how many times a large journal is read.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/jg-wake-drain.sh"
TMP_ROOT=$(jg_test_tmproot jg-wake-drain-status-ack-tests)

SIGNALLED=40   # signalled tasks, one queue row each
BULK_TASKS=30  # unsignalled tasks that only fatten the journal
BULK_EVENTS=300 # events kept per bulk task

# A home with SIGNALLED status files, one signal row each, and a journal fattened by BULK_TASKS
# tasks of already-presented events. Prints the case directory.
make_big_journal_home() {  # <name> [events per bulk task]
  local dir state i
  dir=$(make_case "$1"); state="$dir/state"
  i=1
  while [ "$i" -le "$SIGNALLED" ]; do
    printf 'working [at=1795000000]: task %s is going\nnote [at=1795000001]: still going\n' "$i" > "$state/sig$i.status"
    append_wake "$state" signal "sig$i.status" "signal: sig$i.status" >/dev/null || fail "could not queue a signal row"
    i=$((i + 1))
  done
  python3 -I - "$state/.wake-status-main.json" "$BULK_TASKS" "${2:-$BULK_EVENTS}" <<'PY' || fail "could not write the bulk journal"
import hashlib, json, sys
path, tasks, events = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
journal = {}
for t in range(tasks):
    evs = []
    for e in range(events):
        line = "working: bulk event %d of task %d " % (e, t) + "x" * 400
        evs.append({"id": hashlib.sha256(("%d/%d" % (t, e)).encode()).hexdigest(), "kind": "STATUS", "line": line})
    journal["bulk%d" % t] = {"ident": "strong:0:0:none", "end": 1, "events": evs, "seqs": [1000 + t]}
with open(path, "w") as f:
    json.dump(journal, f, separators=(",", ":"))
    f.write("\n")
PY
  printf '%s\n' "$dir"
}

# A jq that logs the byte size of every input it reads, then runs the real jq on it.
make_counting_jq() {  # <fakebin> <log>
  local fakebin=$1 log=$2 real
  real=$(command -v jq) || fail "jq is not installed"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
tmp=\$(mktemp) || exit 1
cat > "\$tmp"
wc -c < "\$tmp" >> '$log'
"$real" "\$@" < "\$tmp"
rc=\$?
rm -f -- "\$tmp"
exit \$rc
SH
  chmod +x "$fakebin/jq"
}

# How many logged reads were of at least <bytes> bytes.
count_reads_over() {  # <log> <bytes>
  awk -v n="$2" '$1 + 0 >= n { c++ } END { print c + 0 }' "$1"
}

drain_and_ack() {  # <dir> <out> <err>
  local dir=$1
  PATH="$dir/fakebin:$PATH" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$2" 2> "$3" || return 1
  PATH="$dir/fakebin:$PATH" ack_drain_err "$dir/state" "$3"
}

test_big_journal_is_read_a_bounded_number_of_times_and_acks() {
  local dir state log reads size
  dir=$(make_big_journal_home big-journal); state="$dir/state"
  log="$dir/jq-reads.log"; : > "$log"
  make_counting_jq "$dir/fakebin" "$log"
  size=$(wc -c < "$state/.wake-status-main.json" | tr -d '[:space:]')
  [ "$size" -gt 1000000 ] || fail "the bulk journal is only $size bytes; it must be big enough to matter"

  drain_and_ack "$dir" "$dir/out" "$dir/err" \
    || fail "drain then acknowledgement refused on a home whose status files never changed: $(tail -3 "$dir/err")"
  reads=$(count_reads_over "$log" "$((size / 2))")
  [ "$reads" -le 12 ] \
    || fail "the large journal was read $reads times for $SIGNALLED signal rows; the cost must not grow with the row count"
  grep -F 'wake annotation: STATUS: sig1.status: note [at=1795000001]: still going' "$dir/out" >/dev/null \
    || fail "the newest signalled status line was not presented"
  grep -F 'wake annotation: sig1.status: 1 earlier event(s) not shown' "$dir/out" >/dev/null \
    || fail "the first task's cut was not counted"
  grep -F 'wake annotation: STATUS: sig40.status: note [at=1795000001]: still going' "$dir/out" >/dev/null \
    || fail "the last signalled status was not presented"
  pass "a $size-byte journal is read $reads times for $SIGNALLED rows and the acknowledgement lands"
}

test_a_real_append_after_presentation_still_refuses() {
  local dir state
  dir=$(make_big_journal_home append-refuses 5); state="$dir/state"
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "the first drain failed"
  printf 'blocked [at=1795000100]: a new line after the drain\n' >> "$state/sig7.status"
  if ack_drain_err "$state" "$dir/err" 2> "$dir/ack.err"; then
    fail "the acknowledgement landed after sig7.status grew"
  fi
  grep -F 'wake drain: status sig7.status changed after presentation' "$dir/ack.err" >/dev/null \
    || fail "the refusal for the appended status was not the changed-after-presentation line: $(cat "$dir/ack.err")"
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out2" 2> "$dir/err2" || fail "the second drain failed"
  grep -F 'a new line after the drain' "$dir/out2" >/dev/null || fail "the appended line was not presented by the next drain"
  ack_drain_err "$state" "$dir/err2" || fail "the acknowledgement after a fresh drain still refused"
  pass "a real append refuses, then the next drain presents it and the acknowledgement lands"
}

test_a_rewrite_after_presentation_still_refuses() {
  local dir state
  dir=$(make_big_journal_home rewrite-refuses 5); state="$dir/state"
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "the first drain failed"
  rm -f -- "$state/sig3.status"
  printf 'working [at=1795000200]: rewritten\n' > "$state/sig3.status"
  if ack_drain_err "$state" "$dir/err" 2> "$dir/ack.err"; then
    fail "the acknowledgement landed after sig3.status was replaced"
  fi
  grep -F 'status sig3.status changed after presentation' "$dir/ack.err" >/dev/null \
    || fail "the refusal for the replaced status was not the changed-after-presentation line: $(cat "$dir/ack.err")"
  pass "a replaced status file refuses the acknowledgement"
}

# A home nobody drained for days: hundreds of queued rows, one signalled log of hundreds of outcomes, and an unsignalled log
# of hundreds of unread notes. One drain must print a bounded page of each, count what it left, and acknowledge only through
# what it showed; the hidden outcomes need no disposition and the rest of the queue follows the acknowledgement.
test_a_flooded_home_prints_a_bounded_page_and_acks() {
  local dir state i id out
  dir=$(make_case flooded); state="$dir/state"
  i=1
  while [ "$i" -le 450 ]; do
    printf 'done [at=1795000000]: item %s report\n' "$i" >> "$state/big.status"
    printf 'note [at=1795000001]: unread note %s\n' "$i" >> "$state/quiet.status"
    i=$((i + 1))
  done
  append_wake "$state" signal big.status "signal: big.status" >/dev/null || fail "could not queue the signal row"
  i=1
  while [ "$i" -le 450 ]; do
    append_wake "$state" check "chk$i" "check: chk$i is red" >/dev/null || fail "could not queue a check row"
    i=$((i + 1))
  done
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out" 2> "$dir/err" || fail "the flooded drain failed: $(tail -3 "$dir/err")"
  [ "$(wc -c < "$dir/out")" -lt 120000 ] || fail "the flooded drain printed $(wc -c < "$dir/out") bytes"
  grep -F 'WAKE QUEUE: 451 queued event(s)' "$dir/out" >/dev/null || fail "the page did not count the queue: $(grep -c . "$dir/out") lines"
  [ "$(grep -c 'check: chk' "$dir/out")" -le 60 ] || fail "the page printed more than 60 queued rows"
  [ "$(grep -c '^wake annotation: OUTCOME: big.status' "$dir/out")" -le 10 ] || fail "the annotation replayed more than 10 events of one task"
  grep -F 'wake annotation: big.status: ' "$dir/out" | grep -F 'earlier event(s) not shown' >/dev/null \
    || fail "the annotation did not count the events it left out"
  [ "$(grep -c '^quiet unread\|^quiet note' "$dir/out")" -le 20 ] || fail "the unread section printed more than 20 lines"
  grep -F 'UNREAD STATUS: 430 earlier unread line(s) not shown' "$dir/out" >/dev/null || fail "the unread section did not count its cut"
  while IFS= read -r id; do
    JG_STATE_OVERRIDE="$state" "$DRAIN" --outcome "$id" --classified "test relays nothing" > /dev/null 2>&1 || fail "could not classify outcome $id"
  done <<EOF
$(sed -n 's/^OUTCOME_REQUIRED: //p' "$dir/out")
EOF
  ack_drain_err "$state" "$dir/err" || fail "the acknowledgement of the shown page refused: $(tail -3 "$dir/err")"
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/out2" 2> "$dir/err2" || fail "the next drain failed"
  grep -F 'check: chk60 is red' "$dir/out2" >/dev/null || fail "the next page did not follow the acknowledgement"
  out=$(grep -c 'check: chk' "$dir/out2")
  pass "a flooded home prints $(wc -c < "$dir/out") bytes, acknowledges through its page and the next drain shows the next $out rows"
}

test_big_journal_is_read_a_bounded_number_of_times_and_acks
test_a_real_append_after_presentation_still_refuses
test_a_rewrite_after_presentation_still_refuses
test_a_flooded_home_prints_a_bounded_page_and_acks

echo "# jg-wake-drain-status-ack.test.sh: all assertions passed"
