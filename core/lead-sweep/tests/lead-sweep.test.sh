#!/usr/bin/env bash
# Journey: lead-sweep.sh check against a fixture home with real git clones and a recording teardown (it refuses a lane with
# uncommitted work or a scout with no gate pass, the way jg-teardown.sh does) and a gh-axi stub.
# a) a done lane whose head is on the trunk is torn down, once, with the lane id and no --force;
# b) a done lane whose head is on the trunk but holds uncommitted work is refused and reported once; the next beat prints
#    nothing; a changed reason is reported again;
# c) a Recon with a report, Main's relayed move, a quiet inbox and a passing gate is closed; a Recon whose gate refuses is reported once; a Recon with no report is left;
# l) a Recon with a report is left until its ticket has the relayed move and its inbox has been quiet 60 minutes, whatever its done
#    line, a gone agent or a passed critic; a message in that hour restarts the hour; an agent that ends at its done line keeps its copy;
# g) a done lane still on its recorded base (no commit of its own) is never torn down;
# d) a working lane, a done lane not landed, a lead and a lane a landing is running for are never touched;
# e) a done lane whose pull request is merged is torn down; an open one is not, and the forge is asked once per window;
# h) a done lane that has not landed has its agent ended once, with its copy and branch kept; one whose agent is gone is not touched;
# i) a lane parked (paused, blocked, needs-decision) is left until 24 h (2 h with no commit of its own), then parked once, never forced;
# j) a lane that never started is left for 30 minutes, relaunched once, then parked; a lane that started is not relaunched;
# k) a lane whose agent is gone is cleaned up when its work landed, and left alone when it did not.
# Usage: lead-sweep/tests/lead-sweep.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT   # a worker's injected hooks path and identity must not reach the fixture clone
mkdir -p "$HOME"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$P"
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
[ "$2" != exit ] || date +%s > "$JG_STATE_OVERRIDE/$1.exit"
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
sweep() { : > "$STUB_LOG"; "$SRC/lead-sweep.sh" check "$FM" > "$d/out" 2>&1; }
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
check "l: a quiet hour after the relay cleans it up, once" "$(tore lrec)" 1
check "l: it says why" "$(grep -c '^lead-sweep: lrec cleaned up (its report exists and Main relayed it)' "$d/out")" 1
# f: the wiring installs a shim that registers, and the unwiring removes it
if [ -x "$SRC/../../bin/jg-check-register.sh" ]; then
  mkdir -p "$FM/bin"; cp "$SRC/../../bin/"jg-*.sh "$FM/bin/" 2>/dev/null || true
  if XDG_DATA_HOME=$d/share "$SRC/wiring.sh" "$FM" > "$d/wire" 2>&1; then
    check "f: the wiring registers the check" "$(head -n 1 "$FM/state/lead-sweep.check-trust")" jg-custom-check-v1
  else say "FAIL: f: wiring: $(cat "$d/wire")"; fails=$((fails + 1)); fi
  XDG_DATA_HOME=$d/share "$SRC/unwiring.sh" "$FM" > /dev/null 2>&1; check "f: the unwiring removes the shim" "$(ls "$FM/state/lead-sweep.check.sh" 2>/dev/null || echo gone)" gone
fi
[ "$fails" -eq 0 ] || { say "FAILED: $fails"; exit 1; }
say "PASS: lead-sweep"
