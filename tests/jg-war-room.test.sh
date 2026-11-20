#!/usr/bin/env bash
# /war-room starts its variant Recons together with one command: bin/jg-war-room.sh start files one child ticket of the council
# for each angle (found again by its exact title, never filed twice), writes each Recon's brief, and starts every lane that has no
# live task record at the same time. Real bin/jg-war-room.sh, bin/jg-brief.sh, bin/jg-backlog.sh and bin/jg-spawn.sh over a fixture
# project and a Beads store; only the terminal and the worktree tool are stand-ins. The spawn command is JG_WAR_ROOM_SPAWN, a
# wrapper that gives each lane its own copy and runs the real spawn, the way tests/jg-spawn-lock-deferral.test.sh runs it.
#
# T1 three angles: three child tickets of the council, three briefs that hold `Recon depth: standard` and their angle, three task
#    records within 120 s, three `live` lines, exit 0, and the three spawns start within 5 s of each other (one after another they
#    could not: each spawn holds back 3 s before it starts).
# T2 run again: no new ticket, no second record, three `already live` lines, exit 0.
# T3 a spawn refused for one angle (its project is missing for that one lane): exit 1, the line names the refusal, the other two
#    lanes are live.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-war-room)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$HOME_DIR/projects/proj"
mkdir -p "$W" "$HOME_DIR/projects"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

# The stand-in spawn command: the real jg-spawn.sh in a throwaway HOME, in a copy of its own for each lane. It notes when it was
# started, holds back 3 s, and for the angle named in $W/refuse-angle points the spawn at a project that is not there.
STARTS="$W/starts"; mkdir -p "$STARTS"
SPAWN_WRAP="$W/spawn-wrap.sh"
cat > "$SPAWN_WRAP" <<WRAP
#!/usr/bin/env bash
task=\$1; proj=\$2; shift 2
date +%s > "$STARTS/\$task"
sleep 3
refuse=\$(cat "$W/refuse-angle" 2>/dev/null)
if [ -n "\$refuse" ] && grep -qx "Angle: \$refuse" "$HOME_DIR/data/\$task/brief.md" 2>/dev/null; then proj="$W/no-such-project"; fi
wt="$W/wt-\$task"
until mkdir "$W/wt.lock" 2>/dev/null; do /bin/sleep 0.1; done
git -C "$PROJ" worktree add -q --detach "\$wt" origin/main >/dev/null 2>&1
rmdir "$W/wt.lock"
mkdir -p "$HOME_DIR/user-home"
JG_ROOT_OVERRIDE='' JG_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
  XDG_DATA_HOME="$HOME_DIR/user-home/.local/share" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" \
  JG_PROJECTS_OVERRIDE="$HOME_DIR/projects" JG_CONFIG_OVERRIDE="$HOME_DIR/config" JG_SPAWN_NO_GUARD=1 \
  JG_FAKE_PANE_PATH="\$wt" TMUX=fake,1,0 PATH="$FAKEBIN:\$PATH" \
  exec "$ROOT/bin/jg-spawn.sh" "\$task" "\$proj" "\$@"
WRAP
chmod +x "$SPAWN_WRAP"

