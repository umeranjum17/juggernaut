#!/usr/bin/env bash
# takeone kit journey, free (no model call): make a real `takeone motion --no-ai` film, post it to a throwaway board, save the
# receipt and run `check` to PASS; then break each part in turn and see exit 1 with its reason.
# Run by journeys/tool-kit.sh. It writes its transcript, the film, the receipt and the card into $DONE_DONE_EVIDENCE_ROOT.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through journeys/tool-kit.sh or done-done}
TK=$REPO/core/tool-kits/bin/jg-tool-kit.sh
T=$(mktemp -d)
H=$T/home TASK=t1 BOARD=$T/board/.sign-off/decisions.json
D=$H/data/$TASK
mkdir -p "$H/state" "$H/config" "$D" "$T/board"
echo "--board $BOARD" > "$H/config/post-merge"
unset JG_PROOF_BOARD JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_TOOL_KITS_DIR
export JG_HOME=$H
fail() { echo "FAIL $*"; : > "$T/fails"; }
run() {  # <label> <want exit> <text the output must hold> <command...>
  local label=$1 want=$2 text=$3 out rc; shift 3
  out=$("$@" 2>&1); rc=$?; echo "\$ ${*#"$REPO"/} -> exit $rc: $out" | cut -c1-300
  [ "$rc" = "$want" ] || fail "$label: want exit $want, got $rc"
  case $out in *"$text"*) ;; *) fail "$label: output lacks [$text]" ;; esac
}
swap() {  # <file> <jq filter>: change a saved JSON file in place (the caller keeps a copy to restore)
  jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
{
  echo "--- the scaffold's text carries the kit line and this task's folders"
  "$TK" section takeone "$TASK" > "$D/brief.md"
  if ! { grep -qx 'Tool kit: takeone' "$D/brief.md" && grep -q "$D/kit/film" "$D/brief.md"; }; then fail "section: no kit line or no folder"; fi
  echo "--- preflight, then a check with no receipt"
  run doctor 0 "" takeone doctor
  run no-receipt 1 "no kit receipt" "$TK" check "$TASK"
  echo "--- a real motion film of a page, posted to the throwaway board"
  cat > "$T/page.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Umer's task board</title>
<style>body{font:20px sans-serif;margin:40px;background:#fafafa}li{margin:8px 0}</style></head><body><h1>Umer's task board</h1><ul><li>Write the report</li><li>Review the film</li></ul></body></html>
HTML
  gate=$REPO/core/host-memory/bin/jg-mem-gate.sh
  [ -x "$gate" ] || gate=$(command -v env)
  "$gate" takeone motion "$T/page.html" --out "$D/kit/film" --no-ai --title "Umer's task board" --subtitle "A kit proof" >/dev/null || fail "takeone motion"
  FILM=$D/kit/film
  post() { sign-off-axi post "$("$TK" board)" --type evidence --title "Demo film of the test page" --about "TakeOne made this film" --media "$1" --filer "$TASK" >/dev/null && jq -r '.items[-1].key' "$BOARD"; }
  KEY=$(post "$FILM/out/motion.mp4")
  echo "card $KEY"
  echo "--- receipt, then a check that waits for the report, then PASS"
  run receipt 0 "receipt saved" "$TK" receipt "$TASK" --card "$KEY" "$FILM"
  run no-report 1 "report.md is missing or does not name the card" "$TK" check "$TASK"
  printf '%s\n' "Filmed Umer's task board page." "TakeOne 0.4.0." "The film runs 9.9 s." "Card $KEY." "Receipt $D/kit/receipt.json." > "$D/report.md"
  run pass 0 "PASS - takeone" "$TK" check "$TASK"
  echo "--- break each part: every one is refused with its reason"
  REC=$D/kit/record MEDIA=$T/board/.sign-off/$(jq -r '.items[-1].media[0].path' "$BOARD")
  mv "$MEDIA" "$T/film.hold"; run film-missing 1 "is missing beside the board" "$TK" check "$TASK"; mv "$T/film.hold" "$MEDIA"
  cp "$REC/render.json" "$T/r.save"; swap "$REC/render.json" '.frames = 1200'
  run record-disagrees 1 "render.json says 1200 frames" "$TK" check "$TASK"; cp "$T/r.save" "$REC/render.json"
  cp "$REC/take.json" "$T/t.save"; echo '{"id":"x"}' > "$REC/take.json"
  run not-motion 1 "not a motion take" "$TK" check "$TASK"; cp "$T/t.save" "$REC/take.json"
  ffmpeg -v error -i "$MEDIA" -t 3 -c copy "$T/other.mp4"; OTHER=$(post "$T/other.mp4")
  "$TK" receipt "$TASK" --card "$OTHER" "$FILM" >/dev/null; run other-film 1 "the card holds another film" "$TK" check "$TASK"
  "$TK" receipt "$TASK" --card update-99 "$FILM" >/dev/null; run no-card 1 "holds no evidence card under key update-99" "$TK" check "$TASK"
  "$TK" receipt "$TASK" --card "$KEY" "$FILM" >/dev/null; run restored 0 "PASS" "$TK" check "$TASK"
  mkdir -p "$T/nofilm"; cp "$REC"/*.json "$T/nofilm/"
  run receipt-no-film 1 "no output file" "$TK" receipt "$TASK" --card "$KEY" "$T/nofilm"
  cp "$D/kit/receipt.json" "$T/rc.save"
  swap "$D/kit/receipt.json" '.tool.version = "0.3.9"'; run old-tool 1 "older than the kit's minimum" "$TK" check "$TASK"
  swap "$D/kit/receipt.json" '.kit = "other"'; run wrong-kit 1 "the instructions name 'takeone'" "$TK" check "$TASK"; cp "$T/rc.save" "$D/kit/receipt.json"
  printf 'Filmed it.\n' > "$D/report.md"; run report-no-key 1 "report.md is missing or does not name the card" "$TK" check "$TASK"
  printf 'Card %s.\n' "$KEY" > "$D/report.md"
  mv "$H/config/post-merge" "$T/pm.hold"; run no-board 1 "no board found" "$TK" check "$TASK"; mv "$T/pm.hold" "$H/config/post-merge"
  cp "$D/brief.md" "$T/b.save"; echo 'Tool kit: nope' > "$D/brief.md"; run unknown-kit 1 "unknown kit 'nope'" "$TK" check "$TASK"; cp "$T/b.save" "$D/brief.md"
  JG_TOOL_KITS_DIR=$T/nokits run kit-folder-gone 1 "unknown kit 'takeone'" "$TK" check "$TASK"
  mkdir -p "$T/kits"; cp -r "$REPO/core/tool-kits/kits/takeone" "$T/kits/"; printf '#!/bin/sh\nexit 7\n' > "$T/kits/takeone/check.sh"
  JG_TOOL_KITS_DIR=$T/kits run check-crashes 1 "check crashed (exit 7)" "$TK" check "$TASK"
  run still-passes 0 "PASS" "$TK" check "$TASK"
  cp "$FILM/out/motion.mp4" "$OUT/takeone-journey-film.mp4"; cp "$D/kit/receipt.json" "$OUT/takeone-journey-receipt.json"; cp "$D/kit/card.json" "$OUT/takeone-journey-card.json"
} 2>&1 | tee "$OUT/takeone-journey-transcript.txt"
status=0; [ -e "$T/fails" ] && status=1
rm -rf -- "$T"
exit "$status"
