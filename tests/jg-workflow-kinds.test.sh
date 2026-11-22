#!/usr/bin/env bash
# jg-workflow-kinds: an approved workflow always has a runnable first step. The real bin/jg-workflow.sh advance, the real shipped step
# kinds (worker, recon, owner), the real bin/jg-brief.sh and the real approve-dispatch run over a scratch home. K3 uses a
# stand-in board and also checks the legacy hold phase against the real workflow. The project registry and alerts are stand-ins.
#
# K1 a plain ship: one pass writes a complete brief (no placeholder, the ticket's words, no scout contract) and an approval on the
#    worker route; the dispatch check is kicked; a second pass writes and starts nothing more.
# K2 a report-only Recon: its brief carries the Recon contract and the Recon route; with a report, a `done` line and the gate's record
#    the next pass closes the step, and no build starts.
# K3 Recon to build: an answered hold phase alone leaves the worker unstarted. A board yes with a verified row signature
#    closes the owner step, and the worker's brief names the Recon's report.
# K4 a critic with its handler absent is one named alert, and a second pass raises no second one.
# K5 an unreadable prerequisite (an unregistered delivery mode) is one named failure and no approval is written.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-kinds-test.XXXXXX") || exit 1
JOBS=$TMP/jobs
: > "$JOBS"
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
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")
printf '#!/bin/sh\necho "local off"\n' > "$TMP/mode.sh"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nomode.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$TMP" > "$TMP/alert.sh"
chmod +x "$TMP"/*.sh

home() { # <name> <spec>: a scratch home with ticket jg-t1 carrying the workflow
  local h=$TMP/$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state"
  printf '#!/bin/sh\necho kicked >> "%s/kicks"\n' "$h" > "$h/state/auto-dispatch.check.sh"
  chmod +x "$h/state/auto-dispatch.check.sh"
  jg_test_add "$h" jg-t1 "[feature] Faster sign in" --body "Owner order: Main42707. Make sign in take one tap."
  JG_HOME=$h "$WF" set jg-t1 "$2" --by main > /dev/null || fail "could not set $2 on jg-t1"
  printf '%s\n' "$h"
}
adv() { # <home> [mode script]: one pass of the real advance, then wait for its start jobs to end
  local h=$1 mode=${2:-$TMP/mode.sh} i
  res=$(JG_HOME=$h JG_WORKFLOW_PROJECT_MODE=$mode JG_WORKFLOW_ALERT=$TMP/alert.sh timeout 30 "$WF" advance "$h" 2> "$TMP/err")
  err=$(cat "$TMP/err")
  cat "$h"/data/workflows/*.step-start.pid 2> /dev/null >> "$JOBS"
  for ((i = 0; i < 100; i++)); do
    ls "$h"/data/workflows/*.started > /dev/null 2>&1 || break
    local pending=0 f
    for f in "$h"/data/workflows/*.started; do [ -e "${f%.started}.start.rc" ] || pending=1; done
    [ "$pending" = 0 ] && break
    sleep 0.1
  done
}
rowid() { JG_HOME=$1 "${BD[@]}" list --parent "$2" --all --limit 0 --json | jq -r --arg i "$3" '.[] | select(.metadata.wf_stage == $i) | .id'; }
status() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r '.[0].status'; }
task() { printf '%s\n' "${1//./-}"; }
alerts() { { cat "$TMP/alerts.log" 2> /dev/null || true; } | wc -l | tr -d ' '; }
lane_done() { # <home> <row>: a Recon lane that reported: lane record, report, done line, the gate's record
  local h=$1 t; t=$(task "$2")
  printf 'kind=scout\n' > "$h/state/$t.meta"
  printf 'done [at=1]: report ready\n' > "$h/state/$t.status"
  mkdir -p "$h/data/$t" "$h/state/recon-ready"
  printf '## 1. Answer\nit works\n' > "$h/data/$t/report.md"
  printf 'sha\n' > "$h/state/recon-ready/$t"
}
route() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

# K1
H=$(home k1 worker)
R=$(rowid "$H" jg-t1 1); T=$(task "$R")
adv "$H"
assert_equals "started $R (worker)" "$res" "K1 the first step starts: $err"
BRIEF=$H/data/$T/brief.md
assert_present "$BRIEF" "K1 the brief is written"
assert_not_contains "$(cat "$BRIEF")" "{TASK}" "K1 no task placeholder is left"
assert_not_contains "$(cat "$BRIEF")" "{JUGGERNAUT_SPEC}" "K1 no spec placeholder is left"
assert_contains "$(cat "$BRIEF")" "Make sign in take one tap." "K1 the brief carries the ticket's words"
assert_contains "$(cat "$BRIEF")" "Build exactly what the ticket above asks" "K1 the brief says what to build"
assert_present "$H/state/dispatch-approved/$R" "K1 the start is approved"
assert_equals "claude-sonnet-5-5" "$(route "$H/state/dispatch-approved/$R" model)" "K1 the approval is on the worker route"
assert_present "$H/kicks" "K1 the dispatch check was kicked"
adv "$H"
assert_equals "" "$res" "K1 a second pass starts nothing"
assert_equals 0 "$(alerts)" "K1 no alert"
pass "K1 a plain ship has a complete brief and an approval, once"

# K2
H=$(home k2 scout)
R=$(rowid "$H" jg-t1 1); T=$(task "$R")
adv "$H"
assert_equals "started $R (recon)" "$res" "K2 the Recon starts: $err"
assert_contains "$(cat "$H/data/$T/brief.md")" "report" "K2 the brief carries the Recon contract"
assert_not_contains "$(cat "$H/data/$T/brief.md")" "{JUGGERNAUT_SPEC}" "K2 no placeholder is left"
assert_equals "claude-sonnet-5-5" "$(route "$H/state/dispatch-approved/$R" model)" "K2 a quick Recon reads the quick route"
adv "$H"
assert_equals "" "$res" "K2 with no report the step stays open"
lane_done "$H" "$R"
adv "$H"
assert_contains "$res" "closed $R (recon): the report passed the Recon gate" "K2 the report closes the step"
assert_equals closed "$(status "$H" "$R")" "K2 the row is closed"
assert_equals 0 "$(alerts)" "K2 no alert"
pass "K2 a report-only Recon closes on its report and builds nothing"

# K3
mkdir -p "$TMP/k3-bin"
cat > "$TMP/k3-bin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case $1 in
  list) printf '{"decisions":[]}\n' ;;
  raise)
    shift
    while [ "$#" -gt 1 ]; do
      if [ "$1" = --key ]; then printf '%s\n' "$2" > "$SIGN_OFF_HOME/posted"; exit 0; fi
      shift
    done
    exit 1 ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$TMP/k3-bin/sign-off-axi"
k3_advance() {
  PATH="$TMP/k3-bin:$PATH" SIGN_OFF_HOME="$H/board" adv "$H"
}
hold=$ROOT/bin/jg-captain-hold.sh
k3_setup() {
  H=$(home "$1" scout-worker)
  R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2); R3=$(rowid "$H" jg-t1 3)
  mkdir -p "$H/board"
  k3_advance
  lane_done "$H" "$R1"
  k3_advance
  assert_contains "$res" "started $R2 (owner)" "K3 the owner step starts after the report: $err"
  JG_HOME=$H "$hold" open "$R2" --identity >/dev/null || fail "K3 his yes is asked for on the owner row"
}
k3_setup k3-phase
gate=$(JG_HOME=$H "$ROOT/bin/jg-backlog.sh" questions --ticket "$R2" --json | jq -er '.[0].id') \
  || fail "K3 could not find the owner question"
printf 'Fixture marks the question answered without approval.\n' > "$H/words"
JG_HOME=$H "$ROOT/bin/jg-beads-write.py" resolve "$gate" --words-file "$H/words" --resolution answered >/dev/null \
  || fail "K3 could not set the answered phase"
assert_equals answered "$(JG_HOME=$H "$hold" phase "$R2")" "K3 the answered phase fixture is active"
k3_advance
assert_equals open "$(status "$H" "$R2")" "K3 an answered phase alone leaves the owner step open"
assert_absent "$H/state/dispatch-approved/$R3" "K3 an answered phase alone cannot release the worker"

k3_setup k3-board
assert_absent "$H/state/dispatch-approved/$R3" "K3 no build is approved before his yes"
k3_advance
assert_equals "" "$res" "K3 waiting for him starts nothing"
assert_equals open "$(status "$H" "$R3")" "K3 the build row stays open"

key=wf-$(task "$R2")-plan
assert_equals "$key" "$(cat "$H/board/posted")" "K3 the board card belongs to the owner step"
PATH="$TMP/k3-bin:$PATH" SIGN_OFF_HOME="$H/board" JG_HOME=$H \
  "$ROOT/bin/jg-board-answers.sh" route-answer "$key" 1795344000 "a-$(task "${R2#jg-}")" >/dev/null \
  || fail "K3 board yes did not reach the workflow"
( # shellcheck disable=SC2034
  JG_HOME=$H STATE=$H/state DATA=$H/data SCRIPT_DIR=$ROOT/bin
  # shellcheck disable=SC2329
  fail() { echo "$*"; exit 1; }
  # shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
  . "$ROOT/bin/jg-backlog-transition-lib.sh"
  # shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
  . "$ROOT/bin/jg-captain-ask-lib.sh"
  guard_captain_ask_build "$R3"
) || fail "K3 the board yes must verify for this worker's owner row"
k3_advance
assert_contains "$res" "closed $R2 (owner): the owner answered" "K3 his yes closes the owner step"
assert_contains "$res" "started $R3 (worker)" "K3 the build starts in the same pass"
assert_contains "$(cat "$H/data/$(task "$R3")/brief.md")" "data/$(task "$R1")/report.md" "K3 the build brief names the approved report"
assert_present "$H/state/dispatch-approved/$R3" "K3 the build is approved"
assert_equals 0 "$(alerts)" "K3 no alert"
pass "K3 a build after a Recon waits for his yes and then names the report"

# K4
H=$(home k4 deep)
R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2)
mkdir "$TMP/missing-kinds"
ln -sn "$ROOT/core/workflows/kinds/recon.py" "$TMP/missing-kinds/recon.py"
JG_WORKFLOW_KIND_DIR=$TMP/missing-kinds adv "$H"
lane_done "$H" "$R1"
JG_WORKFLOW_KIND_DIR=$TMP/missing-kinds adv "$H"
assert_contains "$res" "failed $R2 (critic): no kind critic" "K4 a kind with no handler is a named failure"
assert_equals 1 "$(alerts)" "K4 one alert"
JG_WORKFLOW_KIND_DIR=$TMP/missing-kinds adv "$H"
assert_equals 1 "$(alerts)" "K4 a second pass raises no second alert"
assert_absent "$H/state/dispatch-approved/$R2" "K4 nothing is approved for it"
pass "K4 a kind with no handler is one named alert"

# K5
H=$(home k5 worker)
R=$(rowid "$H" jg-t1 1)
adv "$H" "$TMP/nomode.sh"
assert_equals 1 "$(alerts)" "K5 an unreadable delivery mode is one alert"
assert_contains "$(cat "$H/data/workflows/$R.start.rc")" "delivery mode" "K5 the record names the cause"
assert_absent "$H/state/dispatch-approved/$R" "K5 no approval is written"
pass "K5 an unreadable prerequisite is one named failure"
