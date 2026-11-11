#!/usr/bin/env bash
# tests/jg-watch-large-check-output.test.sh - a check that prints megabytes (or whose
# capture fails) neither ends the watcher nor reaches an argv unbounded.
# Runs the REAL watcher on a throwaway home with real registered custom checks, then
# the real ready-work reader over a backlog listing far larger than one argv value.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(jg_test_tmproot jg-large-check)
WATCH="$ROOT/bin/jg-watch.sh"
BIG_BYTES=3000000

new_home() {  # <name> -> case dir with a throwaway home
  local d
  d=$(make_case "$1")
  mkdir -p "$d/home/config" "$d/tmp" "$d/config"
  printf '%s\n' "$d"
}

add_check() {  # <dir> <id> <body>: write and bind a custom check
  local d=$1 id=$2
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$d/state/$id.check.sh"
  chmod 700 "$d/state/$id.check.sh"
  env JG_HOME="$d" JG_STATE_OVERRIDE="$d/state" "$ROOT/bin/jg-check-register.sh" "$id" > /dev/null \
    || fail "could not register the $id check"
}

start_watch() {  # <dir> -> sets WPID
  env HOME="$1/home" XDG_CONFIG_HOME="$1/home/config" TMPDIR="$1/tmp" PATH="$1/fakebin:$PATH" \
    JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_CONFIG_OVERRIDE="$1/config" \
    JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=1 JG_POLL=1 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_STALE_ESCALATE_SECS=999999 \
    "$WATCH" > "$1/out" 2> "$1/err" &
  WPID=$!
}

stop_watch() {
  kill "$WPID" 2>/dev/null || true
  wait_for_exit "$WPID" 100 >/dev/null 2>&1 || true
}

wait_for() {  # <limit> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt $((limit * 5)) ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

test_a_huge_check_result_wakes_with_a_short_reason_and_the_watcher_lives() {
  local d row
  d=$(new_home huge)
  add_check "$d" bigcheck "head -c $BIG_BYTES /dev/zero | tr '\\0' 'x'; echo"
  add_check "$d" tinycheck "echo tiny-check-result"
  start_watch "$d"
  wait_for 40 grep -qs 'tiny-check-result' "$d/state/.wake-queue" \
    || { stop_watch; fail "the short check never woke after the huge one: $(cat "$d/err")"; }
  wait_for 20 grep -qs 'bigcheck' "$d/state/.wake-queue" \
    || { stop_watch; fail "the huge check raised no wake: $(cat "$d/err")"; }
  kill -0 "$WPID" 2>/dev/null || fail "the watcher ended after a huge check result: $(cat "$d/err")"
  stop_watch
  row=$(grep 'bigcheck' "$d/state/.wake-queue" | head -n 1)
  [ "${#row}" -lt 8192 ] || fail "the wake row for the huge check is ${#row} bytes"
  grep -q 'full output: ' <<<"$row" || fail "the wake row does not name the full output file: $row"
  [ "$(wc -c < "$d/state/.jg-check-output-bigcheck")" -ge "$BIG_BYTES" ] \
    || fail "the full output was not kept in a file"
  pass "a ${BIG_BYTES}-byte check result wakes with a bounded reason naming the full output; the watcher and the next check carry on"
}

test_a_failed_capture_is_a_logged_skip_not_a_watcher_exit() {
  local d
  d=$(new_home skip)
  add_check "$d" okcheck "echo ok-check-result"
  # A 235-character id fits as a check name but not as a capture-file name, so its capture cannot start.
  add_check "$d" "$(printf 'a%.0s' $(seq 235))" "echo never-captured"
  start_watch "$d"
  wait_for 40 grep -qs 'ok-check-result' "$d/state/.wake-queue" \
    || { stop_watch; fail "the watcher stopped serving checks after one capture failed: $(cat "$d/err")"; }
  kill -0 "$WPID" 2>/dev/null || fail "the watcher ended when one check capture failed"
  stop_watch
  grep -q 'watcher check skipped' "$d/state/.watch-triage.log" 2>/dev/null \
    || fail "the skipped check was not logged"
  pass "a check whose capture fails is logged and skipped; the watcher keeps running"
}

test_the_ready_work_reader_takes_a_huge_backlog_listing() {
  local d out
  d=$(new_home ready)
  mkdir -p "$d/bin"
  cp "$ROOT/bin/jg-supervision-lib.sh" "$d/bin/"
  cat > "$d/bin/jg-backlog.sh" <<SH
#!/usr/bin/env bash
case "\$1" in
  ready) printf 'ready[1]{id,title,priority,repo}:\n  t-1,"x",1,"r"\n' ;;
  list) printf 'tasks[1]{id,priority}:\n'; head -c $BIG_BYTES /dev/zero | tr '\\0' ' ' | sed 's/^/  /'; printf '\n  t-1,1\n' ;;
esac
SH
  chmod +x "$d/bin/jg-backlog.sh"
  out=$(bash -c '. "$1/bin/jg-supervision-lib.sh"; jg_ready_work_rows "$1"' _ "$d" 2>&1) \
    || fail "the ready-work reader failed on a $BIG_BYTES-byte listing: $out"
  [ "$out" = "t-1 r" ] || fail "the ready-work reader printed '$out', not 't-1 r'"
  pass "the ready-work reader reads a $BIG_BYTES-byte priority listing without an argument-list error"
}

test_a_huge_check_result_wakes_with_a_short_reason_and_the_watcher_lives
test_a_failed_capture_is_a_logged_skip_not_a_watcher_exit
test_the_ready_work_reader_takes_a_huge_backlog_listing
