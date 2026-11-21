#!/usr/bin/env bash
# tests/jg-auto-dispatch-batch.test.sh - auto-dispatch and ready-stall batch their
# captain-hold blocking read into one store read per pass, agree identically with the
# per-row blocking predicate across every hold/link/design case, finish a 138-row
# backlog in seconds, keep watcher check cadence moving while a pass runs, and
# align Treehouse pool max_trees with the home's lane limit.
set -u
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/auto-dispatch-batch.log")
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(jg_test_tmproot jg-auto-dispatch-batch)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
DISPATCH="$ROOT/core/auto-dispatch/dispatch.sh"
HOLD_BIN="$ROOT/bin/jg-captain-hold.sh"
BACKLOG_BIN="$ROOT/bin/jg-backlog.sh"

# Helper: make a counting wrapper around the real bin/jg-captain-hold.sh.
make_counting_hold() {  # <wrapper-path> <log-path>
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exec "$HOLD_BIN" "\$@"
SH
  chmod +x "$1"
}

lines_of() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

# ---- T1: Exact parity between `blocking --batch` and per-row `blocking <id>` ----
t1_batch_matches_per_row_parity() {
  local d="$TMP_ROOT/t1" id batch_out batch_rc=0 per_out per_rc b_lines p_lines
  mkdir -p "$d/state/dispatch-approved" "$d/config" "$d/data"
  printf -- '- proj [local-trunk] - parity fixture (added 2026-11-01)\n' > "$d/data/projects.md"
  : > "$d/config/backlog-intake-loose"
  # Generate a valid captain-approval.key and signed line for the approved design-ux ticket.
  local sig_line
  sig_line=$(STATE="$d/state" bash -c 'fail() { echo "$*" >&2; exit 1; }; . "$1" && captain_ask_approval_line jg-dux-approved answer:ok1' _ "$ROOT/bin/jg-captain-ask-lib.sh") \
    || fail "T1: could not sign design-ux approval line"

  python3 - "$d" "$sig_line" <<'PY'
import json, sys
d, sig_line = sys.argv[1], sys.argv[2]
rows = [
    # 1. Plain captain-held decision (no gate)
    {"id": "jg-held-plain", "title": "Plain held decision", "status": "on_hold", "priority": 1, "issue_type": "decision",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"],
     "metadata": {"hold_kind": "captain", "hold_reason": "owner picks"}},
    # 2. Gated ticket (open gate row + blocks edge)
    {"id": "jg-gate-open", "title": "Open gate question", "status": "open", "priority": 1, "issue_type": "gate",
     "created_at": "2026-11-01T00:00:00Z", "description": "Reason: pick A or B", "labels": [],
     "metadata": {"must": "design-pick", "close": "release"}},
    {"id": "jg-gated", "title": "[feature] Gated work", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-gated", "depends_on_id": "jg-gate-open", "type": "blocks"}]},
    # 3. Forward link: candidate links to held decision
    {"id": "jg-fwd-linked", "title": "[feature] Forward linked", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-fwd-linked", "depends_on_id": "jg-held-plain", "type": "blocks"}]},
    # 4. Reverse link: open decision links to candidate
    {"id": "jg-rev-dec", "title": "Reverse linking decision", "status": "on_hold", "priority": 1, "issue_type": "decision",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"],
     "metadata": {"hold_kind": "captain", "hold_reason": "blocks child"},
     "dependencies": [{"issue_id": "jg-rev-dec", "depends_on_id": "jg-rev-linked", "type": "related"}]},
    {"id": "jg-rev-linked", "title": "[feature] Reverse linked", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}},
    # 5. Parent link to gated work
    {"id": "jg-child-of-gated", "title": "[feature] Child of gated", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-child-of-gated", "depends_on_id": "jg-gated", "type": "parent-child"}]},
    # 6. Unheld, unanswered [design-ux] ticket and a candidate linked to it
    {"id": "jg-dux-open", "title": "[design-ux] Choose layout", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj", "design-ux"], "metadata": {}},
    {"id": "jg-waits-dux-open", "title": "[feature] Waits on design", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-waits-dux-open", "depends_on_id": "jg-dux-open", "type": "blocks"}]},
    # 7. Answered [design-ux] ticket (closed gate with resolution=answered)
    {"id": "jg-gate-ans", "title": "Answered design gate", "status": "closed", "priority": 1, "issue_type": "gate",
     "created_at": "2026-11-01T00:00:00Z", "closed_at": "2026-11-02T00:00:00Z", "close_reason": "Option A",
     "labels": [], "metadata": {"resolution": "answered"}},
    {"id": "jg-dux-answered", "title": "[design-ux] Answered layout", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj", "design-ux"], "metadata": {},
     "dependencies": [{"issue_id": "jg-dux-answered", "depends_on_id": "jg-gate-ans", "type": "blocks"}]},
    {"id": "jg-waits-dux-ans", "title": "[feature] After answered design", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-waits-dux-ans", "depends_on_id": "jg-dux-answered", "type": "blocks"}]},
    # 8. Build-approved [design-ux] ticket (signed approved-by-captain line in body)
    {"id": "jg-dux-approved", "title": "[design-ux] Signed layout", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "description": sig_line,
     "labels": ["project:proj", "design-ux"], "metadata": {}},
    {"id": "jg-waits-dux-app", "title": "[feature] After signed design", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {},
     "dependencies": [{"issue_id": "jg-waits-dux-app", "depends_on_id": "jg-dux-approved", "type": "blocks"}]},
    # 9. Plain unblocked row, and a legacy-aliased row linked to held decision
    {"id": "jg-clear", "title": "[feature] Plain clear task", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}},
    {"id": "jg-legacy-canon", "title": "[feature] Legacy aliased task", "status": "open", "priority": 1, "issue_type": "task",
     "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"],
     "metadata": {"legacy_item": "jg-legacy-old"},
     "dependencies": [{"issue_id": "jg-legacy-canon", "depends_on_id": "jg-held-plain", "type": "blocks"}]},
]
with open(d + "/export.jsonl", "w") as out:
    for r in rows:
        out.write(json.dumps(r) + "\n")
PY
  JG_HOME="$d" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$d/export.jsonl" >/dev/null \
    || fail "T1: ticket import failed"

  local -a candidates=(
    jg-held-plain jg-gated jg-fwd-linked jg-rev-linked jg-child-of-gated
    jg-dux-open jg-waits-dux-open jg-waits-dux-ans jg-waits-dux-app
    jg-clear jg-legacy-old jg-absent-id
  )
  printf '%s\n' "${candidates[@]}" > "$d/candidates"

  batch_out=$(JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_DATA_OVERRIDE="$d/data" JG_CONFIG_OVERRIDE="$d/config" \
    "$HOLD_BIN" blocking --batch < "$d/candidates" 2>"$d/batch.err") || batch_rc=$?
  assert_equals 0 "$batch_rc" "T1: blocking --batch exits 0 (err: $(cat "$d/batch.err"))"
  assert_equals "blocking-batch: ok" "$(printf '%s\n' "$batch_out" | head -n 1)" "T1: header line present"

  for id in "${candidates[@]}"; do
    per_rc=0
    per_out=$(JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_DATA_OVERRIDE="$d/data" JG_CONFIG_OVERRIDE="$d/config" \
      "$HOLD_BIN" blocking "$id" 2>/dev/null) || per_rc=$?
    p_lines=$(printf '%s\n' "$per_out" | sed '/^$/d' | LC_ALL=C sort)
    b_lines=$(printf '%s\n' "$batch_out" | tail -n +2 | awk -F'\t' -v id="$id" '$1 == id { print $2 "\t" $3 }' | LC_ALL=C sort)
    if [ "$per_rc" -eq 0 ]; then
      [ -n "$b_lines" ] || fail "T1: batch missed blocked candidate $id (per-row: $p_lines)"
      assert_equals "$b_lines" "$p_lines" "T1: exact blocker lines match for $id"
    elif [ "$per_rc" -eq 1 ]; then
      assert_equals "$b_lines" "" "T1: batch must not block clear candidate $id"
    else
      fail "T1: unexpected per-row rc=$per_rc for $id"
    fi
  done

  # Fail-closed check: unreadable store fails batch in one call (exit 2, jg-captain-hold: stderr).
  local bad_rc=0 bad_err
  bad_err=$(JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_DATA_OVERRIDE="$d/no-such-data" JG_CONFIG_OVERRIDE="$d/config" \
    "$HOLD_BIN" blocking --batch < "$d/candidates" 2>&1 >/dev/null) || bad_rc=$?
  assert_equals 2 "$bad_rc" "T1: unreadable data dir exits 2"
  assert_contains "$bad_err" "jg-captain-hold:" "T1: fail-closed error names jg-captain-hold"
  pass "T1: blocking --batch matches per-row blocking identically across all 12 hold/link/design/legacy/absent cases"
}

# ---- T2: One batched read per pass & 138-row timing benchmark ----
t2_138_row_pass_single_read_and_fast() {
  local d="$TMP_ROOT/t2" t0 t1 elapsed_ms i
  mkdir -p "$d/state/dispatch-approved" "$d/config" "$d/data"
  printf -- '- proj [local-trunk] - synthetic 138-row project (added 2026-11-01)\n' > "$d/data/projects.md"
  printf '4\n' > "$d/config/lane-target"
  touch "$d/state/.last-watcher-beat"
  : > "$d/config/item-store"

  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
with open(d + "/export.jsonl", "w") as out:
    out.write(json.dumps({
        "id": "jg-dec", "title": "Owner decision", "status": "on_hold", "priority": 1, "issue_type": "decision",
        "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"],
        "metadata": {"hold_kind": "captain", "hold_reason": "owner decides"}
    }) + "\n")
    for i in range(1, 139):
        row = {
            "id": f"jg-t{i:03d}", "title": f"[feature] Synthetic slice {i}", "status": "open", "priority": 1,
            "issue_type": "task", "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}
        }
        if i % 10 == 0:
            row["dependencies"] = [{"issue_id": row["id"], "depends_on_id": "jg-dec", "type": "blocks"}]
        out.write(json.dumps(row) + "\n")
PY
  JG_HOME="$d" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$d/export.jsonl" >/dev/null \
    || fail "T2: 138-row import failed"
  for i in $(seq -f '%03g' 1 138); do
    printf 'approved-by=test\napproved-at=1\nharness=claude\nmodel=sonnet\neffort=medium\n' > "$d/state/dispatch-approved/jg-t$i"
    mkdir -p "$d/data/jg-t$i"
    printf 'brief %s\n' "$i" > "$d/data/jg-t$i/brief.md"
  done

  make_counting_hold "$d/count-hold" "$d/hold.calls"
  t0=$(date +%s%3N)
  JG_HOME="$d" JG_AUTO_DISPATCH_BACKLOG="$BACKLOG_BIN" JG_AUTO_DISPATCH_HOLD="$d/count-hold" \
    bash "$DISPATCH" pass "$d" >/dev/null || fail "T2: 138-row dispatch pass failed"
  t1=$(date +%s%3N)
  elapsed_ms=$((t1 - t0))

  assert_equals 1 "$(lines_of "$d/hold.calls")" "T2: exactly one hold invocation for 138 approved rows"
  assert_equals "blocking --batch" "$(cat "$d/hold.calls")" "T2: the single call is blocking --batch"
  assert_equals 138 "$(cut -f3 "$d/data/auto-dispatch/passes.tsv" | tail -n 1)" "T2: passes.tsv counts all 138 candidates"
  assert_equals 13 "$(grep -c $'\tan open decision is linked to it$' "$d/data/auto-dispatch/rows.tsv")" "T2: all 13 linked rows are marked blocked"
  assert_equals 4 "$(grep -c $'\twould start\t' "$d/data/auto-dispatch/rows.tsv")" "T2: 4 free lanes marked would start"
  local store_n
  store_n=$(python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("SELECT count(*) FROM item WHERE kind=\"dispatch\"").fetchone()[0])' "$d/state/item-store/fleet.db")
  assert_equals 138 "$store_n" "T2: item-store recorded all 138 dispatch items in one batch"
  [ "$elapsed_ms" -lt 10000 ] || fail "T2: 138-row pass took ${elapsed_ms}ms (must finish in seconds, <10000ms)"
  pass "T2: 138-row auto-dispatch pass ran in ${elapsed_ms} ms with 1 batched hold read and 138 item-store rows"
}

# ---- T3: ready_backlog_stall_state in bin/jg-watch.sh batches into ONE hold read ----
t3_ready_stall_single_batched_read() {
  local d="$TMP_ROOT/t3" fn="$TMP_ROOT/t3/stall-fn.sh" i
  mkdir -p "$d/bin" "$d/state" "$d/config" "$d/data"
  printf -- '- proj [local-trunk] - stall fixture (added 2026-11-01)\n' > "$d/data/projects.md"
  python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
with open(d + "/export.jsonl", "w") as out:
    out.write(json.dumps({
        "id": "jg-dec", "title": "Open stall decision", "status": "on_hold", "priority": 1, "issue_type": "decision",
        "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"],
        "metadata": {"hold_kind": "captain", "hold_reason": "owner picks"}
    }) + "\n")
    for i in range(1, 21):
        row = {
            "id": f"jg-r{i:02d}", "title": f"[feature] Ready row {i}", "status": "open", "priority": 1,
            "issue_type": "task", "created_at": "2026-11-01T00:00:00Z", "labels": ["project:proj"], "metadata": {}
        }
        if i <= 5:
            row["dependencies"] = [{"issue_id": row["id"], "depends_on_id": "jg-dec", "type": "blocks"}]
        out.write(json.dumps(row) + "\n")
PY
  JG_HOME="$d" python3 "$ROOT/core/item-store/adapters/tickets.py" import --home main "$d/export.jsonl" >/dev/null \
    || fail "T3: import failed"

  sed -n '/^ready_backlog_stall_state() {$/,/^}$/p' "$ROOT/bin/jg-watch.sh" > "$fn"
  [ -s "$fn" ] || fail "T3: ready_backlog_stall_state not found in bin/jg-watch.sh"
  make_counting_hold "$d/bin/jg-captain-hold.sh" "$d/hold.calls"
  : > "$d/bin/jg-question-lib.sh"

  local got_ids
  # shellcheck disable=SC2030,SC2034,SC2329 # intentional subshell env for the sourced ready_backlog_stall_state function
  got_ids=$(
    JG_HOME="$d" STATE="$d/state" CONFIG="$d/config" SCRIPT_DIR="$d/bin" JG_DATA_OVERRIDE="$d/data"
    jg_compat_marker() { printf '%s\n' "$fn"; }
    jg_ready_work_rows() { for i in $(seq -f '%02g' 1 20); do printf 'jg-r%s -\n' "$i"; done; }
    lane_target_value() { printf '4\n'; }
    open_lane_count() { printf '0\n'; }
    admission_refusal_fresh() { return 1; }
    jg_question_signoff_available() { return 1; }
    jg_project_capacity_config_dir() { return 1; }
    watcher_beat() { :; }
    # shellcheck source=/dev/null
    . "$fn"
    ready_backlog_stall_state && printf '%s\n' "$READY_STALL_IDS"
  ) || fail "T3: ready_backlog_stall_state failed"

  assert_equals 1 "$(lines_of "$d/hold.calls")" "T3: ready_backlog_stall_state made exactly 1 hold call for 20 rows"
  assert_equals "blocking --batch" "$(cat "$d/hold.calls")" "T3: ready_backlog_stall_state called blocking --batch"
  assert_equals 15 "$(printf '%s' "$got_ids" | wc -w | tr -d ' ')" "T3: 15 unblocked rows kept, 5 linked rows excluded"
  case " $got_ids " in *" jg-r01 "*|*" jg-r05 "*) fail "T3: blocked row leaked into READY_STALL_IDS: $got_ids" ;; esac
  case " $got_ids " in *" jg-r06 "*|*" jg-r20 "*) ;; *) fail "T3: clear row missing from READY_STALL_IDS: $got_ids" ;; esac
  pass "T3: ready_backlog_stall_state evaluates 20 ready rows with 1 batched hold read and exact exclusion"
}

