#!/usr/bin/env bash
# The throughput measurement: where the hours between a done line and a merge go,
# measured from fixtures whose every timestamp this test chooses, so each stage's
# number is known before the tool runs. It proves the phases, the attribution and
# the ranking, and that a stage below the configured threshold is measured but not
# ranked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/jg-throughput.sh"
TMP=$(jg_test_tmproot jg-throughput)
IN=$TMP/inputs
STATE_DIR=$TMP/state
CONFIG_DIR=$TMP/config
T0=1793500000
mkdir -p "$IN" "$STATE_DIR" "$CONFIG_DIR"
# One day and a two-hour floor: the shipped seven days would put every fixture
# stage under a rounding error, and this case is about the ranking, not the sizes.
jq '. + {"window-days": 1, "min-hours-per-day": 2}' \
  "$ROOT/defaults/throughput.json" >"$CONFIG_DIR/throughput.json"

run() {
  JG_HOME="$TMP" JG_STATE_OVERRIDE="$STATE_DIR" JG_CONFIG_OVERRIDE="$CONFIG_DIR" \
    JG_DATA_OVERRIDE="$TMP/data" JG_THROUGHPUT_NOW="$T0" "$TOOL" "$@"
}

# --- fixtures ---------------------------------------------------------------
# Three merged pull requests in one seven-day window, each with a known timeline:
#   pr-1  done -> final commit  1 h  -> green 2 h -> merged 1 h
#         (two jobs, each queued 10 min and running 30 min and 110 min)
#   pr-2  done -> final commit  0    -> green 3 h -> merged 0.5 h (queue 1 h, run 2 h)
#   pr-3  no run recorded at all, so nothing is green: the whole wait is handoff
merged=$(( T0 - 86400 ))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

cat >"$IN/prs.json" <<EOF
[
  {"repo": "o/r", "number": 1, "url": "https://github.com/o/r/pull/1", "mergedAt": "$(iso $merged)",
   "commits": [{"oid": "sha1", "committedDate": "$(iso $(( merged - 3 * 3600 )))"}]},
  {"repo": "o/r", "number": 2, "url": "https://github.com/o/r/pull/2", "mergedAt": "$(iso $(( merged + 60 )))",
   "commits": [{"oid": "sha2", "committedDate": "$(iso $(( merged + 60 - 10800 )))"}]},
  {"repo": "o/r", "number": 3, "url": "https://github.com/o/r/pull/3", "mergedAt": "$(iso $(( merged + 120 )))",
   "commits": [{"oid": "sha3", "committedDate": "$(iso $(( merged + 120 - 7200 )))"}]}
]
EOF

cat >"$IN/runs.json" <<EOF
[
  {"repo": "o/r", "id": 11, "head_sha": "sha1", "conclusion": "success"},
  {"repo": "o/r", "id": 12, "head_sha": "sha2", "conclusion": "success"}
]
EOF

# pr-1's final CI: two jobs, each queued 10 min; their runtimes are 30 and 110 min.
# pr-2's final CI: two jobs, each queued 1 h and running 110 min.
cat >"$IN/jobs.json" <<EOF
[
  {"repo": "o/r", "id": 11, "jobs": [
    {"created_at": "$(iso $(( merged - 3 * 3600 )))", "started_at": "$(iso $(( merged - 3 * 3600 + 600 )))",
     "completed_at": "$(iso $(( merged - 3 * 3600 + 2400 )))"},
    {"created_at": "$(iso $(( merged - 3 * 3600 )))", "started_at": "$(iso $(( merged - 3 * 3600 + 600 )))",
     "completed_at": "$(iso $(( merged - 1 * 3600 )))"}]},
  {"repo": "o/r", "id": 12, "jobs": [
    {"created_at": "$(iso $(( merged + 60 - 10800 )))", "started_at": "$(iso $(( merged + 60 - 7200 )))",
     "completed_at": "$(iso $(( merged + 60 - 600 )))"},
    {"created_at": "$(iso $(( merged + 60 - 10800 )))", "started_at": "$(iso $(( merged + 60 - 7200 )))",
     "completed_at": "$(iso $(( merged + 60 - 600 )))"}]}
]
EOF

