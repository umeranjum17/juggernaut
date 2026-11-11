#!/usr/bin/env bash
# The session-start sweep that pairs task records with backlog rows reads the backlog once for the whole sweep, not once per
# record (a home with 87 records paid 87 reads of 2.6 to 4.7 s). A counting stand-in around the pinned bd proves a home of 30
# records costs one list read and no row read for a record the list answers, still heals a queued row of an owned record to
# In flight, and, when the list read fails as a whole, falls back to one read per record, says so in one line, and prints the
# same BACKLOG_RECONCILE line for the row it cannot read.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JG_BEADS_TEST_BD=${JG_BEADS_TEST_BD:-$(command -v bd 2>/dev/null || true)}
JG_BEADS_TEST_DOLT=${JG_BEADS_TEST_DOLT:-$(command -v dolt 2>/dev/null || true)}
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
T=$(jg_test_tmproot jg-bootstrap-backlog-reconcile)
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m); case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac

HOME_DIR=$T/home
mkdir -p "$HOME_DIR/state" "$HOME_DIR/projects"
jg_test_beads_home "$HOME_DIR"
: > "$HOME_DIR/config/backlog-intake-loose"
FAKEBIN=$(jg_fakebin "$HOME_DIR")
jg_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi

# A bd that logs each verb it is asked for, can be told to fail every list, and to fail the show of one id, then runs the real bd.
mkdir -p "$T/bin"
cat > "$T/bin/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/calls"
[ "\$1" != list ] || [ ! -e "$T/fail-list" ] || { echo 'list backend down' >&2; exit 1; }
[ "\$1" != show ] || [ ! -e "$T/fail-show" ] || [ "\$2" != "\$(cat "$T/fail-show")" ] || { echo 'show backend down' >&2; exit 1; }
exec "$JG_BEADS_TEST_BD" "\$@"
SH
chmod +x "$T/bin/bd"
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' "$os" "$arch" "$(sha_of "$T/bin/bd")" \
  "$os" "$arch" "$(sha_of "$JG_BEADS_TEST_DOLT")" > "$T/pins"

N=30
# Seed all rows in one real Beads import; per-row backlog writes make the fixture dominate the sweep.
python3 - "$N" > "$T/rows.jsonl" <<'PYROWS'
import json, sys
for i in range(1, int(sys.argv[1]) + 1):
    row = {"id": f"jg-rec-{i}", "title": f"Fixture record {i}", "description": f"Fixture jg-rec-{i}",
           "issue_type": "task", "metadata": {"kind": "ship"}, "labels": ["project:demo"],
           "status": "open" if i <= 10 else "in_progress"}
    if i > 10:
        row["assignee"] = "juggernaut"
    print(json.dumps(row))
PYROWS
BEADS_DIR=$(cat "$HOME_DIR/config/beads-dir") "$ROOT/bin/jg-beads.sh" import "$T/rows.jsonl" >/dev/null 2>&1 \
  || fail "could not import fixture records"
for i in $(seq 1 "$N"); do
  id=jg-rec-$i
  jg_write_meta "$HOME_DIR/state/$id.meta" "window=juggernaut:jg-$id" "harness=codex" "kind=ship" "spawn_gen=fixture-$id"
done
# A record with no backlog row at all is silent: no row is not an unreadable row.
jg_write_meta "$HOME_DIR/state/jg-rec-orphan.meta" "window=juggernaut:jg-jg-rec-orphan" "harness=codex" "kind=ship" "spawn_gen=fixture-orphan"

sweep() {  # prints the bootstrap output; resets the call log first
  : > "$T/calls"
  PATH="$FAKEBIN:$PATH" JG_ROOT_OVERRIDE="$ROOT" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
    JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config" JG_BOOTSTRAP_NETWORK=skip \
    JG_PIN_FILE_OVERRIDE=$T/pins JG_BEADS_BD=$T/bin/bd "$ROOT/bin/jg-bootstrap.sh" 2>&1 || true
}
calls_of() { grep -c "^$1\( \|\$\)" "$T/calls" || true; }
state_of() { jg_test_backlog "$HOME_DIR" show "$1" --full 2>/dev/null | sed -n 's/^  state: *//p'; }

out=$(sweep)
assert_contains "$out" 'marked jg-rec-1 in flight' "the sweep did not heal a queued row of an owned record"
assert_contains "$out" 'marked jg-rec-10 in flight' "the sweep did not heal the last queued row"
assert_not_contains "$out" 'BACKLOG_RECONCILE' "a healthy sweep printed a reconcile line: $out"
assert_not_contains "$out" 'one by one' "a healthy list read fell back to single reads"
[ "$(state_of jg-rec-1)" = in_flight ] || fail "jg-rec-1 is not In flight after the sweep"
[ "$(calls_of show)" = 0 ] || fail "the sweep read $(calls_of show) single rows for $N records: it still reads once per record"
[ "$(calls_of blocked)" -le 1 ] || fail "the sweep asked bd for blocked rows $(calls_of blocked) times for $N records"
pass "$N records cost one list read, no single row read, and the queued rows are healed"

# The list read fails as a whole: one line says so, each record is read on its own, and the row that cannot be read is named.
rm -f "$HOME_DIR/state/jg-rec-orphan.meta"
: > "$T/fail-list"
printf '%s\n' jg-rec-20 > "$T/fail-show"
out=$(sweep)
assert_contains "$out" 'reading the rows one by one' "a failed list read did not say it fell back"
[ "$(printf '%s\n' "$out" | grep -c 'one by one')" = 1 ] || fail "the fallback was not announced in exactly one line: $out"
assert_contains "$out" 'BACKLOG_RECONCILE: jg-rec-20: worker record exists but its backlog item could not be read' \
  "the unreadable row was not reported as before"
[ "$(printf '%s\n' "$out" | grep -c '^BACKLOG_RECONCILE')" = 1 ] || fail "more than one row reported unreadable: $out"
[ "$(calls_of show)" -ge "$N" ] || fail "the fallback read only $(calls_of show) single rows for $N records"
pass "a failed list read falls back to single reads, says so once, and names the unreadable row"
