#!/usr/bin/env bash
# E2E: `jg proof` placement (H30d). The real proof.sh runs from a worker worktree; with this host's heavy slots full and a registered
# runner it runs the proof on the runner through the real core/runners/run-shard.sh, bin/jg-on.sh and bin/jg-runner-shard.sh (only the
# SSH boundary and bin/jg-test-run.sh are stand-ins) and writes the record here; with a free slot, or a lost runner, it runs here.
# Usage: core/agent-cli/tests/proof-runner.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC=$(cd "$here/../../.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/proof-runner.XXXXXX") || exit 1
d=$(cd "$d" && pwd -P)
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
export TMPDIR=$d JG_TEST_HOST_SLOTS=$d/slots
mkdir -p "$d/slots" "$d/fakebin"

H=$d/home; P=$H/projects/proj
mkdir -p "$H/state" "$H/config" "$H/data" "$P/core" "$P/bin"
cp -r "$SRC/bin/." "$P/bin/"; cp -r "$SRC/core/agent-cli" "$SRC/core/lane-scale" "$SRC/core/runners" "$P/core/"
cat > "$P/bin/jg-test-run.sh" <<'S'
#!/usr/bin/env bash
json=; args=()
while [ "$#" -gt 0 ]; do case "$1" in --json) json=$2; shift 2 ;; *) args+=("$1"); shift ;; esac; done
printf '{"ran":"%s","args":"%s"}\n' "$(cd "$(dirname "$0")/.." && pwd)" "${args[*]}" > "$json"
S
git -C "$P" init -q -b main; git -C "$P" config user.email t@example.invalid; git -C "$P" config user.name t
git -C "$P" add -f . >/dev/null; git -C "$P" commit -q -m base
RUNNER_ROOT=$d/runner-root; git clone -q "$P" "$RUNNER_ROOT"
WT=$d/wt; git -C "$P" worktree add -q -b feature/t1 "$WT" || fail worktree
WT=$(cd "$WT" && pwd -P)
echo change > "$WT/change.txt"; git -C "$WT" add change.txt; git -C "$WT" commit -q -m change
printf 'worktree=%s\nkind=ship\nmode=local-trunk\nbranch=feature/t1\nproject=%s\n' "$WT" "$P" > "$H/state/t1.meta"
STUB=$d/stub-done-done
printf '#!/usr/bin/env bash\necho "stub done-done $* ran-here"\n' > "$STUB"; chmod +x "$STUB"
cat > "$d/fakebin/fake-ssh" <<'S'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
host=$1 root_b64=$4 argv_b64=$6
[ "$host" != lab-down ] || exit 255
root=$(printf '%s' "$root_b64" | base64 -d); mapfile -d '' argv < <(printf '%s' "$argv_b64" | base64 -d)
JG_ROOT_OVERRIDE="$root" exec env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" JG_ROOT_OVERRIDE="$root" "$root/bin/${argv[0]}" "${argv[@]:1}"
S
chmod +x "$d/fakebin/fake-ssh"; export JG_SSH_BIN=$d/fakebin/fake-ssh
arch=$(case $(uname -m) in aarch64|arm64) echo arm64 ;; *) echo x86_64 ;; esac)
runner() { printf '%s ssh=%s root=%s home=%s arch=%s cores=8 mem_gb=16 slots=1 cost_per_hour=0 private_ok=yes\n' lab "$1" "$RUNNER_ROOT" "$d/rh" arch="$arch" | sed "s/arch=arch=/arch=/" > "$H/config/runners"
  printf '%s\tlab\tok\t4\t\n' "$(date +%s)" > "$H/state/runner-health.tsv"; }
jg() { (cd "$WT" && env -u JG_TASK JG_HOME="$H" JG_CLI_POLL=1 JG_DONE_DONE="$STUB" bash "$P/core/agent-cli/proof.sh" "$@" 2>&1); }
printf 'heavy_slots=1\n' > "$H/config/lane-scale"; runner lab-up
log=$H/data/t1/jg-proof.log

# 1. A free slot: the proof runs here, as before, and no runner is used.
out=$(jg --wait); has local "$out" "proof: ended, exit 0"; has local-log "$(cat "$log")" "ran-here"
[ ! -e "$H/data/t1/jg-proof.json" ] || fail "a runner result exists though the slot was free"
[ -z "$(ls "$H/state/heavy-slots" 2>/dev/null)" ] || fail "the slot stayed taken"
echo "ok 1: a free heavy slot: the proof ran here (done-done), no runner was used, and the slot was given back"

# 2. The host's one slot is held by a live run: the proof goes to the runner; the record and the result are written here.
sleep 60 & holder=$!; mkdir -p "$H/state/heavy-slots"; echo "$holder" > "$H/state/heavy-slots/other"
out=$(jg --wait); kill "$holder" 2>/dev/null
has runner "$out" "proof: ended, exit 0"
has runner-log "$(cat "$log")" "goes to runner lab"
has runner-json "$(cat "$H/data/t1/jg-proof.json")" "--changed --base $(git -C "$WT" rev-parse HEAD^)"
case $(cat "$H/data/t1/jg-proof.json") in *"\"ran\":\"$P\""*) fail "the proof ran here, not on the runner" ;; esac
case $(cat "$log") in *ran-here*) fail "done-done ran here though the host was full" ;; esac
echo "ok 2: the host's one heavy slot was held by a live run: the proof went to runner lab; the runner result $(cat "$H/data/t1/jg-proof.json") came back to jg-proof.json; the record here reads: $(cat "$H/data/t1/jg-proof.state" | cut -d' ' -f1,3)"

# 3. The host is full and the runner is lost: the run stays here and is not a red.
runner lab-down; sleep 60 & holder=$!; echo "$holder" > "$H/state/heavy-slots/other"
out=$(jg --wait); kill "$holder" 2>/dev/null
has lost "$out" "proof: ended, exit 0"; has lost-log "$(cat "$log")" "was lost"
echo "ok 3: the host was full and the runner was lost (no connection): the run stayed here and ended exit 0, not red; log: $(grep -m1 "was lost" "$log")"
echo "PASS: jg proof placement"
