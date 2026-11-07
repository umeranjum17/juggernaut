#!/usr/bin/env bash
# done-done journey: the real bin/jg-backlog.sh against a real Beads backlog. A [captain-ask]
# ticket with no delivery cannot be closed, cancelled or deleted without the captain's quoted words
# or an answered confirm card; an ordinary ticket is unaffected; the quote lands in the ticket note.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
mkdir -p "$T/code" "$T/home/state"
# shellcheck source=core/lib/beads-test-env.sh
. "$REPO/core/lib/beads-test-env.sh"
core_beads_home "$REPO" "$T/home"
export JG_HOME="$T/home" JG_ROOT_OVERRIDE="$T/code"
unset JG_DATA_OVERRIDE JG_STATE_OVERRIDE
jg() { (cd "$T/code" && "$REPO/bin/jg-backlog.sh" "$@"); }
hold() { (cd "$T/code" && "$REPO/bin/jg-captain-hold.sh" "$@"); }
expect() {  # <label> <want rc> <got rc>
  [ "$2" = "$3" ] || { echo "FAIL $1: want exit $2 got $3"; echo x >> "$T/fails"; }
}
step() {  # <label> <want rc> <args...>
  local label=$1 want=$2 rc=0; shift 2
  echo "--- $label"; jg "$@" 2>&1 | sed 's/^/    /'; rc=${PIPESTATUS[0]}
  expect "$label" "$want" "$rc"
}
{
  for id in jg-rejected jg-quoted jg-carded jg-plain; do jg add "$id" "$([ $id = jg-plain ] && echo "[feature] ordinary" || echo "[captain-ask] $id")" --body "asked: $id" >/dev/null; done
  printf 'Yes.\n' > "$T/answer.txt"
  jg add jg-card1 "[captain-ask] confirm closing carded" --body "asked: close jg-carded" >/dev/null
  jg add jg-card2 "[captain-ask] confirm closing rejected" --body "asked: close jg-rejected" >/dev/null
  hold hold jg-card2 --reason "confirm" >/dev/null
  hold hold jg-card1 --reason "confirm" >/dev/null && hold answer jg-card1 --decision-file "$T/answer.txt" >/dev/null
  step "close it, no words" 2 done jg-rejected
  step "blank quote" 2 done --captain-quote "  " jg-rejected
  step "card that names it but is not answered" 2 done --confirm-card jg-card2 jg-rejected
  step "its own recorded answer is not a confirm card" 2 done --confirm-card jg-carded jg-carded
  step "card that names another ticket" 2 done --confirm-card jg-card1 jg-rejected
  step "quote closes it" 0 done --captain-quote "yes, cancel the rejected ticket" jg-quoted
  step "answered card closes it" 0 done --confirm-card jg-card1 jg-carded
  step "ordinary ticket unaffected" 0 done jg-plain
  echo "--- the record"
  cat "$T/home/data/captain-closures.md"
  grep -q "captain words: yes, cancel the rejected ticket" "$T/home/data/captain-closures.md" || { echo "FAIL: quote not recorded"; echo x >> "$T/fails"; }
  jg show jg-carded --full | grep -q "Closed on answered board confirm card: jg-card1" || { echo "FAIL: card not in ticket note"; echo x >> "$T/fails"; }
  jg show jg-rejected | grep -q "state: queued" || { echo "FAIL: refused ticket left the backlog"; echo x >> "$T/fails"; }
} 2>&1 | tee "$OUT/captain-close-gate-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-backlog.sh and bin/jg-captain-ask-lib.sh at this commit"},
 "start":"a disposable juggernaut home with a real Beads backlog",
 "steps":["try to cancel and close a captain-asked ticket with no words, a blank quote and an unanswered card","close one with a quote and one with an answered confirm card","remove an ordinary ticket"],
 "result":"the captain-asked ticket stays until his words or an answered card are given, and the words are recorded; an ordinary ticket is unaffected"}
J
status=0
[ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