# ---- T4: A running auto-dispatch pass does not stall fast or slow watcher checks ----
t4_running_pass_does_not_stall_check_cadence() {
  local d farm item wpid='' holder_pid=''
  d=$(make_case t4-cadence)
  farm=$d/farm
  mkdir -p "$d/home/config" "$d/tmp" "$d/config" "$d/log" "$d/data/auto-dispatch" "$farm/bin" "$farm/core/wait-timers/bin"
  for item in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in bin|core) ;; *) ln -s "$item" "$farm/${item##*/}" ;; esac
  done
  for item in "$ROOT"/bin/* "$ROOT"/bin/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in jg-board-answers.sh) ;; *) ln -s "$item" "$farm/bin/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/* "$ROOT"/core/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in wait-timers) ;; *) ln -s "$item" "$farm/core/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/wait-timers/* "$ROOT"/core/wait-timers/.[!.]*; do
    [ -e "$item" ] || continue
    case "${item##*/}" in bin) ;; *) ln -s "$item" "$farm/core/wait-timers/${item##*/}" ;; esac
  done
  for item in "$ROOT"/core/wait-timers/bin/*; do
    case "${item##*/}" in jg-wait-timers-lib.sh) ;; *) ln -s "$item" "$farm/core/wait-timers/bin/${item##*/}" ;; esac
  done
  printf '#!/usr/bin/env bash\ndate +%%s >> "%s/log/board"\nexit 0\n' "$d" > "$farm/bin/jg-board-answers.sh"
  chmod +x "$farm/bin/jg-board-answers.sh"
  printf 'jg_wait_timers_tick() { :; }\n' > "$farm/core/wait-timers/bin/jg-wait-timers-lib.sh"

  # Stand-in backlog that waits until the test drops $d/log/release (simulating a long in-flight pass).
  cat > "$d/slow-backlog" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$(date +%s)" >> "$d/log/pass-started"
i=0
while [ ! -e "$d/log/release" ] && [ \$i -lt 100 ]; do sleep 0.2; i=\$((i + 1)); done
SH
  chmod +x "$d/slow-backlog"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/hold"
  chmod +x "$d/hold"

  # Wire auto-dispatch.check.sh to the REAL dispatch.sh, and add a slow-sweep sibling check z-cadence.check.sh.
  cat > "$d/state/auto-dispatch.check.sh" <<SH
#!/usr/bin/env bash
exec env JG_HOME="$d" JG_AUTO_DISPATCH_BACKLOG="$d/slow-backlog" JG_AUTO_DISPATCH_HOLD="$d/hold" bash "$DISPATCH" check "$d"
SH
  cat > "$d/state/z-cadence.check.sh" <<SH
#!/usr/bin/env bash
date +%s >> "$d/log/z-cadence"
SH
  chmod 700 "$d/state/auto-dispatch.check.sh" "$d/state/z-cadence.check.sh"
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" "$ROOT/bin/jg-check-register.sh" auto-dispatch >/dev/null || fail "T4: register auto-dispatch"
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" "$ROOT/bin/jg-check-register.sh" z-cadence >/dev/null || fail "T4: register z-cadence"

  # Start one real dispatch.sh pass in the background holding .check.lock.
  env JG_HOME="$d" JG_AUTO_DISPATCH_BACKLOG="$d/slow-backlog" JG_AUTO_DISPATCH_HOLD="$d/hold" \
    bash "$DISPATCH" check "$d" >/dev/null 2>&1 &
  holder_pid=$!
  local wait_i=0
  while [ "$wait_i" -lt 40 ] && [ ! -d "$d/data/auto-dispatch/.check.lock" ]; do sleep 0.1; wait_i=$((wait_i + 1)); done
  [ -d "$d/data/auto-dispatch/.check.lock" ] || { touch "$d/log/release"; kill "$holder_pid" 2>/dev/null || true; fail "T4: running pass never took lock"; }

  # Start the REAL watcher while the pass is running; BOTH fast checks and slow sweep checks are due.
  env HOME="$d/home" XDG_CONFIG_HOME="$d/home/config" TMPDIR="$d/tmp" PATH="$d/fakebin:$PATH" \
    JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" JG_CONFIG_OVERRIDE="$d/config" \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 JG_STALE_ESCALATE_SECS=999999 \
    JG_CHECK_INTERVAL=1 JG_FAST_CHECK_INTERVAL=1 JG_DISPATCH_INTERVAL=1 \
    "$farm/bin/jg-watch.sh" > "$d/out" 2> "$d/err" &
  wpid=$!

  wait_i=0
  while [ "$wait_i" -lt 60 ]; do
    if [ "$(lines_of "$d/log/z-cadence")" -ge 2 ] && [ "$(lines_of "$d/log/board")" -ge 2 ]; then break; fi
    sleep 0.2
    wait_i=$((wait_i + 1))
  done
  local still_locked=0
  [ -d "$d/data/auto-dispatch/.check.lock" ] && still_locked=1

  touch "$d/log/release"
  kill "$wpid" 2>/dev/null || true
  wait_for_exit "$wpid" 50 >/dev/null 2>&1 || true
  wait "$holder_pid" 2>/dev/null || true

  [ "$(lines_of "$d/log/z-cadence")" -ge 2 ] || fail "T4: slow-sweep check z-cadence stalled while dispatch ran (runs=$(lines_of "$d/log/z-cadence"))"
  [ "$(lines_of "$d/log/board")" -ge 2 ] || fail "T4: fast check board-answers stalled while dispatch ran (runs=$(lines_of "$d/log/board"))"
  assert_equals 1 "$still_locked" "T4: both checks ticked multiple times while the dispatch pass still held its lock"
  pass "T4: a running auto-dispatch pass does not stall fast checks or slow-sweep checks"
}

