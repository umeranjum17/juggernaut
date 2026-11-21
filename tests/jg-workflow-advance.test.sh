#!/usr/bin/env bash
# jg-workflow-advance: one quick pass closes every finished workflow step and starts every ready one as a detached job, safely when
# it runs twice, is killed, or meets a slow step. Real bin/jg-workflow.sh advance over a scratch home whose backlog is the ticket
# tables; the step kind is a stand-in worker.py under JG_WORKFLOW_KIND_DIR (its start writes a marker after a sleep the test sets,
# its result reads a marker) and the alert command is a stand-in that logs.
#
# T1 one pass starts step 1 only; once its start record says rc 0 and its marker says done, one pass closes it and starts step 2.
# T2 a result of `failed` raises one alert, a second pass raises none, and step 3 never starts.
# T3 the same pass twice with nothing new: the second prints nothing and writes nothing.
# T4 a pass killed with TERM while it holds the lock: the next pass takes the lock at once.
# T5 a second pass while the first holds the lock exits 0 at once, and the first makes one more pass (the mark is gone).
# T6 --dry-run writes no file and closes no row.
# T7 a slow start runs in its own job: the pass ends fast, every ready step has its record or its job, and no alert is raised.
# T8 a start job killed before it writes its record raises one alert on the next pass.
# T9 a result that sleeps past its 2 s budget is logged `slow`, and the pass still closes another ticket's done step.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-advance-test.XXXXXX") || exit 1
JOBS=$TMP/jobs
: > "$JOBS"
# A start job a case left sleeping is a process group this test started: its pid file names the group leader.
reap_jobs() {
  local pid
  while read -r pid; do
    case $pid in '' | *[!0-9]*) continue ;; esac
    kill -9 -- "-$pid" 2>/dev/null
  done < "$JOBS"
  return 0
}
trap 'reap_jobs; rm -rf -- "$TMP"' EXIT
WF=$ROOT/bin/jg-workflow.sh
KINDS=$TMP/kinds
mkdir -p "$KINDS"
cat > "$KINDS/worker.py" <<'PY'
import os
import time


def _file(home, step, name):
    return os.path.join(home, "standin", f"{step['id']}.{name}")


def _read(home, step, name):
    try:
        with open(_file(home, step, name)) as f:
            return f.read().strip()
    except OSError:
        return None


def start(home, step):
    nap = _read(home, step, "start-sleep")
    if nap:
        time.sleep(float(nap))
    with open(_file(home, step, "start-ran"), "w") as f:
        f.write("ran\n")
    return "started", "the stand-in started"


def result(home, step):
    with open(_file(home, step, "result-calls"), "a") as f:
        f.write("call\n")
    nap = _read(home, step, "result-sleep")
    if nap:
        time.sleep(float(nap))
    if _read(home, step, "fail") is not None:
        return "failed", "the stand-in failed"
    if _read(home, step, "done") is not None:
        return "done", "the stand-in marker says done"
    return "open", "no marker"
PY
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$TMP" > "$TMP/alert.sh"
chmod +x "$TMP/alert.sh"

BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")
ticket() { # <home> <id>: a ticket carrying the workflow `worker > worker > worker`
  jg_test_add "$1" "$2" "[feature] Faster sign in" --body "Owner order: Main42707."
  JG_HOME=$1 "$WF" set "$2" "worker > worker > worker" --by main > /dev/null || fail "could not set the workflow on $2"
}
home() { # <name>: a scratch home with ticket jg-t1 and a dispatch check that logs its kicks
  local h=$TMP/$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state" "$h/standin"
  printf '#!/bin/sh\necho kicked >> "%s/kicks"\n' "$h" > "$h/state/auto-dispatch.check.sh"
  chmod +x "$h/state/auto-dispatch.check.sh"
  ticket "$h" jg-t1
  printf '%s\n' "$h"
}
adv() { # <home> [args]: res (stdout), err and rc of one pass, under the dispatch check's own bound
  local h=$1
  shift
  res=$(JG_HOME=$h JG_WORKFLOW_KIND_DIR=$KINDS JG_WORKFLOW_ALERT=$TMP/alert.sh timeout 20 "$WF" advance "$h" "$@" 2> "$TMP/err")
  rc=$?
  err=$(cat "$TMP/err")
  cat "$h"/data/workflows/*.step-start.pid 2> /dev/null >> "$JOBS"
  return 0
}
wait_for() { # <path> [seconds=8]
  local i
  for ((i = 0; i < ${2:-8} * 10; i++)); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}
rowid() { JG_HOME=$1 "${BD[@]}" list --parent "$2" --all --limit 0 --json | jq -r --arg i "$3" '.[] | select(.metadata.wf_stage == $i) | .id'; }
status() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r '.[0].status'; }
W() { printf '%s/data/workflows/%s\n' "$1" "$2"; }
tree() { find "$1" -type f -not -path '*/standin/*' -printf '%p %s %T@\n' | sort; }
alerts() { { cat "$TMP/alerts.log" 2> /dev/null || true; } | wc -l | tr -d ' '; }

# T1
H=$(home t1)
R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2); R3=$(rowid "$H" jg-t1 3)
adv "$H"
expect_code 0 "$rc" "T1 the first pass: $err"
assert_equals "started $R1 (worker)" "$res" "T1 only step 1 starts"
assert_present "$(W "$H" "$R1.started")" "T1 step 1 has its started record"
assert_absent "$(W "$H" "$R2.started")" "T1 step 2 has none"
wait_for "$(W "$H" "$R1.start.rc")" || fail "T1 the start record of step 1 never came"
assert_contains "$(cat "$(W "$H" "$R1.start.rc")")" "0 started" "T1 the start record says rc 0"
wait_for "$H/kicks" || fail "T1 a started step never kicked the dispatch check"
adv "$H"
assert_equals "" "$res" "T1 with the marker not set, the next pass does nothing"
: > "$H/standin/$R1.done"
adv "$H"
expect_code 0 "$rc" "T1 the closing pass: $err"
assert_contains "$res" "closed $R1 (worker): the stand-in marker says done" "T1 step 1 closes"
assert_contains "$res" "started $R2 (worker)" "T1 step 2 starts in the same pass"
assert_equals closed "$(status "$H" "$R1")" "T1 the row of step 1 is closed"
assert_absent "$(W "$H" "$R3.started")" "T1 step 3 waits"
pass "T1 one pass starts step 1 only, then closes it and starts step 2 in the same pass"

# T2
wait_for "$(W "$H" "$R2.start.rc")" || fail "T2 the start record of step 2 never came"
: > "$TMP/alerts.log"
: > "$H/standin/$R2.fail"
adv "$H"
assert_contains "$res" "failed $R2 (worker): the stand-in failed" "T2 the failed result is reported"
assert_equals 1 "$(alerts)" "T2 one alert"
assert_contains "$(cat "$TMP/alerts.log")" "raise workflow-step-failed $R2 --note jg-t1: the stand-in failed" "T2 the alert names the step and the ticket"
adv "$H"
assert_equals "" "$res" "T2 the second pass prints nothing"
assert_equals 1 "$(alerts)" "T2 the second pass raises none"
assert_absent "$(W "$H" "$R3.started")" "T2 step 3 is not started"
assert_equals open "$(status "$H" "$R2")" "T2 the failed step stays open"
pass "T2 a failed result raises one alert and holds the later stage"

# T3
wait_for "$(W "$H" "$R1.kick.rc")" || sleep 1
sleep 0.5
before=$(tree "$H")
adv "$H"
assert_equals "" "$res" "T3 prints nothing"
assert_equals "$before" "$(tree "$H")" "T3 writes nothing"
pass "T3 the same pass twice with nothing new prints and writes nothing"

# T4 and T5 share a home whose step 1 has started and recorded rc 0
H=$(home t4)
R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2)
adv "$H"
wait_for "$(W "$H" "$R1.start.rc")" || fail "T4 the start record never came"
printf '1.5\n' > "$H/standin/$R1.result-sleep"
JG_HOME=$H JG_WORKFLOW_KIND_DIR=$KINDS "$WF" advance "$H" > /dev/null 2>&1 &
pass_pid=$!
sleep 0.6
kill -TERM "$pass_pid"
wait "$pass_pid" 2> /dev/null
rm -f "$H/standin/$R1.result-sleep"
: > "$H/standin/$R1.done"
start=$SECONDS
adv "$H"
assert_contains "$res" "closed $R1 (worker)" "T4 the next pass took the lock and closed the step"
assert_contains "$res" "started $R2 (worker)" "T4 and started the next"
[ $((SECONDS - start)) -lt 4 ] || fail "T4 the next pass waited"
assert_absent "$H/state/.workflow-advance.again" "T4 no second pass was asked for"
pass "T4 a pass killed with TERM leaves the lock free for the next pass"

# T5
wait_for "$(W "$H" "$R2.start.rc")" || fail "T5 the start record of step 2 never came"
printf '1.5\n' > "$H/standin/$R2.result-sleep"
rm -f "$H/standin/$R2.result-calls"
JG_HOME=$H JG_WORKFLOW_KIND_DIR=$KINDS "$WF" advance "$H" > /dev/null 2>&1 &
pass_pid=$!
sleep 0.5
t0=$(date +%s%N)
adv "$H"
elapsed=$((($(date +%s%N) - t0) / 1000000))
expect_code 0 "$rc" "T5 the second pass exits 0: $err"
assert_equals "" "$res" "T5 and prints nothing"
[ "$elapsed" -lt 1000 ] || fail "T5 the second pass took $elapsed ms"
assert_present "$H/state/.workflow-advance.again" "T5 it left the mark"
wait "$pass_pid"
assert_absent "$H/state/.workflow-advance.again" "T5 the first pass took the mark"
assert_equals 2 "$(wc -l < "$H/standin/$R2.result-calls" | tr -d ' ')" "T5 the first pass made one more pass"
pass "T5 a second pass leaves a mark and exits at once; the first makes one more pass"

# T6
H=$(home t6)
R1=$(rowid "$H" jg-t1 1)
adv "$H"
wait_for "$(W "$H" "$R1.start.rc")" || fail "T6 the start record never came"
wait_for "$(W "$H" "$R1.kick.rc")" || sleep 1
sleep 0.5
: > "$H/standin/$R1.done"
before=$(tree "$H")
adv "$H" --dry-run
expect_code 0 "$rc" "T6 the dry run: $err"
assert_contains "$res" "would close $R1 (worker)" "T6 it says what it would close"
assert_equals "$before" "$(tree "$H")" "T6 it writes nothing"
assert_equals open "$(status "$H" "$R1")" "T6 it closes no row"
H=$(home t6b)
before=$(tree "$H")
adv "$H" --dry-run
assert_contains "$res" "would start jg-t1.1 (worker)" "T6 it says what it would start"
assert_equals "$before" "$(tree "$H")" "T6 a dry run starts nothing and creates no folder"
pass "T6 --dry-run writes no file and closes no row"

# T7: step 1 of jg-t1 starts slowly, jg-t2 has a ready step with a fast start
H=$(home t7)
ticket "$H" jg-t2
printf '22\n' > "$H/standin/jg-t1.1.start-sleep"
: > "$TMP/alerts.log"
start=$SECONDS
adv "$H"
expect_code 0 "$rc" "T7 the pass: $err"
[ $((SECONDS - start)) -lt 5 ] || fail "T7 the pass took $((SECONDS - start)) s"
assert_contains "$res" "started jg-t1.1 (worker)" "T7 the slow step starts"
assert_contains "$res" "started jg-t2.1 (worker)" "T7 the fast step starts in the same pass"
assert_present "$(W "$H" jg-t1.1.started)" "T7 the slow step has its started record"
wait_for "$(W "$H" jg-t2.1.start.rc)" 5 || fail "T7 the fast start never wrote its record"
assert_equals 0 "$(alerts)" "T7 no alert"
adv "$H"
assert_equals "" "$res" "T7 the next pass starts nothing again"
assert_absent "$(W "$H" jg-t1.1.start.rc)" "T7 the slow start is still running"
wait_for "$(W "$H" jg-t1.1.start.rc)" 30 || fail "T7 the slow start never wrote its record"
assert_contains "$(cat "$(W "$H" jg-t1.1.start.rc)")" "0 started" "T7 the slow start ends with rc 0"
assert_equals 0 "$(alerts)" "T7 still no alert"
pass "T7 a slow start runs in its own job and never holds the pass"

# T8
H=$(home t8)
R1=$(rowid "$H" jg-t1 1)
printf '30\n' > "$H/standin/$R1.start-sleep"
: > "$TMP/alerts.log"
adv "$H"
job=$(cat "$(W "$H" "$R1.step-start.pid")")
adv "$H"
assert_equals "" "$res" "T8 a running job raises nothing"
kill -9 -- "-$job"
sleep 0.3
adv "$H"
assert_contains "$res" "failed $R1 (worker): the start job ended before it wrote its record" "T8 the dead job is reported"
assert_equals 1 "$(alerts)" "T8 one alert"
adv "$H"
assert_equals 1 "$(alerts)" "T8 the next pass raises none"
assert_equals open "$(status "$H" "$R1")" "T8 the step stays open"
pass "T8 a start job killed before its record raises one alert"

# T9
H=$(home t9)
ticket "$H" jg-t2
adv "$H"
wait_for "$(W "$H" jg-t1.1.start.rc)" || fail "T9 the first start record never came"
wait_for "$(W "$H" jg-t2.1.start.rc)" || fail "T9 the second start record never came"
printf '10\n' > "$H/standin/jg-t1.1.result-sleep"
: > "$H/standin/jg-t2.1.done"
start=$SECONDS
adv "$H"
[ $((SECONDS - start)) -lt 5 ] || fail "T9 the pass took $((SECONDS - start)) s"
assert_contains "$res" "slow jg-t1.1 (worker)" "T9 the slow result is logged"
assert_contains "$res" "closed jg-t2.1 (worker)" "T9 the other ticket's done step closes"
assert_equals open "$(status "$H" jg-t1.1)" "T9 the slow step stays open"
pass "T9 a slow result costs the pass 2 s and stops nothing else"
