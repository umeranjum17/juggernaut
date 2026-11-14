#!/usr/bin/env bash
# run-proof.sh - the sealed acceptance of the machine tables, run in a throwaway home.
# It runs every tests/jg-machine*.test.sh with a private JG_HOME, HOME and TMPDIR (each test generates its own
# fixtures), then for every shipped table: lint and coverage must pass, the diagram must read (its dot text; the drawn charts are the machine-diagram journey), and one
# illegal corpus line must turn `check` red naming the machine while the clean corpus stays green.
# Exit 0 only when all of that holds. JG_MACHINES_TABLES overrides the table folder under proof.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
jm="$root/bin/jg-machine.sh"
tables=${JG_MACHINES_TABLES:-$root/core/machines/tables}
home=$(mktemp -d) || exit 1
trap 'rm -rf -- "$home"' EXIT
mkdir -p "$home/home" "$home/tmp"
export JG_HOME="$home/home" HOME="$home/home" TMPDIR="$home/tmp"
rc=0
fail() { echo "FAIL: $*"; rc=1; }

for t in "$root"/tests/jg-machine*.test.sh; do
  [ -e "$t" ] || continue
  if bash "$t" >"$home/out" 2>&1; then echo "ok test $(basename "$t")"; else fail "test $(basename "$t")"; cat "$home/out"; fi
done
n=0
for f in "$tables"/*.tsv; do
  [ -e "$f" ] || continue
  m=$(basename "$f" .tsv); [ "$m" = known-baseline ] && continue
  n=$((n + 1))
  JG_MACHINES_TABLES=$tables bash "$jm" check "$m" >/dev/null || fail "check $m"
  JG_MACHINES_TABLES=$tables bash "$jm" coverage "$m" || fail "coverage $m"
  JG_MACHINES_TABLES=$tables bash "$jm" diagram "$m" --dot wide >/dev/null || fail "diagram $m"
  printf 'no-such-state\n' >"$home/bad.corpus"; : >"$home/ok.corpus"
  out=$(JG_MACHINES_TABLES=$tables bash "$jm" check "$m" --corpus "$home/bad.corpus")
  case "$out" in *"bad $m corpus:1"*) ;; *) fail "an illegal corpus line did not turn $m red" ;; esac
  JG_MACHINES_TABLES=$tables bash "$jm" check "$m" --corpus "$home/ok.corpus" >/dev/null || fail "clean corpus on $m"
done
echo "proof: $n shipped tables"
[ "$rc" = 0 ] && echo "PASS run-proof" || echo "FAIL run-proof"
exit "$rc"
