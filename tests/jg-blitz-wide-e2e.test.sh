#!/usr/bin/env bash
# tests/jg-blitz-wide-e2e.test.sh - one `bin/jg-swarm.sh start` of a 24-slice plan owned by a Squad Lead home puts 20 or more lanes live
# within 300 s of the start, with no hand step. Real swarm start, plan route, approval, arm, dispatch check, spawn, lane lock, pool
# reserve and brief writer, over real stores in a scratch Main home and a scratch Squad Lead home `lead1` bound to it. Stand-ins: the
# terminal (a stateful tmux that keeps one window and one working directory per window), the lead (its send takes the message `jg-swarm.sh`
# sends it and runs the one command in it, as the lead does), and the watcher (a loop that runs the lead's dispatch shim every 300 s). The
# worktree tool is the real `treehouse`, on a repository created under the temp root, with a pool under the temp root.
#
# T1 start: 24 slices start with `--agents 24`; every 5 s a `t=` line is printed; 20 or more lanes are live within 300 s.
# T2 resume: a start stopped after its fifth line starts again: 24 rows under the plan, each once, and 20 or more live within 300 s of the second start.
# T3 twice: a start while one runs says `already running` and adds nothing.
# JG_BLITZ_LIVE=1 (never in the default run) is the live mode: T1 alone, with the real worker runtime (claude, the cheapest model, low
# effort, the installed and signed-in one, under the normal HOME) and the real terminal backend (tmux on a private server, the socket
# directory of bin/jg-lab-home.sh), on the real worktree tool over a scratch clone of this repository (`git clone --no-local`, its own object
# store; its pool is under the temp root). A lane is live when its status file holds its first worker-written line. After 20 lanes it waits up
# to 15 minutes for the dummy orders to report done, prints t-spawn and t-lease for each lane, ends every lane with bin/jg-teardown.sh in the
# scratch homes only, kills its private tmux server and removes the temp root. Each lane pre-registers workspace trust for its scratch path
# in the owner's Claude settings, as every lane does. Start it through the host's memory gate.
set -u
# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v treehouse >/dev/null 2>&1 || { printf 'skip: treehouse is not installed\n'; exit 0; }

PLAN_IN=$ROOT/tests/fixtures/blitz-wide/plan.json
LIVE=${JG_BLITZ_LIVE:-0}
PLAN_RUN=$PLAN_IN
PROJ_NAME=blitzproj
if [ "$LIVE" = 1 ]; then PROJ_NAME=juggernaut-scratch; fi
LANES=24 NEED=20 BOUND=${JG_BLITZ_BOUND:-300} TICK=5
# T1's own bound: with the project lock covering only the moves that need it, 20 lanes were live 71 s after the start on the stand-in
# (jg-wflow-5; 101 s with the lock held through each pane wait), so the bound is 90 s; the live mode's is 120 s (267 s before).
T1_BOUND=${JG_BLITZ_T1_BOUND:-90}; [ "$LIVE" != 1 ] || T1_BOUND=${JG_BLITZ_T1_BOUND:-120}
STEP_DELAY_T2=${JG_BLITZ_T2_STEP_DELAY:-6}
T=$(jg_test_tmproot jg-blitz-wide) || fail "no temp root"
T=$(cd "$T" && pwd -P)
jg_test_isolate_treehouse "$T"
jg_git_identity blitz blitz@example.com
# Nothing here reaches a home, a pool or a terminal of the machine it runs on: the homes and the pools are under $T, and the terminal is
# a stand-in, or in the live mode a tmux server of its own.
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE JG_PROJECTS_OVERRIDE JG_HOME TMUX
# A run inside Herdr would auto-detect it as the terminal backend and put its lanes into that session: no Herdr variable reaches it, and the
# backend is named.
for _v in $(env | sed -n 's/^\(HERDR_[A-Za-z_]*\)=.*/\1/p'); do unset "$_v"; done
export JG_BACKEND=tmux
if [ "$LIVE" != 1 ]; then
  mkdir -p "$T/home"
  export HOME=$T/home XDG_DATA_HOME=$T/home/.local/share XDG_CONFIG_HOME=$T/home/.config
  export CLAUDE_CONFIG_DIR=''
