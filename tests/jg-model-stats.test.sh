#!/usr/bin/env bash
# Slice S29 of jg-q1b3n on real Beads stores, through the real callers: the per-model statistics reader
# (bin/jg-model-stats.sh) reads each home's tickets, not a task-outcome file. The fixture is the table the old outcome file held:
# two homes (main and a registered lead), tickets started by the spawn's own `claim` and `handoff` events (the verb of the spawn
# writer, with the payload the spawn writes), landed, closed and given a pull request, beside the merged-PR and sampled-lane files.
# The reader must print the same per-model figures as before. Teardown must write no outcome row, and neither copy of the recorder
# remains. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; without them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-model-stats)
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
NOW=1700000000 DAY=86400
CODE=https://github.com/acme/app/pull

# store <home> <prefix>: a home with its own real store, named by config/beads-dir like a live home.
store() {
  mkdir -p "$1/config" "$1/data/metrics" "$1/state" "$T/store-$2"
  printf '%s\n' "$T/store-$2/.beads" > "$1/config/beads-dir"
  : > "$1/config/backlog-intake-loose"  # the fixture files rows by their own words, not by strict intake
  BEADS_DIR=$T/store-$2/.beads "$WRAPPER" init --prefix "$2" >"$T/init-$2.log" 2>&1 || fail "init $2: $(cat "$T/init-$2.log")"
}
# ticket <home> <id> <kind> <started days ago> <closed days ago or -> <landed yes|no> <pr number or -> <runtime>...
# Each runtime is harness:model:effort; the first is the spawn's claim, the others are relaunches (handoff), an hour apart.
ticket() {
  local home=$1 id=$2 kind=$3 start=$4 closed=$5 landed=$6 pr=$7 at n=0 spec harness model effort kindname
  shift 7
  at=$((NOW - start * DAY))
  JG_HOME=$home BEADS_DIR=$(< "$home/config/beads-dir")
  export JG_HOME BEADS_DIR
  "$CLI" add "$id" "[feature] fixture $id" --priority 2 --body why >/dev/null || fail "file $id"
  "$WRAPPER" update "$id" --set-metadata "task=$id" >/dev/null || fail "name the task of $id"
  for spec in "$@"; do
    IFS=: read -r harness model effort <<<"$spec"
    kindname=claim
    [ "$n" = 0 ] || kindname=handoff
    "$CLI" trace record "$id" "$kindname" work-id "$id@s$n" --source jg-spawn --at $((at + n * 3600)) \
      --payload "$(jq -cn --arg g "s$n" --arg h "$harness" --arg m "$model" --arg e "$effort" --arg k "$kind" '{gen: $g, harness: $h, model: $m, effort: $e, kind: $k}')" >/dev/null \
      || fail "the $kindname of $id"
    n=$((n + 1))
  done
  [ "$pr" = - ] || "$CLI" update "$id" --pr "$CODE/$pr" >/dev/null || fail "give $id its pull request"
  [ "$landed" = no ] || "$WRAPPER" update "$id" --set-metadata "landed_at=$(date -u -d "@$((NOW - closed * DAY - 60))" +%Y-%m-%dT%H:%M:%SZ)" >/dev/null || fail "land $id"
  if [ "$closed" != - ]; then  # the close time is the fixture's own: bd closes at the real now
    "$WRAPPER" close "$id" >/dev/null 2>&1 || fail "close $id"
    "$WRAPPER" dolt sql -q "update issues set closed_at='$(date -u -d "@$((NOW - closed * DAY))" '+%Y-%m-%d %H:%M:%S')' where id='$id'" >/dev/null || fail "date the close of $id"
  fi
  unset BEADS_DIR  # the reader finds each home's store through its config/beads-dir
}

