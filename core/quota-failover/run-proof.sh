#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
home=$tmp/home; stub=$tmp/bin
mkdir -p "$home/state" "$home/config" "$home/bin" "$stub"
cat >"$home/bin/jg-stub-lib.sh" <<'LIB'
jg_meta_get() { sed -n "s|^$2=||p" "$1" | tail -n 1; }
jg_backend_of_meta() { echo fixture; }
jg_backend_target_of_meta() { jg_meta_get "$1" endpoint_task_id; }
jg_backend_visible_capture() { [ ! -f "$JG_HOME/state/$2.screen" ] || cat "$JG_HOME/state/$2.screen"; return 0; }
jg_busy_classify_meta() { echo 'idle no-busy-record'; }
jg_busy_record_read() { echo ''; }
JG_QUOTA_ROW_JQ='def quota_lane($harness; $model): ""; def quota_row($snapshot; $provider; $lane): null;'
jg_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
jg_quota_single_provider_for_harness() { return 1; }
jg_parent_channel_report() { :; }
jg_run_timed() { shift; "$@"; }
LIB
for lib in jg-backend.sh jg-busy-lib.sh jg-quota-axi-lib.sh jg-parent-channel-lib.sh; do ln -s jg-stub-lib.sh "$home/bin/$lib"; done
cat >"$home/bin/jg-control.sh" <<'CONTROL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$JG_HOME/state/control.log"
CONTROL
cat >"$home/bin/jg-crew-state.sh" <<'CREW'
#!/usr/bin/env bash
echo 'state: working · source: fixture'
CREW
cat >"$stub/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
QUOTA
cat >"$stub/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "${CLAUDE_LIMIT:-}" = yes ]; then echo "You've hit your usage limit for your plan; try again in 3h"; exit 1; fi
echo PONG
CLAUDE
chmod +x "$home/bin/jg-control.sh" "$home/bin/jg-crew-state.sh" "$stub/quota-axi" "$stub/claude"
cat >"$home/config/crew-dispatch.json" <<'DISPATCH'
{"rules":[],"default":[{"harness":"claude","model":"claude-haiku-5-5"}]}
DISPATCH
printf 'endpoint_task_id=cw\nharness=claude\nmodel=claude-haiku-5-5\nkind=operator\nspawn_gen=s0.cw\n' >"$home/state/cw.meta"
printf 'quota exhausted' >"$home/state/cw.screen"
: >"$home/state/quota-failover.log"
export PATH="$stub:$PATH" QUOTA_FAILOVER_TEST_SECS=1 QUOTA_FAILOVER_PROBE_SECS=0 QUOTA_FAILOVER_RETEST_SECS=0 QUOTA_FAILOVER_STALL_SECS=0
"$repo/quota-failover/quota-failover" "$home"
cp "$home/state/cw.screen" "$evidence/wrapper-text.txt"
cp "$home/config/crew-dispatch.json" "$evidence/after-wrapper.json"
if ! jq -e '.default[0].model == "claude-haiku-5-5"' "$home/config/crew-dispatch.json" >/dev/null; then echo 'wrapper text unexpectedly removed route' >&2; exit 1; fi
cp "$home/state/quota-failover.log" "$evidence/wrapper-log.txt"
: >"$home/state/quota-failover.log"
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cw.screen"
cp "$home/state/cw.screen" "$evidence/real-limit-banner.txt"
CLAUDE_LIMIT=yes "$repo/quota-failover/quota-failover" "$home"
cp "$home/config/crew-dispatch.json" "$evidence/after-limit-banner.json"
cp "$home/state/quota-failover-dead.json" "$evidence/dead-routes.json"
cp "$home/state/quota-failover.log" "$evidence/limit-log.txt"
jq -e '.default | length == 0' "$home/config/crew-dispatch.json" >/dev/null
jq -e 'any(.[]; .model == "claude-haiku-5-5")' "$home/state/quota-failover-dead.json" >/dev/null
jq -n --arg wrapperScreen "$(cat "$evidence/wrapper-text.txt")" --slurpfile wrapperDispatch "$evidence/after-wrapper.json" --rawfile wrapperLog "$evidence/wrapper-log.txt" --arg limitScreen "$(cat "$evidence/real-limit-banner.txt")" --slurpfile limitDispatch "$evidence/after-limit-banner.json" --slurpfile dead "$evidence/dead-routes.json" --rawfile limitLog "$evidence/limit-log.txt" '{wrapper_case:{screen:$wrapperScreen,dispatch:$wrapperDispatch[0],log:$wrapperLog,route_retained:($wrapperDispatch[0].default[0].model == "claude-haiku-5-5")},limit_case:{screen:$limitScreen,probe:{command:"claude -p --model claude-haiku-5-5",exit:1,output:"You\u0027ve hit your usage limit for your plan; try again in 3h"},dispatch:$limitDispatch[0],dead_routes:$dead[0],log:$limitLog,route_removed:(($limitDispatch[0].default|length)==0 and any($dead[0][]; .model=="claude-haiku-5-5"))}}' >"$evidence/result.json"
printf 'PASS: wrapper screen retained route; real limit banner plus confirming one-line probe removed route.\n'