fi

# --- the stand-in terminal: one window and one working directory for each window, in $T/term -----------------------------
FAKEBIN=$T/fakebin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
# The terminal of the blitz test: windows/<id> holds the window's name, byname/<name> its id, cwd/<id> its working directory.
set -u
D=${JG_BLITZ_TERM:?}
mkdir -p "$D/windows" "$D/byname" "$D/cwd"
target() { local t=$1; t=${t#=}; case $t in @*) echo "$t" ;; *) [ -f "$D/byname/${t#*:}" ] && cat "$D/byname/${t#*:}" || echo "$t" ;; esac; }
case "${1:-}" in
  display-message)
    t=''; fmt=''
    shift
    while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -p) ;; *) fmt=$1 ;; esac; shift; done
    case $fmt in
      '#{pane_current_path}') id=$(target "$t"); cat "$D/cwd/$id" 2>/dev/null; echo ;;
      '#{pane_current_command}') echo bash ;;
      *) echo juggernaut ;;
    esac ;;
  list-windows) for f in "$D"/windows/*; do [ -f "$f" ] && echo "$(cat "$f")"; done; exit 0 ;;
  new-window)
    shift; name=''; cwd=''
    while [ $# -gt 0 ]; do case $1 in -n) name=$2; shift ;; -c) cwd=$2; shift ;; esac; shift; done
    id=@$$-$RANDOM
    printf '%s\n' "$name" > "$D/windows/$id"; printf '%s\n' "$id" > "$D/byname/$name"; printf '%s\n' "$cwd" > "$D/cwd/$id"
    echo "$id" ;;
  kill-window)
    shift; t=''; while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; esac; shift; done
    id=$(target "$t"); name=$(cat "$D/windows/$id" 2>/dev/null)
    rm -f "$D/windows/$id" "$D/cwd/$id" "$D/byname/$name"; exit 0 ;;
  send-keys)
    shift; t=''; lit=0
    while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -l) lit=1 ;; *) break ;; esac; shift; done
    id=$(target "$t"); text=${1:-}
    case $text in "cd -- "*) p=${text#"cd -- "}; p=${p#\'}; p=${p%\'}; printf '%s\n' "$p" > "$D/cwd/$id" ;; esac
    [ "$lit" = 0 ] || printf '%s\t%s\n' "$id" "$text" >> "$D/launch.log"
    exit 0 ;;
  capture-pane) exit 0 ;;
  show-environment) exit 1 ;;
  has-session | new-session | set-window-option) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
# The worktree tool is the real one; this wrapper only times each lease, for the t-lease line of each lane.
REAL_TREEHOUSE=$(command -v treehouse)
cat > "$FAKEBIN/treehouse" <<SH
#!/usr/bin/env bash
start=\$(date +%s.%N)
$REAL_TREEHOUSE "\$@"; rc=\$?
if [ "\${1:-}" = get ]; then
  holder=''; prev=''
  for a in "\$@"; do [ "\$prev" = --lease-holder ] && holder=\$a; prev=\$a; done
  printf '%s\\t%s\\n' "\$holder" "\$(awk -v s="\$start" -v e="\$(date +%s.%N)" 'BEGIN { printf "%.1f", e - s }')" >> "\${JG_BLITZ_LEASE_LOG:-/dev/null}"
fi
exit \$rc
SH
chmod +x "$FAKEBIN/treehouse"
export JG_SPAWN_NO_GUARD=1
if [ "$LIVE" = 1 ]; then
  rm -f "$FAKEBIN/tmux"
  # The plan the live run starts: the fixture with the scratch project, and its order beside it.
  mkdir -p "$T/plan-live"
  cp "$ROOT/tests/fixtures/blitz-wide/order-dummy.md" "$T/plan-live/"
  jq --arg p "$PROJ_NAME" '.slices |= map(.project = $p)' "$PLAN_IN" > "$T/plan-live/plan.json"
  PLAN_RUN=$T/plan-live/plan.json
else
  export TMUX=fake,1,0
fi
PATH="$FAKEBIN:$PATH"
jg_test_pin_real_tools "$T/realbin"

# --- a world: a Main home, a Squad Lead home bound to it, a project, the plan ----------------------------------------------
# Each world has its own terminal state and its own pools, so a world never sees another's windows or copies. ENV_FILE is the environment
# a process of the world starts with (the lead's shim, its arm and the watcher read it, as the watcher's wiring reads its own).
world_env() {  # <world dir>
  ENV_FILE=$1/env.sh
  export JG_BLITZ_TERM=$1/term JG_WORKER_POOL_DIR=$1/pools JG_BLITZ_LEASE_LOG=$1/lease.log JG_SPAWN_PHASE_LOG=$1/phase.log
  mkdir -p "$JG_BLITZ_TERM" "$JG_WORKER_POOL_DIR"
  {
    printf 'export JG_WORKER_POOL_DIR=%q JG_BLITZ_LEASE_LOG=%q JG_SPAWN_PHASE_LOG=%q PATH=%q JG_BLITZ_TERM=%q JG_SPAWN_NO_GUARD=1 JG_TEST_FIXTURE_PROC=%q\n' \
      "$JG_WORKER_POOL_DIR" "$JG_BLITZ_LEASE_LOG" "$JG_SPAWN_PHASE_LOG" "$PATH" "$JG_BLITZ_TERM" "$$"
    printf 'export JG_BACKEND=tmux GIT_CEILING_DIRECTORIES=%q\nunset TREEHOUSE_ROOT\n' "$GIT_CEILING_DIRECTORIES"
    if [ "$LIVE" = 1 ]; then printf 'export TMUX_TMPDIR=%q\nunset TMUX\n' "$LAB_TMUX_DIR"   # the normal HOME and login stay as they are
    else printf 'export HOME=%q XDG_DATA_HOME=%q XDG_CONFIG_HOME=%q CLAUDE_CONFIG_DIR= TMUX=fake,1,0\n' "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"; fi
  } > "$ENV_FILE"
}

mkhome() {  # <home> <registered-line-file>
  local h=$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state" "$h/data" "$h/projects" "$h/config"
  git init -q "$h"   # a home below the root is a repository: its pool root derives from its git directory
  for d in .agents AGENTS.md bin core defaults docs policy skills toolchain.versions; do [ ! -e "$ROOT/$d" ] || ln -sn "$ROOT/$d" "$h/$d"; done
  printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$h/config/host-memory"
  : > "$h/config/delivery-risk-loose"
  touch "$h/state/.last-watcher-beat"
  printf -- '- %s [local-trunk +yolo] - the scratch project (added 2026-11-20)\n' "$PROJ_NAME" > "$h/data/projects.md"
}

# mkproject <home> <origin>: the project clone of a home, with its own pool under the temp root (max_trees 26).
mkproject() {
  local h=$1 origin=$2 name=$PROJ_NAME
  git clone -q "$origin" "$h/projects/$name" 2>/dev/null
  git -C "$h/projects/$name" remote set-head origin main >/dev/null 2>&1 || true
  printf 'root = "%s"\nmax_trees = 26\n' "$(dirname "$h")/pools/$(basename "$h")" > "$h/projects/$name/treehouse.toml"
  printf '/treehouse.toml\n' >> "$(git -C "$h/projects/$name" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
}

mkorigin() {  # <dir>: a bare origin with one commit on main
  local o=$1 w
  git init -q --bare "$o"
  git -C "$o" symbolic-ref HEAD refs/heads/main
  w=$(mktemp -d "$T/seed.XXXXXX")
  git clone -q "$o" "$w" 2>/dev/null
  printf 'blitz scratch project\n' > "$w/README.md"
  git -C "$w" add -A; git -C "$w" commit -qm 'seed'; git -C "$w" push -q origin HEAD:refs/heads/main
  rm -rf -- "$w"
}

# mkscratch_clone: the live project, an independent clone of this repository's local trunk branch with its own object store, under the temp root.
mkscratch_clone() {  # <dir>
  local c=$1 common
  git clone -q --no-local --branch release/v12 "$ROOT" "$c" || fail "could not clone the scratch repository"
  [ ! -e "$c/.git/objects/info/alternates" ] || fail "blocked: scratch clone shares objects"
  common=$(git -C "$c" rev-parse --path-format=absolute --git-common-dir)
  case $(cd "$common" && pwd -P) in "$T"/*) ;; *) fail "blocked: scratch clone shares objects ($common)" ;; esac
}

mkworld() {  # <dir>: Main at <dir>/main, the lead at <dir>/lead
  local w=$1 origin=$1/origin.git h
  mkdir -p "$w"
  if [ "$LIVE" = 1 ]; then
    # Main is a marked lab home: bin/jg-lab-home.sh owns the private socket directory of the tmux server the lanes run in.
    LAB_HOME_HELPER=$ROOT/bin/jg-lab-home.sh
    "$LAB_HOME_HELPER" create "$w/main" >/dev/null || fail "could not make the lab home"
    LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$w/main") || fail "no private tmux directory"
    export TMUX_TMPDIR=$LAB_TMUX_DIR
  fi
  world_env "$w"
  if [ "$LIVE" = 1 ]; then
    tmux new-session -d -s juggernaut || fail "could not start the private tmux server"   # the captain's session, as it is at a real start
    mkscratch_clone "$T/projects/$PROJ_NAME"
    mkhome "$w/main"; mkhome "$w/lead"
    for h in main lead; do ln -sn "$T/projects/$PROJ_NAME" "$w/$h/projects/$PROJ_NAME"; done
    printf 'root = "%s"\nmax_trees = 26\n' "$w/pools/lead" > "$T/projects/$PROJ_NAME/treehouse.toml"
    printf '/treehouse.toml\n' >> "$(git -C "$T/projects/$PROJ_NAME" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    JG_HOME="$w/lead" "$ROOT/bin/jg-trunk.sh" init "$w/lead/projects/$PROJ_NAME" HEAD >/dev/null 2>&1 || fail "trunk init in lead"
  else
    mkorigin "$origin"
    mkhome "$w/main"; mkhome "$w/lead"
    mkproject "$w/main" "$origin"; mkproject "$w/lead" "$origin"
    # A local-trunk project has a trunk in each home that works on it.
    for h in main lead; do JG_HOME="$w/$h" "$ROOT/bin/jg-trunk.sh" init "$w/$h/projects/$PROJ_NAME" HEAD >/dev/null 2>&1 || fail "trunk init in $h"; done
  fi
  printf 'lead1\n' > "$w/lead/.jg-squad-lead-home"
  if [ "$LIVE" = 1 ]; then
    # A real lead home is trusted already (the owner opened it); a scratch one is not, and each lane adds the lead's inbox directory to its worker.
    trust_out=$("$ROOT/bin/jg-claude-trust.sh" --squad-lead-home "$w/lead" lead1 2>&1) || fail "could not register trust for the scratch lead home: $trust_out"
  fi
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$w/main" > "$w/lead/.jg-squad-lead-parent"
  printf -- '- lead1 - the scratch lead (home: %s; scope: blitz; projects: %s; added 2026-11-20)\n' "$w/lead" "$PROJ_NAME" > "$w/main/data/squad_leads.md"
  printf 'kind=squad_lead\n' > "$w/main/state/lead1.meta"
  printf '%s\n' "$LANES" > "$w/lead/config/lane-target"
  # The watcher's wiring: the shim the watcher runs every beat.
  printf '#!/usr/bin/env bash\n. %q\nexec bash %q check %q\n' "$ENV_FILE" "$ROOT/core/auto-dispatch/dispatch.sh" "$w/lead" > "$w/lead/state/auto-dispatch.check.sh"
  chmod +x "$w/lead/state/auto-dispatch.check.sh"
  # The lead: it takes the message `jg-swarm.sh` sends it and runs the one command in it, in its own home.
  cat > "$w/send" <<SH
#!/usr/bin/env bash
# jg-send stand-in: <lead> <text>. The lead reads "Run: <command>" and runs it in its home, as a lead does on its next turn.
lead=\$1; text=\$2
cmd=\${text#*Run: }
printf '%s\t%s\n' "\$(date +%s)" "\$cmd" >> "$w/send.log"
( . "$ENV_FILE"; cd "$w/lead" && JG_HOME="$w/lead" setsid nohup bash -c "\$cmd" > "$w/lead-arm.log" 2>&1 < /dev/null & )
SH
  chmod +x "$w/send"
}

# Main's own env for one call: the swarm start and the board.
# shellcheck disable=SC1090 # the world's own environment file
at() { local h=$1; shift; ( . "$ENV_FILE"; JG_HOME="$h" JG_SWARM_SEND="$W/send" "$@" ); }

# --- the numbers ----------------------------------------------------------------------------------------------------------
# live: a lane record in the lead whose stand-in endpoint is up (live mode: whose worker has written its first status line).
count_live() {
  local meta task n=0
  for meta in "$W/lead/state"/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta" .meta)
    # A record that only keeps a failed launch's copy is no lane (core/auto-dispatch/dispatch.sh lane_record says the same).
    grep -q '^cleanup_recovery=' "$meta" && continue
    if [ "$LIVE" = 1 ]; then   # live: the lane's status file holds its first worker-written line
      grep -qE '^(working|paused|blocked|needs-decision|done)[ :[]' "$W/lead/state/$task.status" 2>/dev/null && n=$((n + 1))
    else
      [ -f "$JG_BLITZ_TERM/byname/jg-$task" ] && n=$((n + 1))
    fi
  done
  echo "$n"
}
count_records() { local n=0 m; for m in "$W/lead/state"/*.meta; do [ -f "$m" ] && n=$((n + 1)); done; echo "$n"; }
count_refused() { grep -l '^result=refused' "$W/lead/data/auto-dispatch"/*.start.* 2>/dev/null | wc -l; }
count_filed() { [ -f "$W/main/data/swarm/blitzwide/plan.json" ] && jq '[.slices[] | select(.row != null)] | length' "$W/main/data/swarm/blitzwide/plan.json" 2>/dev/null || echo 0; }
step_done() { jq -e --arg s "$1" '.steps | index($s) != null' "$W/main/data/swarm/blitzwide/swarm.json" >/dev/null 2>&1 && echo 1 || echo 0; }
armed() { [ -f "$W/lead/data/swarm/blitzwide/arm.json" ] && echo 1 || echo 0; }

# watch <seconds-from-t0> <stop-when>: print the t= line every $TICK s until the stop condition holds or the time is up. Sets
# FIRST_N (seconds when NEED lanes were live), ALL_N (when all LANES were), LAST_LIVE. A stand-in watcher runs the lead's dispatch
# shim every 300 s of the start, as the watcher's own interval does; only the kick of the arm can start lanes sooner.
watch_start() {  # <t0 epoch> <max seconds> [<stop after n lines>]
  local t0=$1 max=$2 stop_lines=${3:-0} t lines=0 next_beat=300
  FIRST_N='' ALL_N='' LAST_LIVE=0
  while :; do
    t=$(( $(date +%s) - t0 ))
    LAST_LIVE=$(count_live)
    printf 't=%s filed=%s approved=%s armed=%s records=%s live=%s\n' "$t" "$(count_filed)" "$(step_done approved)" "$(armed)" "$(count_records)" "$LAST_LIVE"
    lines=$((lines + 1))
    [ -n "$FIRST_N" ] || { [ "$LAST_LIVE" -ge "$NEED" ] && FIRST_N=$t; }
    [ -n "$ALL_N" ] || { [ "$LAST_LIVE" -ge "$LANES" ] && ALL_N=$t; }
    [ "$stop_lines" -eq 0 ] || [ "$lines" -lt "$stop_lines" ] || return 0
    [ "$stop_lines" -ne 0 ] || [ -z "$ALL_N" ] || return 0
    [ "$t" -lt "$max" ] || return 0
    if [ "$t" -ge "$next_beat" ]; then
      next_beat=$((next_beat + 300))
      setsid nohup "$W/lead/state/auto-dispatch.check.sh" > /dev/null 2>&1 < /dev/null &
    fi
    sleep "$TICK"
  done
}

report_live() {  # <label> [<seconds waited>] [<bound seconds>]
  [ -n "$FIRST_N" ] || fail "$1: only $LAST_LIVE of $LANES lanes live by ${2:-$BOUND} s (need $NEED); see the t= lines above"
  [ "$FIRST_N" -le "${3:-$BOUND}" ] || fail "$1: $NEED lanes live only at $FIRST_N s, the bound is ${3:-$BOUND} s"
  if [ -n "$ALL_N" ]; then pass "$1: $NEED lanes live in $FIRST_N s; $LANES live in $ALL_N s"
  else pass "$1: $NEED lanes live in $FIRST_N s; $LANES not live by ${2:-$BOUND} s"; fi
}

# lane_times: the t-spawn (the spawn's start to its lane record) and t-lease (the lease call's own time) of each lane, in seconds.
lane_times() {
  local meta task row launched born lease
  for meta in "$W/lead/state"/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta" .meta); row=${task/-/.}
    launched=$(cat "$W/lead/data/auto-dispatch/$row".start.* 2>/dev/null | sed -n 's/^launched-at=//p' | tail -n 1)
    born=$(stat -c %W "$meta" 2>/dev/null); [ "${born:-0}" -gt 0 ] || born=$(stat -c %Y "$meta")
    lease=$(awk -F'\t' -v h="$task" '$1 == h { v = $2 } END { print v }' "$W/lease.log" 2>/dev/null)
    printf 't-spawn=%s t-lease=%s lane=%s\n' "$(( born - ${launched:-$born} ))" "${lease:-none}" "$task"
  done | sort -t= -k4
}

# phase_report: from the spawn phase log (bin/jg-spawn.sh spawn_phase_mark), the time each spawn held the project lock (median and maximum),
# the number of spawns whose pane-settle wait (lease done to pane settled) overlapped another spawn's, and for each phase between taking
# and letting go of the lock the median and maximum of the time since the mark before it, in ms.
phase_report() {
  [ -s "$JG_SPAWN_PHASE_LOG" ] || { printf 'no spawn phase log\n'; return 0; }
  sort -t$'\t' -k1,1 -k3,3n "$JG_SPAWN_PHASE_LOG" | awk -F'\t' '
    function med(a, n,   i, j, t) { for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }; return a[int((n + 1) / 2)] }
    { at[$1, $2] = $3; if (!($1 in seen)) { seen[$1] = 1; tasks[++nt] = $1 }
      if ($1 == prev && inlock[$1]) d[$2, ++cnt[$2]] = $3 - last
      prev = $1; last = $3
      if ($2 == "lock-held") inlock[$1] = 1
      if ($2 == "lock-released") inlock[$1] = 0 }
    END {
      for (i = 1; i <= nt; i++) { t = tasks[i]
        if (((t, "lock-held") in at) && ((t, "lock-released") in at)) held[++nh] = at[t, "lock-released"] - at[t, "lock-held"]
        if (((t, "lease-done") in at) && ((t, "pane-settled") in at)) { ps[++np] = at[t, "lease-done"]; pe[np] = at[t, "pane-settled"] } }
      for (i = 1; i <= np; i++) { o = 0; for (j = 1; j <= np; j++) if (j != i && ps[j] < pe[i] && ps[i] < pe[j]) o = 1; ov += o }
      mx = 0; for (i = 1; i <= nh; i++) if (held[i] > mx) mx = held[i]
      printf "project lock held: median %s ms, max %s ms over %s spawns; pane-settle waits that overlapped another spawn'"'"'s: %s of %s\n", med(held, nh), mx, nh, ov + 0, np
      n = split("endpoint-made protect-done reserve-done lease-done pane-settled claim-done base-fresh lock-released", ph, " ")
      for (k = 1; k <= n; k++) { c = cnt[ph[k]]; if (!c) continue; m = 0; for (i = 1; i <= c; i++) { v[i] = d[ph[k], i]; if (v[i] > m) m = v[i] }
        printf "  phase %-14s median %5s ms, max %5s ms (%s spawns)\n", ph[k], med(v, c), m, c }
    }'
}

# live_finish: the live mode after the bound is proved: wait up to 15 minutes for the dummy orders to report done, then the cleanup runs.
live_finish() {
  local t0 n=0
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt 900 ]; do
    n=$(grep -lE '^done[ :[]' "$W/lead/state"/blitzwide-*.status 2>/dev/null | wc -l)
    printf 'wait t=%s done=%s of %s\n' "$(( $(date +%s) - t0 ))" "$n" "$LANES"
    [ "$n" -lt "$LANES" ] || break
    sleep 30
  done
  printf 'dummy orders reported done: %s of %s\n' "$n" "$LANES"
  exit 0
}

# The one exit cleanup. In the live mode it first ends every lane with bin/jg-teardown.sh in the scratch lead home (a scratch lane's commit is
# unlanded by design, so a refusal over it is repeated with --force, in this home only), stops the private tmux server and removes its socket
# directory; then the suite's own cleanup removes the temp root, with the pools and the scratch clone.
live_cleanup() {
  trap - EXIT INT TERM HUP
  if [ "$LIVE" = 1 ] && [ -d "${W:-}/lead/state" ]; then
    local meta task ended=0 forced=0
    # shellcheck disable=SC1090
    for meta in "$W/lead/state"/blitzwide-*.meta; do
      [ -f "$meta" ] || continue
      task=$(basename "$meta" .meta)
      if ( . "$ENV_FILE"; JG_HOME="$W/lead" "$ROOT/bin/jg-teardown.sh" "$task" ) >/dev/null 2>&1; then ended=$((ended + 1))
      elif ( . "$ENV_FILE"; JG_HOME="$W/lead" "$ROOT/bin/jg-teardown.sh" "$task" --force ) >/dev/null 2>&1; then ended=$((ended + 1)); forced=$((forced + 1)); fi
    done
    printf 'teardown: %s lanes ended (%s of them forced, scratch lead home only); remaining lane records: %s\n' "$ended" "$forced" "$(find "$W/lead/state" -maxdepth 1 -name 'blitzwide-*.meta' | wc -l)"
    TMUX_TMPDIR=$LAB_TMUX_DIR tmux kill-server >/dev/null 2>&1
    "$LAB_HOME_HELPER" teardown "$W/main" || echo "teardown of the private tmux directory failed"
  fi
  jg_test_cleanup
}
trap live_cleanup EXIT
trap 'live_cleanup; exit 130' INT
trap 'live_cleanup; exit 143' TERM
trap 'live_cleanup; exit 129' HUP

# --- T1 ----------------------------------------------------------------------------------------------------------------------
W=$T/w1
mkworld "$W"
swarm_start() {  # <main home> [<step delay seconds>]
  at "$1" env ${2:+JG_SWARM_STEP_DELAY=$2} bash "$ROOT/bin/jg-swarm.sh" start "$PLAN_RUN" --harness claude --model claude-haiku-5-5 --effort low --agents "$LANES"
}
# stop_start: stop the background start of this world: its own unit when it runs in one, else its process.
stop_start() {
  local pid unit
  pid=$(cat "$W/main/data/swarm/blitzwide/.run.lock/pid" 2>/dev/null) || return 0
  case $pid in '' | *[!0-9]*) return 0 ;; esac
  unit=$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')
  case $unit in jg-swarm-blitzwide-*.service) systemctl --user stop "$unit" >/dev/null 2>&1 ;; *) kill "$pid" 2>/dev/null ;; esac
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  fail "the background start (pid $pid) did not stop"
}
# rows_of <home>: the ids of the plan's slice rows in that home's store, one for each row there is.
rows_of() { at "$1" "$ROOT/bin/jg-backlog.sh" list --all 2>/dev/null | awk '/^  / && !/^  - / { sub(/^  /, ""); sub(/,.*/, ""); print }' | grep -E '^blitzwide\.[0-9]+$' | sort; }
t0=$(date +%s)
out=$(swarm_start "$W/main" 2>&1) || fail "T1 the start failed: $out"
printf '%s\n' "$out"
watch_start "$t0" 600
report_live "T1 start" 600 "$T1_BOUND"
lane_times
phase_report
[ "$LIVE" != 1 ] || live_finish

