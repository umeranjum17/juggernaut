#!/usr/bin/env bash
# Journey: lead-sweep.sh check against a fixture home with real git clones and a recording teardown (it refuses a lane with
# uncommitted work or a scout with no gate pass, the way jg-teardown.sh does) and a gh-axi stub.
# a) a done lane whose head is on the trunk is torn down, once, with the lane id and no --force;
# b) a done lane whose head is on the trunk but holds uncommitted work is refused and reported once; the next beat prints
#    nothing; a changed reason is reported again;
# c) a Recon with a report, Main's relayed move, a quiet inbox and a passing gate is closed; a Recon whose gate refuses is reported once; a Recon with no report is left;
# l) a Recon with a report is left until its ticket has the relayed move and its inbox has been quiet 60 minutes, whatever its done
#    line, a gone agent or a passed critic; a message in that hour restarts the hour; an agent that ends at its done line keeps its copy;
# m) a Recon with a handoff record is closed only when its current draft is accepted and the relay is not older than that verdict:
#    an old relay receipt does not close a new draft, a draft waiting for its critic keeps it, and a pending steer keeps it;
# g) a done lane still on its recorded base (no commit of its own) is never torn down;
# d) a working lane, a done lane not landed, a lead and a lane a landing is running for are never touched;
# e) a done lane whose pull request is merged is torn down; an open one is not, and the forge is asked once per window;
# h) a done lane that has not landed has its agent ended once, with its copy and branch kept; one whose agent is gone is not touched;
# i) a lane parked (paused, blocked, needs-decision) is left until 24 h (2 h with no commit of its own), then parked once, never forced;
# j) a lane that never started is left for 30 minutes, relaunched once, then parked; a lane that started is not relaunched;
# k) a lane whose agent is gone is cleaned up when its work landed, and left alone when it did not;
# o) a lane someone waits for (an unread steer, a steer read after its done line, a relaunch after it) is never ended, parked or torn down, and a
#    waited-for agent that is gone raises one P1 alert to Main at once; a lane whose head is already on the trunk is finished whatever its
#    exit file or read steer says (it is torn down), while an unread steer or unlanded work still keeps it;
# q) a landed lane that kept its exit file and a pending backlog close finishes on one beat: its ticket closes, the close record and the exit
#    file go, and unlanded work is never touched;
# p) a parked lane's lead owns the decision a park leaves: its head on the trunk cleans the park record, a lane with a record again
#    clears the stale one, and every other parked lane raises ONE alert after the recheck window that names its branch and the next
#    step (land, re-prove or drop), rung again only when that step changes and resolved when the work lands.
# Usage: lead-sweep/tests/lead-sweep.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT   # a worker's injected hooks path and identity must not reach the fixture clone
mkdir -p "$HOME"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$P"
# Use the actual central alert owner in this fixture, as the waited-for journey below does.
mkdir -p "$FM/bin" "$FM/core/machines" "$FM/config"; echo off > "$FM/config/wake-bus"
cp "$SRC/../../bin/"jg-*.sh "$FM/bin/"
cp -r "$SRC/../machines/observers" "$SRC/../machines/tables" "$SRC/../machines/styles" "$FM/core/machines/"
ln -sn "$SRC/../bus" "$FM/core/bus"; ln -sn "$SRC/../wake" "$FM/core/wake"; ln -sn "$SRC/../item-store" "$FM/core/item-store"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base
export STUB_LOG=$d/calls STUB_MERGED=$d/merged
cat > "$d/teardown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
{ [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --park ]; }; } || { echo "REFUSED: unexpected arguments" >&2; exit 1; }
if [ -e "$JG_STATE_OVERRIDE/dirty-$1" ]; then echo "REFUSED: $1 holds uncommitted work: $(cat "$JG_STATE_OVERRIDE/dirty-$1")" >&2; exit 1; fi
if [ "$#" -eq 2 ]; then : > "$JG_STATE_OVERRIDE/$1.parked"; exit 0; fi
rm -f "$JG_STATE_OVERRIDE/$1.meta"
STUB
cat > "$d/control" <<'STUB'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$STUB_LOG"
[ ! -e "$JG_STATE_OVERRIDE/nocontrol-$1" ] || exit 1
[ "$2" != exit ] || { date +%s > "$JG_STATE_OVERRIDE/$1.exit"; echo dead > "$JG_STATE_OVERRIDE/agent-$1"; }   # a stopped agent is dead
STUB
cat > "$d/agent" <<'STUB'
#!/usr/bin/env bash
cat "$JG_STATE_OVERRIDE/agent-$1" 2>/dev/null || echo alive
STUB
cat > "$d/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB_LOG"
if [ -e "$STUB_MERGED" ] && grep -qx "$2" "$STUB_MERGED"; then echo true; else echo false; fi
STUB
chmod +x "$d/teardown" "$d/gh" "$d/control" "$d/agent"
export JG_LEAD_SWEEP_TEARDOWN=$d/teardown JG_LEAD_SWEEP_GH=$d/gh JG_LEAD_SWEEP_CONTROL=$d/control JG_LEAD_SWEEP_AGENT=$d/agent
fails=0; LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/lead-sweep.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
# lane <id> <kind> <status line> [extra meta]: branch fm/<id> holds one commit; the trunk tip is moved over it with `onto`.
lane() {
  git -C "$P" branch "fm/$1" trunk; git -C "$P" checkout -q "fm/$1"; echo "$1" > "$P/$1"; git -C "$P" add "$1"
  git -C "$P" commit -qm "$1"; git -C "$P" checkout -q trunk
  printf 'kind=%s\nproject=%s\nbranch=fm/%s\n%s\n' "$2" "$P" "$1" "${4:-}" > "$FM/state/$1.meta"
  [ -z "$3" ] || printf '%s\n' "$3" > "$FM/state/$1.status"
}
onto() { git -C "$P" merge -q --no-ff "fm/$1" -m "land $1"; git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"; }
git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"
sweep() { : > "$STUB_LOG"; "$SRC/lead-sweep.sh" run "$FM" > "$d/out" 2>&1; }
tore() { grep -c "^$1\$" "$STUB_LOG" || true; }

lane land ship 'done [at=1]: ready' ; lane dirty ship 'done [at=1]: ready'; echo "src/a.go" > "$FM/state/dirty-dirty"
lane busy ship 'working [at=1]: coding'; lane open ship 'done [at=1]: ready'; lane lead squad_lead 'done [at=1]: x'
lane running ship 'done [at=1]: ready'; : > "$FM/state/.trunk-run-running-$(git -C "$P" rev-parse fm/running).lock"
lane recon scout 'done [at=1]: report' ticket=t-recon; lane gate scout 'done [at=1]: report' ticket=t-gate; lane noreport scout 'done [at=1]: report' ticket=t-noreport
printf '%s\t%s\tproving\trelayed\tproving\n' 1 t-recon 1 t-gate 1 t-noreport > "$FM/data/moves.log"

mkdir -p "$FM/data/recon" "$FM/data/gate"; echo r > "$FM/data/recon/report.md"; echo r > "$FM/data/gate/report.md"
echo "src/a.go" > "$FM/state/dirty-gate"
for t in land dirty running; do onto "$t"; done
sweep
check "a: the landed lane is torn down once" "$(tore land)" 1
check "a: it is reported cleaned up" "$(grep -c '^lead-sweep: land cleaned up (its head is on the trunk)' "$d/out")" 1
check "b: the dirty landed lane is refused and reported once" "$(grep -c '^lead-sweep: dirty .*not cleaned up, nothing was forced: REFUSED: dirty holds uncommitted work: src/a.go' "$d/out")" 1
check "c: the Recon with a report is closed" "$(tore recon)" 1
check "c: the Recon whose gate refuses is reported once" "$(grep -c '^lead-sweep: gate ' "$d/out")" 1
check "c: the Recon with no report is not touched" "$(tore noreport)" 0
for t in busy open lead running; do check "d: $t is never touched" "$(tore $t)" 0; done
sweep
check "b: the second beat prints nothing" "$(cat "$d/out")" ""
check "b: the refused lanes are retried, never forced" "$(tore dirty)$(tore gate)" 11
echo "src/b.go" > "$FM/state/dirty-dirty"; sweep
check "b: a changed reason is reported again" "$(grep -c 'src/b.go' "$d/out")" 1
# e: a merged pull request
lane merged ship 'done [at=1]: ready' "pr=https://github.com/o/r/pull/7"; lane pending ship 'done [at=1]: ready' "pr=https://github.com/o/r/pull/8"
echo repos/o/r/pulls/7 > "$STUB_MERGED"; sweep
check "e: the lane with a merged pull request is torn down" "$(tore merged)" 1
check "e: the lane with an open pull request is not" "$(tore pending)" 0
sweep
check "e: the forge is asked once per lane per window" "$(grep -c 'pulls/8' "$STUB_LOG")" 0
check "no --force reaches the teardown" "$(grep -c -- '--force' "$STUB_LOG")" 0
# g: an empty lane (head is still its recorded base, an ancestor of the trunk) is not landed, so it is not torn down
lane empty ship 'done [at=1]: ready' "base=$(git -C "$P" rev-parse trunk)"; git -C "$P" branch -f fm/empty trunk; sweep
check "g: the empty lane is not torn down" "$(tore empty)" 0
check "g: the empty lane is not reported cleaned up" "$(grep -c '^lead-sweep: empty .*cleaned up' "$d/out")" 0
# h: a done lane that has not landed has its agent ended once
lane hd ship 'done [at=1]: ready'; lane hgone ship 'done [at=1]: ready'; echo dead > "$FM/state/agent-hgone"
sweep
check "h: the done lane not landed has its agent ended" "$(grep -c '^control hd exit$' "$STUB_LOG")" 1
check "h: it is reported once" "$(grep -c '^lead-sweep: hd is done, its agent was ended' "$d/out")" 1
check "h: a done lane whose agent is gone is not touched" "$(grep -c '^control hgone ' "$STUB_LOG")" 0
sweep
check "h: the next beat ends nothing more" "$(grep -c '^control hd exit$' "$STUB_LOG")" 0
touch "$FM/state/nocontrol-lost"; lane lost ship 'done [at=1]: ready'; sweep
check "h: an agent that cannot be ended is reported once" "$(grep -c '^lead-sweep: lost is done, but its agent could not be ended' "$d/out")" 1
sweep; check "h: the same failure prints nothing more" "$(grep -c '^lead-sweep: lost' "$d/out")" 0
# i: a parked lane
now=$(date +%s)
lane pk24 ship 'blocked [at=1]: waits' "base=$(git -C "$P" rev-parse trunk)"; lane pk2 ship 'paused [at=1]: wait' "base=$(git -C "$P" rev-parse trunk)"
lane pkfresh ship 'needs-decision [at=1]: x' "base=$(git -C "$P" rev-parse trunk)"
git -C "$P" branch -f fm/pk2 trunk
for t in pk24 pk2 pkfresh; do touch -d "@$((now - 3 * 3600))" "$FM/state/$t.status"; done
touch -d "@$((now - 30 * 3600))" "$FM/state/pk24.status"
sweep
check "i: a lane parked 30 h is parked once" "$(tore 'pk24 --park')" 1
check "i: an empty lane parked 3 h is parked" "$(tore 'pk2 --park')" 1
check "i: a lane with its own commit parked 3 h is left" "$(tore 'pkfresh --park')" 0
check "i: it is reported" "$(grep -c '^lead-sweep: pk24 parked (waiting for 24 hours)' "$d/out")" 1
sweep; check "i: a parked lane is not parked again" "$(tore 'pk24 --park')" 0
touch "$FM/state/dirty-pkfresh"; echo x > "$FM/state/dirty-pkfresh"; touch -d "@$((now - 30 * 3600))" "$FM/state/pkfresh.status"; sweep
check "i: a refused park is reported once and nothing is forced" "$(grep -c '^lead-sweep: pkfresh could not be parked' "$d/out")" 1
# i2: a declared park (paused ... reason=parked) gives its copy back on the next beat, however fresh the line is
lane pkdecl ship 'paused [at=1] [wait=lead] [reason=parked]: set aside' "base=$(git -C "$P" rev-parse trunk)"
lane pkwait ship 'paused [at=1] [wait=outside] [reason=ci]: waits for ci' "base=$(git -C "$P" rev-parse trunk)"
sweep
check "i2: a declared park is parked at once" "$(tore 'pkdecl --park')" 1
check "i2: it says why" "$(grep -c '^lead-sweep: pkdecl parked (declared parked)' "$d/out")" 1
check "i2: its branch is kept" "$(git -C "$P" rev-parse --verify --quiet refs/heads/fm/pkdecl >/dev/null && echo kept)" kept
check "i2: a fresh paused line for another reason is left" "$(tore 'pkwait --park')" 0
# j: never started
lane ns ship '' ; lane started ship 'working [at=1]: coding'; rm -f "$FM/state/ns.status"
touch -d "@$((now - 10 * 60))" "$FM/state/ns.meta"; sweep
check "j: a lane 10 minutes old is left" "$(grep -c '^control ns relaunch' "$STUB_LOG")" 0
touch -d "@$((now - 40 * 60))" "$FM/state/ns.meta"; sweep
check "j: a lane 40 minutes old with no status is relaunched once" "$(grep -c '^control ns relaunch --note' "$STUB_LOG")" 1
sweep; check "j: and not again at once" "$(grep -c '^control ns relaunch' "$STUB_LOG")$(tore 'ns --park')" 00
JG_LEAD_SWEEP_NOW=$((now + 40 * 60)) sweep
check "j: still no status after the relaunch: parked" "$(tore 'ns --park')" 1
check "j: a lane with a status line is never relaunched" "$(grep -c 'control started relaunch' "$STUB_LOG")" 0
# k: agent gone
lane gone ship 'working [at=1]: coding'; lane goneopen ship 'working [at=1]: coding'; echo dead > "$FM/state/agent-gone"; echo missing > "$FM/state/agent-goneopen"
onto gone; sweep
check "k: a gone agent with landed work is cleaned up" "$(tore gone)" 1
check "k: it says why" "$(grep -c '^lead-sweep: gone cleaned up (its agent is gone and its head is on the trunk)' "$d/out")" 1
check "k: a gone agent with unlanded work is left, silently" "$(tore goneopen)$(grep -c '^lead-sweep: goneopen' "$d/out")" 00
check "k: a live agent that is working is never swept" "$(tore busy)" 0
check "no --force reaches the teardown or the control" "$(grep -c -- '--force' "$STUB_LOG")" 0
# l: a Recon is cleaned up only after Main relayed it and its inbox was quiet for 60 minutes
mkdir -p "$FM/data/lrec" "$FM/data/lgone"; echo r > "$FM/data/lrec/report.md"; echo r > "$FM/data/lgone/report.md"
lane lrec scout 'done [at=1]: report' ticket=t-lrec; lane lgone scout 'done [at=1]: report' ticket=t-lgone; echo dead > "$FM/state/agent-lgone"
sweep
check "l: a Recon not relayed is left, its agent ended at the done line" "$(tore lrec)$(tore lgone)$(grep -c '^control lrec exit$' "$STUB_LOG")" 001
check "l: a gone agent with a report on disk is not enough" "$(grep -c '^lead-sweep: lgone' "$d/out")" 0
printf '1\tt-lrec\tproving\trelayed\tproving\n1\tt-lgone\tproving\trelayed\tproving\n' >> "$FM/data/moves.log"
mkdir -p "$FM/state/lrec.inbox"; echo m > "$FM/state/lrec.inbox/1.msg"; touch -d "@$((now - 10 * 60))" "$FM/state/lrec.inbox/1.msg"
sweep
check "l: a message in the last hour keeps a relayed Recon" "$(tore lrec)" 0
check "l: a relayed Recon with no inbox is cleaned up" "$(tore lgone)" 1
touch -d "@$((now - 70 * 60))" "$FM/state/lrec.inbox/1.msg"; sweep
check "l: an unread message keeps a relayed Recon, however old" "$(tore lrec)" 0
mkdir -p "$FM/state/lrec.inbox/handled"; mv "$FM/state/lrec.inbox/1.msg" "$FM/state/lrec.inbox/handled/"; touch -d "@$((now - 70 * 60))" "$FM/state/lrec.inbox/handled/1.msg"; sweep
check "l: a quiet hour after the relay cleans it up, once" "$(tore lrec)" 1
check "l: it says why" "$(grep -c '^lead-sweep: lrec cleaned up (its report exists and Main relayed it)' "$d/out")" 1
# m: the Recon table decides: an old relay receipt cannot close a new draft
H=$SRC/../../bin/jg-recon-handoff.sh; mkdir -p "$FM/bin"; cp "$H" "$FM/bin/" 2>/dev/null || true
mkdir -p "$FM/core/machines"; cp -r "$SRC/../machines/observers" "$SRC/../machines/tables" "$FM/core/machines/" 2>/dev/null || true
mkdir -p "$FM/data/mrec"; echo draft1 > "$FM/data/mrec/report.md"
lane mrec scout 'done [at=1]: report' ticket=t-mrec
hand() { JG_HOME=$FM JG_DATA_OVERRIDE=$FM/data "$FM/bin/jg-recon-handoff.sh" "$@" >/dev/null; }
sha() { sha256sum "$FM/data/mrec/report.md" | cut -d' ' -f1; }
hand draft mrec; hand verdict mrec --critic c1 --hash "$(sha)" --gaps 1
printf '%s\tt-mrec\tproving\trelayed\tproving\n' "$(date +%s)" >> "$FM/data/moves.log"   # the receipt of draft 1
echo draft2 > "$FM/data/mrec/report.md"; hand revise mrec
sweep
check "m: a relay receipt for an older draft does not close a revised draft waiting for its critic" "$(tore mrec)" 0
sleep 1; hand verdict mrec --critic c1 --hash "$(sha)" --gaps 0
sweep
check "m: an accepted draft whose only relay receipt is older is not closed" "$(tore mrec)" 0
sleep 1; printf '%s\tt-mrec\tproving\trelayed\tproving\n' "$(date +%s)" >> "$FM/data/moves.log"
mkdir -p "$FM/state/mrec.inbox"; echo steer > "$FM/state/mrec.inbox/1.msg"; touch -d "@$((now - 70 * 60))" "$FM/state/mrec.inbox/1.msg"
sweep
check "m: a pending steer keeps an accepted, relayed Recon" "$(tore mrec)" 0
mkdir -p "$FM/state/mrec.inbox/handled"; mv "$FM/state/mrec.inbox/1.msg" "$FM/state/mrec.inbox/handled/"; touch -d "@$((now - 70 * 60))" "$FM/state/mrec.inbox/handled/1.msg"
sweep
check "m: the accepted draft, relayed after its verdict, is cleaned up" "$(tore mrec)" 1
# n: the INSTALLED copy, alone in a directory with no bin next to it, finds the facts lib through the home argument
mkdir -p "$d/installed" "$FM/bin"; cp "$SRC/lead-sweep.sh" "$d/installed/lead-sweep.sh"; cp "$SRC/../../bin/jg-facts-lib.sh" "$FM/bin/"
if "$d/installed/lead-sweep.sh" run "$FM" > "$d/inst" 2>&1; then check "n: the installed copy runs from the home" ok ok
else say "FAIL: n: installed copy: $(cat "$d/inst")"; fails=$((fails + 1)); fi
check "n: the installed copy found the lib" "$(grep -c 'No such file' "$d/inst" || true)" 0
# f: the wiring installs a shim that registers, and the unwiring removes it
if [ -x "$SRC/../../bin/jg-check-register.sh" ]; then
  mkdir -p "$FM/bin"; cp "$SRC/../../bin/"jg-*.sh "$FM/bin/" 2>/dev/null || true
  if XDG_DATA_HOME=$d/share "$SRC/wiring.sh" "$FM" > "$d/wire" 2>&1; then
    check "f: the wiring registers the check" "$(head -n 1 "$FM/state/lead-sweep.check-trust")" jg-custom-check-v1
  else say "FAIL: f: wiring: $(cat "$d/wire")"; fails=$((fails + 1)); fi
  XDG_DATA_HOME=$d/share "$SRC/unwiring.sh" "$FM" > /dev/null 2>&1; check "f: the unwiring removes the shim" "$(ls "$FM/state/lead-sweep.check.sh" 2>/dev/null || echo gone)" gone
fi
# o: a lane someone waits for is live, whatever its last line says (worker-stop-alert). A second fixture home runs the real alert path.
FM=$d/fm2; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$P"; ln -sn "$SRC/../../bin" "$FM/bin"; ln -sn "$SRC/../../core" "$FM/core"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base; git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"
stamp() { touch -d "@$((now - 100))" "$FM/state/$1.status"; }   # the done line is older than the steers below
steer() { mkdir -p "$FM/state/$1.inbox"; echo "please answer" > "$FM/state/$1.inbox/1.msg"; }
ends() { grep -c "^control $1 exit\$" "$STUB_LOG" || true; }
lane w1 ship 'done [at=1]: ready'; steer w1; stamp w1
lane w2 ship 'done [at=1]: ready'; steer w2; stamp w2; onto w2
lane w3 ship 'paused [at=1] [wait=lead] [reason=parked]: set aside'; steer w3; stamp w3
lane w4 ship 'done [at=1]: ready'; stamp w4; mkdir -p "$FM/state/w4.inbox/handled"; echo read > "$FM/state/w4.inbox/handled/1.msg"
lane w5 ship 'done [at=1]: ready'; stamp w5; onto w5; date +%s > "$FM/state/w5.exit"
lane w6 ship 'done [at=1]: ready'; steer w6; stamp w6; onto w6; echo dead > "$FM/state/agent-w6"
lane w7 ship 'done [at=1]: ready'; stamp w7
lane w8 ship 'done [at=1]: ready'; stamp w8; date +%s > "$FM/state/w8.exit"
sweep
check "o: a done lane with an unread steer keeps its agent" "$(ends w1)" 0
check "o: a landed lane with an unread steer is not torn down" "$(tore w2)" 0
check "o: a declared park with an unread steer is not parked" "$(tore 'w3 --park')" 0
check "o: a steer newer than the done line, already read, keeps the agent" "$(ends w4)" 0
check "o: a landed lane relaunched after its done line is finished: torn down once" "$(tore w5)" 1
check "o: a relaunched lane whose work has not landed is not torn down" "$(tore w8)" 0
check "o: a landed lane with an unread steer is still not torn down" "$(tore w2)" 0
check "o: a done lane nobody waits for is still ended once" "$(ends w7)" 1
check "o: a waited-for agent that is gone raises one alert" "$(JG_HOME=$FM JG_STATE_OVERRIDE=$FM/state "$FM/bin/jg-alert.sh" list | grep -c '^worker-stopped--w6$')" 1
check "o: the alert is P1 at Main's rung" "$(sed -n 's/^\(precedence\|rung\)=//p' "$FM/state/alerts/worker-stopped--w6.rec" | paste -sd' ')" "P1 3"
check "o: the alert reached Main at once, as one wake" "$(grep -c 'alert worker-stopped (P1) at rung 3 for main: w6' "$FM/state/.wake-queue")" 1
sweep
check "o: a second beat raises no second alert" "$(find "$FM/state/alerts" -name 'worker-stopped--w6*' | wc -l | tr -d ' ')" 1
mkdir -p "$FM/state/w1.inbox/handled"; mv "$FM/state/w1.inbox/1.msg" "$FM/state/w1.inbox/handled/"; touch -d "@$((now - 200))" "$FM/state/w1.inbox/handled/1.msg"; sweep
check "o: once the steer is read and answered the done lane is ended once" "$(ends w1)" 1
# p: a parked lane keeps state/<id>.parked (task, project, mode, branch, head, base, spawn_gen, owner, owner_home, parked_at). Its lead
# owns the next step, and the sweep rechecks it: landed cleans it, a live lane clears the stale record, the rest raise one alert.
parkrec() {  # <id> <head> <base> <gen> [parked_at]: the park record, and the lane record the park removes
  printf 'task=%s\nkind=ship\nproject=%s\nmode=local-trunk\nbranch=fm/%s\nhead=%s\nbase=%s\nspawn_gen=%s\nbackend=pi\nowner=lead\nowner_home=%s\nparked_at=%s\n' \
    "$1" "$P" "$1" "$2" "$3" "$4" "$FM" "${5:-$now}" > "$FM/state/$1.parked"
  rm -f "$FM/state/$1.meta"
}
prove_at() {  # <id> <head> <gen>: the PASS receipt and the sealed clean run the lander's own proof reader accepts at that head
  mkdir -p "$FM/data/$1/.done-done/runs"; printf 'ok\n' > "$FM/data/$1/run.log"
  printf '{"task":"%s","head":"%s","verdict":"PASS","spawn_gen":"%s"}\n' "$1" "$2" "$3" > "$FM/state/$1.run-receipt.json"
  printf '{"schema":1,"run_id":"20260101T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-01-01T00:00:00Z","files":["run.log"]}\n' "${2:0:8}" "$2" > "$FM/data/$1/.done-done/runs/run-$2.json"
}
parked_alerts() { local n=0 f; for f in "$FM/state/alerts/parked-lane--$1"*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
parked_note() { sed -n 's/^note=//p' "$FM/state/alerts/parked-lane--$1.rec" 2>/dev/null | tail -n 1; }
parked_notes() { grep -c "^lead-sweep: $1 is parked and its work is not on the trunk" "$d/out" || true; }
old=$((now - 7200)); trunk0=$(git -C "$P" rev-parse trunk)
lane pp1 ship 'paused [at=1] [wait=lead] [reason=parked]: set aside'; onto pp1
parkrec pp1 "$(git -C "$P" rev-parse fm/pp1)" "$trunk0" g-pp1 "$old"          # landed: its head is on the trunk
lane pp2 ship 'done [at=1]: ready'; prove_at pp2 "$(git -C "$P" rev-parse fm/pp2)" g-pp2
parkrec pp2 "$(git -C "$P" rev-parse fm/pp2)" "$trunk0" g-pp2 "$old"            # built and proved: land
lane pp3 ship 'done [at=1]: ready'
parkrec pp3 "$(git -C "$P" rev-parse fm/pp3)" "$trunk0" g-pp3 "$old"             # built, not proved at that head: re-prove
lane pp4 ship 'paused [at=1] [wait=lead] [reason=parked]: set aside'
parkrec pp4 "$(git -C "$P" rev-parse fm/pp4)" "$trunk0" g-pp4 "$old"; git -C "$P" branch -D fm/pp4 >/dev/null   # branch gone: drop
lane pp5 ship 'working [at=1]: coding'
parkrec pp5 "$(git -C "$P" rev-parse fm/pp5)" "$trunk0" g-pp5 "$old"             # then a record again: the park record is stale
printf 'kind=ship\nproject=%s\nbranch=fm/pp5\n' "$P" > "$FM/state/pp5.meta"   # the respawn's record
lane pp6 ship 'paused [at=1] [wait=lead] [reason=parked]: set aside'; git -C "$P" branch -f fm/pp6 "$trunk0"
parkrec pp6 "$trunk0" "$trunk0" g-pp6 "$old"                                     # no commit of its own: drop
lane pp7 ship 'paused [at=1] [wait=lead] [reason=parked]: set aside'
parkrec pp7 "$(git -C "$P" rev-parse fm/pp7)" "$trunk0" g-pp7                     # a fresh park: inside the recheck window
sweep
check "p: a parked lane whose head is on the trunk is cleaned up" "$( [ -e "$FM/state/pp1.parked" ] && echo kept || echo cleaned)" cleaned
check "p: and it says so" "$(grep -c '^lead-sweep: pp1 was parked and its head is on the trunk; its park record is cleaned up' "$d/out")" 1
check "p: a landed park raises no alert" "$(parked_alerts pp1)" 0
check "p: a parked lane with a whole proof names land as the next step" "$(parked_note pp2-g-pp2)" "pp2 is parked and its work is not on the trunk: branch fm/pp2 at $(git -C "$P" rev-parse --short=12 fm/pp2); next step for its lead: land"
check "p: the park record's lead is the owner of the obligation" "$(sed -n 's/^owner=//p' "$FM/data/lead-sweep/pp2.parked-owner")" lead
check "p: the obligation keeps the branch, head and next step" "$(sed -n 's/^next_action=//p' "$FM/data/lead-sweep/pp2.parked-owner") $(sed -n 's/^branch=//p' "$FM/data/lead-sweep/pp2.parked-owner")" "land fm/pp2"
check "p: the obligation names when its recheck was due" "$([ -n "$(sed -n 's/^recheck_after=//p' "$FM/data/lead-sweep/pp2.parked-owner")" ] && echo kept)" kept
check "p: one alert, rung at the lead" "$(sed -n 's/^rung=//p' "$FM/state/alerts/parked-lane--pp2-g-pp2.rec")" 2
check "p: an unproved park names re-prove" "$(parked_note pp3-g-pp3 | sed 's/.*next step for its lead: //')" re-prove
check "p: a park with no branch names drop" "$(parked_note pp4-g-pp4 | sed 's/.*next step for its lead: //')" 'drop (its branch is gone)'
check "p: a park with no commit of its own names drop" "$(parked_note pp6-g-pp6 | sed 's/.*next step for its lead: //')" drop
check "p: a lane with a record again clears its stale park record" "$( [ -e "$FM/state/pp5.parked" ] && echo kept || echo cleared)" cleared
check "p: a cleared park raises no alert" "$(parked_alerts pp5)" 0
check "p: a fresh park is left alone until its recheck window runs out" "$(parked_alerts pp7)" 0
check "p: the sweep printed the alert line once per lane" "$(parked_notes pp2)$(parked_notes pp3)$(parked_notes pp4)$(parked_notes pp6)" 1111
sweep
check "p: a second beat raises no second record for a lane" "$(parked_alerts pp2)" 1
check "p: and rings nothing more" "$(grep -c "^[0-9]*	[0-9]*	check	pp2-g-pp2	" "$FM/state/.wake-queue")" 1
prove_at pp3 "$(git -C "$P" rev-parse fm/pp3)" g-pp3; sweep
check "p: the same alert rings again when the next step changes" "$(parked_note pp3-g-pp3 | sed 's/.*next step for its lead: //')" land
check "p: it is still one record" "$(parked_alerts pp3)" 1
check "p: and the changed step is printed once in that beat" "$(grep -c '^lead-sweep: pp3 is parked' "$d/out")" 1
onto pp2; sweep
check "p: a parked lane that lands later is cleaned up" "$( [ -e "$FM/state/pp2.parked" ] && echo kept || echo cleaned)" cleaned
check "p: its one alert is closed with the landed commit as proof" "$(sed -n 's/^state=//p' "$FM/state/alerts/parked-lane--pp2-g-pp2.rec") $(sed -n 's/^proof=//p' "$FM/state/alerts/parked-lane--pp2-g-pp2.rec")" "resolved commit:$(git -C "$P" rev-parse fm/pp2)"
check "p: its obligation is gone with it" "$( [ -e "$FM/data/lead-sweep/pp2.parked-owner" ] && echo kept || echo cleaned)" cleaned
# q: the lanes of jg-6si-10 and jg-6si-12 were on the trunk, yet kept an exit file and a pending backlog close, so their tickets stayed in flight.
# A third fixture home has a real backlog, and the real replay runs.
FM=$d/fm3; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$FM/config" "$P"; ln -sn "$SRC/../../bin" "$FM/bin"; ln -sn "$SRC/../../core" "$FM/core"
: > "$FM/config/backlog-intake-loose"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base; git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"
bl() { (cd "$FM" && JG_HOME="$FM" JG_CONFIG_OVERRIDE="$FM/config" "$FM/bin/jg-backlog.sh" "$@"); }
rowstate() { bl show "$1" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
for t in q1 q2 q3; do bl add "$t" "[feature] fixture $t" --priority 1 --kind ship --repo demo --body "fixture" >/dev/null; bl start "$t" >/dev/null; done
# q1: its head is on the trunk and its agent was started again after the done line (exit file newer than the status); its record is still there
lane q1 ship 'done [at=1]: ready'; stamp q1; onto q1; date +%s > "$FM/state/q1.exit"
# q2: teardown removed the record and died before the close landed: the close record and the exit file are all that is left
printf 'task=q2\nspawn_gen=g-q2\n' > "$FM/state/q2.meta"
(. "$FM/bin/jg-wake-lib.sh"; . "$FM/bin/jg-backlog-lib.sh"; . "$FM/bin/jg-backlog-transition-lib.sh"
 jg_backlog_close_marker_write "$FM/state" q2 "$FM/data" g-q2 --note local-trunk) || { say "FAIL: q: could not write the close record"; fails=$((fails + 1)); }
rm -f "$FM/state/q2.meta"; date +%s > "$FM/state/q2.exit"
# q3: unlanded work that is waited for stays exactly as it is
lane q3 ship 'done [at=1]: ready'; stamp q3; date +%s > "$FM/state/q3.exit"
check "q: the fixture left q2's ticket in flight with its close pending" "$(rowstate q2) $([ -e "$FM/state/q2.backlog-close" ] && echo pending)" "in_flight pending"
sweep
check "q: the landed lane with an exit file is torn down on that beat" "$(tore q1)" 1
check "q: the pending close finished: the ticket is closed" "$(rowstate q2 | cut -d' ' -f1)" done
check "q: the close record is gone" "$([ -e "$FM/state/q2.backlog-close" ] && echo pending || echo gone)" gone
check "q: the exit file is gone" "$([ -e "$FM/state/q2.exit" ] && echo kept || echo gone)" gone
check "q: it says so once" "$(grep -c "^lead-sweep: q2's recorded backlog close was finished" "$d/out")" 1
check "q: unlanded work is not torn down and keeps its exit file" "$(tore q3) $([ -e "$FM/state/q3.exit" ] && echo kept)" "0 kept"
check "q: its ticket is still in flight" "$(rowstate q3)" in_flight
sweep
check "q: a second beat prints nothing about q2" "$(grep -c 'q2' "$d/out" || true)" 0
[ "$fails" -eq 0 ] || { say "FAILED: $fails"; exit 1; }
say "PASS: lead-sweep"
