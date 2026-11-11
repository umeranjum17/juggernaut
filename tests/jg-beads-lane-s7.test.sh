#!/usr/bin/env bash
# Slice S7 on a real Beads store: a worker's row is owned by its Herdr agent name, the same across a relaunch, and the
# spawn generation is metadata.lane. A start from another generation is refused unless it is a relaunch. The moves run
# through the transition library the spawn calls. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the builds; without
# them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-beads-lane-s7)
WRAPPER=$ROOT/bin/jg-beads.sh CLI=$ROOT/bin/jg-backlog.sh
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_SPAWN_GEN JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
mkdir -p "$T/store" "$T/home/config" "$T/home/data" "$T/home/state"
export TZ=UTC TMPDIR=$T BEADS_DIR=$T/store/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
printf '%s\n' "$BEADS_DIR" > "$T/home/config/beads-dir"
jail=()
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --ro-bind "$ROOT" "$ROOT" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)

bd() { "${jail[@]}" "$WRAPPER" "$@"; }
axi() { JG_HOME="$T/home" "${jail[@]}" "$CLI" "$@"; }
field() {  # <id> <jq filter>: one value of the row as bd prints it.
  bd show "$1" --json 2>/dev/null | jq -r "(if type == \"array\" then .[0] else . end) | $2"
}
cat > "$T/transition.sh" <<'SH'
. "$BIN/jg-timeout-lib.sh"
. "$BIN/jg-backlog-lib.sh"
. "$BIN/jg-backlog-transition-lib.sh"
state=$JG_HOME/state data=$JG_HOME/data op=$1 id=$2
shift 2
case "$op" in
  dispatch|handover)
    printf 'spawn_gen=%s\nharness=claude\n' "$1" > "$state/$id.meta"
    jg_backlog_atomic_transition "$op" "$state/$id.meta" "$data" "$id" "$state" ;;
  close) jg_backlog_atomic_transition close "" "$state/$id.backlog-close" "$data" "$id" "$state" "$@" ;;
esac
rc=$?
printf '%s rc=%s %s\n' "$op" "$rc" "${JG_BACKLOG_TRANSITION_ERROR:-}"
exit "$rc"
SH
spawn() {  # <op> <id> <spawn gen>: the library's answer on the home.
  env -u JG_DATA_OVERRIDE -u JG_STATE_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$T/home" BIN="$ROOT/bin" \
    "${jail[@]}" bash "$T/transition.sh" "$@" 2>&1
}

# The agent-name core is built once here, outside the jail, so the jailed library only runs it.
export JG_HERDR_BIN=$T/jg-herdr
"$ROOT/bin/jg-herdr.sh" agent-name-for jg-s7a >/dev/null || fail "build the agent-name core"

bd init --prefix jg >"$T/init.log" 2>&1 || fail "init the store: $(cat "$T/init.log")"
axi add jg-s7a "[feature] Worker row" --priority 2 --body why >/dev/null || fail "seed the row"
name=$("$ROOT/bin/jg-herdr.sh" agent-name-for jg-s7a)
[ "$name" = jg-s7a ] || fail "the agent name of the seeded id must be the id, got [$name]"

out=$(spawn dispatch jg-s7a s1.1.1) || fail "the first spawn must start the row: $out"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "the assignee must be the agent name, got [$(field jg-s7a .assignee)]"
[ "$(field jg-s7a .metadata.lane)" = s1.1.1 ] || fail "metadata.lane must be the spawn generation"
[ "$(field jg-s7a .metadata.agent)" = claude ] || fail "metadata.agent must be the harness"
printf 'ok - a start owns the row under the agent name, with the generation in metadata.lane\n'

out=$(spawn handover jg-s7a s2.2.2) || fail "a relaunch must take the row: $out"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "a relaunch must keep the agent name"
[ "$(field jg-s7a .metadata.lane)" = s2.2.2 ] || fail "a relaunch must move metadata.lane"
printf 'ok - a relaunch keeps the name and moves the generation\n'

out=$(spawn dispatch jg-s7a s3.3.3)
rc=$?
[ "$rc" = 13 ] || fail "a second spawn must exit 13, got $rc: $out"
assert_contains "$out" 'stale write refused: jg-s7a is held by lane \"s2.2.2\"' "a second spawn must name the generation that holds the row"
[ "$(field jg-s7a .metadata.lane)" = s2.2.2 ] || fail "a refused spawn must change nothing"
spawn dispatch jg-s7a s2.2.2 >/dev/null || fail "a repeat of the holding generation must pass"
printf 'ok - a second spawn is refused: %s\n' "$out"

spawn close jg-s7a --pr https://github.com/o/r/pull/9 >/dev/null || fail "close the row"
[ "$(field jg-s7a .status)" = closed ] || fail "the row must close"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "a closed row must keep the agent name as history"
printf 'ok - the row closes under the agent name\n'
pass "jg-beads lane s7"