[ "$LIVE" != 1 ] || exit 0   # the live mode is T1 alone

# --- T3 ----------------------------------------------------------------------------------------------------------------------
# A start while one runs: the run holds the plan's lock, so the second start says so and adds nothing. A step delay keeps the first run
# in front of its first step.
W=$T/w3
mkworld "$W"
out=$(swarm_start "$W/main" 30 2>&1) || fail "T3 the first start failed: $out"
for _ in $(seq 1 50); do [ -f "$W/main/data/swarm/blitzwide/swarm.json" ] && break; sleep 0.2; done
steps_before=$(jq -c '.steps' "$W/main/data/swarm/blitzwide/swarm.json")
out=$(swarm_start "$W/main" 30 2>&1); rc=$?
expect_code 0 "$rc" "T3 a second start while one runs should exit 0: $out"
assert_contains "$out" "swarm blitzwide: already running" "T3 the second start must say it is running"
assert_equals "$steps_before" "$(jq -c '.steps' "$W/main/data/swarm/blitzwide/swarm.json")" "T3 the second start must add no step"
assert_equals "0 0" "$(rows_of "$W/main" | wc -l) $(rows_of "$W/lead" | wc -l)" "T3 the second start must file no row"
stop_start
pass "T3 a start while one runs prints already running and adds nothing"

