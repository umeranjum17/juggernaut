#!/usr/bin/env bash
# A fresh ship whose only refusal is a file another live lane holds waits (exit 75, one `deferred:` line, nothing
# written) instead of failing for good; any other refusal still exits 1, JG_SPAWN_HELD_FILE_REFUSES=1 keeps the
# old exit 1, and a hot file another lane leases defers the same way. Each case runs the real bin/jg-spawn.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-held-file-defers)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
mkdir -p "$PROJ/bin"
printf 'v1\n' > "$PROJ/AGENTS.md"; printf 'a\n' > "$PROJ/bin/a.sh"; printf 'b\n' > "$PROJ/bin/b.sh"; printf 'c\n' > "$PROJ/bin/c.sh"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
bd_() { JG_HOME=$HOME_DIR python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" "$@"; }

# lane <id> <label> <files json>: file a plan-filed row, scaffold its brief, spawn it; sets id, out, rc.
lane() {
  local label=$2 files=$3 wt="$W/wt-$1"; id=$1
  jg_test_add "$HOME_DIR" "$id" "[feature] defer $id"
  bd_ update "$id" --remove-label project:demo --add-label "project:$label" --set-metadata "files=$files" \
    --set-metadata "new_files=[]" >/dev/null 2>&1 || fail "could not set the plan fields of $id"
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" --migration-row none >/dev/null 2>&1 \
    || fail "could not scaffold the brief for $id"
  sed -i "s|{TASK}|Defer $id.|;s|{JUGGERNAUT_SPEC}|Exercise the held-file deferral.|" "$HOME_DIR/data/$id/brief.md"
  git -C "$PROJ" worktree add -q --detach "$wt" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  out=$(jg_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off 2>&1); rc=$?
}
row_status() { bd_ show "$1" --json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end).status'; }
wrote_nothing() {  # the last lane wrote no task record, took no lease and moved no backlog row
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a deferred ticket wrote a task record"
  [ ! -e "$HOME_DIR/state/file-leases/$id" ] || fail "a deferred ticket took a lease"
  [ "$(git -C "$W/wt-$id" branch --show-current)" = "" ] || fail "a deferred ticket changed its copy"
  [ "$(row_status "$id")" != in_progress ] || fail "a deferred ticket moved its backlog row to in progress"
}

# The live lane L holds bin/a.sh.
lane jg-hf-l proj '["bin/a.sh"]'
expect_code 0 "$rc" "setup: the first lane must launch: $out"
bd_ update jg-hf-l --status in_progress >/dev/null 2>&1 || fail "could not mark the live lane"

# T1: every refusal is a held file: the start waits.
lane jg-hf1 proj '["bin/a.sh","bin/b.sh"]'
expect_code 75 "$rc" "T1: a file another live lane holds must defer the start: $out"
assert_contains "$out" "deferred:" "T1: the line must say the start is deferred"
assert_contains "$out" "held by the live lane jg-hf-l" "T1: the line must name the holder"
assert_contains "$out" "bin/a.sh" "T1: the line must name the file"
wrote_nothing
echo "ok - a file another live lane holds defers the start (exit 75)"

# T2: another reason as well keeps the failed start, the other reason first.
lane jg-hf2 elsewhere '["bin/a.sh","bin/b.sh"]'
expect_code 1 "$rc" "T2: a mixed refusal must still fail: $out"
assert_contains "$out" "wrong-repo: ticket jg-hf2 belongs to elsewhere, not proj" "T2: the other reason must be named"
case $out in *deferred:*) fail "T2: a mixed refusal must not say deferred: $out" ;; esac
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T2: a refused ticket wrote a task record"
echo "ok - a held file beside another refusal still fails (exit 1)"

# T3: a free file is admitted as before.
lane jg-hf3 proj '["bin/b.sh"]'
expect_code 0 "$rc" "T3: a ticket whose files are free must launch: $out"
echo "ok - a free file launches"

# T4: the switch keeps today's refusal.
JG_SPAWN_HELD_FILE_REFUSES=1 lane jg-hf4 proj '["bin/a.sh","bin/b.sh"]'
expect_code 1 "$rc" "T4: the switch must keep the exit 1: $out"
assert_contains "$out" "held-file: bin/a.sh is held by the live lane jg-hf-l" "T4: the refusal must name the holder"
case $out in *deferred:*) fail "T4: the switch must not defer: $out" ;; esac
echo "ok - JG_SPAWN_HELD_FILE_REFUSES=1 keeps the exit 1"

# T5: a hot file another lane leases defers the same way (the admission passes: the holder is not in progress).
bd_ update jg-hf-l --status open >/dev/null 2>&1 || fail "could not unmark the live lane"
printf 'bin/c.sh\n' > "$HOME_DIR/config/hot-files"
mkdir -p "$HOME_DIR/state/file-leases"
touch "$HOME_DIR/state/jg-hf-holder.meta"
printf 'at=%s\nbin/c.sh\n' "$(date +%s)" > "$HOME_DIR/state/file-leases/jg-hf-holder"
lane jg-hf5 proj '["bin/c.sh"]'
expect_code 75 "$rc" "T5: a hot file another lane leases must defer the start: $out"
assert_contains "$out" "deferred:" "T5: the line must say the start is deferred"
assert_contains "$out" "lease-held: bin/c.sh is leased by the live lane jg-hf-holder" "T5: the line must name the holder"
wrote_nothing
JG_SPAWN_HELD_FILE_REFUSES=1 lane jg-hf6 proj '["bin/c.sh"]'
expect_code 1 "$rc" "T5: the switch must keep the lease refusal at exit 1: $out"
echo "ok - a hot file another lane leases defers the start; the switch keeps exit 1"
