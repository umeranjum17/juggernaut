#!/usr/bin/env bash
# bin/jg-ship-local.sh stages a task's lane locally: push, prove the exact head,
# merge through the guarded path, then sync the homes.
# This drives the real script against a real git lane, a local bare origin and
# stub stage commands, so the stage order, the wall-clock lines, the stop after a
# refused merge and the head-mismatch refusal are proven rather than described.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIP="$ROOT/bin/jg-ship-local.sh"
TMP_ROOT=$(jg_test_tmproot jg-ship-local)
SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
URL='https://github.com/umeranjum17/juggernaut/pull/401'

# One task world: a stub repo holding the real script and stub stage commands, a
# real git lane whose origin is a local bare repository, a lead home, and the
# task's records.
world() {  # <name>
  local name=$1 dir repo lane
  dir="$TMP_ROOT/$name"
  repo="$dir/repo"
  lane="$dir/lane"
  mkdir -p "$dir/home/state" "$dir/home/data" "$repo/bin" "$dir/fakebin"
  cp "$SHIP" "$repo/bin/jg-ship-local.sh"
  cp "$ROOT/bin/jg-pr-lib.sh" "$repo/bin/jg-pr-lib.sh"

  cat > "$repo/bin/jg-local-suite.sh" <<EOF
#!/usr/bin/env bash
echo "local-suite: exit=0 wall=1s shards=1 head=$SHA1"
exit "\$(cat $dir/suite.rc 2>/dev/null || echo 0)"
EOF
  cat > "$repo/bin/jg-pr-merge.sh" <<EOF
#!/usr/bin/env bash
echo "merge: attempted"
exit "\$(cat $dir/merge.rc 2>/dev/null || echo 0)"
EOF
  cat > "$repo/bin/jg-update.sh" <<'EOF'
#!/usr/bin/env bash
echo "juggernaut: already current"
echo "jg-alpha: updated 1111111..2222222"
EOF
  chmod +x "$repo/bin/"*.sh

  # The forge head read: the lane's own commit unless the case says otherwise.
  cat > "$dir/fakebin/gh" <<EOF
#!/usr/bin/env bash
cat $dir/forge-head 2>/dev/null
exit 0
EOF
  chmod +x "$dir/fakebin/gh"

  git init -q --bare "$dir/origin.git" || return 1
  git init -q "$lane" || return 1
  printf 'lane work\n' > "$lane/work.txt"
  git -C "$lane" -c user.name=test -c user.email=test@example.invalid add work.txt || return 1
  git -C "$lane" -c user.name=test -c user.email=test@example.invalid commit -q -m lane || return 1
  git -C "$lane" checkout -q -b fm/lane || return 1
  git -C "$lane" remote add origin "$dir/origin.git" || return 1
  head=$(git -C "$lane" rev-parse HEAD)
  printf '%s\n' "$head" > "$dir/forge-head"

  # A lead home so the sync stage has one local home to name.
  git init -q "$dir/lead" || return 1
  printf 'lead\n' > "$dir/lead/README.md"
  git -C "$dir/lead" -c user.name=test -c user.email=test@example.invalid add README.md || return 1
  git -C "$dir/lead" -c user.name=test -c user.email=test@example.invalid commit -q -m lead || return 1

  printf 'kind=squad_lead\nhome=%s\n' "$dir/lead" > "$dir/home/state/jg-alpha.meta"
  printf 'kind=ship\nworktree=%s\nbranch=fm/lane\nmode=direct-PR\nproject=%s\n' \
    "$lane" "$repo" > "$dir/home/state/ship-one.meta"
  printf '%s\n' "$dir"
}

# ship <dir> [<task>] [<url>]: run the real script in that world.
ship() {  # <dir> [<task>] [<url>]
  local dir=$1 task=${2:-ship-one} url=${3:-$URL}
  ( cd "$dir/repo" && \
    PATH="$dir/fakebin:$PATH" \
    JG_HOME="$dir/home" JG_STATE_OVERRIDE="$dir/home/state" JG_DATA_OVERRIDE="$dir/home/data" \
    JG_ROOT_OVERRIDE="$dir/repo" \
    bash "$dir/repo/bin/jg-ship-local.sh" "$task" "$url" 2>&1 )
}

