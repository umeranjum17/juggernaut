#!/usr/bin/env bash
# Real local landing through the fork's unmodified bin, which sources this
# feature's loader from JG_ADDONS_DIR. JG_TEST_FORK names a read-only Juggernaut
# checkout; no watcher is armed.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${JG_TEST_FORK:?set JG_TEST_FORK to a Juggernaut checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"
  else printf 'fixture retained: %s\nproduction output: %s/out\n' "$d" "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user XDG_CONFIG_HOME=$d/xdg-config XDG_DATA_HOME=$d/xdg-data TMPDIR=$d/tmp
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$JG_TEST_FORK/bin" "$d/fork/"
# No rewriting: jg-dod-lib.sh and jg-merge-outcome-lib.sh load the feature
# library themselves from JG_ADDONS_DIR, and jg-merge-local.sh calls the hooks.

fail() { echo "not ok - $*" >&2; exit 1; }
run_merge() { JG_HOME=$home bash "$d/fork/bin/jg-merge-local.sh" task > "$d/out" 2>&1; }
for mode in present absent; do
  home=$d/$mode
  repo=$home/project
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf 'manual\n' > "$home/config/backlog-backend"
  git init -q -b main "$repo"
  git -C "$repo" config user.name Umer
  git -C "$repo" config user.email umer@example.invalid
  git -C "$repo" commit -q --allow-empty -m base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b fm/task
  git -C "$repo" commit -q --allow-empty -m candidate
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  printf 'project=%s\nworktree=%s\nbranch=fm/task\nkind=ship\nmode=local-only\nspawn_gen=fixture-merge\n' "$repo" "$repo" > "$home/state/task.meta"
  cat > "$home/config/merge-gate" <<'HOOK'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$JG_HOME/gate.args"
echo 'done-done: proof missing for this head'
exit 3
HOOK
  cat > "$home/config/post-merge" <<'HOOK'
#!/usr/bin/env bash
printf '%s|%s\n' "$JG_HOME" "$*" >> "$JG_HOME/post.args"
exit 5
HOOK
  chmod +x "$home/config/merge-gate" "$home/config/post-merge"
  if [ "$mode" = absent ]; then
    export JG_ADDONS_DIR=$d/no-addons
    run_merge || fail "absent feature changed Kun landing: $(<"$d/out")"
    [ ! -e "$home/gate.args" ] && [ ! -e "$home/post.args" ] || fail 'absent feature ran config policy'
  else
    export JG_ADDONS_DIR=$addons
    if run_merge; then fail 'refusing gate allowed landing'; fi
    grep -q 'merge refused by config/merge-gate (exit 3)' "$d/out"
    grep -q 'done-done: proof missing for this head' "$d/out"
    [ "$(git -C "$repo" rev-parse HEAD)" = "$base" ] || fail 'refusal changed main'
    [ "$(<"$home/gate.args")" = "$home|task $repo $head -" ] || fail 'gate arguments changed'
    # Non-executable and dangling hooks fail closed, without attempting a merge.
    chmod -x "$home/config/merge-gate"
    if run_merge; then fail 'non-executable gate allowed landing'; fi
    grep -q 'merge-gate is not executable' "$d/out"
    rm "$home/config/merge-gate"
    ln -s "$home/missing" "$home/config/merge-gate"
    if run_merge; then fail 'dangling gate allowed landing'; fi
    rm "$home/config/merge-gate"
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$home/config/merge-gate"
    chmod +x "$home/config/merge-gate"
    if JG_MERGE_GATE_TIMEOUT=1 run_merge; then fail 'hung gate allowed landing'; fi
    grep -q 'merge gate timed out after 1s' "$d/out"
    [ "$(git -C "$repo" rev-parse HEAD)" = "$base" ] || fail 'invalid gate changed main'
    printf '#!/usr/bin/env bash\necho "done-done: inconclusive"\n' > "$home/config/merge-gate"
    run_merge || fail "passing gate refused landing: $(<"$d/out")"
    grep -q 'done-done: inconclusive' "$d/out"
    grep -q 'post-merge hook failed (exit 5); the merge stands' "$d/out"
    [ "$(<"$home/post.args")" = "$home|task $repo $head -" ] || fail 'post arguments changed'
  fi
  [ "$(git -C "$repo" rev-parse HEAD)" = "$head" ] || fail "$mode did not land candidate"
  run_merge || fail "$mode repeat landing failed"
  if [ "$mode" = present ]; then
    [ "$(wc -l < "$home/post.args")" -eq 1 ] || fail 'repeat landing reran post'
    rm "$home/config/merge-gate" "$home/config/post-merge"
    run_merge || fail 'missing config hooks changed landing'
  fi
  echo "ok - $mode: actual set-e local landing, exact candidate and optional config hooks"
done
