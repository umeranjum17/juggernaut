#!/usr/bin/env bash
# Slice S7 on a real Beads store: a worker's row is owned by its Herdr agent name, the same across a relaunch, and the
# spawn generation is metadata.spawn_gen, with the model and effort beside it. The name is the task record's agent_name= (a record with none keeps the id's name). A start from another generation is refused unless it is a relaunch. The moves run
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
    printf 'spawn_gen=%s\nharness=claude\nmodel=m-5\neffort=high\n%s' "$1" "${2:+agent_name=$2$'\n'}" > "$state/$id.meta"
    jg_backlog_atomic_transition "$op" "$state/$id.meta" "$data" "$id" "$state" ;;
  rename) jg_backlog_lane_rename "$data" "$id" "$@" ;;
  reopen) jg_backlog_mutate "$data" reopen "$id" ;;
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
id_name=$("$ROOT/bin/jg-herdr.sh" agent-name-for jg-s7a)
[ "$id_name" = jg-s7a ] || fail "the agent name of the seeded id must be the id, got [$id_name]"
name=fix-the-row-jg-s7a

out=$(spawn dispatch jg-s7a s1.1.1 "$name") || fail "the first spawn must start the row: $out"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "the assignee must be the agent name of the record, got [$(field jg-s7a .assignee)]"
[ "$(field jg-s7a .metadata.spawn_gen)" = s1.1.1 ] || fail "metadata.spawn_gen must be the spawn generation"
[ "$(field jg-s7a .metadata.lane)" = null ] || fail "no metadata.lane is written"
[ "$(field jg-s7a .metadata.agent)" = claude ] || fail "metadata.agent must be the harness"
[ "$(field jg-s7a '.metadata.model|type+"="+.')" = string=m-5 ] || fail "metadata.model must be the model, as a string"
[ "$(field jg-s7a '.metadata.effort|type+"="+.')" = string=high ] || fail "metadata.effort must be the effort, as a string"
[ "$(field jg-s7a '.metadata.spawn_gen|type')" = string ] || fail "metadata.spawn_gen must be a string"
printf 'ok - a start owns the row under the record agent name, with generation, model and effort in metadata\n'

out=$(spawn handover jg-s7a s2.2.2 "$name") || fail "a relaunch must take the row: $out"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "a relaunch must keep the agent name"
[ "$(field jg-s7a .metadata.spawn_gen)" = s2.2.2 ] || fail "a relaunch must move metadata.spawn_gen"
printf 'ok - a relaunch keeps the name and moves the generation\n'

out=$(spawn dispatch jg-s7a s3.3.3 "$name")
rc=$?
[ "$rc" = 13 ] || fail "a second spawn must exit 13, got $rc: $out"
assert_contains "$out" 'stale write refused: jg-s7a is held by lane \"s2.2.2\"' "a second spawn must name the generation that holds the row"
[ "$(field jg-s7a .metadata.spawn_gen)" = s2.2.2 ] || fail "a refused spawn must change nothing"
spawn dispatch jg-s7a s2.2.2 "$name" >/dev/null || fail "a repeat of the holding generation must pass"
printf 'ok - a second spawn is refused: %s\n' "$out"

# Herdr kept a variant: the row follows the name that stuck, and only from the name that owns it.
out=$(spawn rename jg-s7a wrong-first stuck-name-1)
[ "$?" = 13 ] || fail "a rename from a name that does not own the row must exit 13: $out"
[ "$(field jg-s7a .assignee)" = "$name" ] || fail "a refused rename must change nothing"
spawn rename jg-s7a "$name" stuck-name-1 >/dev/null || fail "the rename from the owning name must pass"
[ "$(field jg-s7a .assignee)" = stuck-name-1 ] || fail "the assignee must be the name that stuck"
out=$(spawn handover jg-s7a s4.4.4 stuck-name-1) || fail "a relaunch under the name that stuck must take the row: $out"
[ "$(field jg-s7a .assignee)" = stuck-name-1 ] || fail "a relaunch must keep the name that stuck"
printf 'ok - a variant name moves the assignee once and the relaunch keeps it\n'

# A reclaimed row (open, no owner) is taken back by a relaunch under the same name.
spawn reopen jg-s7a >/dev/null || fail "reclaim the row"
[ -z "$(field jg-s7a '.assignee // empty')" ] || fail "a reclaimed row has no owner"
out=$(spawn handover jg-s7a s5.5.5 stuck-name-1) || fail "a relaunch must take a reclaimed row: $out"
[ "$(field jg-s7a .assignee)" = stuck-name-1 ] && [ "$(field jg-s7a .status)" = in_progress ] || fail "the reclaimed row must be owned and in flight again"
printf 'ok - a relaunch takes a reclaimed row\n'

# A record with no agent_name= (a lane from before) keeps the name made from its id.
axi add jg-s7b "[feature] Old record" --priority 2 --body why >/dev/null || fail "seed the old row"
spawn dispatch jg-s7b s1.1.1 >/dev/null || fail "an old record must start"
[ "$(field jg-s7b .assignee)" = jg-s7b ] || fail "a record with no agent name keeps the id's name, got [$(field jg-s7b .assignee)]"
printf 'ok - a record with no agent_name= keeps the name made from the id\n'

spawn close jg-s7a --pr https://github.com/o/r/pull/9 >/dev/null || fail "close the row"
[ "$(field jg-s7a .status)" = closed ] || fail "the row must close"
[ "$(field jg-s7a .assignee)" = stuck-name-1 ] || fail "a closed row must keep the agent name as history"
printf 'ok - the row closes under the agent name\n'
pass "jg-beads lane s7"
