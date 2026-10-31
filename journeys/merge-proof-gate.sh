#!/usr/bin/env bash
# done-done journey: drive the real merge proof gate, bin/jg-merge-alert.sh, sign-off-axi and merge-card
# against a disposable board: a merge with no proof is refused, a merge with proof posts its proof card,
# and a merge alert raised while the board is down is queued and then posted by drain. Only the forge (gh) is faked.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-merge-proof-gate}.log
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
HEAD=0123456789abcdef0123456789abcdef01234567
PR=https://github.com/acme/app/pull/7
H=$T/home B=$T/board.json
export JG_HOME=$H SIGN_OFF_HOME=$T/signoff PATH="$T/fakebin:$PATH" STUB_BODY=$T/body STUB_HEAD=$HEAD
mkdir -p "$H/config" "$H/state" "$H/data/t1" "$T/fakebin"
printf '#!/bin/sh\nexec x post --board %s "$@"\n' "$B" > "$H/config/post-merge"
printf 'project=/x/projects/app\nharness=claude\nmodel=claude-sonnet-5-5\n' > "$H/state/t1.meta"
cat > "$T/fakebin/gh" <<'SH'
#!/usr/bin/env bash
all="$*"
case " $* " in
  *" edit "*) cp -- "${all##*--body-file }" "$STUB_BODY" ;;
  *headRefOid*) echo "$STUB_HEAD" ;;
  *"--json title"*) echo "Show merge alerts on the board" ;;
  *) cat -- "$STUB_BODY" ;;
esac
SH
chmod +x "$T/fakebin/gh"
printf '## Checks\noutcome: Merge alerts show on the board\n' > "$T/body"
fails=0
gate() {  # <label> <want-exit>
  local out rc=0
  # shellcheck disable=SC2016 # the quoted script reads its own positional arguments
  out=$(bash -c '. "$1/bin/jg-merge-gate-lib.sh"; jg_dod_proof_gate "$2" t1 "$3" "$4"' _ "$REPO" "$H" "$HEAD" "$PR" 2>&1) || rc=$?
  printf '== %s (exit %s)\n%s\n' "$1" "$rc" "$out" >> "$LOG"
  [ "$rc" = "$2" ] || { echo "FAIL $1: want exit $2 got $rc" >> "$LOG"; fails=1; }
}
gate "a merge with no proof is refused" 1
cat > "$T/screen.html" <<'HTML'
<!doctype html><meta name=viewport content="width=device-width"><body style="font:16px sans-serif;margin:24px"><h1>Sign in</h1><p>Enter your email to continue.</p><input style="box-sizing:border-box;width:100%;padding:12px;font-size:16px" value="you@example.com"><button style="margin-top:16px;padding:12px 24px;font-size:16px">Continue</button></body>
HTML
done-done look "file://$T/screen.html" --out "$H/data/t1/screen.png" >> "$LOG" 2>&1 || { echo "FAIL: could not capture the screen" >> "$LOG"; exit 1; }
rm -f "$H/data/t1/screen.dom.json"
gate "a merge with proof posts its proof card" 0
printf '== proof card\n%s\n' "$(sign-off-axi list "$B" --json --full | jq -c '.decisions[] | {key, media: (.media // [] | length)}')" >> "$LOG"
alert() { bash "$REPO/bin/jg-merge-alert.sh" "$@" 2>&1; }
mv "$B" "$B.away"
printf '== alert while the board is down\n%s\n' "$(alert post t1 --pr "$PR")" >> "$LOG"
[ -e "$H/state/merge-alerts/pending/mergealert-acme-app-pull-7.json" ] || { echo "FAIL: the alert was not queued" >> "$LOG"; fails=1; }
mv "$B.away" "$B"
printf '== drain\n%s\n' "$(alert drain)" >> "$LOG"
[ -e "$H/state/merge-alerts/sent/mergealert-acme-app-pull-7.json" ] || { echo "FAIL: drain did not post the alert" >> "$LOG"; fails=1; }
printf '== board\n%s\n' "$(sign-off-axi list "$B" --json --full | jq -c '.decisions[] | {key, title}')" >> "$LOG"
cat > "$OUT/steps.json" <<'J'
{"target":{"version":"juggernaut bin/jg-merge-gate-lib.sh and bin/jg-merge-alert.sh at this commit"},
 "start":"a disposable home with a board, the real sign-off-axi and merge-card, and a task whose PR has no proof",
 "steps":["run the merge proof gate for a task with no proof","add a screenshot and run the gate again","raise the merge alert while the board is missing","bring the board back and drain the queue"],
 "result":"the first gate run refuses the merge, the second posts the proof card, the alert waits in the queue while the board is down, and drain puts it on the board"}
J
exit "$fails"
