#!/usr/bin/env bash
# done-done journey: drive the real core/lead-sweep/lead-sweep.sh and bin/jg-recon-gate.sh against fixture homes: a Recon is
# cleaned up only after Main relayed it and its inbox was quiet for an hour, a Recon with a handoff record only after its current draft is accepted (an old relay receipt does not close a new draft), and a report changed after the critic's last
# round fails the depth gate. The transcript goes into the evidence folder.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-recon-relayed-cleanup}.log
st=0
{
  echo "== lead-sweep: a Recon is cleaned up only after the relayed move and a quiet hour"
  bash "$REPO/core/lead-sweep/tests/lead-sweep.test.sh" 2>&1 | grep -E '^(ok|FAIL|PASS): (l:|m:|c:|PASS)' || true
  echo "== depth gate: a report changed after the critic's last round is refused"
  bash "$REPO/tests/jg-recon-gate.test.sh" 2>&1 | grep -E 'critic round names the report|^not ok' || true
} >"$LOG" 2>&1
grep -q '^FAIL\|^not ok' "$LOG" && st=1
[ "$(grep -c '^ok: l:' "$LOG")" -ge 6 ] || st=1
[ "$(grep -c '^ok: m:' "$LOG")" -ge 4 ] || st=1
[ "$(grep -c 'names the report it read' "$LOG")" -ge 1 ] || st=1
cat "$LOG"
cat >"$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut core/lead-sweep/lead-sweep.sh and bin/jg-recon-gate.sh at this commit"},
 "start":"a fixture home with Recon lanes that each have a report and a done line, and a fixture Recon whose critic has read its report",
 "steps":["run the lead-sweep check before Main relayed the Recon","write the relayed move and run it again with a message in the inbox","age the message past an hour and run it again","revise a Recon draft after its relay receipt and run it before and after the new verdict, with a pending steer","change the report after the critic's last round and run the depth gate"],
 "result":"a Recon not relayed is left even with its agent gone; a relayed Recon with a message in the last hour is left; after the relay and a quiet hour it is cleaned up once; an old relay receipt does not close a revised draft, and cleanup waits for the current draft's verdict; a report changed after the critic's last round is refused until a new round names it"}
J
exit "$st"
