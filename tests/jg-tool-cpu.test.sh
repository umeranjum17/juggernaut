#!/usr/bin/env bash
# Behavior test for core/fleet-stats/tool-cpu.sh (H53): run the real script over a fixture process table and check which fleet
# script each mise, gh, chromium and shellcheck process is charged to, the daily record, and one ticket per top caller.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/core/fleet-stats/tool-cpu.sh"
T=$(jg_test_tmproot jg-tool-cpu); H=$T/home; mkdir -p "$H/data"
export JG_HOME=$H JG_DATA_OVERRIDE=$H/data

# pid ppid pcpu comm args. The lander runs a mise shim that runs gh (the shim is skipped on the way up); a watch script runs a
# chromium with a child chromium; an agent's own shell runs shellcheck (no script above it); a small script is under the floor.
cat > "$T/ps" <<'P'
    1     0  0.0 systemd /sbin/init
   10     1  0.0 claude claude --model x
   20    10  0.0 bash bash /h/bin/jg-lander.sh run
   21    20 150.0 mise /usr/bin/mise exec -- gh pr list
   22    21 70.0 gh gh pr list
   30    10  0.0 bash bash -c lint
   31    30 50.0 shellcheck shellcheck a.sh
   40     1  0.0 bash bash /h/core/watch/watch.sh
   41    40 100.0 chromium chromium --headless
   42    41 100.0 chromium chromium --type=renderer
   50     1  0.0 bash bash /h/bin/jg-small.sh
   51    50  5.0 gh gh api x
P

# A stub backlog: `show` finds a ticket once added and not closed; `add` records the id and title.
cat > "$T/backlog" <<'B'
#!/usr/bin/env bash
case $1 in
  show) grep -qx "$2" "$BL/ids" 2>/dev/null && { echo '  closed: "-"'; exit 0; }; exit 1 ;;
  add) echo "$2" >> "$BL/ids"; printf '%s\n%s\n' "$3" "$*" >> "$BL/adds" ;;
esac
B
chmod +x "$T/backlog"; export BL=$T JG_TOOL_CPU_BACKLOG=$T/backlog

run() { OUT=$(bash "$TOOL" --ps-file "$T/ps" --samples 2 "$@" 2>&1); RC=$?; }

run
assert_equals 0 "$RC" "a plain sample succeeds"
assert_contains "$OUT" "1.50 cores  mise       jg-lander.sh" "the mise shim is charged to the lander script"
assert_contains "$OUT" "0.70 cores  gh         jg-lander.sh" "gh under the shim skips the shim and reaches the lander script"
assert_contains "$OUT" "2.00 cores  chromium   watch.sh  (2.0 procs)" "both chromium processes are charged to the watch script"
assert_contains "$OUT" "0.50 cores  shellcheck (none) claude" "a tool with no script above it names its nearest parent and is not a fleet script"
assert_absent "$H/data/metrics/tool-cpu.tsv" "a plain sample records nothing"

run --daily; assert_equals 0 "$RC" "a daily sample succeeds"
assert_equals 5 "$(wc -l < "$H/data/metrics/tool-cpu.tsv" | tr -d ' ')" "the daily sample records one row per tool and caller"
run --daily; assert_equals "already sampled $(date -u +%F)" "$OUT" "a second daily sample on the same UTC day is skipped"
assert_equals 5 "$(wc -l < "$H/data/metrics/tool-cpu.tsv" | tr -d ' ')" "the skipped sample records nothing"

rm "$H/data/metrics/tool-cpu.tsv"
run --daily --file-tickets --top 2 --min-cores 0.2
assert_equals 0 "$RC" "a daily sample that files tickets succeeds"
assert_equals "tool-cpu-jg-lander
tool-cpu-watch" "$(cat "$T/ids")" "one ticket per top caller, none for the unattributed shell or the caller under the floor"
assert_contains "$(cat "$T/adds")" "- mise: 1.50 cores" "the ticket body carries the caller's numbers per tool"
assert_contains "$(cat "$T/adds")" "- gh: 0.70 cores" "the ticket body names every tool the caller starts"

rm "$H/data/metrics/tool-cpu.tsv"
run --daily --file-tickets --top 2
assert_contains "$OUT" "open ticket tool-cpu-jg-lander" "an open ticket files nothing again"
assert_equals 2 "$(wc -l < "$T/ids" | tr -d ' ')" "no second ticket while one is open"

run --file-tickets; assert_equals 2 "$RC" "--file-tickets without --daily is refused"
pass "tool-cpu: attribution, daily record and one ticket per top caller"
