#!/usr/bin/env bash
# Integration test for bin/jg-trunk.sh: a landing gate gives the same result from every caller.
# A worker session carries git hook settings in its environment (GIT_CONFIG_COUNT and its keys); the lead, the
# watcher and a bare shell do not. Before the fix the gate took the caller's environment, so one tip was red or
# green by who started the landing (report fable-why-no-landing, row 8, slice S10).
#
# T1 A real landing started from an environment whose git hook setting refuses every ref transaction outside the
#    project lands green: the gate's clone, its first run and its rerun all start from the gate's own environment,
#    so the gate makes a new git repository and prints no git setting count.
# T2 A lane with its whole proof lands from a caller whose python3 and node refuse, the way a mise shim does when the
#    caller's mise settings point elsewhere (ten lanes were refused on 10 Nov 2026 with "mise ERROR error parsing config file"):
#    with an explicit done-done home, and with the sealed run in the evidence root done-done names relative to the lane.
set -u
# The fixture lane is judged in its own proof context, not the account or done-done home of whoever runs this suite.
unset CLAUDE_CONFIG_DIR DONE_DONE_HOME
export JG_TRUNK_SEALED_REUSE=0   # this suite tests the gate's own environment, so the gate must run (see tests/jg-trunk-fixture.sh)

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

W=$(jg_test_tmproot jg-trunk-gate-env); HOME_D="$W/home"; PROJ="$HOME_D/projects/proj"
mkdir -p "$W/root" "$HOME_D/state" "$HOME_D/data" "$HOME_D/config"
cp -r "$ROOT/bin" "$W/root/bin"; ln -sn "$ROOT/core" "$W/root/core"; ln -sn "$ROOT/policy" "$W/root/policy"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/root/bin/jg-captain-hold.sh"   # no open decision blocks the lane
# A stand-in for bin/jg-test-run.sh that keeps its marker contract, so a red first run is rerun.
cat > "$W/rig.sh" <<'SH'
#!/usr/bin/env bash
failed=0
for s in "$@"; do
  echo "JG_TEST_BEGIN 2026-01-01T00:00:00Z $s family=x expected_gate_skip=none"
  bash "$s" 2>&1; rc=$?
  echo "JG_TEST_END 2026-01-01T00:00:00Z $s exit=$rc duration_ms=1 gate_skip=false"
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
echo "JG_TEST_SUMMARY total=$# failed=$failed skipped_gate=0 duration_ms=1"
[ "$failed" -eq 0 ]
SH
chmod +x "$W/root/bin/jg-captain-hold.sh"
printf 'gate-full=bash %s/rig.sh t/env.test.sh\ngate-rerun=bash %s/rig.sh\ngate-lint=true\nlanding-gate=tests\n' "$W" "$W" > "$HOME_D/config/trunk-policy"
printf -- '- proj [local-trunk] - fixture project in local-trunk mode (added 2026-11-09)\n' > "$HOME_D/data/projects.md"
jg_git_init_commit "$PROJ"
trunk() { JG_HOME="$HOME_D" JG_ROOT_OVERRIDE="$W/root" JG_STATE_OVERRIDE="$HOME_D/state" JG_DATA_OVERRIDE="$HOME_D/data" \
  JG_CONFIG_OVERRIDE="$HOME_D/config" "$W/root/bin/jg-trunk.sh" "$@"; }
trunk init "$PROJ" >/dev/null || fail "trunk init must work"

# The lane's one test makes a new git repository and prints the git setting count it sees; its first run fails once.
git -C "$PROJ" worktree add -q -b fm/env "$W/lane" trunk
mkdir -p "$W/lane/t"
cat > "$W/lane/t/env.test.sh" <<SH
echo "git settings: \${GIT_CONFIG_COUNT:-none}"
d=\$(mktemp -d); git init -q "\$d/n" && git -C "\$d/n" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m m; rc=\$?; rm -rf -- "\$d"
[ "\$rc" -eq 0 ] || exit 1
[ -e "$W/ran-once" ] || { : > "$W/ran-once"; echo "not ok - first run" >&2; exit 1; }
SH
git -C "$W/lane" add t/env.test.sh; git -C "$W/lane" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket env"
head=$(git -C "$W/lane" rev-parse HEAD); d="$HOME_D/data/env"; mkdir -p "$d/.done-done/runs"
jg_write_meta "$HOME_D/state/env.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/env" "worktree=$W/lane" "spawn_gen=g-env"
printf '{"schema":1,"task":"env","mode":"local-trunk","spawn_gen":"g-env","head":"%s","pr":"","verdict":"PASS","at":1,"evidence":"done-done run: ok"}\n' "$head" > "$HOME_D/state/env.run-receipt.json"
printf '{"head":"%s","verdict":"pass","check":{"claim":"a user can land","evidence":["%s/run.log"]}}\n' "$head" "$d" > "$d/merge-card.json"
printf 'ok\n' > "$d/run.log"
printf '{"schema":1,"run_id":"20261109T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-09T00:00:00Z","files":["run.log"]}\n' "${head:0:8}" "$head" > "$d/.done-done/runs/run-$head.json"

