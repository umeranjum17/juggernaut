#!/usr/bin/env bash
# done-done journey: drive the real bin/jg-migration-card.sh and sign-off-axi against a disposable
# board. Two consecutive merges each post a fresh card with a view page, dismiss the predecessor
# and record a captain digest. Then the card's live parts are measured rather than remembered: the
# real probe reports every part of this machine in the page, and the watcher's own cadence pass
# keeps it current while printing nothing. Only the forge (gh) is faked.
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

# The live side: a real probe of the machine this runs on, then the cadence pass.
{
  echo "== live probe on this machine"
  bash "$REPO/bin/jg-migration-card.sh" live
  echo "card: $(sed -n 's/^card=//p' "$JG_HOME/config/migration-card")"
  echo "== live rows (part, state, measured)"
  cat "$JG_HOME/data/migration-card/live.tsv"
  echo "== the cadence pass, nothing changed"
  bash "$REPO/bin/jg-migration-card.sh" arm
  cadence_out=$(bash "$JG_HOME/state/migration-card.check.sh" 2>&1)
  echo "stdout: '$cadence_out'"
  echo "cards now: $(find "$T/board/reports" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "== one part changes: config/crew-dispatch.json appears with two rules"
  printf '{"rules":[{"match":"a"},{"match":"b"}]}\n' > "$JG_HOME/config/crew-dispatch.json"
  cadence_out=$(bash "$JG_HOME/state/migration-card.check.sh" 2>&1)
  echo "stdout: '$cadence_out'"
  echo "cards now: $(find "$T/board/reports" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "card now: $(sed -n 's/^card=//p' "$JG_HOME/config/migration-card")"
  echo "== the part table as the captain reads it"
  grep -o '<tr><td>[^<]*</td><td>[^<]*</td><td>[^<]*' "$T/board/reports/$(sed -n 's/^card=//p' "$JG_HOME/config/migration-card")/index.html"
} >> "$LOG" 2>&1
rows=$(sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | grep -c $'\t')
[ "$rows" = 15 ] || { echo "FAIL: the probe wrote $rows part rows, not 15" >> "$LOG"; fails=1; }
sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | grep -q $'^wake queue\t' || { echo "FAIL: the wake queue row is missing" >> "$LOG"; fails=1; }
sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | awk -F'\t' 'NF >= 3 && $2 !~ /^(live|pending|absent)$/ { found=1 } END { exit !found }' &&
  { echo "FAIL: a part has no measured state, so the card would leave it blank" >> "$LOG"; fails=1; }
grep -q "^stdout: ''" "$LOG" || { echo "FAIL: the cadence pass printed a line, which would cost a wake" >> "$LOG"; fails=1; }
grep -q 'What runs on this machine' "$LOG" || { echo "FAIL: the card carries no live section" >> "$LOG"; fails=1; }
[ "$fails" = 0 ] || { echo "FAIL: see log" >> "$LOG"; exit 1; }
{
  echo "== result: what a reader can now see"
  echo "cards posted, one fresh key per merge: $(grep -o '^  card-live-[0-9]' "$LOG" | tr -d ' ' | sort -u | paste -sd' ')"
  echo "previous cards shown as replaced: $(grep -c 'discarded: Replaced by newer' "$LOG")"
  echo "current card title: $(grep 'card-live-3,waiting' "$LOG" | cut -d'"' -f2)"
  echo "captain digests recorded: $(grep -c '"verdict":"captain"' "$LOG")"
  jq -r '"digest (" + (.summary|split("\n")|length|tostring) + " lines): " + (.summary|gsub("\n";" | "))' "$JG_HOME/state/branch-outcomes.jsonl"
  echo "parts measured by the probe: $(sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | grep -c $'\t')"
  echo "parts measured as live: $(sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | awk -F'\t' '$2 == "live"' | wc -l)"
  echo "parts measured as pending: $(sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | awk -F'\t' '$2 == "pending"' | wc -l)"
  echo "parts measured as not installed: $(sed -n '/^== live rows/,/^== the cadence/p' "$LOG" | awk -F'\t' '$2 == "absent"' | wc -l)"
  echo "cadence passes that printed nothing: $(grep -c "^stdout: ''" "$LOG")"
} > "$T/result"
cat "$T/result" >> "$LOG"
jq -n --arg v "$(git -C "$REPO" rev-parse --short HEAD)" '{target: {version: $v}, start: "a board with no migration card posted yet and a release branch with 9,446 lines deleted", steps: ["merge three changes into the release branch, one after another", "read the board and the captain digests after each merge", "probe every part of the stack on this machine and read the card", "run the watcher cadence pass with nothing changed, then with one part changed"], result: "each merge posted a fresh card with the running total against 31,832, the previous card shows as replaced, and a milestone recorded a three-line digest; the card also shows every part of this machine as runs here, pending or not installed, with what was measured, and the cadence pass refreshed it while printing nothing so it costs no wake and no model turn"}' > "$OUT/steps.json"