# ---- T5: Pool cap (max_trees) follows the lane limit automatically ----
t5_pool_max_trees_follows_lane_limit() {
  local t5dir="$TMP_ROOT/t5" main lead origin mclone lclone
  main="$t5dir/main"; lead="$t5dir/lead"; origin="$t5dir/origin.git"
  mkdir -p "$main/state" "$main/config" "$main/projects" "$lead/state" "$lead/config" "$lead/projects"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$main" > "$lead/.jg-squad-lead-parent"
  git init -q --bare "$origin" || fail "T5: origin init"
  git clone -q "$origin" "$t5dir/seed" 2>/dev/null || fail "T5: seed clone"
  git -C "$t5dir/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed || fail "T5: seed commit"
  git -C "$t5dir/seed" push -q origin HEAD 2>/dev/null || fail "T5: seed push"
  git init -q "$lead" || fail "T5: lead git init"
  mclone="$main/projects/juggernaut"; lclone="$lead/projects/juggernaut"
  git clone -q "$origin" "$mclone" 2>/dev/null || fail "T5: main clone"
  git clone -q "$origin" "$lclone" 2>/dev/null || fail "T5: lead clone"

  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"

  # 1. Main home with lane-target=60 -> copy cap 62 -> writes max_trees = 62 and excludes /treehouse.toml.
  printf '60\n' > "$main/config/lane-target"
  JG_HOME="$main" JG_WORKER_POOL_DIR="$t5dir/pools" jg_treehouse_clone_pool_prepare "$mclone" || fail "T5: main prepare"
  assert_grep 'max_trees = 62' "$mclone/treehouse.toml" "T5: main treehouse.toml carries max_trees = 62"
  assert_equals "" "$(git -C "$mclone" status --short)" "T5: main clone git status stays clean"

  # 2. Squad Lead home with lane-target=60 -> writes BOTH max_trees = 62 and root = "...".
  printf '60\n' > "$lead/config/lane-target"
  JG_HOME="$lead" JG_WORKER_POOL_DIR="$t5dir/pools" jg_treehouse_clone_pool_prepare "$lclone" || fail "T5: lead prepare"
  assert_grep 'max_trees = 62' "$lclone/treehouse.toml" "T5: lead treehouse.toml carries max_trees = 62"
  assert_grep 'root = "' "$lclone/treehouse.toml" "T5: lead treehouse.toml keeps its isolated pool root"
  assert_equals "" "$(git -C "$lclone" status --short)" "T5: lead clone git status stays clean"

  # 3. A higher hand-set max_trees (100) stays untouched when lane-target is 60 (cap 62).
  printf 'max_trees = 100\nroot = "%s/pools/custom"\n\n[hooks]\npost_create = "true"\n' "$t5dir" > "$mclone/treehouse.toml"
  JG_HOME="$main" JG_WORKER_POOL_DIR="$t5dir/pools" jg_treehouse_clone_pool_prepare "$mclone" || fail "T5: higher cap prepare"
  assert_grep 'max_trees = 100' "$mclone/treehouse.toml" "T5: higher hand-set max_trees stays untouched"

  # 4. Raising lane-target above current max_trees updates max_trees in-place and preserves other lines/sections.
  printf '120\n' > "$main/config/lane-target"
  JG_HOME="$main" JG_WORKER_POOL_DIR="$t5dir/pools" jg_treehouse_clone_pool_prepare "$mclone" || fail "T5: raised cap prepare"
  assert_grep 'max_trees = 122' "$mclone/treehouse.toml" "T5: raised lane-target updates max_trees to 122"
  assert_grep '[hooks]' "$mclone/treehouse.toml" "T5: existing TOML sections are preserved"

  # 5. Real treehouse CLI accepts the generated treehouse.toml when installed.
  if command -v treehouse >/dev/null 2>&1; then
    (cd "$lclone" && HOME="$t5dir/th-home" TREEHOUSE_NO_UPDATE_CHECK=1 treehouse status >/dev/null 2>&1) \
      || fail "T5: real treehouse status rejected generated treehouse.toml"
  fi
  pass "T5: jg_treehouse_clone_pool_prepare syncs max_trees to the home's copy cap cleanly for Main and Squad Lead"
}

t1_batch_matches_per_row_parity
t2_138_row_pass_single_read_and_fast
t3_ready_stall_single_batched_read
t4_running_pass_does_not_stall_check_cadence
t5_pool_max_trees_follows_lane_limit
