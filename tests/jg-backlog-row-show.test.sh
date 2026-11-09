#!/usr/bin/env bash
# A slow backlog read is retried before it counts as a wedge. jg_backlog_row_show is the one row read behind task cleanup,
# bin/jg-captain-hold.sh and the bootstrap sweeps; a stand-in bd whose `show` is slow on chosen calls proves a read that a
# retry rescues succeeds and leaves the sweep unlatched, and a backend that is slow on every attempt refuses once, inside the
# total bound, naming its attempts, and only then latches the sweep.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(jg_test_tmproot jg-backlog-row-show)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
mkdir -p "$T/bin" "$T/config" "$T/data" "$T/store/.beads/embeddeddolt/jg"
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$T/store/.beads/metadata.json"
printf 'no-git-ops: true\n' > "$T/store/.beads/config.yaml"
# SLOW_CALLS is how many leading `show` calls hang; every later call answers at once. CALLS counts the calls made.
cat > "$T/bin/bd" <<'SH'
#!/usr/bin/env bash
if [ "$1" = show ]; then
  n=$(($(cat "$CALLS" 2>/dev/null || echo 0) + 1)); printf '%s\n' "$n" > "$CALLS"
  [ "$n" -gt "$SLOW_CALLS" ] || exec sleep 60
  python3 -c 'import json,sys; print(json.dumps([r for r in json.load(open(sys.argv[1])) if r["id"]==sys.argv[2]]))' "$ROWS" "$2"
else
  echo '[]'
fi
SH
{ cat "$T/bin/bd"; printf '# dolt\n'; } > "$T/bin/dolt"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$T/bin/bd")" "$os" "$arch" "$(sha_of "$T/bin/dolt")" > "$T/pins"
printf '%s\n' "$T/store/.beads" > "$T/config/beads-dir"
cat > "$T/rows.json" <<'JSON'
[{"id":"jg-open","title":"open one","status":"open","created_at":"2026-11-01T00:00:00Z","labels":["project:p"]}]
JSON
export JG_PIN_FILE_OVERRIDE=$T/pins CALLS=$T/calls ROWS=$T/rows.json JG_BEADS_BD=$T/bin/bd JG_BEADS_DOLT=$T/bin/dolt
export JG_CONFIG_OVERRIDE=$T/config JG_BACKLOG_ROW_TIMEOUT_SECS=1
unset JG_BACKLOG_SNAPSHOT JG_BACKLOG_TIMEOUT
# shellcheck source=bin/jg-backlog-lib.sh disable=SC1091
. "$ROOT/bin/jg-backlog-lib.sh"
# shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
. "$ROOT/bin/jg-backlog-transition-lib.sh"

# <slow-calls>: reset the stand-in, read one row the way every caller does (inside a command substitution), and time it.
SHOW_OUT='' SHOW_CODE='' SHOW_SECS='' SHOW_CALLS=''
read_row() {
  local started=$SECONDS
  SLOW_CALLS=$1 && export SLOW_CALLS
  rm -f "$CALLS"
  SHOW_OUT=$(jg_backlog_row_show "$T/data" jg-open --full); SHOW_CODE=$?
  SHOW_SECS=$((SECONDS - started))
  SHOW_CALLS=$(cat "$CALLS" 2>/dev/null || echo 0)
}

read_row 0
expect_code 0 "$SHOW_CODE" "a fast read succeeds"
assert_contains "$SHOW_OUT" 'title: open one' "a fast read prints the row"
[ "$SHOW_CALLS" = 1 ] || fail "a fast read asked the backend $SHOW_CALLS times, not once"

read_row 1
expect_code 0 "$SHOW_CODE" "a read that is slow once succeeds on its retry"
assert_contains "$SHOW_OUT" 'title: open one' "the retried read prints the row"
assert_not_contains "$SHOW_OUT" 'read bound' "the retried read reports no bound"
[ "$SHOW_CALLS" = 2 ] || fail "a read slow once asked the backend $SHOW_CALLS times, not twice"
pass "a read slow past the base bound succeeds on a retry with a larger bound"

