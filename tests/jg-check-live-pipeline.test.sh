#!/usr/bin/env bash
# bin/jg-check-live-pipeline.sh: the check that gates the no-mistakes removal refuses while a fixture home
# holds a ship task whose pipeline run is still in flight, and passes once every run has ended or when
# a worktree is gone, belongs to a scout, or is unknown to the pipeline.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

root=$(jg_test_tmproot live-pipeline) || fail "no fixture root"
mkdir -p "$root/fakebin" "$root/home/state" "$root/home2/state" "$root/wt-live" "$root/wt-done" "$root/wt-scout" "$root/wt-unknown"
# A stand-in pipeline CLI: the answer for `axi status` is the file named by the worktree it runs in.
cat > "$root/fakebin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = axi ] && [ "${2:-}" = status ] || exit 2
f=$PWD/axi-status.txt
[ -f "$f" ] || { echo "error: repo not initialized (run 'no-mistakes init' first)"; exit 1; }
cat "$f"
STUB
chmod +x "$root/fakebin/no-mistakes"
export PATH="$root/fakebin:$PATH"
C=$ROOT/bin/jg-check-live-pipeline.sh

printf 'run:\n  id: "01A"\n  branch: fm/a\n  status: running\n  head: abc\n' > "$root/wt-live/axi-status.txt"
printf 'run:\n  id: "01B"\n  branch: fm/b\n  status: completed\n  head: abc\noutcome: passed\n' > "$root/wt-done/axi-status.txt"
printf 'run:\n  id: "01C"\n  branch: fm/c\n  status: running\n  head: abc\n' > "$root/wt-scout/axi-status.txt"

jg_write_meta "$root/home/state/live.meta" "worktree=$root/wt-live"
jg_write_meta "$root/home/state/done.meta" "kind=ship" "worktree=$root/wt-done"
jg_write_meta "$root/home/state/scout.meta" "kind=scout" "worktree=$root/wt-scout"
jg_write_meta "$root/home/state/unknown.meta" "kind=ship" "worktree=$root/wt-unknown"
jg_write_meta "$root/home/state/gone.meta" "kind=ship" "worktree=$root/no-such-dir"

out=$("$C" "$root/home" 2>&1) && rc=0 || rc=$?
[ "$rc" = 1 ] || fail "a live run did not refuse (rc=$rc): $out"
assert_contains "$out" "live pipeline run: $root/home live running" "the refusal names the home, the task and the status"
assert_not_contains "$out" 'done running' "a finished run is not reported"
assert_not_contains "$out" 'scout' "a scout's run is not reported"
assert_not_contains "$out" 'unknown' "a worktree the pipeline does not know has no run"

# The same home is clear once the run ends; a second home with a live run still refuses the pair.
printf 'run:\n  id: "01A"\n  branch: fm/a\n  status: completed\n  head: abc\noutcome: failed\n' > "$root/wt-live/axi-status.txt"
out=$("$C" "$root/home" 2>&1) || fail "a home with no live run refused: $out"
assert_contains "$out" 'no live pipeline run' "a clear home passes"
jg_write_meta "$root/home2/state/other.meta" "worktree=$root/wt-scout"
"$C" "$root/home" "$root/home2" >/dev/null 2>&1 && fail "a live run in the second home did not refuse"

# JG_HOME is the default home, and without the pipeline installed there is nothing to wait for.
JG_HOME=$root/home "$C" >/dev/null 2>&1 || fail "the default home was not read"
out=$(PATH=/usr/bin:/bin "$C" "$root/home2" 2>&1) || fail "a missing pipeline CLI refused: $out"
pass "jg-check-live-pipeline"
