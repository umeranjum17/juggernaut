#!/usr/bin/env bash
# Behavior test for a gate shard on a runner (H30b): jg_test_host_run_shard goes through the real core/runners/run-shard.sh,
# bin/jg-on.sh --stdin and bin/jg-runner-shard.sh; only the SSH process boundary is a stand-in. The repository under test is a
# fixture whose bin/jg-test-run.sh only reports where and at which commit it ran.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(jg_test_tmproot jg-runner-shard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT
FAKEBIN=$(jg_fakebin "$TMP_ROOT/fakebin")
HOME_DIR="$TMP_ROOT/home"
FX="$TMP_ROOT/fx"
RUNNER_ROOT="$TMP_ROOT/runner-root"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$TMP_ROOT/slots" "$FX"
export JG_TEST_HOST_SLOTS="$TMP_ROOT/slots"
export TMPDIR="$TMP_ROOT"
export JG_HOME="$HOME_DIR"

# The fixture repository: the real scripts under test, plus a stand-in test runner.
cp -r "$SRC/bin" "$FX/bin"
mkdir -p "$FX/core"
cp -r "$SRC/core/runners" "$FX/core/runners"
cat > "$FX/bin/jg-test-run.sh" <<'SH'
#!/usr/bin/env bash
json=; args=()
while [ "$#" -gt 0 ]; do case "$1" in --json) json=$2; shift 2 ;; *) args+=("$1"); shift ;; esac; done
printf '{"ran":"%s","head":"%s","args":"%s"}\n' "$(cd "$(dirname "$0")/.." && pwd)" "$(git -C "$(dirname "$0")/.." rev-parse HEAD)" "${args[*]}" > "$json"
case "${args[*]}" in *red*) exit 1 ;; esac
SH
git -C "$FX" init -q -b main
git -C "$FX" config user.email t@example.invalid
git -C "$FX" config user.name t
git -C "$FX" add -f . >/dev/null
git -C "$FX" commit -q -m base
BASE=$(git -C "$FX" rev-parse HEAD)
git clone -q "$FX" "$RUNNER_ROOT"
echo change > "$FX/change.txt"
git -C "$FX" add change.txt
git -C "$FX" commit -q -m change
COMMIT=$(git -C "$FX" rev-parse HEAD)

# The SSH stand-in runs the job the way the remote entrypoint would: the decoded argv under the runner's code root.
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
host=$1 root_b64=$4 argv_b64=$6
[ "$host" != lab-down ] || exit 255
root=$(printf '%s' "$root_b64" | base64 -d)
mapfile -d '' argv < <(printf '%s' "$argv_b64" | base64 -d)
cmd=${argv[0]}
JG_ROOT_OVERRIDE="$root" exec env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" JG_ROOT_OVERRIDE="$root" "$root/bin/$cmd" "${argv[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"
export JG_SSH_BIN="$FAKEBIN/fake-ssh"

arch=$(case $(uname -m) in aarch64|arm64) echo arm64 ;; *) echo x86_64 ;; esac)
runner_line() { # <id> <alias> <slots>
  printf '%s ssh=%s root=%s home=%s arch=%s cores=8 mem_gb=16 slots=%s cost_per_hour=0 private_ok=yes\n' "$1" "$2" "$RUNNER_ROOT" "$TMP_ROOT/runner-home" "$arch" "$3"
}
health() { printf '%s\t%s\tok\t%s\t\n' "$(date +%s)" "$1" "$2" >> "$HOME_DIR/state/runner-health.tsv"; }

# shellcheck source=bin/jg-test-host-lib.sh
. "$FX/bin/jg-test-host-lib.sh"
log() { printf 'log: %s\n' "$*" >&2; }
shard() { # <k> <extra arg>: runs the shard through the placement; output in $OUT
  local extra=()
  [ -z "$2" ] || extra=("$2")
  OUT="$TMP_ROOT/shard-$1.json"; rm -f "$OUT"
  jg_test_host_run_shard "$HOME_DIR" "$1" "$COMMIT" "$BASE" "$OUT" -- --changed --base "$BASE" --shard "$1of8" "${extra[@]+"${extra[@]}"}" 2>"$TMP_ROOT/err.txt"
}

# 1. No runner registered: the shard runs here, at the commit, as before.
shard 1 "" || fail "a local shard failed"
assert_contains "$(cat "$OUT")" "\"ran\":\"$FX\"" "with no runner the shard did not run here"
pass "with no runner registered the shard runs here"