# A worker session's hook setting: a config hook that refuses every ref transaction outside the project.
common=$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)
# shellcheck disable=SC2016 # the hook body is written out verbatim and expands when git runs it
printf '#!/bin/sh\n[ "$(git rev-parse --path-format=absolute --git-common-dir)" = "%s" ] && exit 0\necho "refused by the session hook" >&2; exit 1\n' "$common" > "$W/session-hook"
chmod +x "$W/session-hook"

out=$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=hook.session.event GIT_CONFIG_VALUE_0=reference-transaction \
  GIT_CONFIG_KEY_1=hook.session.command GIT_CONFIG_VALUE_1="$W/session-hook" JG_TASK_ID=caller-task trunk land env 2>&1) \
  || fail "T1 a landing started from a session with a refusing hook setting must be green: $out"
[ "$(git -C "$PROJ" rev-parse 'trunk^{tree}')" = "$(git -C "$W/lane" rev-parse 'HEAD^{tree}')" ] || fail "T1 the lane must be on the trunk: $out"
assert_contains "$out" "gate=full-rerun" "T1 the lane's first red must go through the rerun path"
# The first run's log is kept with the landing attempt, the rerun's beside the trunk records: both under data/.
seen=$(grep -rh '^git settings:' "$HOME_D/data" | sort | uniq -c | awk '{ $1 = $1; print }')
[ "$seen" = "2 git settings: none" ] || fail "T1 the first run and the rerun must each print no git setting count, got: $seen"
if grep -rq 'refused by the session hook' "$HOME_D/data"; then fail "T1 the session's hook must not reach the gate"; fi
pass "T1 a gate started with a refusing hook setting is green: the clone, the run and the rerun take only the gate's environment"

# A caller whose interpreters refuse: python3 and node exit 1 with the mise refusal; done-done is a shell stand-in that names
# its evidence root relative to the lane, as `done-done doctor --json` does, and has no receipt of its own.
mkdir -p "$W/refusing"
for tool in python3 node; do
  printf '#!/bin/sh\necho "mise ERROR error parsing config file: ~/.config/mise/config.toml" >&2\nexit 1\n' > "$W/refusing/$tool"
done
cat > "$W/refusing/done-done" <<'SH'
#!/usr/bin/env bash
[ "$1" = doctor ] || exit 1
printf '{"checks":[{"check":"evidence_root","detail":"writable: ../dd-root/../dd-root"}]}\n'
SH
chmod +x "$W/refusing/"*
proved_lane() {  # <id> <evidence-folder>: a lane off the trunk with its whole proof, the sealed run kept in <evidence-folder>
  local id=$1 ev=$2 h
  git -C "$PROJ" worktree add -q -b "fm/$id" "$W/$id" trunk
  printf '%s\n' "$id" > "$W/$id/$id.txt"; git -C "$W/$id" add "$id.txt"; git -C "$W/$id" -c user.name=t -c user.email=t@example.invalid commit -q -m "ticket $id"
  h=$(git -C "$W/$id" rev-parse HEAD); mkdir -p "$HOME_D/data/$id" "$ev/.done-done/runs"
  jg_write_meta "$HOME_D/state/$id.meta" "project=$PROJ" "mode=local-trunk" "branch=fm/$id" "worktree=$W/$id" "spawn_gen=g-$id"
  printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"PASS","at":1,"evidence":"done-done run: ok"}\n' "$id" "$id" "$h" > "$HOME_D/state/$id.run-receipt.json"
  printf '{"head":"%s","verdict":"pass","check":{"claim":"a user can land","evidence":["%s/run.log"]}}\n' "$h" "$ev" > "$HOME_D/data/$id/merge-card.json"
  printf 'ok\n' > "$ev/run.log"
  printf '{"schema":1,"run_id":"20261110T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-10T00:00:00Z","files":["run.log"]}\n' "${h:0:8}" "$h" > "$ev/.done-done/runs/run-$h.json"
}
lands_from_refusing() {  # <id>: the proof check leaves no gap and the lane lands, from a caller whose interpreters refuse
  local id=$1 out
  out=$(PATH="$W/refusing:$PATH" trunk proof "$id" 2>&1) \
    || fail "T2 the whole proof of $id must pass from a caller whose python3 and node refuse: $out"
  [ -z "$out" ] || fail "T2 the whole proof of $id must leave no gap, got: $out"
  out=$(PATH="$W/refusing:$PATH" trunk land "$id" 2>&1) \
    || fail "T2 $id must land from a caller whose python3 and node refuse: $out"
  [ "$(git -C "$PROJ" rev-parse 'trunk^{tree}')" = "$(git -C "$W/$id" rev-parse 'HEAD^{tree}')" ] || fail "T2 $id must be on the trunk: $out"
}
proved_lane dhome "$HOME_D/data/dhome"
DONE_DONE_HOME="$W/dd-home/./x/.." lands_from_refusing dhome
proved_lane droot "$W/dd-root"
lands_from_refusing droot
pass "T2 a caller whose mise shims refuse lands a lane with its whole proof: the proof check starts no python3 or node"
