#!/usr/bin/env bash
# Journey: a finished Recon raises one alert with the next items, and then arms no owner timer.
# The check (core/recon-ready/ready.sh) and the timer library's quiet rule (core/wait-timers) are the real ones; the gate is
# the real bin/jg-recon-gate.sh for a quick Recon and a recorder for the refusal case.
# a) a Recon with a report, a done line and a passing gate prints one wake line naming the report, its answer, its next items
#    and its open decisions; a rerun prints nothing; a revised report is announced again;
# b) a Recon whose gate refuses, a ship, a Recon still working and a Recon with no report print nothing;
# c) a Recon waiting on its owner (paused, wait=owner) arms an owner timer until its alert exists and none after it.
# Usage: tests/jg-recon-ready.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home
mkdir -p "$H/state" "$H/data" "$H/bin"
LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/recon-ready.log}
fails=0
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
has() { case $2 in *"$3"*) say "ok: $1" ;; *) say "FAIL: $1 (missing: $3 in: $2)"; fails=$((fails + 1)) ;; esac; }

mk() { # <task> <kind> <status line> [report]
  printf 'kind=%s\n' "$2" > "$H/state/$1.meta"
  printf '%s\n' "$3" > "$H/state/$1.status"
  mkdir -p "$H/data/$1"
  printf 'Recon depth: quick\n' > "$H/data/$1/brief.md"
  [ -z "${4:-}" ] || printf '%s\n' "$4" > "$H/data/$1/report.md"
}
REPORT='## 1. Answer

Use one queue for all alerts.

## 8. Implementation plan

| Slice | Outcome | Proof | Size | Risk | Depends |
|---|---|---|---|---|---|
| Queue table | one table | test | S | low | none |
| Alert wiring | alerts read it | test | S | low | 1 |

## 10. Open decisions

| Question | Options |
|---|---|
| Keep old queue? | yes, no |'
cp "$ROOT/bin/jg-recon-gate.sh" "$H/bin/"
mk r1 scout 'done [at=1]: report ready' "$REPORT"
mk r2 scout 'done [at=1]: report ready' "$REPORT"
mk r3 scout 'working [at=1]: reading' "$REPORT"
mk r4 scout 'done [at=1]: report ready'
mk s1 ship 'done [at=1]: ready' "$REPORT"
# shellcheck disable=SC2016 # the stub expands its own arguments when run
printf '#!/usr/bin/env bash\ncase "$1" in r2) echo "recon gate: refused" >&2; exit 1 ;; *) echo "recon gate: PASS - $1" ;; esac\n' > "$H/bin/gate"
chmod +x "$H/bin/gate"
export JG_RECON_READY_GATE=$H/bin/gate

out=$("$ROOT/core/recon-ready/ready.sh" check "$H")
check "one line for the one passing Recon" "$(printf '%s\n' "$out" | wc -l)" 1
has "names the report" "$out" "recon-ready: r1 report is ready at data/r1/report.md"
has "carries the answer" "$out" "answer: Use one queue for all alerts."
has "carries the next items" "$out" "next items: Queue table; Alert wiring"
has "counts the open decisions" "$out" "open decisions: 1"
check "a rerun prints nothing" "$("$ROOT/core/recon-ready/ready.sh" check "$H")" ""
printf '\nrevised\n' >> "$H/data/r1/report.md"
has "a revised report is announced again" "$("$ROOT/core/recon-ready/ready.sh" check "$H")" "recon-ready: r1"
check "a refused gate leaves no record" "$([ -e "$H/state/recon-ready/r2" ] && echo yes || echo no)" no
check "no record for a ship, a working Recon or a missing report" "$(ls "$H/state/recon-ready")" r1
unset JG_RECON_READY_GATE
mk q1 scout 'needs-decision [at=1]: open call' "$REPORT"
has "the real gate passes a quick Recon" "$(JG_HOME=$H "$ROOT/core/recon-ready/ready.sh" check "$H")" "recon-ready: q1"

# c) the owner timer: the library's own quiet rule, over the same state directory.
mk w1 scout "paused [at=1] [wait=owner] [reason=review]: report waits" "$REPORT"
quiet() ( export JG_HOME=$ROOT STATE=$H/state; . "$ROOT/bin/jg-classify-lib.sh"; . "$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh"; jg_wait_timer_quiet "$1" working '' && echo quiet || echo rings )
check "a Recon with no alert keeps its owner timer" "$(quiet w1)" rings
printf 'abc\n' > "$H/state/recon-ready/w1"
check "a Recon with its alert arms no owner timer" "$(quiet w1)" quiet

[ "$fails" -eq 0 ] || { say "recon-ready: $fails failed"; exit 1; }
say "recon-ready: all passed"