# --- T2 ----------------------------------------------------------------------------------------------------------------------
# A stopped start starts again: the first start is stopped after its fifth line (a step delay keeps it in the middle of its steps), the
# second finishes it; 24 rows under the plan in the lead's home, each once, and 20 or more lanes live within the bound of the second start.
W=$T/w2
mkworld "$W"
out=$(swarm_start "$W/main" "$STEP_DELAY_T2" 2>&1) || fail "T2 the first start failed: $out"
printf '%s\n' "$out"
watch_start "$(date +%s)" 600 5
stop_start
state_stopped=$(jq -r '.state' "$W/main/data/swarm/blitzwide/swarm.json")
assert_equals starting "$state_stopped" "T2 the first start must stop before it finished (increase JG_BLITZ_T2_STEP_DELAY)"
printf 'stopped after the fifth line, steps: %s\n' "$(jq -c '.steps' "$W/main/data/swarm/blitzwide/swarm.json")"
t0=$(date +%s)
out=$(swarm_start "$W/main" 2>&1) || fail "T2 the second start failed: $out"
printf '%s\n' "$out"
watch_start "$t0" 600
report_live "T2 resume" 600
# The route files each slice in its owner's home: the lead's, and none in Main's.
rows=$(rows_of "$W/lead")
assert_equals "$LANES" "$(printf '%s\n' "$rows" | grep -c .)" "T2 the lead must hold $LANES slice rows"
assert_equals "" "$(printf '%s\n' "$rows" | uniq -d)" "T2 the lead must hold each slice row once"
assert_equals 0 "$(rows_of "$W/main" | grep -c .)" "T2 Main must hold no slice row"
assert_equals "$LANES" "$(find "$W/lead/state" -maxdepth 1 -name 'blitzwide-*.meta' | wc -l)" "T2 each slice must have one lane record"
pass "T2 a stopped start resumes: $LANES rows under the plan in the lead home, each once"