OPUS=claude:claude-opus-5-5:medium MUSE_H=pi:opencode-go/muse-spark-1.3-contributor:high MUSE_M=pi:opencode-go/muse-spark-1.3-contributor:medium DEEP=pi:opencode-go/deepseek-v4.1-flash:medium
M=$T/main B=$T/byokit
store "$M" jg; store "$B" bk
printf -- '- byokit - BYOKit (home: %s; scope: toolkit; projects: byokit)\n' "$B" > "$M/data/squad_leads.md"
ticket "$M" jg-t1 ship 2 1 yes 1 "$OPUS"
ticket "$M" jg-t2 ship 3 2 yes 2 "$OPUS" "$MUSE_H"
ticket "$M" jg-t3 ship 5 4 no - "$MUSE_M"
ticket "$M" jg-t4 scout 1 1 no - "$MUSE_M"
ticket "$M" jg-t5 ship 20 19 yes 5 "$MUSE_M"
ticket "$M" jg-t6 ship 1 - no - "$MUSE_M"  # still open: started, not finished
ticket "$B" bk-b1 ship 2 1 yes 11 "$DEEP"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
{ printf 'home\trepo\tpr\tcreated\tmerged\thours_to_merge\tbuild_hours\tcommits\tcommits_after_open\trework_ci\trework_pipeline\trework_other\treverted\tescaped\tfirst_pass\tbot\ttitle\n'
  prow() { printf '%s\t%s\t%s\t%s\t%s\t0\t0\t1\t%s\t%s\t%s\t%s\t0\t0\t%s\t0\tt\n' "$1" "$2" "$3" "$(iso $(($4 - 3600)))" "$(iso "$4")" "$5" "$6" "$7" "$8" "$9"; }
  prow main acme/app 1 $((NOW - DAY)) 0 0 0 0 1; prow main acme/app 2 $((NOW - 2 * DAY)) 2 1 1 0 0
  prow main acme/app 5 $((NOW - 19 * DAY)) 0 0 0 0 1; prow main acme/app 3 $((NOW - 2 * DAY)) 0 0 0 0 1
  prow byokit acme/tool 11 $((NOW - DAY)) 0 0 0 0 1; } > "$M/data/metrics/prs.tsv"
{ printf 'first_seen\thome\ttask\tkind\tproject\tharness\tmodel\teffort\tmode\tpr\n'
  printf '%s\tmain\toldkind\tship\tacme\tpi\topencode-go/muse-spark-1.3-contributor\tmedium\tno-mistakes\t%s/3\n' "$(iso $((NOW - 3 * DAY)))" "$CODE"
  printf '%s\tmain\tjg-t1\tship\tacme\tclaude\tclaude-opus-5-5\tmedium\tno-mistakes\t%s/1\n' "$(iso $((NOW - 2 * DAY)))" "$CODE"; } > "$M/data/metrics/lanes.tsv"

# The verb: one JSON fact per ticket, the runtimes in launch order, the kind from the claim.
facts=$(JG_HOME=$M "$CLI" times --json --since $((NOW - 30 * DAY))) || fail "times --json"
[ "$(jq length <<<"$facts")" = 6 ] || fail "times --json must list the six tickets this home touched in the window, got: $facts"
[ "$(jq -r '.[] | select(.ticket == "jg-t2") | .models | map(join(":")) | join(";")' <<<"$facts")" = "$OPUS;$MUSE_H" ] || fail "a relaunch must show both runtimes in order: $facts"
[ "$(jq -r '.[] | select(.ticket == "jg-t4") | .kind' <<<"$facts")" = scout ] || fail "the claim names a Recon as a scout"
[ "$(jq '[.[] | select(.requested_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length' <<<"$facts")" = 6 ] || fail "times --json must carry each ticket's requested_at, got: $facts"
JG_HOME=$M "$CLI" times --json --since x >/dev/null 2>&1 && fail "a bad --since must be refused"
pass "times --json: one fact per ticket with its runtimes in order"

