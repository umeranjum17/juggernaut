#!/usr/bin/env bash
# done-done journey: drive the real bin/jg-proof-attach.sh, merge-card and sign-off-axi against a
# disposable board: a UI card with media is accepted, a text-only UI card is refused, a screen-free
# change is allowed text-only with a sealed receipt. Only the forge (gh) is faked.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-proof-attach}.log
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
HEAD=0123456789abcdef0123456789abcdef01234567
PR=https://github.com/acme/app/pull/7
export JG_HOME=$T/home SIGN_OFF_HOME=$T/signoff PATH="$T/fakebin:$PATH" STUB_BODY=$T/body STUB_HEAD=$HEAD
mkdir -p "$JG_HOME/data" "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/usr/bin/env bash
all="$*"
case " $* " in
  *" edit "*) cp -- "${all##*--body-file }" "$STUB_BODY" ;;
  *headRefOid*) echo "$STUB_HEAD" ;;
  *) cat -- "$STUB_BODY" ;;
esac
SH
chmod +x "$T/fakebin/gh"
B=$T/board.json
fails=0
step() {  # <label> <want-exit> <task>
  local out rc=0
  out=$(bash "$REPO/bin/jg-proof-attach.sh" attach ready "$3" --pr "${4:-$PR}" --board "$B" 2>&1) || rc=$?
  printf '== %s (exit %s)\n%s\n' "$1" "$rc" "$out" >> "$LOG"
  [ "$rc" = "$2" ] || { echo "FAIL $1: want exit $2 got $rc" >> "$LOG"; fails=1; }
}
printf '## Checks\noutcome: Sign-in works\n' > "$T/body"
mkdir -p "$JG_HOME/data/ui-ok" "$JG_HOME/data/ui-bare" "$JG_HOME/data/lib-ok/.done-done/runs"
cat > "$T/screen.html" <<'HTML'
<!doctype html><meta name=viewport content="width=device-width"><body style="font:16px sans-serif;margin:24px"><h1>Sign in</h1><p>Enter your email to continue.</p><input style="box-sizing:border-box;width:100%;padding:12px;font-size:16px" value="you@example.com"><button style="margin-top:16px;padding:12px 24px;font-size:16px">Continue</button></body>
HTML
done-done look "file://$T/screen.html" --out "$JG_HOME/data/ui-ok/screen.png" >> "$LOG" 2>&1 || { echo "FAIL: could not capture the screen" >> "$LOG"; exit 1; }
rm -f "$JG_HOME/data/ui-ok/screen.dom.json"
step "UI work with media is accepted" 0 ui-ok
step "UI work without media (text-only card) is refused" 1 ui-bare
cardstep() {  # <label> <want-exit> <task> <pr>: the done-time picture rule asks the board
  local out rc=0
  out=$(bash "$REPO/bin/jg-proof-attach.sh" card "$3" --pr "$4" --head "$HEAD" --board "$B" 2>&1) || rc=$?
  printf '== %s (exit %s)\n%s\n' "$1" "$rc" "$out" >> "$LOG"
  [ "$rc" = "$2" ] || { echo "FAIL $1: want exit $2 got $rc" >> "$LOG"; fails=1; }
}
cardstep "done for UI work whose picture card is on the board passes" 0 ui-ok "$PR"
cardstep "done for UI work with no card is refused, naming the command" 1 ui-nocard https://github.com/acme/app/pull/9
printf '## Checks\nscreen: none\noutcome: Parser is faster\n' > "$T/body"
printf '{"schema":1,"exit":0,"dirty":false,"commit":"%s","run_id":"20261029T000000Z-01234567-ab","started_at":"1","files":["out.txt"]}' "$HEAD" > "$JG_HOME/data/lib-ok/.done-done/runs/r.json"
step "non-UI work with a sealed receipt is allowed text-only" 0 lib-ok https://github.com/acme/app/pull/8
printf '== board\n%s\n' "$(sign-off-axi list "$B" --json --full | jq -c '.decisions[] | {key, media: (.media // [] | length)}')" >> "$LOG"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-proof-attach.sh at this commit"},
 "start":"a disposable home and an empty sign-off board, with the real sign-off-axi and merge-card",
 "steps":["attach a ready card for UI work that has a real screenshot","attach a ready card for UI work that has no media","attach a ready card for screen-free work that has a sealed receipt","ask the done rule about UI work whose card is posted, and about UI work with no card"],
 "result":"the screenshot card is posted with one media file, the text-only UI card is refused with the fix named, and the screen-free card is posted text-only; the done rule passes the posted card and refuses a UI change with none, printing the one command that posts it"}
J
exit "$fails"
