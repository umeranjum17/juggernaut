#!/usr/bin/env bash
# done-done journey: the ticket is one statechart. The real jg-machine.sh lints the three tables, lists the moves, accepts a move out
# of a stage from each sub-state, replays the older words (this repository's tables, generated status and shadow logs) and the 21
# pull request records, and the whole behavior test (tests/jg-machine-ticket.test.sh) runs after it.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"; t=$(mktemp -d) || exit 1; trap 'rm -rf -- "$t"' EXIT
rc=0
{
  for m in ticket delivering proving; do bash "$jm" check "$m" || rc=1; done
  echo "moves: $(bash "$jm" events ticket | cut -f1 | tr '\n' ' ')"
  for s in planned running sealed aborted; do bash "$jm" edge-check ticket "proving.$s" building || rc=1; done
  for s in queued resolving gated batched on-main; do bash "$jm" edge-check ticket "delivering.$s" released || rc=1; done
  bash "$jm" edge-check ticket intake proving && rc=1
  mkdir -p "$t/state"; printf 'working [at=1]: x\n2026-11-07T14:50:22Z done: y\npaused: z\n' > "$t/state/lane.status"
  printf '1794202567\ttask\tunknown\tdone\tshadow\n' > "$t/shadow.log"
  bash "$root/core/machines/ticket-corpus.sh" --state "$t/state" --shadow "$t/shadow.log" > "$t/corpus.tsv"
  bash "$jm" replay ticket-words "$t/corpus.tsv" || rc=1
  bash "$jm" records ticket-words "$root/core/machines/corpus/pr-records.tsv" || rc=1
  bash "$jm" diagram ticket | head -8
  bash "$root/tests/jg-machine-ticket.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped ticket, delivering and proving tables and the ticket word map, with generated status and shadow logs and the 21 pull request records",
 "steps": ["lint the ticket, delivering and proving tables", "list the 16 moves of the ticket", "ask for a move out of a stage from four sub-states of proving and five of delivering", "ask for a move that skips proving and require a refusal", "replay the words of the eleven older tables, a status log and a shadow log", "check the 21 pull request records against their targets", "draw the diagram and run the behavior test"],
 "result": "the three tables lint clean, the moves are the sixteen of the plan and J3b, each stage is left from every sub-state, a skipped stage is refused, every older word has a target (0 unmapped) and the 21 records get theirs"}
JSON
exit "$rc"
