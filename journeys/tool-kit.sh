#!/usr/bin/env bash
# done-done journey: the tool kits (core/tool-kits). It runs every kit's journey.sh and asks.txt found by folder, the cross-kit rules on
# two fixture kits (a named kit wins, build words win, two matches give no kit), and guard 1 of the spending journey on a fixture kit.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
TK=$REPO/core/tool-kits/bin/jg-tool-kit.sh
KITS=$REPO/core/tool-kits/kits FIX=$REPO/core/tool-kits/tests/fixture-kits
T=$(mktemp -d)
fail() { echo "FAIL $*"; : > "$T/fails"; }
asks() {  # <kits folder> <asks file>: every `<kit or none> | <ask>` line must resolve as written
  local want ask got
  while IFS='|' read -r want ask; do
    want=${want// /}; ask=${ask# }
    case $want in ''|'#'*) continue ;; esac
    [ "$want" = none ] || want="specialist $want"
    got=$(JG_TOOL_KITS_DIR=$1 "$TK" resolve "$ask")
    if [ "$got" = "$want" ]; then echo "ok   [$got] $ask"; else fail "ask [$ask]: want [$want] got [$got]"; fi
  done < "$2"
}
spend() {  # <argument or empty> <marker present? yes|no> <label>: run the spending journey on the fixture kit
  local out rc marker=$T/marker ev; ev=$(mktemp -d -p "$T"); rm -f -- "$marker"
  out=$(env JG_TOOL_KITS_DIR="$FIX" TOOL_KIT_SPEND_MARKER="$marker" DONE_DONE_EVIDENCE_ROOT="$ev" bash "$REPO/journeys/tool-kit-spend.sh" ${1:+"$1"} 2>&1); rc=$?
  echo "$3: exit $rc: $out"
  [ "$rc" = 0 ] || fail "$3: exit $rc"
  [ "$([ -e "$marker" ] && echo yes || echo no)" = "$2" ] || fail "$3: marker present? want $2"
  if [ "$2" = no ]; then case $out in *"skipped: needs spend approval"*) ;; *) fail "$3: no skipped line" ;; esac; fi
}
{
  echo "--- every kit's asks.txt, then the cross-kit rules on the fixture kits"
  for f in "$KITS"/*/asks.txt; do asks "$KITS" "$f"; done
  asks "$FIX" "$FIX/asks.txt"
  echo "--- the spending journey: guard 1 holds, on a fixture kit whose journey-spend.sh only writes a marker"
  spend '' no "no approval"
  spend --yes no "wrong argument"
  spend --approved yes "approved"
  for j in "$KITS"/*/journey.sh; do
    echo "--- kit journey: $(basename "$(dirname "$j")")"
    bash "$j" || fail "kit journey $j"
  done
} 2>&1 | tee "$OUT/tool-kit-transcript.txt"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut core/tool-kits at this commit, with the installed takeone and sign-off-axi"},
 "start":"a throwaway home with an empty board and no kit receipt",
 "steps":["resolve every ask of every kit's asks.txt and of two fixture kits","run the spending journey with no approval, a wrong value and approval on a fixture kit","make a real takeone motion film, post it to the board, save the receipt and run the check to PASS","break the film, the record, the take, the card, the receipt, the report, the board, the kit name, the kit folder and the check, one at a time"],
 "result":"the real film passes; each broken part is refused with its reason and exit 1; a named kit wins, build words win, two matches give no kit; the spending journey calls nothing without approval"}
J
status=0; [ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
