#!/usr/bin/env bash
# A deep Recon critic starts from the project's version branch.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
jg_git_identity fmtest fmtest@example.com
W=$(jg_test_tmproot jg-critic-version)
H="$W/home"; P="$H/projects/proj"; S="$H/state"; D="$H/data"
mkdir -p "$H/projects" "$H/user-home"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$P" 2>/dev/null
printf 'main\n' > "$P/AGENTS.md"
git -C "$P" add AGENTS.md; git -C "$P" commit -qm main
git -C "$P" push -q origin HEAD:main
git -C "$P" checkout -qb release/c-1
printf 'version\n' > "$P/version-marker"
git -C "$P" add version-marker; git -C "$P" commit -qm version
git -C "$P" push -q origin HEAD:release/c-1
git -C "$P" checkout -q main
git -C "$P" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$H"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
export JG_HOME="$H" JG_STATE_OVERRIDE="$S" JG_DATA_OVERRIDE="$D" JG_CONFIG_OVERRIDE="$H/config" JG_PROJECTS_OVERRIDE="$H/projects"
jg_test_add "$H" jg-vb1 'Version branch Recon'
mkdir -p "$D/jg-vb1"
printf 'project=%s\nticket=jg-vb1\nbase_branch=release/c-1\n' "$P" > "$S/jg-vb1.meta"
cat > "$W/spawn" <<WRAP
#!/usr/bin/env bash
task=\$1; proj=\$2; shift 2
printf '%s\n' "\$*" > "$W/args"
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in --harness|--model|--effort) shift 2 ;; *) args+=("\$1"); shift ;; esac
done
git -C "$P" worktree add -q --detach "$W/copy" origin/release/c-1
JG_ROOT_OVERRIDE='' JG_HOME="$H" HOME="$H/user-home" CLAUDE_CONFIG_DIR='' \
  XDG_DATA_HOME="$H/user-home/.local/share" JG_STATE_OVERRIDE="$S" JG_DATA_OVERRIDE="$D" \
  JG_PROJECTS_OVERRIDE="$H/projects" JG_CONFIG_OVERRIDE="$H/config" JG_SPAWN_NO_GUARD=1 \
  JG_FAKE_PANE_PATH="$W/copy" TMUX=fake,1,0 PATH="$FAKEBIN:\$PATH" \
  exec "$ROOT/bin/jg-spawn.sh" "\$task" "\$proj" "\${args[@]}" --harness codex --model gpt-5.5 --effort high
WRAP
chmod +x "$W/spawn"
export JG_RECON_CRITIC_SPAWN="$W/spawn" JG_STATUS_KICK=0
out=$(bash "$ROOT/bin/jg-recon-critic.sh" start jg-vb1 1); rc=$?
[ "$rc" -eq 75 ] || fail "critic start returned $rc: $out"
task=$(printf '%s\n' "$out" | head -1)
for _ in $(seq 1 120); do [ ! -f "$D/jg-vb1/critic-1/spawn.rc" ] || break; /bin/sleep 0.5; done
[ -f "$D/jg-vb1/critic-1/spawn.rc" ] || fail 'critic spawn did not finish'
[ "$(cat "$D/jg-vb1/critic-1/spawn.rc")" = 0 ] || fail "critic spawn refused: $(tail -3 "$D/jg-vb1/critic-1/spawn.log")"
grep -qx 'Base branch: release/c-1' "$D/$task/brief.md" || fail 'critic brief has no version branch'
grep -q -- '--base-branch release/c-1' "$W/args" || fail 'critic spawn has no version branch'
grep -qx 'base_branch=release/c-1' "$S/$task.meta" || fail 'critic record has no version branch'
[ -f "$W/copy/version-marker" ] || fail 'critic copy did not start from the version branch'
pass 'critic starts from the version branch'
