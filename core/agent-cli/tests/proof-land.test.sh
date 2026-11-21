#!/usr/bin/env bash
# E2E: the proof and land verbs (core/agent-cli/proof.sh, land.sh) run from a worker worktree with no JG_HOME, JG_TASK or loop.
# done-done is a stub named by JG_DONE_DONE; landing records are written the way core/trunk-landing writes them.
# Usage: core/agent-cli/tests/proof-land.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/proof-land.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
jg() { (cd "$WT" && env -u JG_HOME -u JG_TASK -u JG_STATE_OVERRIDE JG_CLI_POLL=1 JG_DONE_DONE="$STUB" bash "$ROOT/core/agent-cli/$1.sh" "${@:2}" 2>&1); }

H=$d/home; P=$H/projects/proj
mkdir -p "$H/state" "$H/data/jg-trunk-landing"
git -C "$P" init -q . 2>/dev/null || { mkdir -p "$P"; git -C "$P" init -q .; }
git -C "$P" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
WT=$d/wt
git -C "$P" worktree add -q -b feature/t1 "$WT" || fail "worktree"
WT=$(cd "$WT" && pwd -P)
printf 'worktree=%s\nkind=ship\nmode=local-trunk\nbranch=feature/t1\nproject=%s\n' "$WT" "$P" > "$H/state/t1.meta"
head=$(git -C "$P" rev-parse feature/t1)
STUB=$d/stub-done-done
cat > "$STUB" <<'S'
#!/usr/bin/env bash
echo "stub done-done $* in $(pwd) home=${JG_HOME:-unset}"
[ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
exit "${STUB_RC:-0}"
S
chmod +x "$STUB"

# proof: affected by default, a command through run, the log in the home's data folder
out=$(jg proof --wait); has proof "$out" "proof: ended, exit 0"; has proof "$out" "stub done-done affected in $WT home=$H"
has proof-next "$out" "Next:"
out=$(jg proof --wait -- bash -c 'echo hi'); has proof-run "$out" "stub done-done run -- bash -c echo hi"
out=$(STUB_RC=1 jg proof --wait); case $out in *"exit 1"*"Next: fix what the log shows"*) ;; *) fail "red proof: $out" ;; esac
STUB_RC=1 jg proof --wait >/dev/null; [ $? = 1 ] || fail "red proof must exit 1"
# a run that outlasts the bound returns with the log and exit 3, and the next call finds it still running
export STUB_SLEEP=4
out=$(jg proof --wait --bound 1); rc=$?; [ $rc = 3 ] || fail "bound: exit $rc"; has bound "$out" "still running after 1 s"
out=$(jg proof); has running "$out" "proof: running"
out=$(jg proof --wait --bound 30); has finished "$out" "proof: ended, exit 0"
unset STUB_SLEEP
echo dirty > "$WT/x"; out=$(jg proof) && fail "dirty tree passed"; has dirty "$out" "not clean"; rm -f "$WT/x"
out=$(jg proof --bound x) && fail "bad bound passed"; has badbound "$out" "whole seconds"

# proof on a trunk project: `done-done affected` gets the commit the lane left the trunk at, never the project's stale main
# (which would select every journey of the trunk's history), and a trunk that moved on since is not in the lane's diff
TP=$H/projects/tproj; TG="git -C $TP -c user.email=t@example.com -c user.name=t"
git -C "$TP" init -q -b main . 2>/dev/null || { mkdir -p "$TP"; git -C "$TP" init -q -b main .; }
$TG commit -q --allow-empty -m stale-main
$TG checkout -q -b trunk; $TG commit -q --allow-empty -m trunk-1; $TG commit -q --allow-empty -m trunk-2
fork=$(git -C "$TP" rev-parse trunk); stale=$(git -C "$TP" rev-parse main)
SAVE_WT=$WT; WT=$d/twt
git -C "$TP" worktree add -q -b feature/t2 "$WT" trunk || fail "trunk worktree"
WT=$(cd "$WT" && pwd -P)
printf 'worktree=%s\nkind=ship\nmode=local-trunk\nbranch=feature/t2\nproject=%s\n' "$WT" "$TP" > "$H/state/t2.meta"
$TG commit -q --allow-empty -m trunk-3-after-fork   # trunk is checked out nowhere: this moves it ahead of the lane
printf '%s\n' '- tproj [local-trunk] - fixture' > "$H/data/projects.md"; : > "$H/state/trunk-tip-tproj"
(cd "$WT" && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m lane)
out=$(jg proof --wait); has trunk-base "$out" "stub done-done affected $fork in $WT"
case $out in *"$stale"*) fail "the stale main is the base: $out" ;; esac
# a project that is not a trunk project keeps done-done's own default base
printf '%s\n' '- tproj [direct-PR] - fixture' > "$H/data/projects.md"
out=$(jg proof --wait); has plain-base "$out" "stub done-done affected in $WT"
WT=$SAVE_WT

# land: before the done line, with a done line, then each record the lander writes
mem=$H/data/jg-trunk-landing
out=$(jg land); rc=$?; [ $rc = 3 ] || fail "notready exit $rc"; has notready "$out" "landing: notready"; has notready "$out" "no done line yet"
printf 'done [at=100]: ready in branch feature/t1 (local-trunk)\n' > "$H/state/t1.status"
printf 'worktree=/x\nkind=ship\nmode=local-trunk\nbranch=feature/o\nproject=%s\n' "$P" > "$H/state/o1.meta"
git -C "$P" branch feature/o; printf 'done [at=50]: ready\n' > "$H/state/o1.status"
out=$(jg land); has proofgap "$out" "landing: notready"; has proofgap "$out" "proof inputs missing"
printf 'env-wait build host busy\n' > "$mem/t1.$head.state"
out=$(jg land); has envwait "$out" "landing: waiting"; has envwait "$out" "build host busy"
printf 'running 1 99\n' > "$mem/t1.$head.state"
out=$(jg land); has running "$out" "landing: running"
printf 'final conflict in a.txt\n' > "$mem/t1.$head.state"
out=$(jg land); rc=$?; [ $rc = 1 ] || fail "refused exit $rc"; has refused "$out" "landing: refused"; has refused "$out" "conflict in a.txt"; has refused "$out" "Next: fix it in the lane"
# --wait returns by itself when the landing ends, and at the bound when it does not
printf 'running 1 99\n' > "$mem/t1.$head.state"
( sleep 2; printf 'landed abc123\n' > "$mem/t1.$head.state" ) &
out=$(jg land --wait --bound 30); rc=$?; [ $rc = 0 ] || fail "landed exit $rc: $out"; has landed "$out" "landing: landed"; has landed "$out" "abc123"
printf 'running 1 99\n' > "$mem/t1.$head.state"
out=$(jg land --wait --bound 2); rc=$?; [ $rc = 3 ] || fail "land bound exit $rc"; has landbound "$out" "bound of 2 s passed"
# a pull-request lane has no landing queue
printf 'worktree=%s\nkind=ship\nmode=direct-PR\nbranch=feature/t1\nproject=%s\n' "$WT" "$P" > "$H/state/t1.meta"
out=$(jg land) && fail "PR lane passed"; has prlane "$out" "no landing queue"
echo PASS