test_every_stage_runs_in_order_and_reports_its_wall_clock() {
  local dir out
  dir=$(world happy) || fail 'the fixture world must build'
  out=$(ship "$dir") || fail "a ship run must succeed: $out"
  assert_contains "$out" 'stage=push wall=' 'the push stage must report its wall clock'
  assert_contains "$out" 'stage=suite wall=' 'the suite stage must report its wall clock'
  assert_contains "$out" 'stage=merge wall=' 'the merge stage must report its wall clock'
  assert_contains "$out" 'stage=sync wall=' 'the sync stage must report its wall clock'
  assert_contains "$out" ' = ' 'the summary must total the run'
  [ "$(printf '%s\n' "$out" | grep -n 'stage=' | head -1)" != '' ] || fail 'the stages must be printed'
  local order
  order=$(printf '%s\n' "$out" | sed -n 's/^ship-local: stage=\([a-z]*\).*/\1/p' | tr '\n' ' ')
  [ "$order" = 'push suite merge sync ' ] || fail "the stages must run push, suite, merge, sync; got: $order"
  assert_contains "$out" 'synced-home: juggernaut ' 'the sync stage must name this home and the commit it ends on'
  assert_contains "$out" "synced-home: jg-alpha " 'the sync stage must name the lead home and the commit it ends on'
  pass 'every stage runs in order and reports its wall clock'
}

test_a_refused_merge_stops_before_the_sync() {
  local dir out rc=0
  dir=$(world merge-refused) || fail 'the fixture world must build'
  printf '7\n' > "$dir/merge.rc"
  out=$(ship "$dir") || rc=$?
  [ "$rc" -eq 7 ] || fail "a refused merge must exit with the merge's status 7, got $rc: $out"
  assert_contains "$out" 'stage=merge failed' 'the refusal must name the merge stage'
  assert_contains "$out" 'nothing was synced' 'the refusal must say the homes were not synced'
  assert_not_contains "$out" 'stage=sync' 'a refused merge must not reach the sync stage'
  [ ! -e "$dir/home/data/jg-ship-local/ship-one-sync.log" ] \
    || fail 'a refused merge must not run the sync stage at all'
  pass 'a refused merge stops before the sync'
}

test_a_forge_head_that_is_not_the_lane_head_refuses() {
  local dir out rc=0
  dir=$(world head-mismatch) || fail 'the fixture world must build'
  printf '%s\n' "$SHA2" > "$dir/forge-head"
  out=$(ship "$dir") || rc=$?
  [ "$rc" -eq 1 ] || fail "a head mismatch must exit 1, got $rc: $out"
  assert_contains "$out" 'stage=push failed' 'the mismatch must be named at the push stage'
  assert_contains "$out" 'the suite would prove a commit this pull request does not hold' \
    'the refusal must say why the suite cannot run'
  [ ! -e "$dir/home/data/jg-ship-local/ship-one-suite.log" ] \
    || fail 'a head mismatch must not run the suite'
  pass 'a forge head that is not the lane head refuses'
}

test_a_dirty_lane_is_refused_before_anything_runs() {
  local dir out rc=0
  dir=$(world dirty) || fail 'the fixture world must build'
  printf 'uncommitted\n' > "$dir/lane/work.txt"
  out=$(ship "$dir") || rc=$?
  [ "$rc" -eq 1 ] || fail "a dirty lane must exit 1, got $rc: $out"
  assert_contains "$out" 'uncommitted changes' 'the refusal must name the dirty tree'
  [ ! -e "$dir/home/data/jg-ship-local/ship-one-push.log" ] \
    || fail 'a dirty lane must be refused before the push'
  pass 'a dirty lane is refused before anything runs'
}

test_a_request_that_cannot_be_satisfied_is_refused() {
  local dir out rc=0
  dir=$(world misuse) || fail 'the fixture world must build'
  out=$(ship "$dir" 'not a task id!' "$URL") || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed task id must exit 2, got $rc"
  rc=0
  out=$(ship "$dir" ship-one 'https://github.com/umeranjum17/juggernaut/pull/notanumber') || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed URL must exit 2, got $rc"
  rc=0
  out=$(ship "$dir" ship-one 'https://gitlab.example.com/o/r/-/merge_requests/1') || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-GitHub change must exit 2, got $rc: $out"
  assert_contains "$out" 'GitHub pull request head' 'the refusal must say why another forge cannot be shipped'
  pass 'a request that cannot be satisfied is refused'
}

test_every_stage_runs_in_order_and_reports_its_wall_clock
test_a_refused_merge_stops_before_the_sync
test_a_forge_head_that_is_not_the_lane_head_refuses
test_a_dirty_lane_is_refused_before_anything_runs
test_a_request_that_cannot_be_satisfied_is_refused
printf 'jg-ship-local: ok\n'