# 2. A probed runner takes the shard: it ran at the commit in a copy under the runner, and its JSON came back.
runner_line own1 lab-own 1 > "$HOME_DIR/config/runners"
health own1 4
shard 2 "" || fail "the runner shard failed: $(cat "$TMP_ROOT/err.txt")"
assert_contains "$(cat "$OUT")" "\"head\":\"$COMMIT\"" "the runner did not run the shard at the commit"
case $(cat "$OUT") in *"\"ran\":\"$FX\""*) fail "the shard ran here, not on the runner" ;; esac
assert_contains "$(cat "$OUT")" "--shard 2of8" "the shard's arguments did not reach the runner"
assert_contains "$(cat "$TMP_ROOT/err.txt")" "shard 2 goes to runner own1" "the placement was not logged"
compgen -G "$JG_TEST_HOST_SLOTS/runner-*" >/dev/null && fail "a runner slot stayed claimed after the shard"
[ -z "$(git -C "$RUNNER_ROOT" for-each-ref refs/jg-shard)" ] || fail "the runner's own repository gained a ref"
pass "a runner shard runs at the bundled commit and its JSON comes back; the runner slot is freed"

# 3. A red on the runner is a red: its JSON is kept and it is not rerun here.
shard 3 red && fail "a red shard on the runner reported green"
assert_contains "$(cat "$OUT")" "red" "the red shard's JSON did not come back"
case $(cat "$OUT") in *"\"ran\":\"$FX\""*) fail "a red shard was rerun here" ;; esac
pass "a red on the runner stays a red and is not rerun"

# 4. A full runner (one slot, taken by a live owner) leaves the shard here.
slot="$JG_TEST_HOST_SLOTS/runner-own1.slot-1"
mkdir "$slot"; echo $$ > "$slot/owner"
shard 4 "" || fail "the shard failed while the runner was full"
assert_contains "$(cat "$OUT")" "\"ran\":\"$FX\"" "a full runner was given a shard"
# A slot whose owner died is taken over.
echo 999999 > "$slot/owner"
shard 5 "" || fail "the shard failed with a dead slot owner"
case $(cat "$OUT") in *"\"ran\":\"$FX\""*) fail "a slot with a dead owner was not taken over" ;; esac
pass "a full runner is skipped and a dead owner's slot is taken over"

# 5. A lost runner is not a red: the shard reruns here and reports its own result.
runner_line down1 lab-down 2 > "$HOME_DIR/config/runners"
health down1 4
shard 6 "" || fail "a lost runner turned the shard red: $(cat "$TMP_ROOT/err.txt")"
assert_contains "$(cat "$OUT")" "\"ran\":\"$FX\"" "the lost runner's shard did not rerun here"
assert_contains "$(cat "$TMP_ROOT/err.txt")" "runner down1 lost: no connection" "the lost runner was not named"
pass "a lost runner's shard reruns here and is never a red"

# 6. A runner whose code root lacks the base commit cannot apply the bundle: also lost, not red.
runner_line own1 lab-own 2 > "$HOME_DIR/config/runners"
STRANGER="$TMP_ROOT/stranger-root"
git init -q -b main "$STRANGER"
git -C "$STRANGER" config user.email t@example.invalid
git -C "$STRANGER" config user.name t
cp -r "$FX/bin" "$STRANGER/bin"
git -C "$STRANGER" add -f . >/dev/null
git -C "$STRANGER" commit -q -m unrelated
sed -i "s| root=$RUNNER_ROOT | root=$STRANGER |" "$HOME_DIR/config/runners"
shard 7 "" || fail "an unappliable bundle turned the shard red: $(cat "$TMP_ROOT/err.txt")"
assert_contains "$(cat "$TMP_ROOT/err.txt")" "could not run the shard" "the unappliable bundle was not reported"
assert_contains "$(cat "$OUT")" "\"ran\":\"$FX\"" "the shard did not rerun here"
pass "a bundle the runner cannot apply reruns the shard here"

# 7. The shard job's timeout is its own, longer one; every other command keeps the queue's.
# shellcheck source=bin/jg-remote-job-lib.sh
. "$FX/bin/jg-remote-job-lib.sh"
[ "$(jg_remote_job_command_timeout jg-runner-shard.sh)" = 1200 ] || fail "the shard job did not get 1200 s"
[ "$(jg_remote_job_command_timeout jg-remote-doctor.sh)" = "$JG_REMOTE_JOB_TIMEOUT" ] || fail "another command lost the queue's timeout"
pass "the shard job carries 1200 s and other commands keep the queue's timeout"
