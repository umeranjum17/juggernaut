#!/usr/bin/env bash
# Exercise worker starts and completion through the real workflow and scratch backlog.
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
cat > "$TMP/hold.sh" <<'SH'
#!/bin/sh
# hold <row> --reason <why> | phase <row>: the owner's hold, answered when $JG_HOME/standin/<row>.yes exists.
case $1 in
  hold) echo "$2" >> "$JG_HOME/standin/holds" ;;
  phase) if [ -e "$JG_HOME/standin/$2.yes" ]; then echo answered; else echo raised; fi ;;
esac
SH
chmod +x "$TMP"/*.sh

home() { # <name> <spec>: a scratch home with ticket jg-t1 carrying the workflow
  local h=$TMP/$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state" "$h/standin"
  printf '#!/bin/sh\necho kicked >> "%s/kicks"\n' "$h" > "$h/state/auto-dispatch.check.sh"
  chmod +x "$h/state/auto-dispatch.check.sh"
  jg_test_add "$h" jg-t1 "[feature] Faster sign in" --body "Owner order: Main1. Make sign in take one tap."
  JG_HOME=$h "$WF" set jg-t1 "$2" --by main --order Main1 > /dev/null || fail "could not set $2 on jg-t1"
  printf '%s\n' "$h"
}
adv() { # <home> [mode script]: one pass of the real advance, then wait for its start jobs to end
  local h=$1 mode=${2:-$TMP/mode.sh} i
  JG_HOME=$h JG_WORKFLOW_PROJECT_MODE=$mode JG_WORKFLOW_HOLD=$TMP/hold.sh JG_WORKFLOW_ALERT=$TMP/alert.sh timeout 30 "$WF" advance "$h" > /dev/null 2> "$TMP/err"
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

H=$(home worker 'worker > worker')
R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2); T=$(task "$R1")
adv "$H"
assert_present "$H/data/$T/brief.md" 'first brief exists'
assert_equals "../$T/brief.md" "$(readlink "$H/data/$R1/brief.md")" 'row links to brief'
assert_contains "$(cat "$H/data/$T/brief.md")" 'Faster sign in' 'brief has title'
assert_contains "$(cat "$H/data/$T/brief.md")" 'mode=local' 'brief has delivery mode'
assert_present "$H/state/dispatch-approved/$R1" 'first approval exists'
assert_equals claude-sonnet-5-5 "$(route "$H/state/dispatch-approved/$R1" model)" 'default worker route'
assert_absent "$H/state/dispatch-approved/$R2" 'second waits'
printf '%s\tproject\tcommit\t1\n' "$T" > "$H/data/trunk-landings.tsv"
adv "$H"
assert_equals closed "$(status "$H" "$R1")" 'landing closes first'
assert_present "$H/state/dispatch-approved/$R2" 'landing starts second'
pass 'worker landing advances'

for answer in open merged; do
 H=$(home "pr-$answer" 'worker > worker')
 R1=$(rowid "$H" jg-t1 1); T=$(task "$R1")
 adv "$H"
 printf 'pr=https://example.invalid/pr/1\n' > "$H/state/$T.meta"
 printf 'done [at=1]: ready\n' > "$H/state/$T.status"
 export JG_WORKFLOW_PR_MERGED=$answer
 adv "$H"
 sleep 0.3
 adv "$H"
 if [ "$answer" = merged ]; then expected=closed; else expected=open; fi
 assert_equals "$expected" "$(status "$H" "$R1")" "PR $answer"
done
unset JG_WORKFLOW_PR_MERGED
pass 'PR state controls completion'
H=$(home failure 'worker > worker')
R1=$(rowid "$H" jg-t1 1); T=$(task "$R1")
adv "$H"
printf 'kind=worker\n' > "$H/state/$T.meta"
printf 'failed [at=1]: failure\n' > "$H/state/$T.status"
: > "$TMP/alerts.log"
adv "$H"
adv "$H"
assert_equals open "$(status "$H" "$R1")" 'failure stays open'
assert_equals 1 "$(alerts)" 'one alert'
H=$(home route 'worker > worker')
printf 'worker claude claude-opus-5-5 high\n' > "$H/config/workflow-routes"
R1=$(rowid "$H" jg-t1 1)
adv "$H"
assert_equals claude-opus-5-5 "$(route "$H/state/dispatch-approved/$R1" model)" 'custom route'
pass 'failure and route'
# The closest report stage, not all previous Recon stages, supplies a build's reports.
H=$(home reports 'recon(standard) > critic > owner > worker')
R1=$(rowid "$H" jg-t1 1); R2=$(rowid "$H" jg-t1 2)
R3=$(rowid "$H" jg-t1 3); R4=$(rowid "$H" jg-t1 4)
for row in "$R1" "$R2" "$R3"; do
 JG_HOME=$H "$ROOT/bin/jg-backlog.sh" "done" "$row" --note 'fixture complete' >/dev/null || fail 'close prerequisite'
done
adv "$H"
brief=$(cat "$H/data/$(task "$R4")/brief.md")
assert_contains "$brief" "data/$(task "$R2")/report.md" 'nearest critic report'
assert_not_contains "$brief" "data/$(task "$R1")/report.md" 'older Recon omitted'
pass 'nearest report stage'