# The reader: the figures the outcome file gave, now from the tickets.
stats() { JG_HOME=$1 "$ROOT/bin/jg-model-stats.sh" --json --now $NOW; }
before=$(find "$M" -type f -printf '%p %T@\n' | sort)
x=$(stats "$M") || fail "model stats failed"
[ "$x" = "$(stats "$M")" ] && [ "$before" = "$(find "$M" -type f -printf '%p %T@\n' | sort)" ] || fail "the reader must be deterministic and read-only"
q() { jq -r "$1" <<<"$x"; }  # <filter over the output>
[ "$(q '.schema')" = jg-model-stats.v1 ] && [ "$(q '.windows | join(",")')" = 7,30 ] || fail "schema and windows"
[ "$(q '.coverage | [.outcome_rows, .sampled_tasks] | join(",")')" = 7,1 ] || fail "coverage: seven tickets worked, one sampled lane, got $(q '.coverage')"
w7() { q ".models[] | select(.model == \"$1\") | .w7 | [$2] | join(\",\")"; }
[ "$(w7 claude-opus-5-5 '.n_finished, .merged, .ended_ship, .merge_rate')" = 1,1,1,1.0 ] || fail "opus cohort and rate, got $(w7 claude-opus-5-5 '.n_finished, .merged, .ended_ship, .merge_rate') in $(q '.models | map(.model) | join(" ")')"
[ "$(w7 claude-opus-5-5 '.p50_hours, .p75_hours, .timed_merges, .first_pass_n, .first_pass_rate, .switches')" = 24.0,24.0,1,1,1.0,0 ] || fail "opus time, first pass, switches"
M7=opencode-go/muse-spark-1.3-contributor
[ "$(w7 $M7 '.n_finished, .merged, .ended_ship, .merge_rate')" = 4,2,2,0.5 ] || fail "muse cohort and recorded-only rate, got $(w7 $M7 '.n_finished, .merged, .ended_ship, .merge_rate')"
[ "$(w7 $M7 '.sampled, .unknown_outcome, .cancelled_failed')" = true,0,1 ] || fail "the sampled lane is disclosed and the cancelled ticket counted"
[ "$(w7 $M7 '.switches, .first_pass_n, .first_pass_sample, .first_pass_rate')" = 1,0,1,0.0 ] || fail "a relaunch to another model is one switch"
[ "$(w7 $M7 '.rework, .rework_ci, .rework_pipeline')" = 1,1,1 ] || fail "rework join"
[ "$(q '.models[] | select(.model == "opencode-go/deepseek-v4.1-flash") | [.provider, .name, .w7.merge_rate] | join(",")')" = "OpenCode Go,DeepSeek,1.0" ] || fail "the lead home's ticket is counted and named"
[ "$(q '.models[] | select(.model == "'$M7'") | .w30.merged')" = 3 ] || fail "30-day window"
[ "$(w7 $M7 '.n_started')" = 5 ] || fail "the open ticket and the sampled lane count as started, got $(w7 $M7 '.n_started')"
pass "model reader: the same per-model table from the tickets of two homes"

# A home with no store is not an error, and its lane ledger still answers.
E=$T/empty; mkdir -p "$E/data/metrics"
y=$(stats "$E") || fail "an empty home must not fail the reader"
[ "$(jq -r '.models | length' <<<"$y")" = 0 ] || fail "an empty home has no model rows: $y"
jq -e '.limitations | any(test("no readable Beads store"))' <<<"$y" >/dev/null || fail "an unreadable store is said in the limitations: $y"
pass "model reader: a home with no store reports it and fails nothing"

# Teardown writes no outcome row, and neither copy of the recorder remains.
[ ! -e "$ROOT/bin/jg-task-outcome.sh" ] && [ ! -e "$ROOT/core/fleet-stats/bin/jg-task-outcome.sh" ] || fail "a copy of the recorder remains"
[ ! -e "$M/data/metrics/task-outcomes.tsv" ] || fail "reading the statistics must write no outcome file"
pass "teardown: no outcome row, no recorder"
