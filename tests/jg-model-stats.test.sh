#!/usr/bin/env bash
# Slice S29 of jg-q1b3n on the tickets tables, through the real callers: the per-model statistics reader
# (bin/jg-model-stats.sh) reads each home's tickets, not a task-outcome file. The fixture is the table the old outcome file held:
# two homes (main and a registered lead), tickets started the way the spawn starts them (a start naming the tool, model and effort, and a
# handover start for each relaunch), landed, closed and given a pull request, beside the merged-PR and sampled-lane files.
# The reader must print the same per-model figures as before. Teardown must write no outcome row, and neither copy of the recorder
# remains.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-model-stats)
CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC
NOW=1700000000 DAY=86400
CODE=https://github.com/acme/app/pull

# store <home>: a home whose backlog is the tickets tables of its own fleet.db.
store() {
  mkdir -p "$1/config" "$1/data/metrics" "$1/state"
  : > "$1/config/backlog-intake-loose"  # the fixture files rows by their own words, not by strict intake
}
bd_() { python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@"; }
# backdate <home> <id> <epoch>: the ticket's last change happened at <epoch>. The tables stamp each change with the host clock and a
# trigger keeps a change from changing, so the fixture lifts that trigger for the one update and puts it back as it was.
backdate() {
  python3 - "$1/state/item-store/fleet.db" "$2" "$3" <<'PY' || fail "date the start of $2"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
(trigger,) = con.execute("select sql from sqlite_master where name = 'ticket_change_final'").fetchone()
con.execute("drop trigger ticket_change_final")
con.execute("update ticket_change set at = ? where seq = (select max(seq) from ticket_change where id = ?)", (int(sys.argv[3]), sys.argv[2]))
con.execute(trigger)
con.commit()
PY
}
# ticket <home> <id> <kind> <started days ago> <closed days ago or -> <landed yes|no> <pr number or -> <runtime>...
# Each runtime is harness:model:effort; the first is the spawn's claim, the others are relaunches (handoff), an hour apart.
ticket() {
  local home=$1 id=$2 kind=$3 start=$4 closed=$5 landed=$6 pr=$7 at n=0 spec harness model effort handover
  shift 7
  at=$((NOW - start * DAY))
  JG_HOME=$home
  export JG_HOME
  "$CLI" add "$id" "[feature] fixture $id" --priority 2 --body why >/dev/null || fail "file $id"
  bd_ update "$id" --set-metadata "task=$id" >/dev/null || fail "name the task of $id"
  [ "$kind" = ship ] || bd_ update "$id" --set-metadata "kind=$kind" >/dev/null || fail "name the kind of $id"
  for spec in "$@"; do
    IFS=: read -r harness model effort <<<"$spec"
    handover=
    [ "$n" = 0 ] || handover=1
    JG_BACKLOG_LANE="lane-$id" JG_BACKLOG_SPAWN_GEN="s$n" JG_BACKLOG_LANE_HANDOVER=$handover JG_BACKLOG_AGENT=$harness JG_BACKLOG_MODEL=$model \
      JG_BACKLOG_EFFORT=$effort "$CLI" start "$id" >/dev/null || fail "launch $n of $id"
    backdate "$home" "$id" $((at + n * 3600))
    n=$((n + 1))
  done
  [ "$pr" = - ] || "$CLI" update "$id" --pr "$CODE/$pr" >/dev/null || fail "give $id its pull request"
  [ "$landed" = no ] || bd_ update "$id" --set-metadata "landed_at=$(date -u -d "@$((NOW - closed * DAY - 60))" +%Y-%m-%dT%H:%M:%SZ)" >/dev/null || fail "land $id"
  if [ "$closed" != - ]; then  # the close time is the fixture's own: done closes at the real now
    "$CLI" 'done' "$id" >/dev/null 2>&1 || fail "close $id"
    python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("update ticket set closed_at = ? where id = ?", sys.argv[2:]); c.commit()' \
      "$home/state/item-store/fleet.db" "$(date -u -d "@$((NOW - closed * DAY))" +%Y-%m-%dT%H:%M:%SZ)" "$id" || fail "date the close of $id"
  fi
}

OPUS=claude:claude-opus-5-5:medium MUSE_H=pi:opencode-go/muse-spark-1.3-contributor:high MUSE_M=pi:opencode-go/muse-spark-1.3-contributor:medium DEEP=pi:opencode-go/deepseek-v4.1-flash:medium
M=$T/main B=$T/byokit
store "$M"; store "$B"
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
# A read of the WAL-mode tables leaves SQLite's own -wal and -shm files beside fleet.db; they hold no data, so they are not a write.
files() { find "$M" -type f ! -name '*-wal' ! -name '*-shm' -printf '%p %T@\n' | sort; }
before=$(files)
x=$(stats "$M") || fail "model stats failed"
[ "$x" = "$(stats "$M")" ] && [ "$before" = "$(files)" ] || fail "the reader must be deterministic and read-only"
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

# A home with no tickets tables is not an error, and its lane ledger still answers.
E=$T/empty; mkdir -p "$E/data/metrics"
y=$(stats "$E") || fail "an empty home must not fail the reader"
[ "$(jq -r '.models | length' <<<"$y")" = 0 ] || fail "an empty home has no model rows: $y"
jq -e '.limitations | any(test("no readable tickets tables"))' <<<"$y" >/dev/null || fail "an unreadable home is said in the limitations: $y"
pass "model reader: a home with no tickets tables reports it and fails nothing"

# Teardown writes no outcome row, and neither copy of the recorder remains.
[ ! -e "$ROOT/bin/jg-task-outcome.sh" ] && [ ! -e "$ROOT/core/fleet-stats/bin/jg-task-outcome.sh" ] || fail "a copy of the recorder remains"
[ ! -e "$M/data/metrics/task-outcomes.tsv" ] || fail "reading the statistics must write no outcome file"
pass "teardown: no outcome row, no recorder"
