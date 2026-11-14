#!/usr/bin/env bash
# Journey: a follow-up the captain stated ahead runs when the Recon's report lands.
# Real bin/jg-backlog.sh (on-report, add --parent, approve-dispatch) over a real Beads store, real bin/jg-inbox.sh
# for his chat note, real bin/jg-recon-gate.sh and the real core/recon-ready/ready.sh check; only the captain-hold
# read is a stand-in, so a held call can be switched on and off.
# T1 a ticket with `on-report: triage-build claude sonnet medium` and his words as owner-words: the report lands, one
#    slice is filed under the ticket (born-from: recon, parent: the ticket) and approved for dispatch on that route;
#    a rerun files nothing more.
# T2 the same line typed with no record of his yes: nothing is filed, and `on-report` exits 3 naming why.
# T3 a ticket with the record that an open call blocks stays held: nothing is filed until the call clears.
# T4 a report that lists an open decision starts nothing.
# T5 a malformed line is refused with exit 2 and nothing is filed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/on-report.log")

if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  printf '%s\n' '{"target":{"version":"juggernaut"},"start":"a Recon ticket that states on-report: triage-build claude sonnet medium on the owner'"'"'s chat words, and a finished report","steps":["the report lands and the recon-ready check runs","the check reads the on-report line through jg-backlog.sh on-report","the check files the first slice under the ticket and approves it for dispatch","a rerun, a line with no record of his yes, a held ticket, an open decision and a malformed line each file nothing"],"result":"one slice filed under the ticket and approved on the stated route; every other case files nothing"}' > "$DONE_DONE_EVIDENCE_ROOT/steps.json"
fi
TMP_ROOT=$(jg_test_tmproot jg-on-report)
H=$TMP_ROOT/home
mkdir -p "$H/state" "$H/data" "$H/config" "$H/bin"
jg_test_beads_home "$H"
export JG_TASK_PRIORITY_CHECK=/nonexistent
export JG_RECON_READY_GATE=$ROOT/bin/jg-recon-gate.sh JG_RECON_READY_BACKLOG=$ROOT/bin/jg-backlog.sh

tasks() { jg_test_backlog "$H" "$@"; }
inbox() { JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config "$ROOT/bin/jg-inbox.sh" "$@" 2>&1; }
check() { JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data "$ROOT/core/recon-ready/ready.sh" check "$H"; }
# The hold stand-in blocks the tickets named in $H/blocked and no others.
# shellcheck disable=SC2016  # the stand-in expands its own argument when run
printf '#!/usr/bin/env bash\ngrep -qx "$2" "%s/blocked" 2>/dev/null\n' "$H" > "$H/bin/hold"
chmod +x "$H/bin/hold"
export JG_RECON_READY_HOLD=$H/bin/hold

REPORT='## 1. Answer

Use one queue for all alerts.

## 8. Implementation plan

| Slice | Outcome | Proof | Size | Risk | Depends |
|---|---|---|---|---|---|
| Queue table | one table | test | S | low | none |
| Alert wiring | alerts read it | test | S | low | 1 |

## 10. Open decisions

'
chat=$(inbox note $'[chat telegram 42:9]\nWhen it lands, triage and build on Sonnet.')
note=$(printf '%s\n' "$chat" | grep -oE '[0-9]{6,}-[A-Za-z0-9]+' | head -1)
[ -n "$note" ] || fail "could not file his chat note: $chat"

# recon <id> <on-report line> <owner-words or none> [open decision row]: a Recon ticket whose report has landed.
recon() {
  local id=$1 body out
  body=$(printf 'A Recon with a stated follow-up.\n%s' "$2")
  [ "$3" = none ] || body=$(printf '%s\nowner-words: note:%s "%s"' "$body" "$note" "$3")
  out=$(tasks add "$id" "[captain-ask] $id" --priority 0 --kind scout --repo proj --body "$body" 2>&1) || fail "could not add $id: $out"
  printf 'kind=scout\nticket=%s\n' "$id" > "$H/state/$id.meta"
  printf 'done [at=1]: report ready\n' > "$H/state/$id.status"
  mkdir -p "$H/data/$id"
  printf 'Recon depth: quick\n' > "$H/data/$id/brief.md"
  { printf '%s' "$REPORT"; [ -z "${4:-}" ] || printf '| %s | yes, no |\n' "$4"; } > "$H/data/$id/report.md"
}
slices_of() { tasks list 2>/dev/null | grep -o "$1\.[0-9]*" | sort -u; }

