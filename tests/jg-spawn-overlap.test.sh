#!/usr/bin/env bash
# Many fresh spawns of one project start together: the project lock covers only the moves that need it (the protect pass, the copy
# reserve, the lease, the slot owner claim and, outside local-trunk, the base refresh), so the wait for each pane to reach its leased
# copy runs beside the other spawns'. Real bin/jg-brief.sh and bin/jg-spawn.sh over the real worktree tool on a scratch clone; the terminal
# is a stateful stand-in (one window and one working directory per window) whose pane reports the leased path 2 s after the `cd`.
# JG_SPAWN_PHASE_LOG (bin/jg-spawn.sh spawn_phase_mark) is how the test reads where each spawn was and when.
#
# T1 overlap: 8 fresh spawns of one project at once: every spawn's log has every mark its path takes; no two spawns hold the lock at the
#    same time; at least two spawns wait for their pane at the same time; all 8 records exist within 15 s (8 pane waits of 2 s inside
#    the lock would take 16 s).
# T2 own copies: the 8 records name 8 different copies, and each copy's owner claim names its own task.
# T3 pane that never settles: the spawn exits 1 after it let go of the lock; its claim is gone, the copy is free, and the next spawn of
#    that one-copy pool takes it and starts.
# T4 capacity: a project with a declared capacity keeps the lock until the record is published.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { printf 'skip: treehouse is not installed\n'; exit 0; }
jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-overlap) || fail "no temp root"
jg_test_isolate_treehouse "$TMP_ROOT"
W="$TMP_ROOT/world"; HOME_DIR="$W/home"
mkdir -p "$W"
export JG_WORKER_POOL_DIR="$W/pools"
FAKEBIN=$(jg_fakebin "$W/fake")
jg_fake_exit0 "$FAKEBIN" gh gh-axi
# The terminal: windows/<id> holds the name, byname/<name> the id, cwd/<id> the working directory the pane reports, pending/<id> the
# `cd` that has not reached the pane yet (its time and path). The pane reports a `cd` JG_OVERLAP_SETTLE_MS after it was sent, never when
# JG_OVERLAP_NEVER is set.
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${JG_OVERLAP_TERM:?}
mkdir -p "$D/windows" "$D/byname" "$D/cwd" "$D/pending"
now_ms() { date +%s%3N; }
target() { local t=$1; t=${t#=}; case $t in @*) echo "$t" ;; *) [ -f "$D/byname/${t#*:}" ] && cat "$D/byname/${t#*:}" || echo "$t" ;; esac; }
case "${1:-}" in
  display-message)
    t=''; fmt=''
    shift
    while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -p) ;; *) fmt=$1 ;; esac; shift; done
    case $fmt in
      '#{pane_current_path}')
        id=$(target "$t")
        if [ -f "$D/pending/$id" ] && [ -z "${JG_OVERLAP_NEVER:-}" ]; then
          read -r at path < "$D/pending/$id"
          if [ $(( $(now_ms) - at )) -ge "${JG_OVERLAP_SETTLE_MS:-2000}" ]; then printf '%s\n' "$path" > "$D/cwd/$id"; rm -f "$D/pending/$id"; fi
        fi
        cat "$D/cwd/$id" 2>/dev/null; echo ;;
      '#{pane_current_command}') echo bash ;;
      *) echo juggernaut ;;
    esac ;;
  list-windows) for f in "$D"/windows/*; do [ -f "$f" ] && cat "$f"; done; exit 0 ;;
  new-window)
    shift; name=''; cwd=''
    while [ $# -gt 0 ]; do case $1 in -n) name=$2; shift ;; -c) cwd=$2; shift ;; esac; shift; done
    id=@$$-$RANDOM
    printf '%s\n' "$name" > "$D/windows/$id"; printf '%s\n' "$id" > "$D/byname/$name"; printf '%s\n' "$cwd" > "$D/cwd/$id"
    echo "$id" ;;
  kill-window)
    shift; t=''; while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; esac; shift; done
    id=$(target "$t"); name=$(cat "$D/windows/$id" 2>/dev/null)
    rm -f "$D/windows/$id" "$D/cwd/$id" "$D/pending/$id" "$D/byname/$name"; exit 0 ;;
  send-keys)
    shift; t=''
    while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -l) ;; *) break ;; esac; shift; done
    id=$(target "$t"); text=${1:-}
    case $text in "cd -- "*) p=${text#"cd -- "}; p=${p#\'}; p=${p%\'}; printf '%s %s\n' "$(now_ms)" "$p" > "$D/pending/$id" ;; esac
    exit 0 ;;
  capture-pane) exit 0 ;;
  show-environment) exit 1 ;;
  has-session | new-session | set-window-option) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
export JG_OVERLAP_TERM="$W/term"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
: > "$HOME_DIR/data/projects.md"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
printf 'v1\n' > "$W/seed/AGENTS.md"; git -C "$W/seed" add -A; git -C "$W/seed" commit -qm c1
git -C "$W/seed" push -q origin HEAD:refs/heads/main

now_ms() { date +%s%3N; }

# make_case <name> <count> <pool size>: project <name> with its own origin (the project lock is keyed by the origin), a worktree tool
# pool of <pool size> copies under the temp root, and <count> scaffolded tasks jg-ov<name>-1...
make_case() {
  local name=$1 n=$2 pool=$3 p i id
  p="$W/$name"
  git clone -q --bare "$W/origin.git" "$W/origin-$name.git" 2>/dev/null
  git clone -q "$W/origin-$name.git" "$p" 2>/dev/null
  git -C "$p" remote set-head origin main >/dev/null 2>&1 || true
  printf 'root = "%s"\nmax_trees = %s\n' "$JG_WORKER_POOL_DIR/$name" "$pool" > "$p/treehouse.toml"
  printf '/treehouse.toml\n' >> "$(git -C "$p" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  printf -- '- %s [direct-PR] - fixture (added 2026-11-20)\n' "$name" >> "$HOME_DIR/data/projects.md"
  for i in $(seq 1 "$n"); do
    id="jg-ov$name-$i"
    jg_test_add "$HOME_DIR" "$id" "[feature] spawn overlap $name $i"
    JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" "$name" --mode direct-PR --project "$p" --migration-row none >/dev/null 2>&1 \
      || fail "could not scaffold the brief for $id"
    sed -i 's/{TASK}/Exercise the overlap./;s/{JUGGERNAUT_SPEC}/Exercise the overlap end to end./' "$HOME_DIR/data/$id/brief.md"
  done
}

# spawn_one <name> <index> <outdir>: one real spawn of task jg-ov<name>-<index>; writes <outdir>/<id>.out and .rc.
spawn_one() {
  local name=$1 i=$2 outdir=$3 id="jg-ov$1-$2" o rc
  o=$(jg_test_run_spawn "$HOME_DIR" "$W/$name" "$FAKEBIN" "$id" "$W/$name" codex --mode direct-PR --yolo off 2>&1); rc=$?
  printf '%s\n' "$o" > "$outdir/$id.out"; printf '%s\n' "$rc" > "$outdir/$id.rc"
}

# run_case <name> <first> <last>: spawns <first>..<last> at once; CASE_OUT is the output directory, CASE_WALL the wall time in ms.
run_case() {
  local name=$1 i start pids=()
  CASE_OUT="$W/out-$name"; mkdir -p "$CASE_OUT"
  JG_SPAWN_PHASE_LOG="$W/phase-$name.log"; export JG_SPAWN_PHASE_LOG; : > "$JG_SPAWN_PHASE_LOG"
  start=$(now_ms)
  for i in $(seq "$2" "$3"); do spawn_one "$name" "$i" "$CASE_OUT" & pids+=($!); done
  wait "${pids[@]}"
  CASE_WALL=$(( $(now_ms) - start ))
}

# mark <task> <phase>: the epoch ms of a mark in the case's phase log (empty when it is not there).
mark() { awk -F'\t' -v t="$1" -v p="$2" '$1 == t && $2 == p { v = $3 } END { print v }' "$JG_SPAWN_PHASE_LOG"; }
# overlapping <from-mark> <to-mark> <task>...: how many of the tasks' [from, to] intervals overlap another task's.
overlapping() {
  local from=$1 to=$2 n=0 a b s1 e1 s2 e2; shift 2
  for a in "$@"; do
    s1=$(mark "$a" "$from"); e1=$(mark "$a" "$to")
    for b in "$@"; do
      [ "$a" != "$b" ] || continue
      s2=$(mark "$b" "$from"); e2=$(mark "$b" "$to")
      if [ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]; then n=$((n + 1)); break; fi
    done
  done
  echo "$n"
}
count_rc() { grep -lx "$2" "$1"/jg-ov"$3"-*.rc 2>/dev/null | wc -l | tr -d ' '; }
all_out() { cat "$1"/*.out 2>/dev/null; }

# T1 / T2: eight spawns of one project at once.
make_case t1 8 10
run_case t1 1 8
TASKS=(); for i in $(seq 1 8); do TASKS+=("jg-ovt1-$i"); done
[ "$(count_rc "$CASE_OUT" 0 t1)" = 8 ] || fail "T1 all 8 spawns should exit 0: $(all_out "$CASE_OUT")"
for t in "${TASKS[@]}"; do
  for p in lock-wait lock-held endpoint-made protect-done reserve-done lease-done pane-settled claim-done base-fresh lock-released record-published; do
    [ -n "$(mark "$t" "$p")" ] || fail "T1 $t has no $p mark; its log: $(grep "^$t" "$JG_SPAWN_PHASE_LOG" | cut -f2 | tr '\n' ' ')"
  done
done
[ "$(overlapping lock-held lock-released "${TASKS[@]}")" = 0 ] || fail "T1 two spawns held the project lock at the same time"
[ "$(overlapping claim-done pane-settled "${TASKS[@]}")" -ge 2 ] || fail "T1 no two spawns waited for their pane at the same time: the lock still covers the wait"
[ "$CASE_WALL" -lt 15000 ] || fail "T1 8 spawns with a 2 s pane wait took ${CASE_WALL} ms: the lock still covers the wait"
pass "T1 eight spawns of one project overlap their pane waits: 8 records in ${CASE_WALL} ms"

copies=$(for t in "${TASKS[@]}"; do sed -n 's/^worktree=//p' "$HOME_DIR/state/$t.meta"; done | sort -u)
[ "$(printf '%s\n' "$copies" | grep -c .)" = 8 ] || fail "T2 the 8 records should name 8 different copies, found: $copies"
for t in "${TASKS[@]}"; do
  wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$t.meta")
  slot=$(dirname "$wt")
  [ "$(sed -n 's/^task=//p' "$slot/.jg-slot-owner" 2>/dev/null)" = "$t" ] || fail "T2 the owner claim of $wt does not name $t"
done
pass "T2 the 8 records name 8 different copies, each claimed by its own task"

# T3: the pane never reaches the copy; the spawn fails after it let go of the lock, and the one copy of the pool is free again.
make_case t3 2 1
CASE_OUT="$W/out-t3"; mkdir -p "$CASE_OUT"
JG_SPAWN_PHASE_LOG="$W/phase-t3.log"; export JG_SPAWN_PHASE_LOG; : > "$JG_SPAWN_PHASE_LOG"
JG_OVERLAP_NEVER=1 JG_SPAWN_WT_POLLS=3 spawn_one t3 1 "$CASE_OUT"
[ "$(cat "$CASE_OUT/jg-ovt3-1.rc")" = 1 ] || fail "T3 a pane that never settles should fail the spawn: $(cat "$CASE_OUT/jg-ovt3-1.out")"
assert_contains "$(cat "$CASE_OUT/jg-ovt3-1.out")" "did not enter an isolated worktree" "T3 the failure does not name the pane"
[ -n "$(mark jg-ovt3-1 lock-released)" ] || fail "T3 the failed spawn never let go of the lock"
[ -z "$(mark jg-ovt3-1 pane-settled)" ] || fail "T3 the pane should not have settled"
status=$(cd "$W/t3" && treehouse status 2>&1)
case $status in *leased*) fail "T3 the failed spawn's copy is still leased: $status" ;; esac
for l in "$HOME_DIR"/state/.treehouse-project-*.lock; do [ -d "$l" ] && fail "T3 the project lock is still held after the failed spawn"; done
[ ! -e "$HOME_DIR/state/jg-ovt3-1.meta" ] || fail "T3 the failed spawn left a record"
spawn_one t3 2 "$CASE_OUT"
[ "$(cat "$CASE_OUT/jg-ovt3-2.rc")" = 0 ] || fail "T3 the next spawn should take the freed copy: $(cat "$CASE_OUT/jg-ovt3-2.out")"
[ -f "$HOME_DIR/state/jg-ovt3-2.meta" ] || fail "T3 the next spawn left no record"
pass "T3 a pane that never settles fails the spawn after the lock, returns its copy, and the next spawn starts on it"

# T4: a declared capacity keeps today's span: the lock is let go after the record is published.
make_case t4 2 10
printf 't4 3\n' > "$HOME_DIR/config/project-capacity"
run_case t4 1 2
rm -f "$HOME_DIR/config/project-capacity"
[ "$(count_rc "$CASE_OUT" 0 t4)" = 2 ] || fail "T4 both spawns should exit 0: $(all_out "$CASE_OUT")"
for t in jg-ovt4-1 jg-ovt4-2; do
  [ "$(mark "$t" lock-released)" -ge "$(mark "$t" record-published)" ] || fail "T4 $t let go of the lock before its record was published"
done
[ "$(overlapping lock-held lock-released jg-ovt4-1 jg-ovt4-2)" = 0 ] || fail "T4 two spawns held the project lock at the same time"
pass "T4 a declared capacity keeps the lock until the record is published"
