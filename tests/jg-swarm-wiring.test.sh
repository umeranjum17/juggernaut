#!/usr/bin/env bash
# Journey: core/swarm/wiring.sh wires the swarm check and the word-row upkeep into a home as one watcher check.
# The register script and the two scripts the shim runs are stand-ins that log their calls; the wiring is the real one.
# a) --dry-run prints the shim, the register call and writes nothing; b) a wiring writes the shim (mode 700, three lines),
#    registers `swarm`, the shim runs the words script then the check, and a second run leaves the same file;
# c) a refused registration puts the old shim back, or leaves none; d) a symlinked shim is refused; e) usage errors exit 2.
# Usage: tests/jg-swarm-wiring.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
W=$ROOT/core/swarm/wiring.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
H=$d/home
LOG=$d/calls.log
mkdir -p "$H/state" "$H/bin"
fails=0
LOG_OUT=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/swarm-wiring.log}
say() { printf '%s\n' "$*" | tee -a "${LOG_OUT:-/dev/null}" >&2; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
stand() { printf '#!/usr/bin/env bash\necho "%s $*" >> %q\nexit %s\n' "$2" "$LOG" "${3:-0}" > "$H/bin/$1"; chmod +x "$H/bin/$1"; }
stand jg-check-register.sh register
stand jg-swarm-words.sh words
stand jg-swarm-check.sh check
rc() { set +e; "$@" >"$d/out" 2>"$d/err"; echo $?; set -e; }

# a
check "a1 dry run exits 0" "$(rc "$W" --dry-run "$H")" 0
check "a2 dry run writes nothing" "$([ -e "$H/state/swarm.check.sh" ] && echo 1 || echo 0)$([ -e "$LOG" ] && echo 1 || echo 0)" 00
out=$(cat "$d/out")
for want in "jg-swarm-words.sh" "exec " "would run: env -u JG_STATE_OVERRIDE JG_HOME=$H $H/bin/jg-check-register.sh swarm" "dry run: nothing written"; do
  case $out in *"$want"*) say "ok: a3 dry run prints: $want" ;; *) say "FAIL: a3 dry run misses: $want"; fails=$((fails + 1)) ;; esac
done

# b
check "b1 wiring exits 0" "$(rc "$W" "$H")" 0
SHIM=$H/state/swarm.check.sh
want=$(printf '#!/usr/bin/env bash\n%q %q\nexec %q check %q\n' "$H/bin/jg-swarm-words.sh" "$H" "$H/bin/jg-swarm-check.sh" "$H")
check "b2 shim is the three lines" "$(cat "$SHIM")" "$want"
check "b3 shim mode is 700" "$(stat -c %a "$SHIM")" 700
check "b4 register was called with swarm" "$(cat "$LOG")" "register swarm"
: > "$LOG"; "$SHIM"
check "b5 shim runs the words script, then the check" "$(tr '\n' ',' < "$LOG")" "words $H,check check $H,"
before=$(cat "$SHIM")
check "b6 a second wiring exits 0" "$(rc "$W" "$H")" 0
check "b7 and leaves the same file" "$(cat "$SHIM")" "$before"

# c
stand jg-check-register.sh register 1
check "c1 refused registration exits 1" "$(rc "$W" "$H")" 1
check "c2 old shim is back" "$(cat "$SHIM")" "$before"
rm "$SHIM"
check "c3 refused registration with no old shim exits 1" "$(rc "$W" "$H")" 1
check "c4 and leaves none" "$([ -e "$SHIM" ] && echo 1 || echo 0)" 0
stand jg-check-register.sh register

# d
ln -s "$d/elsewhere" "$SHIM"
check "d1 a symlinked shim is refused" "$(rc "$W" "$H")" 1
check "d2 and nothing is written" "$([ -e "$d/elsewhere" ] && echo 1 || echo 0)$([ -L "$SHIM" ] && echo L)" 0L
rm "$SHIM"

# e
check "e1 no argument exits 2" "$(rc "$W")" 2
mkdir "$d/bare"
check "e2 a folder with no register script exits 2" "$(rc "$W" "$d/bare")" 2

[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say "all checks passed"
