#!/usr/bin/env bash
# done-done journey: the release branch pushes its own readiness, driven by the
# real script against a real release branch and a real board.
#
# A branch whose features are complete, carried and green raises one approve card
# at once; a second pass inside the configured wait resends nothing; past the wait
# the release itself queues one alert; that alert never repeats; and a changed
# release replaces its card. The provider facts come from a recording `gh` on
# PATH, because the evidence run has no network; every git fact is measured from
# the fixture repository and every card is posted by the real board.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
RR=$REPO/bin/jg-release-readiness.sh
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/release-readiness.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

# The board lives in the fixture home, so nothing here can touch a real one.
export HOME=$T
(cd "$T" && sign-off-axi init >/dev/null 2>&1) || fail "could not create the proof board"
BOARD=$T/.sign-off/decisions.json
[ -f "$BOARD" ] || fail "the proof board was not created"

# A world: a bare origin, a seed clone that plays the forge, and the home whose
# copy the pass reads. release/c-2 starts at the default branch and carries two
# merged features.
git init -q --bare "$T/origin.git" || fail "cannot create the fixture origin"
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null || fail "cannot clone the fixture"
printf 'v1\n' > "$T/seed/README.md"
git -C "$T/seed" add -A
git -C "$T/seed" commit -qm c1 || fail "cannot seed the fixture"
git -C "$T/seed" push -q origin main || fail "cannot push the fixture"
git -C "$T/seed" checkout -qb release/c-2
printf 'feature one\n' > "$T/seed/one.txt"
git -C "$T/seed" add -A && git -C "$T/seed" commit -qm 'Add the first feature (#11)'
printf 'feature two\n' >> "$T/seed/one.txt"
git -C "$T/seed" commit -qam 'Add the second feature (#12)'
git -C "$T/seed" push -q origin release/c-2 || fail "cannot push the release branch"
git clone -q "$T/origin.git" "$T/copy" 2>/dev/null || fail "cannot clone the copy"
git -C "$T/copy" remote set-head origin main >/dev/null 2>&1 || true
git -C "$T/copy" remote add forge "file://$T/origin.git"
git -C "$T/copy" remote set-url origin https://github.com/acme/thing.git
mkdir -p "$T/home"/{config,data,state} "$T/bin"
printf 'project-dir=%s\nwait-hours=6\n' "$T/copy" > "$T/home/config/release-readiness"

# The provider facts. The evidence run has no network, so this records the two
# reads the pass makes: the open pull requests targeting the release (none) and
# the checks on its tip (green).
printf '0\n' > "$T/gh-open"
printf 'completed success,completed success\n' > "$T/gh-checks"
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  */pulls\?*) cat "$GH_OPEN" ;;
  */check-runs*) cat "$GH_CHECKS" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_OPEN=$T/gh-open GH_CHECKS=$T/gh-checks

tick() {  # <epoch> -> the pass's own lines in OUTX, the board's answers in the log
  OUTX=$(cd "$T" && bash "$RR" "$T/home" tick --now "$1" 2>"$T/tick.err") || fail "the pass failed"
  log "$OUTX"
  [ ! -s "$T/tick.err" ] || sed 's/^/  /' "$T/tick.err" | tee -a "$LOG" >/dev/null
}
said() { printf '%s\n' "$1" | grep -q -- "$2"; }
show() { (cd "$T" && bash "$RR" "$T/home" show --now "$1" 2>&1); }
live_cards() { sign-off-axi list "$BOARD" --full 2>/dev/null | grep -c ',waiting,'; }

log "== the fixture table"
bash "$REPO/tests/jg-release-readiness.test.sh" 2>&1 | tee -a "$LOG" | tail -20
grep -q '^not ok' "$LOG" && fail "the fixture table failed"

