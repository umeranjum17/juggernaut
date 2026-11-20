#!/usr/bin/env bash
# jg-workflow-rounds: a deep Recon's critic loop runs itself. `bin/jg-workflow.sh rounds <researcher> <row>` reads the real handoff moves
# (draft, assign, verdict, revise) of a stand-in report on a scratch home and tells the right lane once per report hash: the critic's gaps
# reach the researcher, a revised draft reaches the critic, a lane that ended is relaunched with the words as its note, and a fourth
# critiqued draft is `failed`. The three hooks ($JG_WORKFLOW_SEND, _CONTROL, _CREW_STATE) record every call instead of steering a lane.
# Proves: T1 a verdict with gaps, researcher live: one send, none on a second run; T2 researcher ended: one relaunch, no send;
# T3 a revise, critic ended, item store on: one relaunch; T4 critic live, item store on: nothing; T5 critic live, no item store: one send;
# T6 a fourth critiqued hash: failed, nothing sent; T7 accepted: nothing sent; T8 a researcher that revised without the revise move:
# one revise, the critic told once, then nothing.
set -u
here=$(cd "$(dirname "$0")" && pwd) || exit 1
root=$(cd "$here/.." && pwd) || exit 1
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-rounds-test.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
WF=$root/bin/jg-workflow.sh
HO=$root/bin/jg-recon-handoff.sh
fails=0
is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
has() { case $2 in *"$3"*) echo "ok - $1" ;; *) echo "not ok - $1: [$2] lacks [$3]"; fails=$((fails + 1)) ;; esac; }

# The hooks: each appends one line to $H/calls and exits 0; the crew-state hook reads $H/live/<task> (a file there means an agent is in the lane).
cat > "$w/send" <<'EOF'
#!/usr/bin/env bash
printf 'send %s | %s\n' "$1" "$2" >> "$JG_HOME/calls"
EOF
cat > "$w/control" <<'EOF'
#!/usr/bin/env bash
printf 'control %s %s %s | %s\n' "$1" "$2" "$3" "$4" >> "$JG_HOME/calls"
EOF
cat > "$w/crew" <<'EOF'
#!/usr/bin/env bash
if [ -e "$JG_HOME/live/$1" ]; then echo 'state: working · source: pane · x'; else echo 'state: unknown · source: none · x'; fi
EOF
chmod +x "$w/send" "$w/control" "$w/crew"

# sc: a fresh scratch home H with researcher rA and critic cA, a draft recorded and cA assigned.
sc() {
  H=$w/h$1; rm -rf -- "${H:?}"
  mkdir -p "$H/config" "$H/state" "$H/data/rA" "$H/data/cA" "$H/live"
  printf 'report v1\n' > "$H/data/rA/report.md"
  ho draft rA >/dev/null; ho assign rA --critic cA >/dev/null
}
ho() { JG_HOME=$H "$HO" "$@"; }
# verdict <gaps>: the critic answers the current draft.
verdict() { ho verdict rA --critic cA --hash "$(sha256sum "$H/data/rA/report.md" | cut -d' ' -f1)" --gaps "$1" >/dev/null; }
# rounds: one pass; out holds its answer. The detached call gets a moment to write its line.
rounds() {
  out=$(JG_HOME=$H JG_WORKFLOW_SEND=$w/send JG_WORKFLOW_CONTROL=$w/control JG_WORKFLOW_CREW_STATE=$w/crew "$WF" rounds rA row1 2>&1)
  sleep 0.2
}
calls() { cat "$H/calls" 2>/dev/null || true; }
ncalls() { calls | grep -c . || true; }
live() { : > "$H/live/$1"; }
WORDS1='Critic round 1 is in data/rA/critic.md: 4 gaps. Revise the report and plan, run bin/jg-recon-handoff.sh revise rA, and report the next draft ready.'

# T1: a verdict with 4 gaps, researcher live: one send with the round words; a second run: none.
sc 1; verdict 4; live rA
rounds; is "T1 open" "${out%%:*}" open; is "T1 one call" "$(ncalls)" 1
is "T1 the send" "$(calls)" "send rA | $WORDS1"
rounds; is "T1 second run adds none" "$(ncalls)" 1

# T2: the same with the researcher's lane ended: one relaunch with the same words; no send.
sc 2; verdict 4
rounds; is "T2 one call" "$(ncalls)" 1
is "T2 the relaunch" "$(calls)" "control rA relaunch --note | $WORDS1"
rounds; is "T2 second run adds none" "$(ncalls)" 1

# a revise: report changes, the real revise move records the second hash (phase drafted).
revise() { printf 'report v2\n' > "$H/data/rA/report.md"; ho revise rA >/dev/null; }

# T3: a revise, critic lane ended, item store present: one relaunch to the critic.
sc 3; verdict 4; revise; : > "$H/config/item-store"
rounds; is "T3 one call" "$(ncalls)" 1
has "T3 the relaunch" "$(calls)" "control cA relaunch --note | Draft 2 of rA is ready at data/rA/report.md"

# T4: the same with the critic lane live and the item store present: nothing (the store's steer serves it).
sc 4; verdict 4; revise; : > "$H/config/item-store"; live cA
rounds; is "T4 no call" "$(ncalls)" 0

# T5: the critic lane live and no item store: one send to the critic.
sc 5; verdict 4; revise; live cA
rounds; is "T5 one call" "$(ncalls)" 1
has "T5 the send" "$(calls)" "send cA | Draft 2 of rA is ready at data/rA/report.md: read it and record your verdict with bin/jg-recon-handoff.sh verdict."
rounds; is "T5 second run adds none" "$(ncalls)" 1

# T6: three critiqued hashes on file and a fourth: failed, nothing sent.
sc 6; mkdir -p "$H/data/workflows"; printf '%s\n' aaa bbb ccc > "$H/data/workflows/row1.rounds"; verdict 4; live rA
rounds; is "T6 failed" "${out%%:*}" failed; has "T6 why" "$out" "three critic rounds and gaps remain"; is "T6 no call" "$(ncalls)" 0

# T7: accepted: accepted, nothing sent.
sc 7; verdict 0; live rA; live cA
rounds; is "T7 accepted" "${out%%:*}" accepted; is "T7 no call" "$(ncalls)" 0

# T8: a verdict with 2 gaps, a changed report and a done line, no revise move: one revise, the critic told once; a second run adds nothing.
sc 8; verdict 2; live cA
printf 'report v2\n' > "$H/data/rA/report.md"
printf 'done [at=1]: draft v2 ready\n' > "$H/state/rA.status"
rounds
is "T8 one revise" "$(ho show rA | grep -c "$(printf '\trevise\t')")" 1
is "T8 phase" "$(ho phase rA)" drafted
is "T8 one call" "$(ncalls)" 1
has "T8 the critic told" "$(calls)" "send cA | Draft 2 of rA is ready"
rounds
is "T8 second run adds no revise" "$(ho show rA | grep -c "$(printf '\trevise\t')")" 1
is "T8 second run adds no message" "$(ncalls)" 1

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all ok"