# The ledger carries each done line and the merge, the way a home with the ledger
# on writes them.
cat >"$IN/ledger.jsonl" <<EOF
{"v": 1, "ts": $(( merged - 6 * 3600 )), "event": "task.pr_ready", "task": "one", "pr": "https://github.com/o/r/pull/1"}
{"v": 1, "ts": $(( merged - 5 * 3600 )), "event": "task.status", "task": "one", "pr": "https://github.com/o/r/pull/1", "state": "working", "text": "working [at=$(( merged - 5 * 3600 ))]: implementing"}
{"v": 1, "ts": $(( merged - 4 * 3600 )), "event": "task.status", "task": "one", "pr": "https://github.com/o/r/pull/1", "state": "done", "text": "done [at=$(( merged - 4 * 3600 ))]: PR ready"}
{"v": 1, "ts": $merged, "event": "task.merged", "task": "one", "pr": "https://github.com/o/r/pull/1"}
{"v": 1, "ts": $(( merged + 60 - 7200 )), "event": "task.status", "task": "two", "pr": "https://github.com/o/r/pull/2", "state": "done", "text": "done [at=$(( merged + 60 - 7200 ))]: PR ready"}
{"v": 1, "ts": $(( merged + 60 )), "event": "task.merged", "task": "two", "pr": "https://github.com/o/r/pull/2"}
{"v": 1, "ts": $(( merged + 120 - 7200 )), "event": "task.status", "task": "three", "pr": "https://github.com/o/r/pull/3", "state": "done", "text": "done [at=$(( merged + 120 - 7200 ))]: PR ready"}
{"v": 1, "ts": $(( merged + 120 )), "event": "task.merged", "task": "three", "pr": "https://github.com/o/r/pull/3"}
EOF
: >"$IN/task-outcomes.tsv"

# --- measure ----------------------------------------------------------------
out=$(run measure --inputs "$IN") || fail "measure failed: $out"
dataset=$(cat "$out")
assert_contains "$dataset" '"measured":3' 'not every merged pull request was measured'
n=$(printf '%s' "$dataset" | jq -r '.merges | length')
[ "$n" -eq 3 ] || fail "measure recorded $n merges, not 3"

row() { printf '%s' "$dataset" | jq -r --argjson pr "$1" ".merges[] | select(.pr == \$pr) | .$2"; }
# pr-1: done four hours before the merge, final commit one hour later.
assert_equals 3600 "$(row 1 rework_s)" 'rework for a pull request with one post-done commit'
assert_equals 7200 "$(row 1 final_ci_s)" 'the final CI window from the last commit to the last green job'
assert_equals 1200 "$(row 1 queue_s)" 'the job-hours of runner queue wait in the final CI'
assert_equals 8400 "$(row 1 run_s)" 'the job runtime of the final CI'
assert_equals 3600 "$(row 1 green_to_merged_s)" 'the wait from green to merged'
assert_equals 0 "$(row 1 handoff_s)" 'a fully recorded wait has no handoff'
# pr-2: the final commit predates the done line, so no rework; the CI window is
# clamped to the wait, and the stages still sum to it.
assert_equals 0 "$(row 2 rework_s)" 'a final commit before the done line is no rework'
assert_equals 6600 "$(row 2 final_ci_s)" 'the final CI window is not clamped to the wait'
assert_equals 7200 "$(row 2 total_s)" 'the wait is not measured from the done line to the merge'
assert_equals 7200 "$(printf '%s' "$dataset" | jq -r '[.merges[] | select(.pr == 2) | .rework_s + .final_ci_s + .green_to_merged_s + .handoff_s][0]')" \
  'the stages of a clamped merge do not sum to its wait'
# pr-3: no run at all, so nothing is green and the whole wait is handoff.
assert_equals null "$(row 3 green_at)" 'a pull request with no run must not claim a green time'
assert_equals 7200 "$(row 3 handoff_s)" 'an unrecorded wait is handoff'
pass 'measure attributes every second of the done-to-merged wait to one stage'

# --- the window -------------------------------------------------------------
# A merge outside the window is neither measured nor counted.
jq --arg old "$(iso $(( T0 - 30 * 86400 )))" \
  '. + [{repo: "o/r", number: 99, url: "https://github.com/o/r/pull/99", mergedAt: $old,
         commits: [{oid: "sha9", committedDate: $old}]}]' \
  "$IN/prs.json" >"$TMP/prs-old.json" && mv "$TMP/prs-old.json" "$IN/prs.json"
out=$(run measure --inputs "$IN") || fail "measure failed: $out"
assert_equals 3 "$(jq -r '.measured' "$out")" 'a merge outside the window was measured'
pass 'a merge outside the window is not measured'

# --- rank -------------------------------------------------------------------
ranked=$(run rank --inputs "$IN" --json) || fail "rank failed: $ranked"
assert_equals run "$(printf '%s' "$ranked" | jq -r '.[0].stage')" \
  'the stage losing the most hours is not ranked first'
assert_equals 'run queue handoff green_to_merged rework' \
  "$(printf '%s' "$ranked" | jq -r '[.[].stage] | join(" ")')" \
  'the ranking is not ordered by hours lost'
assert_equals 1 "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "rework") | .prs')" \
  'the rework stage does not count the one pull request that reworked'
assert_equals false "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "rework") | .ranked')" \
  'a stage under the configured hours per day must not be ranked for a ticket'
assert_equals 1.0 "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "rework") | .hours')" \
  'the rework stage does not carry the one hour it lost'
assert_equals 2 "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "handoff") | .hours_per_day | round')" \
  'the handoff stage is not the two hours a day it carries'
assert_equals true "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "run") | .ranked')" \
  'a stage over the configured hours per day must be ranked'