# The real control transaction runs against a tmux stand-in and an isolated
# git worktree. Only the spawn boundary and provider calls are stubbed.
agy_tmp=$tmp/agy
agy_home=$agy_tmp/home
agy_bin=$agy_tmp/bin
agy_repo=$agy_tmp/repo
agy_worktree=$agy_tmp/worktree
mkdir -p "$agy_home"/{bin,config,state,data/t1} "$agy_bin" "$agy_tmp"/{user,tmp,fake,xdg}
mkdir -p "$agy_tmp/proc/pressure"
printf 'MemAvailable: 20971520 kB\n' >"$agy_tmp/proc/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' >"$agy_tmp/proc/pressure/memory"
fixture_path="$(getconf PATH):$PATH"
env -i PATH="$fixture_path" HOME="$agy_tmp/user" XDG_CONFIG_HOME="$agy_tmp/xdg" GIT_CONFIG_NOSYSTEM=1 \
  bash -eu -c '
    git init -q "$1"
    git -C "$1" -c user.name=Umer -c user.email=umer@example.invalid commit --allow-empty -qm fixture
    git -C "$1" worktree add -qb fixture-worker "$2" HEAD
  ' _ "$agy_repo" "$agy_worktree"
printf '%s\n' 'unsaved work to keep' >"$agy_worktree/draft.txt"
printf '# Fixture brief\n' >"$agy_home/data/t1/brief.md"

for source in "$repo/../bin/"*; do
  [ "${source##*/}" != jg-spawn.sh ] || continue
  ln -s "$source" "$agy_home/bin/${source##*/}"
done
cat >"$agy_home/bin/jg-spawn.sh" <<'SPAWN'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$JG_FAKE_DIR/spawn.log"
[ "$*" = 't1 --relaunch --harness codex --model gpt-6.2-astra' ]
[ "$(cat "$JG_FAKE_DIR/command")" = zsh ]
[ "$(cat "$JG_FAKE_DIR/sends.log")" = "$(printf '/quit\nEnter')" ]
sed -e 's/^harness=agy$/harness=codex/' -e 's/^model=.*/model=gpt-6.2-astra/' \
  -e 's/^spawn_gen=.*/spawn_gen=s2.t1/' "$JG_HOME/state/t1.meta" >"$JG_FAKE_DIR/replacement"
mv "$JG_FAKE_DIR/replacement" "$JG_HOME/state/t1.meta"
printf 'codex\n' >"$JG_FAKE_DIR/command"
SPAWN
cat >"$agy_bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -eu
dir=$JG_FAKE_DIR
case "$1" in
  list-windows) printf 'jg-t1\n' ;;
  display-message)
    case "$*" in
      *pane_current_command*) cat "$dir/command" ;;
      *cursor_y*) printf '1\n' ;;
      *pane_current_path*) cat "$dir/cwd" ;;
      *pane_tty*) exit 1 ;;
      *) printf 'jg-t1\n' ;;
    esac ;;
  capture-pane) cat "$dir/pane" ;;
  send-keys)
    shift
    [ "$1" = -t ] && shift 2
    [ "${1:-}" != -l ] || shift
    printf '%s\n' "$1" >>"$dir/sends.log"
    if [ "$1" = Enter ] && grep -qxF /quit "$dir/sends.log"; then
      printf 'zsh\n' >"$dir/command"
      printf '$\n' >"$dir/pane"
    fi ;;
