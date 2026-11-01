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
cp "$ROOT/defaults/throughput.json" "$CONFIG_DIR/throughput.json"

run() {
  JG_HOME="$TMP" JG_STATE_OVERRIDE="$STATE_DIR" JG_CONFIG_OVERRIDE="$CONFIG_DIR" \
    JG_DATA_OVERRIDE="$TMP/data" JG_THROUGHPUT_NOW="$T0" "$TOOL" "$@"
}

# --- fixtures ---------------------------------------------------------------
# Three merged pull requests in one seven-day window, each with a known timeline:
#   pr-1  done -> final commit  1 h  -> green 2 h -> merged 1 h   (queue 10 min, run 50 min)
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

# pr-1's final CI: two jobs, one queued 10 min, run 50 min in total.
# pr-2's final CI: two jobs, one queued 1 h, run 2 h in total.
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
assert_equals "$(row 1 rework_s)" 3600 'rework for a pull request with one post-done commit'
assert_equals "$(row 1 final_ci_s)" 7200 'the final CI window from the last commit to the last green job'
assert_equals "$(row 1 queue_s)" 600 'the runner queue wait of the final CI'
assert_equals "$(row 1 run_s)" 2400 'the CI runtime of the final CI'
assert_equals "$(row 1 green_to_merged_s)" 3600 'the wait from green to merged'
assert_equals "$(row 1 handoff_s)" 0 'a fully recorded wait has no handoff'
# pr-2: done at the last commit, so no rework; every second is CI and pickup.
assert_equals "$(row 2 rework_s)" 0 'a done line at the final commit is no rework'
# pr-3: no run at all, so nothing is green and the whole wait is handoff.
assert_equals "$(row 3 green_at)" null 'a pull request with no run must not claim a green time'
assert_equals "$(row 3 handoff_s)" 7200 'an unrecorded wait is handoff'
pass 'measure attributes every second of the done-to-merged wait to one stage'

# --- the window -------------------------------------------------------------
# A merge outside the window is neither measured nor counted.
jq --arg old "$(iso $(( T0 - 30 * 86400 )))" \
  '. + [{repo: "o/r", number: 99, url: "https://github.com/o/r/pull/99", mergedAt: $old,
         commits: [{oid: "sha9", committedDate: $old}]}]' \
  "$IN/prs.json" >"$TMP/prs-old.json" && mv "$TMP/prs-old.json" "$IN/prs.json"
out=$(run measure --inputs "$IN") || fail "measure failed: $out"
assert_equals "$(jq -r '.measured' "$out")" 3 'a merge outside the window was measured'
pass 'a merge outside the window is not measured'

# --- rank -------------------------------------------------------------------
ranked=$(run rank --inputs "$IN" --json) || fail "rank failed: $ranked"
assert_equals "$(printf '%s' "$ranked" | jq -r '.[0].stage')" handoff \
  'the worst stage is not ranked first'
assert_equals "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "rework") | .prs')" 1 \
  'the rework stage does not count the one pull request that reworked'
assert_equals "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "rework") | .ranked')" false \
  'a stage under the configured hours per day must not be ranked for a ticket'
assert_equals "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "handoff") | .ranked')" true \
  'a stage over the configured hours per day must be ranked'
assert_equals "$(printf '%s' "$ranked" | jq -r '.[] | select(.stage == "queue") | .fix' | grep -c .)" 1 \
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
assert_equals "$(printf '%s' "$ranked" | jq -r '[.[] | select(.ranked)] | length')" 0 \
  'a threshold moved up in config did not demote the stages'
pass 'the threshold is config: a stage below it is measured and never ranked'

# show prints the ranking with the fix and the owner of each stage.
out=$(run show --inputs "$IN") || fail "show failed: $out"
assert_contains "$out" 'handoff with nothing recorded running' 'show does not name the worst stage'
assert_contains "$out" '[owner: lead]' 'show does not name the stage owner'
pass 'show prints the ranking with each stage fix and owner'