war_room() {  # <council> <angles> -> sets out, rc
  out=$(JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config" \
    JG_PROJECTS_OVERRIDE="$HOME_DIR/projects" JG_WAR_ROOM_SPAWN="$SPAWN_WRAP" \
    "$ROOT/bin/jg-war-room.sh" start "$1" --project proj --angles "$2" --depth standard --harness codex --model gpt-5.5 --effort high 2>&1)
  rc=$?
}
children() {  # <council> -> the ids of its children
  JG_HOME="$HOME_DIR" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" list --parent "$1" --all --limit 0 --json 2>/dev/null | jq -r '.[]?.id' | sort
}

# T1: three angles at once.
council=jg-wrc
jg_test_add "$HOME_DIR" "$council" "[feature] War room council"
t1_start=$(date +%s)
war_room "$council" "alpha,bravo,gamma"
t1_took=$(( $(date +%s) - t1_start ))
expect_code 0 "$rc" "T1 every lane should be live: $out"
kids=$(children "$council")
[ "$(printf '%s\n' "$kids" | grep -c .)" = 3 ] || fail "T1 the council should have three child tickets, has: $kids"
for angle in alpha bravo gamma; do
  assert_contains "$out" "$angle: " "T1 no line for $angle"
  line=$(printf '%s\n' "$out" | grep "^$angle: ")
  task=$(printf '%s\n' "$line" | sed -n "s/^$angle: \([^ ]*\) live\$/\1/p")
  [ -n "$task" ] || fail "T1 the line for $angle should read '$angle: <task> live', got: $line"
  [ -f "$HOME_DIR/state/$task.meta" ] || fail "T1 no task record for $angle ($task)"
  brief="$HOME_DIR/data/$task/brief.md"
  grep -qx 'Recon depth: standard' "$brief" || fail "T1 the brief of $angle does not hold 'Recon depth: standard'"
  grep -qx "Angle: $angle" "$brief" || fail "T1 the brief of $angle does not name its angle"
  grep -q 'jg-recon-handoff.sh draft' "$brief" || fail "T1 the brief of $angle lacks the handoff spec lines"
  grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$brief" && fail "T1 the brief of $angle still holds a placeholder"
  show=$(jg_test_backlog "$HOME_DIR" show "${task#fable-}" 2>&1 || true)
  assert_contains "$show" "$angle variant Recon" "T1 the child ticket of $angle has the wrong title"
done
[ "$(printf '%s\n' "$out" | grep -c ' live$')" = 3 ] || fail "T1 the output should have three live lines: $out"
[ "$t1_took" -lt 120 ] || fail "T1 the three lanes took ${t1_took}s; the limit is 120 s"
lo=999999999999 hi=0
for f in "$STARTS"/*; do
  t=$(cat "$f"); [ "$t" -ge "$hi" ] && hi=$t; [ "$t" -le "$lo" ] && lo=$t
done
[ "$(find "$STARTS" -type f | wc -l)" = 3 ] || fail "T1 three spawns should have started"
[ $((hi - lo)) -le 5 ] || fail "T1 the three spawns started $((hi - lo)) s apart; they must start within 5 s of each other"
pass "T1 three angles: three tickets, three briefs, three records, started together"

# T2: a second run changes nothing.
records_before=$(find "$HOME_DIR/state" -name '*.meta' | sort | xargs md5sum)
war_room "$council" "alpha,bravo,gamma"
expect_code 0 "$rc" "T2 the second run should exit 0: $out"
[ "$(children "$council")" = "$kids" ] || fail "T2 the second run filed a ticket: $(children "$council")"
[ "$(printf '%s\n' "$out" | grep -c ' already live$')" = 3 ] || fail "T2 the output should have three 'already live' lines: $out"
[ "$(find "$HOME_DIR/state" -name '*.meta' | sort | xargs md5sum)" = "$records_before" ] || fail "T2 the second run changed a task record"
[ "$(find "$STARTS" -type f | wc -l)" = 3 ] || fail "T2 the second run started a spawn"
pass "T2 a second run files nothing, starts nothing and reports already live"

# T3: one lane's spawn is refused.
council3=jg-wrd
jg_test_add "$HOME_DIR" "$council3" "[feature] War room refusal"
printf 'gamma\n' > "$W/refuse-angle"
war_room "$council3" "alpha,bravo,gamma"
rm -f "$W/refuse-angle"
expect_code 1 "$rc" "T3 a refused lane should make the exit 1: $out"
[ "$(printf '%s\n' "$out" | grep -c ' live$')" = 2 ] || fail "T3 two lanes should be live: $out"
line=$(printf '%s\n' "$out" | grep '^gamma: ')
assert_contains "$line" "not started: " "T3 the refused lane's line should say not started"
[ "${line#*not started: }" != "" ] || fail "T3 the refused lane's line names no refusal: $line"
for angle in alpha bravo; do
  task=$(printf '%s\n' "$out" | sed -n "s/^$angle: \([^ ]*\) live\$/\1/p")
  [ -f "$HOME_DIR/state/$task.meta" ] || fail "T3 the $angle lane left no task record"
done
gtask=$(printf '%s\n' "$line" | sed -n 's/^gamma: \([^ ]*\) not started.*/\1/p')
[ -n "$gtask" ] && [ ! -f "$HOME_DIR/state/$gtask.meta" ] || fail "T3 the refused lane should have no task record: $line"
pass "T3 a refused spawn is named, the exit is 1 and the other lanes are live"