esac
TMUX
cp "$stub/quota-axi" "$agy_bin/quota-axi"
cat >"$agy_bin/agy" <<'AGY'
#!/usr/bin/env bash
[ "$*" = '-p Reply with the single word PONG. --model gemini-3.8-flash-low' ] || exit 2
printf '%s\n' 'RESOURCE_EXHAUSTED (code 429): Individual quota reached.' | tee -a "$JG_FAKE_DIR/probes.log" >&2
exit 3
AGY
cat >"$agy_bin/codex" <<'CODEX'
#!/usr/bin/env bash
[ "$*" = 'exec --skip-git-repo-check --model gpt-6.2-astra Reply with the single word PONG.' ] || exit 2
printf 'PONG\n' | tee -a "$JG_FAKE_DIR/probes.log"
CODEX
chmod +x "$agy_bin/"* "$agy_home/bin/jg-spawn.sh"
printf 'agy\n' >"$agy_tmp/fake/command"
printf '%s\n' "$agy_worktree" >"$agy_tmp/fake/cwd"
cat >"$agy_home/config/crew-dispatch.json" <<'DISPATCH'
{"default":[{"harness":"agy","model":"gemini-3.8-flash-low"},{"harness":"codex","model":"gpt-6.2-astra"}]}
DISPATCH
cat >"$agy_home/state/t1.meta" <<META
window=fixture:jg-t1
endpoint_task_id=t1
worktree=$agy_worktree
project=$agy_repo
harness=agy
model=gemini-3.8-flash-low
kind=ship
spawn_gen=s1.t1
backend=tmux
META
: >"$agy_home/state/quota-failover.log"
touch "$agy_tmp/fake/"{sends,spawn,probes}.log
agy_env=(env -i PATH="$agy_bin:$fixture_path" HOME="$agy_tmp/user" TMPDIR="$agy_tmp/tmp"
  XDG_CONFIG_HOME="$agy_tmp/xdg" XDG_CACHE_HOME="$agy_tmp/xdg/cache" XDG_DATA_HOME="$agy_tmp/xdg/data"
  GIT_CONFIG_NOSYSTEM=1 JG_HOME="$agy_home" JG_ROOT_OVERRIDE="$repo/.." JG_FAKE_DIR="$agy_tmp/fake"
  JG_HOST_MEMORY_PROC="$agy_tmp/proc" JG_HOST_MEMORY_CGROUP_ROOT="$agy_tmp/cgroup"
  JG_CONTROL_POLL=0.05 JG_CONTROL_EXIT_WAIT=1 JG_CONTROL_LAUNCH_WAIT=1
  QUOTA_FAILOVER_TEST_SECS=5 QUOTA_FAILOVER_STALL_SECS=0)
agy_pass() {
  local draft=$1 rule=──────────────────────────────────────────────────────────────────────────────
  printf '%s\n' "$rule" ">$draft" "$rule" '? for shortcuts     Gemini 3.8 Flash · low' >"$agy_tmp/fake/pane"
  "${agy_env[@]}" "$repo/quota-failover/quota-failover" "$agy_home"
}

agy_pass ' preserve this draft'
cp "$agy_home/state/quota-failover.log" "$evidence/agy-draft.log"
[ ! -s "$agy_tmp/fake/sends.log" ]
[ ! -s "$agy_tmp/fake/spawn.log" ]
agy_pass ''
cp "$agy_home/state/quota-failover.log" "$evidence/agy-failover.log"
cp "$agy_tmp/fake/"*.log "$evidence/"
grep -Fq 'refusing to type the /quit exit command' "$evidence/agy-draft.log" ||
  { echo 'FAIL: quota recovery never reached the draft refusal' >&2; exit 1; }
grep -Fq 't1: switched agy gemini-3.8-flash-low -> codex gpt-6.2-astra' "$evidence/agy-failover.log" ||
  { echo 'FAIL: quota recovery never reached the configured Codex route' >&2; exit 1; }
grep -Fxq 'harness=codex' "$agy_home/state/t1.meta"
grep -Fxq 'model=gpt-6.2-astra' "$agy_home/state/t1.meta"
grep -Fxq "worktree=$agy_worktree" "$agy_home/state/t1.meta"
grep -Fxq 'unsaved work to keep' "$agy_worktree/draft.txt"
jq -e '.default == [{"harness":"codex","model":"gpt-6.2-astra"}]' "$agy_home/config/crew-dispatch.json" >/dev/null
printf '%s\n' '{"target":{"version":"Juggernaut quota failover and control at this commit"},"start":"isolated agy worker in a git worktree with unsaved work, a quota-exhausted provider probe, and a working Codex fallback","steps":["run quota failover with text in the agy composer","check the refusal and clear the fixture composer","run quota failover once more","read the recorded quit, spawn and switch and check the preserved file"],"result":"the draft was preserved; an empty agy composer accepted one /quit and Enter before the same worker relaunched on configured Codex gpt-6.2-astra with the unsaved file intact"}' >"$evidence/steps.json"
printf 'PASS: AGY quota failover preserved the draft and relaunched the same worker on configured Codex after /quit.\n'