read_row 2
expect_code 0 "$SHOW_CODE" "a read that is slow twice succeeds on its last attempt"
[ "$SHOW_CALLS" = 3 ] || fail "a read slow twice asked the backend $SHOW_CALLS times, not three times"
pass "the last attempt still gets its read"

read_row 99
expect_code 124 "$SHOW_CODE" "a backend slow on every attempt refuses with the bound's status"
[ "$SHOW_CALLS" = 3 ] || fail "a wedged read asked the backend $SHOW_CALLS times, not three times"
[ "$SHOW_SECS" -le 9 ] || fail "a wedged read took ${SHOW_SECS}s, past the total bound of 1+2+3 seconds"
[ "$SHOW_SECS" -ge 5 ] || fail "a wedged read took ${SHOW_SECS}s, so it did not wait out its larger bounds"
[ "$(printf '%s\n' "$SHOW_OUT" | wc -l | tr -d ' ')" = 1 ] || fail "the refusal is not one line: $SHOW_OUT"
[ "$SHOW_OUT" = 'backlog show jg-open exceeded its 3s backlog read bound after 3 attempts (1s, 2s, 3s)' ] \
  || fail "the refusal does not name its attempts: $SHOW_OUT"
printf '%s\n' "$SHOW_OUT" | grep -qE '^(jg-captain-hold: )?backlog show [A-Za-z0-9._-]+ exceeded its [0-9]+s backlog read bound( after [0-9]+ attempts \([0-9s, ]+\))?$' \
  || fail "the refusal no longer matches the landing retry's pattern in bin/jg-trunk.sh: $SHOW_OUT"
grep -qF 'backlog read bound( after [0-9]+ attempts \([0-9s, ]+\))?$' "$ROOT/bin/jg-trunk.sh" \
  || fail "bin/jg-trunk.sh no longer matches the refusal pattern this suite pins"
pass "a true wedge refuses once, inside the total bound, naming its attempts"

# The latch is the callers' write, made only after the last attempt: a probe the retry rescued leaves the sweep open.
JG_BACKLOG_ROW_SHOW_WEDGED=0
SLOW_CALLS=1 && export SLOW_CALLS; rm -f "$CALLS"
jg_backlog_row_probe "$T/data" jg-open || fail "a probe the retry rescued reports $JG_BACKLOG_ROW_RESULT: $JG_BACKLOG_ROW_ERROR"
[ "$JG_BACKLOG_ROW_SHOW_WEDGED" = 0 ] || fail "a rescued read latched the sweep"
SLOW_CALLS=99 && export SLOW_CALLS; rm -f "$CALLS"
jg_backlog_row_probe "$T/data" jg-open; code=$?
expect_code 124 "$code" "a wedged probe returns the bound's status"
[ "$JG_BACKLOG_ROW_SHOW_WEDGED" = 1 ] || fail "a read wedged on every attempt did not latch the sweep"
assert_contains "$JG_BACKLOG_ROW_ERROR" 'after 3 attempts' "the probe error names the attempts"
started=$SECONDS; rm -f "$CALLS"
out=$(jg_backlog_row_show "$T/data" jg-open); code=$?
expect_code 124 "$code" "a later read in a latched sweep refuses"
[ "$((SECONDS - started))" -le 1 ] && [ ! -e "$CALLS" ] || fail "a later read in a latched sweep reached the backend"
assert_contains "$out" 'jg-open' "a latched read still names its own item"
pass "the sweep latches only after the last attempt, and a latched sweep reads nothing more"

# Wedged-backend stragglers: every timed-out attempt must have been killed.
stray=$(pgrep -f "$T/bin/bd" 2>/dev/null | wc -l | tr -d ' ')
[ "$stray" -eq 0 ] || fail "the timed-out attempts left $stray hung backend process(es) behind"
pass "no timed-out attempt is left running"