# T1
recon jg-or1 'on-report: triage-build claude sonnet medium' "triage and build on Sonnet"
out=$(check)
assert_contains "$out" "recon-ready: jg-or1 report is ready" "T1 the report is announced"
assert_contains "$out" "on-report: jg-or1 follow-up ran: slice jg-or1.1 filed and approved for dispatch on claude sonnet medium" "T1 the follow-up ran"
slice_show=$(tasks show jg-or1.1 --full 2>&1)
assert_contains "$slice_show" "Queue table" "T1 the slice is the report's first row"
assert_contains "$slice_show" "born-from: recon" "T1 the slice is born from the Recon"
assert_contains "$slice_show" "jg-or1" "T1 the slice names its parent"
rec=$(cat "$H/state/dispatch-approved/jg-or1.1" 2>/dev/null)
assert_contains "$rec" "harness=claude" "T1 the approval holds the stated harness"
assert_contains "$rec" "model=sonnet" "T1 the approval holds the stated model"
assert_equals "$(check)" "" "T1 a rerun prints nothing"
assert_equals "$(slices_of jg-or1)" "jg-or1.1" "T1 a rerun files no second slice"
pass "T1 the stated follow-up files and approves the first slice once"

# T2
recon jg-or2 'on-report: triage-build claude sonnet medium' none
tasks on-report jg-or2 >"$TMP_ROOT/o2.out" 2>&1; rc=$?
assert_equals "$rc" 3 "T2 on-report refuses a line with no record"
assert_contains "$(cat "$TMP_ROOT/o2.out")" "no record of the captain's yes" "T2 the refusal names why"
out=$(check)
assert_contains "$out" "recon-ready: jg-or2" "T2 the report is still announced"
assert_equals "$(slices_of jg-or2)" "" "T2 nothing is filed"
assert_absent "$H/state/dispatch-approved/jg-or2.1" "T2 nothing is approved"
pass "T2 a typed on-report line with no record of his yes is not run"

# T3
recon jg-or3 'on-report: triage-build claude sonnet medium' "triage and build on Sonnet"
echo jg-or3 > "$H/blocked"
out=$(check)
assert_not_contains "$out" "follow-up ran" "T3 a held call stays held"
assert_equals "$(slices_of jg-or3)" "" "T3 nothing is filed while the call is open"
: > "$H/blocked"
out=$(check)
assert_contains "$out" "on-report: jg-or3 follow-up ran" "T3 the follow-up runs once the call clears"
pass "T3 an open call holds the follow-up until it clears"

# T4
recon jg-or4 'on-report: triage-build claude sonnet medium' "triage and build on Sonnet" "Keep the old queue?"
out=$(check)
assert_not_contains "$out" "follow-up ran" "T4 a report with an open decision starts nothing"
assert_equals "$(slices_of jg-or4)" "" "T4 nothing is filed"
pass "T4 an open decision in the report holds the follow-up"

# T5
recon jg-or5 'on-report: triage and build on Sonnet' "triage and build on Sonnet"
tasks on-report jg-or5 >"$TMP_ROOT/o5.out" 2>&1; rc=$?
assert_equals "$rc" 2 "T5 a malformed line exits 2"
assert_not_contains "$(check)" "follow-up ran" "T5 a malformed line runs nothing"
assert_equals "$(slices_of jg-or5)" "" "T5 nothing is filed"
pass "T5 a malformed on-report line is refused"
