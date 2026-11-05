#!/usr/bin/env bash
# E2E: the merge path holds the task control lock while it runs the evidence lint, and the lint publishes the
# completion receipt, which takes the same lock. Real checks-lint.sh and the real receipt publisher (only done-done
# and gh are stubs). (a) A lint run by the lock holder finishes at once instead of waiting out the lint timeout, and
# the lock still excludes every other process; (b) a standalone lint run records the PR url in the receipt, so it
# never overwrites a good receipt with pr="".
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
REPO=$(cd "$ROOT/.." && pwd -P)
# shellcheck source=lib/policy-test-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/policy-test-env.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d JG_HOME=$d/fm JG_CORE_DIR=$ROOT JG_FORK_BIN=$REPO/bin
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/bin" "$JG_HOME"/{state,data/lane-x/evidence} "$d/wt"
fails=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got [$2], want [$3]"; fi }

URL=https://github.com/o/r/pull/7
# A done-done that passes the version probe and logs one passing lint row; gh reports a one-page PR.
cat > "$d/bin/done-done" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  lint) if [ "${2:-}" = --help ]; then echo 'checks.generated_paths:'; else
          printf 't\t%s\thead1\tpass\tok\n' "$2" >> "$DONE_DONE_HOME/lint.log"; fi ;;
esac
STUB
printf '#!/usr/bin/env bash\necho 3\n' > "$d/bin/gh"
chmod +x "$d/bin/done-done" "$d/bin/gh"
export PATH="$d/bin:$PATH" JG_DONE_DONE_BIN="$d/bin/done-done"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\npr=%s\n' "$d/wt" "$URL" > "$JG_HOME/state/lane-x.meta"
printf 'frame\n' > "$JG_HOME/data/lane-x/evidence/shot.png"
printf '## Checks\noutcome: the lane proves the new screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' > "$JG_HOME/data/lane-x/report.md"
LINT=$ROOT/merge-on-green/checks-lint.sh
RECEIPT=$JG_HOME/state/lane-x.run-receipt.json
LOCK=$JG_HOME/state/.control-lane-x.lock

# (b) A standalone lint run (no lock held) records the PR url.
"$LINT" "$URL" "$JG_HOME/data/lane-x" >"$d/standalone.out" 2>&1 || bad "standalone lint must PASS: $(cat "$d/standalone.out")"
is 'a standalone lint run records the PR url in the receipt' "$(jq -r .pr "$RECEIPT" 2>/dev/null || echo none)" "$URL"
is 'a standalone lint run publishes a PASS receipt' "$(jq -r .verdict "$RECEIPT" 2>/dev/null || echo none)" PASS
rm -f "$RECEIPT"

# (a) The lock holder runs the lint the way jg-pr-merge does, naming itself as the holder.
holder=$(cat <<'HOLDER'
. "$JG_FORK_BIN/jg-wake-lib.sh"
STATE=$JG_HOME/state
jg_lock_acquire_wait "$STATE/.control-lane-x.lock"
jg_current_pid self
SECONDS=0
rc=0
env JG_CONTROL_LOCK_HELD_BY="$self" timeout 30 "$LINT" "$URL" "$JG_HOME/data/lane-x" >"$OUT" 2>&1 || rc=$?
echo "rc=$rc secs=$SECONDS owner_after=$(cat "$STATE/.control-lane-x.lock/pid" 2>/dev/null || echo none) self=$self"
jg_lock_release "$STATE/.control-lane-x.lock"
HOLDER
)
line=$(OUT=$d/held.out LINT=$LINT URL=$URL bash -c "$holder")
rc=$(printf '%s' "$line" | sed -n 's/.*rc=\([0-9]*\).*/\1/p'); secs=$(printf '%s' "$line" | sed -n 's/.*secs=\([0-9]*\).*/\1/p')
is 'the lint run under the held control lock passes' "$rc" 0
if [ "${secs:-99}" -lt 10 ]; then ok "it finishes in ${secs}s, well inside the 300s lint timeout"; else bad "it took ${secs}s: $(cat "$d/held.out")"; fi
is 'the receipt under the held lock records the PR url' "$(jq -r .pr "$RECEIPT" 2>/dev/null || echo none)" "$URL"
is 'the holder still owns the lock afterwards (the receipt did not release it)' "$(printf '%s' "$line" | sed -n 's/.*owner_after=\([0-9]*\).*/\1/p')" "$(printf '%s' "$line" | sed -n 's/.*self=\([0-9]*\).*/\1/p')"
[ ! -e "$LOCK" ] && ok 'the holder released the lock itself' || bad 'the lock leaked'
rm -f "$RECEIPT"

# Mutual exclusion: a live process holds the lock; a publisher that names a different pid, or none, must still wait.
printf 'frame\n' >/dev/null
bash -c '. "$JG_FORK_BIN/jg-wake-lib.sh"; jg_lock_acquire_wait "$JG_HOME/state/.control-lane-x.lock"; sleep 8' &
other=$!
for _ in $(seq 1 50); do [ -e "$LOCK/pid" ] && break; sleep 0.1; done
for claim in "" "$$"; do
  rc=0
  env JG_CONTROL_LOCK_HELD_BY="$claim" timeout 3 "$ROOT/receipts/bin/jg-run-receipt.sh" lane-x PASS "$d/standalone.out" "$d/wt" >/dev/null 2>&1 || rc=$?
  is "a publisher claiming holder [$claim] still waits on another process's lock" "$rc" 124
  [ ! -e "$RECEIPT" ] && ok 'and wrote no receipt' || bad 'a receipt was written while another process held the lock'
done
kill "$other" 2>/dev/null || true
wait "$other" 2>/dev/null || true

[ "$fails" -eq 0 ] && echo 'PASS: the lint receipt neither deadlocks on the merge lock nor loses the PR url' || { echo "FAIL: $fails" >&2; exit 1; }
