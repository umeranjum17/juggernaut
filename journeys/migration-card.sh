#!/usr/bin/env bash
# done-done journey: drive the real bin/jg-migration-card.sh and sign-off-axi against a disposable
# board. Two consecutive merges each post a fresh card with a view page, dismiss the predecessor
# and record a captain digest. Only the forge (gh) is faked.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
LOG=$OUT/${RUN_ID:-migration-card}.log
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export JG_HOME=$T/home SIGN_OFF_HOME=$T/signoff PATH="$T/bin:$PATH"
mkdir -p "$JG_HOME/config" "$JG_HOME/state" "$T/bin" "$T/board"
B=$T/board/decisions.json
cat > "$T/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$3" in
  */1) echo '{"baseRefName":"release/c-2","title":"Queue paths move","additions":100,"deletions":200}' ;;
  */2) echo '{"baseRefName":"release/c-2","title":"Queue switch live","additions":1200,"deletions":2100}' ;;
  *) echo '{"baseRefName":"release/c-2","title":"Delete the old path","additions":300,"deletions":4800}' ;;
esac
SH
chmod +x "$T/bin/gh"
printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><rect width="8" height="8"/></svg>' > "$T/board/icon.svg"
{
  sign-off-axi project --name juggernaut --icon icon.svg "$B"
  printf 'branch=release/c-2\ntarget=31832\nboard=%s\ncard=card-live\nproject=juggernaut\nbaseline-deleted=9446\nbaseline-added=13174\n' "$B" > "$JG_HOME/config/migration-card"
  for n in 1 2 3; do bash "$REPO/bin/jg-migration-card.sh" merge "https://github.com/acme/app/pull/$n"; done
  echo "== board"; sign-off-axi list "$B" --full
  echo "== captain digests"; cat "$JG_HOME/state/branch-outcomes.jsonl"
  echo "== page"; cat "$T/board/reports/card-live-3/index.html"
} >> "$LOG" 2>&1
fails=0
grep -q 'card-live-3,waiting' "$LOG" || fails=1
[ "$(grep -c 'discarded: Replaced by newer' "$LOG")" -ge 2 ] || fails=1
[ "$(grep -c '"verdict":"captain"' "$LOG")" -ge 2 ] || fails=1
grep -q '16,546 of 31,832' "$LOG" || fails=1
[ "$fails" = 0 ] || { echo "FAIL: see log" >> "$LOG"; exit 1; }
{
  echo "== result: what a reader can now see"
  echo "cards posted, one fresh key per merge: $(grep -o '^  card-live-[0-9]' "$LOG" | tr -d ' ' | sort -u | paste -sd' ')"
  echo "previous cards shown as replaced: $(grep -c 'discarded: Replaced by newer' "$LOG")"
  echo "current card title: $(grep 'card-live-3,waiting' "$LOG" | cut -d'"' -f2)"
  echo "captain digests recorded: $(grep -c '"verdict":"captain"' "$LOG")"
  grep -o 'Migration milestone: [^\\]*' "$LOG" | sed 's/^/milestone: /'
} >> "$LOG"
jq -n --arg v "$(git -C "$REPO" rev-parse --short HEAD)" '{target: {version: $v}, start: "a board with no migration card posted yet and a release branch with 9,446 lines deleted", steps: ["merge three changes into the release branch, one after another", "read the board and the captain digests after each merge"], result: "each merge posted a fresh card with the running total against 31,832, the previous card shows as replaced, and a milestone recorded a three-line digest"}' > "$OUT/steps.json"