log ""
log "== a release whose features are green raises one approve card"
tick 1800000000
said "$OUTX" '^card: release-c-2-' || fail "a finished release must raise its card: $OUTX"
COUNT=$(live_cards)
log "live cards on the board: $COUNT"
[ "$COUNT" = 1 ] || { sign-off-axi list "$BOARD" --full | tee -a "$LOG" >/dev/null; fail "one card expected, found $COUNT"; }
log "the card the board holds:"
sign-off-axi list "$BOARD" --full | grep -E '^  release-c-2-' | tee -a "$LOG" >/dev/null
log "the digest line for the captain: $(show 1800000000)"

log ""
log "== a second pass inside the 6 h wait: nothing is resent"
tick 1800010000
said "$OUTX" '^unchanged' || fail "a pass inside the wait must resend nothing: $OUTX"
[ "$(live_cards)" = 1 ] || fail "a pass inside the wait must not post another card"
[ ! -s "$T/home/data/release-readiness/alerts.jsonl" ] || fail "nothing alerts before the wait limit"

log ""
log "== past the 6 h wait: the release queues one alert"
tick 1800021601
said "$OUTX" '^alert:' || fail "past the wait limit the release must alert: $OUTX"
NOTE=''
for f in "$T/home/state/inbox"/*.note; do
  [ -e "$f" ] || continue
  NOTE=$f
  break
done
[ -n "$NOTE" ] || fail "the alert must be a durable note"
cat "$NOTE" >> "$LOG"
grep -q 'waited 6 hours for approval' "$NOTE" || fail "the alert must name the wait"
WAKE=$(cat "$T/home/state/.wake-queue" 2>/dev/null || true)
log "the queued check: $WAKE"
case $WAKE in *'check: captain inbox note'*) : ;; *) fail "the alert must queue a check the supervisor drains" ;; esac

log ""
log "== every later pass: the same wait is never alerted again"
tick 1800030000
set -- "$T/home/state/inbox"/*.note
[ "$#" = 1 ] && [ -e "$1" ] || fail "the same wait must not queue a second alert"
[ "$(live_cards)" = 1 ] || fail "an alert must not raise another card"

log ""
log "== a feature lands on the release: one new card replaces the old"
git -C "$T/seed" checkout -q release/c-2
printf 'feature three\n' >> "$T/seed/one.txt"
git -C "$T/seed" commit -qam 'Add a third feature (#13)'
git -C "$T/seed" push -q origin release/c-2 || fail "cannot push the third feature"
git -C "$T/copy" fetch -q forge "release/c-2:refs/remotes/forge/release/c-2" || fail "cannot fetch the release branch"
git -C "$T/copy" update-ref refs/remotes/origin/release/c-2 \
  "$(git -C "$T/copy" rev-parse refs/remotes/forge/release/c-2)"
tick 1800030100
said "$OUTX" '^card: release-c-2-' || fail "a changed release must raise its card: $OUTX"
[ "$(live_cards)" = 1 ] || fail "a changed release must replace its card, not add one"
sign-off-axi list "$BOARD" --full | grep -E '^  release-c-2-' | tee -a "$LOG" >/dev/null
log "the digest line for the captain: $(show 1800030100)"

log ""
log "RESULT: a finished release raised one approve card with its changes, numbers and risks, a second pass inside the wait resent nothing, the release queued one alert past its 6 h limit and never again, and a changed release replaced its own card."
jq -n '{target:{version:"bin/jg-release-readiness.sh from this branch"},
  start:"a fixture repository whose release/c-2 carries two green features, a real board, config/release-readiness at 6 h, and a recording gh on PATH because the evidence run has no network",
  steps:["run the fixture table",
         "pass on a finished release and read the board",
         "pass again inside the 6 h wait",
         "pass past the wait limit and read the durable note and its check",
         "pass once more and read the note count",
         "land a third feature, pass again and read the board"],
  result:"one approve card for a finished release, nothing resent inside the wait, one alert past the limit and never again, and a changed release replacing its card"}' > "$OUT/steps.json"