assert_equals 1 "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "queue") | .fix' | grep -c .)" \
  'every ranked stage must carry the fix its config names'
pass 'rank orders the stages by hours lost and keeps the fixes in config'

# The threshold is config: raising it past the handoff stage demotes that stage.
python3 - "$CONFIG_DIR/throughput.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['min-hours-per-day'] = 100
json.dump(d, open(p, 'w'), indent=2)
PY
ranked=$(run rank --inputs "$IN" --json) || fail "rank failed: $ranked"
assert_equals 0 "$(printf '%s' "$ranked" | jq -r '[.[] | select(.ranked)] | length')" \
  'a threshold moved up in config did not demote the stages'
pass 'the threshold is config: a stage below it is measured and never ranked'

# show prints the ranking with the fix and the owner of each stage.
out=$(run show --inputs "$IN") || fail "show failed: $out"
assert_contains "$out" 'handoff with nothing recorded running' 'show does not name the worst stage'
assert_contains "$out" '[owner: lead]' 'show does not name the stage owner'
pass 'show prints the ranking with each stage fix and owner'

# --- propose: one ticket per ranked bottleneck, filed once --------------------
# The captain asked for the bottleneck to be proposed by itself: one ticket per
# ranked stage carrying its measured saving, and one line to the captain per run.
mkdir -p "$TMP/data" "$TMP/config"
jg_test_tasks_toml "$TMP/.tasks.toml"
: >"$TMP/data/backlog.md"
jq '. + {"window-days": 1, "min-hours-per-day": 2, "max-filed": 2}' \
  "$ROOT/defaults/throughput.json" >"$CONFIG_DIR/throughput.json"
cat >"$TMP/bus" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${JG_TEST_CAPTAIN_LOG:?}"
SH
chmod +x "$TMP/bus"
export JG_TEST_CAPTAIN_LOG=$TMP/captain.log
CAPTAIN=$TMP/captain.log
: >"$CAPTAIN"

out=$(run measure --inputs "$IN") || fail "measure failed: $out"
out=$(JG_THROUGHPUT_BUS="$TMP/bus" run propose --inputs "$IN" --dry-run) || fail "propose failed: $out"
assert_contains "$out" 'would file: throughput-run' 'the worst ranked stage is not proposed'
assert_absent "$TMP/state/.throughput/filed/run" 'a dry run recorded a filing'
assert_absent "$TMP/data/backlog.md.filed" 'a dry run wrote to the backlog'

out=$(JG_THROUGHPUT_BUS="$TMP/bus" run propose --inputs "$IN") || fail "propose failed: $out"
assert_contains "$out" 'filed: throughput-run' 'the worst ranked stage was not filed'
assert_contains "$(cat "$TMP/data/backlog.md")" 'throughput-run' 'the ticket is not in the backlog'
assert_contains "$(cat "$TMP/data/backlog.md")" '2.3333 hours a day' \
  'the ticket does not carry the measured saving'
assert_equals 2 "$(grep -c '^- \[ \] throughput-' "$TMP/data/backlog.md")" \
  'the top-max-filed limit did not hold'
assert_contains "$(cat "$CAPTAIN")" 'throughput: 2 ranked bottleneck(s)' \
  'the captain was not told what was measured'
assert_equals 1 "$(wc -l <"$CAPTAIN" | tr -d ' ')" 'the captain got one line per stage instead of one per run'
pass 'propose files one ticket per ranked bottleneck and one captain line per run'

# A second run inside the window files nothing: the same bottleneck is not
# proposed twice, and a grown measurement does propose it again.
out=$(JG_THROUGHPUT_BUS="$TMP/bus" run propose --inputs "$IN") || fail "propose failed: $out"
assert_contains "$out" 'skip: throughput-run' 'the same bottleneck was filed twice'
assert_equals 2 "$(grep -c '^- \[ \] throughput-' "$TMP/data/backlog.md")" \
  'a second run added a duplicate ticket'
# Inside the window but grown by more than the configured growth: the same item
# is updated, never filed a second time.
printf '%s\t%s\n' "$T0" 1.0 >"$TMP/state/.throughput/filed/run"
out=$(JG_THROUGHPUT_BUS="$TMP/bus" run propose --inputs "$IN") || fail "propose failed: $out"
assert_contains "$out" 'updated: throughput-run' 'a bottleneck that grew inside the window was not refreshed'
assert_equals 2 "$(grep -c '^- \[ \] throughput-' "$TMP/data/backlog.md")" \
  'a refreshed bottleneck filed a second ticket'
# Past the refile window the same size is refreshed too.
printf '%s\t%s\n' "$(( T0 - 30 * 86400 ))" 6.0 >"$TMP/state/.throughput/filed/run"
out=$(JG_THROUGHPUT_BUS="$TMP/bus" run propose --inputs "$IN") || fail "propose failed: $out"
assert_contains "$out" 'updated: throughput-run' 'a stale filing was never refreshed'
pass 'a filed bottleneck is left alone until its window or its hours move'
