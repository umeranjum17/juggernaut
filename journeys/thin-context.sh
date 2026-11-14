#!/usr/bin/env bash
# done-done journey: the supervisor contract has a carrier of its own (thin-context plan, slice TC4a).
# Step 0 (always): tests/jg-contract-carrier.test.sh runs and its log is kept.
# Step 1 (always): bin/jg-contract-carrier.sh names one proof for each of the nine verified primary harnesses,
#   ensure writes the carrier file of a fixture claude home with its one import line, and the real
#   bin/jg-session-start.sh holds the contract in its digest for harness unknown and in the re-emit after a
#   compaction for harness pi, and stops repeating it for a claude home whose file stands.
# Step 2 (opt-in, spends model tokens: JG_THIN_CONTEXT_LIVE=1): a real Claude Code session (Haiku) started in
#   a fixture home that holds only the carrier file reads the contract sentence in its first request.
#   A request after a compaction is not driven here: print mode has no compaction (unverified).
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
# shellcheck source=tests/lib.sh
. "$REPO/tests/lib.sh"
CARRIER="$REPO/bin/jg-contract-carrier.sh"
MARK='THIN-CONTEXT-JOURNEY-SENTENCE-2b9d'
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
log() { printf '%s\n' "$*" | tee -a "$OUT/replay.txt"; }
die() { log "FAIL: $*"; exit 1; }
: > "$OUT/replay.txt"

home() {  # <name>: a fixture home whose AGENTS.md is the contract, with a fake ps that names the harness
  local h=$T/$1
  mkdir -p "$h/state" "$h/data" "$h/config" "$h/fakebin"
  git init -q -b main "$h"
  printf '# Juggernaut\n%s\n' "$MARK" > "$h/AGENTS.md"
  cat > "$h/fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=; prev=
for a in "$@"; do [ "$prev" = -p ] && pid=$a; prev=$a; done
case "$*" in
  *-eo*) exec /bin/ps "$@" ;;
  *comm=*) if [ "$pid" = "${JG_FAKE_HARNESS_PID:-}" ]; then printf '/usr/local/bin/%s\n' "${JG_FAKE_HARNESS:-claude}"; else printf '/bin/bash\n'; fi; exit 0 ;;
  *args=*) if [ "$pid" = "${JG_FAKE_HARNESS_PID:-}" ]; then printf '%s\n' "${JG_FAKE_HARNESS:-claude}"; else printf 'bash\n'; fi; exit 0 ;;
  *ppid=*) /bin/ps -o ppid= -p "$pid"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$h/fakebin/ps"
  echo "$h"
}
start() {  # <home> <harness> <session-start args>...
  local h=$1 harness=$2; shift 2
  env -u CLAUDECODE -u PI_CODING_AGENT -u JG_PI_HARNESS -u GROK_AGENT \
    JG_FAKE_HARNESS="$harness" JG_FAKE_HARNESS_PID=$$ JG_HOME="$h" JG_ROOT_OVERRIDE="$h" \
    JG_SESSION_START_STAGE_FILE=/dev/null PATH="$h/fakebin:/usr/bin:/bin" "$REPO/bin/jg-session-start.sh" "$@" 2>&1
}

bash "$REPO/tests/jg-contract-carrier.test.sh" > "$OUT/contract-carrier-test.log" 2>&1 || die "tests/jg-contract-carrier.test.sh failed; see contract-carrier-test.log"
log "tests/jg-contract-carrier.test.sh: all assertions passed"

H=$(home table)
for harness in claude pi pi-signed omp codex cursor opencode grok kimi; do
  proof=$(JG_HOME="$H" JG_ROOT_OVERRIDE="$H" "$CARRIER" check "$harness")
  case "$proof" in file | reemit | none) ;; *) die "check $harness printed '$proof'" ;; esac
  log "check $harness -> $proof"
done

C=$(home claude)
start "$C" claude --source startup > "$OUT/claude-start.txt"
grep -q 'wrote CLAUDE.local.md' "$OUT/claude-start.txt" || die "the first claude start did not write the carrier file"
grep -q "$MARK" "$OUT/claude-start.txt" || die "the first claude start did not hold the contract"
[ "$(cat "$C/CLAUDE.local.md")" = '@AGENTS.md' ] || die "the carrier file does not hold the one import line"
start "$C" claude --reemit --source compact > "$OUT/claude-compact.txt"
grep -q "$MARK" "$OUT/claude-compact.txt" && die "a claude home with its file stands still repeats the contract after a compaction"
log "claude home: the first start wrote CLAUDE.local.md (@AGENTS.md); the digest after a compaction no longer repeats the contract"

U=$(home unknown)
start "$U" unknown --source startup > "$OUT/unknown-start.txt"
grep -q "$MARK" "$OUT/unknown-start.txt" || die "the digest of harness unknown does not hold the contract"
[ ! -e "$U/CLAUDE.local.md" ] || die "harness unknown got a carrier file"
log "harness unknown: no file written, the digest holds the contract"

P=$(home pi)
start "$P" pi --source startup > "$OUT/pi-start.txt"
start "$P" pi --reemit --source compact > "$OUT/pi-compact.txt"
grep -q "$MARK" "$OUT/pi-compact.txt" || die "the re-emit after a pi compaction does not hold the contract"
log "harness pi: the re-emit after a compaction holds the contract"

printf '{"target":{"version":"bin/jg-contract-carrier.sh and bin/jg-session-start.sh at this head"},"start":"fixture homes holding only an AGENTS.md that is the contract, run under a fake harness","steps":["ask the carrier for its proof for each of the nine verified primary harnesses","start a claude home and read the digest and the file the start wrote","re-emit that claude home after a compaction","start a home of harness unknown","start a pi home and re-emit it after a compaction"],"result":"each harness read file, reemit or none; the claude home got CLAUDE.local.md with one import line and stopped repeating the contract after a compaction; harness unknown and pi held the contract in the digest"}\n' > "$OUT/steps.json"
jg_live_gate opt-in JG_THIN_CONTEXT_LIVE claude
L=$T/live
mkdir -p "$L"
printf 'The contract sentence is %s.\n' "$MARK" > "$L/contract.md"
printf '@contract.md\n' > "$L/CLAUDE.local.md"
(cd "$L" && claude -p --model claude-haiku-5-5 --dangerously-skip-permissions \
  'Reply with only the contract sentence code from your instructions, or NONE if you have none.') > "$OUT/live-first-request.txt" 2>&1
grep -q "$MARK" "$OUT/live-first-request.txt" || die "the first request of a real session did not hold the contract from the carrier file"
log "live: the first request of a real session held the contract from CLAUDE.local.md"
