#!/usr/bin/env bash
# jg-test-host-lib.sh - what one bin/jg-test-run.sh run shares with every other test run on this machine: the Go
# build cache, run slots and shard tokens. Sourced by bin/jg-test-run.sh, which decides when each function runs; the
# functions call that runner's log and now_ms.
#
# Go build cache.
#   Every Go core under core/ is built on first use by its dispatcher (bin/jg-classify.sh and its siblings), and Go
#   keeps compiled packages in a cache under the caller's HOME. A test that moves HOME therefore compiled the standard
#   library again for every build: 10 to 31 cpu-seconds for one core cold, under 2 warm. jg_test_host_pin_go_cache
#   resolves the caller's own cache once, before any script moves HOME, and exports GOCACHE so every script and shard
#   of the run shares it. A caller that set GOCACHE keeps it, and so does a script that sets its own. The cache is
#   content-addressed and safe for builds running at once. jg_test_host_warm_go_cache compiles every core module into
#   it once, so shards that start together link from it instead of each compiling the same packages at the same time.
#
# Toolchain state.
#   Tool shims on PATH (python3 under mise) keep their trust records, their installs and the versions they resolved
#   in the caller's own mise state, data and cache directories. A test that moves HOME to a throwaway one makes the
#   shim see none of it: it refuses a config file it does not trust, or fetches every "latest" version from the
#   network and prints its warnings into the script's output, so a script that reads the backlog through python3
#   failed in the gate and passed on a developer's shell. jg_test_host_pin_mise_dirs resolves the three directories
#   once, before any script moves HOME, and exports MISE_STATE_DIR, MISE_DATA_DIR and MISE_CACHE_DIR. A caller that
#   set one keeps it, and a host with no such directory is left as it is.
#
# Run slots.
#   jg_test_host_admit <max> lets at most <max> runs execute tests on this machine at once; the rest wait, printing one
#   line that names the runners holding the slots. A slot is a kernel lock on JG_TEST_HOST_SLOTS/slot-<k> (default
#   <scratch root>/jg-test-runs-<uid>, the disk scratch root of bin/jg-scratch-root-lib.sh) held by a small keeper process that lives exactly as long as its runner: a killed runner
#   frees its slot within a second, and no test inherits the lock. A run started inside an admitted run (a shard, a
#   test of the runner) inherits JG_TEST_RUN_SLOT and takes no slot. One whose environment was cleared is recognised
#   while it waits: a slot held by one of its own ancestors admits it, so it never waits on the run that started it.
#   A run of the trunk itself (the lander's gate or the verify; bin/jg-trunk.sh gives both JG_TRUNK_GATE_OUTPUT) marks
#   itself as waiting, and a lane run takes no slot while such a mark of a live runner stands, so the trunk run gets
#   the first slot that frees. The trunk run also owns one reserved slot, slot-<max+1>, that a lane run never takes: it
#   tries that slot first, so the landing gate starts at once while every general slot is held by lane proofs.
#   The default limit is one run per 16 cpus held between 2 and 3 (machine_runs_max in defaults/test-speed-limits
#   overrides it), so a burst of test suites never takes more than 3 runs of the host at once.
#   jg_test_host_admit <max> <burst> adds burst slots (machine_runs_burst in defaults/test-speed-limits; 0 is off): when
#   every general slot is held, a lane run (never a trunk run) may take slot-<max+2> to slot-<max+1+burst>, the slots
#   after the reserved trunk slot, but only while this machine's cpu pressure is low: /proc/pressure/cpu some avg10 under
#   10, or, where that file is absent (macOS), load1 under 0.8 x cpus. The load average is not used where the pressure
#   file exists: test runs and agents hold it near half the cpus while agents still feel no stall. The keeper reads the
#   gauge at each try, a burst slot already granted is kept until its run ends, and the grant is recorded in load.tsv
#   as the event admit-burst. JG_TEST_HOST_PRESSURE_FILE and JG_TEST_HOST_LOADAVG_FILE name other files for the two
#   gauges (tests/jg-test-host-burst.test.sh).
#   A run that holds a slot lowers its own CPU priority to nice JG_TEST_NICE (default 10; 0 leaves it alone; never
#   raises priority), so its scripts, shards and their children yield the cpus to agents. Each real slot grant and
#   release appends one line to JG_TEST_HOST_SLOTS/load.tsv: epoch, event, slot, runner pid, load1, cpu pressure
#   (/proc/pressure/cpu some avg10), nice and the ms waited, which is the record of the load during a burst.
#   Time spent waiting is left in JG_TEST_HOST_WAITED_MS. Without python3 or a writable slot directory the run starts
#   without a slot and says so. jg_test_host_release frees the slot at once.
#
# Shard tokens.
#   Each executing shard and each standalone lane run takes a token from the same pool for this OS user, regardless
#   of Juggernaut home, HOME, XDG_CACHE_HOME or TMPDIR. JG_TEST_HOST_SLOTS isolates the pool for tests. A required
#   gate orchestrates its eight shards and holds only a run slot. JG_REQUIRED_SHARD_PARALLEL sets the shared capacity
#   (default 4, maximum 8; 1 runs one shard at a time). When invocations request different capacities, admission
#   honours the lowest among the requester and active holders. A keeper owns the kernel lock until its runner exits,
#   including after a crash. Nested runs of tests can borrow their ancestor's token to avoid waiting on themselves.
#
# Shards on runners (H30b).
#   jg_test_host_run_shard <jg-home> <k> <commit> <base> <out-json> -- <jg-test-run.sh arguments> runs one gate shard
#   on a runner when one has room, else here. A runner is usable when core/runners/registry.sh names it (registered and
#   its latest probe passed), its arch is this host's, and it has a free slot: the record's slots, held down to the
#   probe's free cores. The shard then goes through core/runners/run-shard.sh: the commit travels as a git bundle through
#   the remote job queue and the shard's JSON comes back to <out-json>. A runner that is lost (no connection, no result,
#   a bundle it cannot take) is never a red: the shard runs here in its place, with the same arguments. With no runner
#   registered every shard runs here, as before. A runner slot is a directory JG_TEST_HOST_SLOTS/runner-<id>.slot-<n>
#   made atomically and holding its owner's pid, so shards placed at once never overfill a runner, and a slot whose
#   owner died is taken over.
# The disk scratch root (bin/jg-scratch-root-lib.sh) holds the run slots; a copy of this file with no sibling lib uses /tmp.
_jg_host_dir=${BASH_SOURCE[0]%/*}
if [ -r "$_jg_host_dir/jg-scratch-root-lib.sh" ]; then
  # shellcheck source=bin/jg-scratch-root-lib.sh
  . "$_jg_host_dir/jg-scratch-root-lib.sh"
else
  jg_scratch_root() { return 1; }
fi
unset _jg_host_dir

JG_TEST_HOST_KEEPER=
JG_TEST_SHARD_KEEPER=
JG_TEST_HOST_WAITED_MS=0
JG_TEST_HOST_RECORD_DIR=

jg_test_host_pin_go_cache() {
  local cache
  [ -z "${GOCACHE:-}" ] || return 0
  command -v go >/dev/null 2>&1 || return 0
  cache=$(go env GOCACHE 2>/dev/null) || cache=
  case $cache in
    /*) export GOCACHE="$cache" ;;
    *) log "warning: go env GOCACHE named no cache directory (${cache:-nothing}), so every test that moves HOME compiles Go again" ;;
  esac
}

jg_test_host_pin_mise_dirs() {
  local spec name xdg sub base dir
  for spec in STATE:XDG_STATE_HOME:.local/state DATA:XDG_DATA_HOME:.local/share CACHE:XDG_CACHE_HOME:.cache; do
    IFS=: read -r name xdg sub <<<"$spec"
    name=MISE_${name}_DIR
    [ -z "${!name:-}" ] || continue
    base=${!xdg:-${HOME:-}/$sub}
    dir=$base/mise
    case $dir in /*) [ -d "$dir" ] && export "$name=$dir" ;; esac
  done
  return 0
}

jg_test_host_warm_go_cache() {  # <repository root>
  local mod dir out
  [ -n "${GOCACHE:-}" ] && command -v go >/dev/null 2>&1 || return 0
  for mod in "$1"/core/*/go.mod; do
    [ -f "$mod" ] || continue
    dir=${mod%/go.mod}
    out=$(cd "$dir" && go build ./... 2>&1) ||
      log "warning: could not build ${dir#"$1"/} before the shards started, so each shard that needs it compiles it: $(printf '%s\n' "$out" | tail -n 1)"
  done
}

# The keeper: takes the first free slot, prints "slot <name>" (a burst slot: "burst <name>") and holds the lock while its
# runner lives; prints "nested <name>" when an ancestor of the runner holds a slot; otherwise waits, saying so once.
# shellcheck disable=SC2016 # Python source, not shell
_JG_TEST_HOST_KEEPER_PY='
import fcntl, os, signal, subprocess, sys, time
d, n, owner, mode, burst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
trunk = mode == "trunk"
mark = os.path.join(d, "trunk-waiting-%d" % owner)
def unmark():
    if not trunk:
        return
    try:
        os.unlink(mark)
    except OSError:
        pass
def leave(*_):
    unmark()
    os._exit(0)
signal.signal(signal.SIGTERM, leave)
os.closerange(3, 1024)
def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True
def lineage(pid):
    seen = []
    while pid > 1 and pid not in seen:
        seen.append(pid)
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        pid = int(out) if out.isdigit() else 0
    return seen
def hold(name):
    print(name, flush=True)
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1)
    os.dup2(null, 2)
    while os.getppid() == owner:
        time.sleep(0.5)
    os._exit(0)
def take_shard(claim=True):
    # Count and grant under one short lock so that mixed capacities cannot overbook.
    with open(os.path.join(d, "admission"), "a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        holders, free = [], None
        cap = n
        for k in range(1, 9):
            name = "shard-%d" % k
            fd = os.open(os.path.join(d, name), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pid, width = map(int, os.read(fd, 64).split())
                holders.append(pid)
                cap = min(cap, width)
            else:
                if free is None:
                    free = name, fd
                    continue
            os.close(fd)
        if claim and free and len(holders) < cap:
            name, fd = free
            os.ftruncate(fd, 0)
            os.write(fd, ("%d %d\n" % (owner, n)).encode())
            return free, holders
        if free:
            os.close(free[1])
        return None, holders
if mode in ("shard", "shard-nested"):
    if os.stat(d).st_uid != os.geteuid():
        sys.exit("jg-test-run: host shard token pool is owned by another user: " + d)
    if mode == "shard-nested":
        _, holders = take_shard(claim=False)
        sys.exit(0 if holders and set(holders).intersection(lineage(owner)[1:]) else 1)
    told = False
    ancestors = None
    while os.getppid() == owner:
        token, holders = take_shard()
        if token:
            hold("shard " + token[0])
        if ancestors is None:
            ancestors = set(lineage(owner)[1:])
        if ancestors.intersection(holders):
            print("nested shard", flush=True)
            sys.exit(0)
        if not told:
            sys.stderr.write("jg-test-run: waiting for a host shard token (requested capacity %d)\n" % n)
            told = True
        time.sleep(0.5)
    sys.exit(0)
def trunk_waiting():
    for f in os.listdir(d):
        if f.startswith("trunk-waiting-") and f[14:].isdigit() and int(f[14:]) != owner and alive(int(f[14:])):
            return True
    return False
def gauge(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError:
        return ""
def burst_open():
    text = gauge(os.environ.get("JG_TEST_HOST_PRESSURE_FILE", "/proc/pressure/cpu"))
    if text is not None:
        for line in text.splitlines():
            if line.startswith("some "):
                for field in line.split():
                    if field.startswith("avg10="):
                        try:
                            return float(field[6:]) < 10
                        except ValueError:
                            return False
        return False
    text = gauge(os.environ.get("JG_TEST_HOST_LOADAVG_FILE", "/proc/loadavg"))
    try:
        return float(text.split()[0]) < 0.8 * (os.cpu_count() or 1)
    except (AttributeError, IndexError, ValueError):
        return False
told = False
if trunk:
    open(mark, "w").close()
while alive(owner):
    holders = []
    for k in ([n + 1] if trunk else []) + list(range(1, n + 1)) + ([] if trunk else list(range(n + 2, n + 2 + burst))):
        if not trunk and trunk_waiting():
            break
        if k > n + 1 and not trunk and not burst_open():
            break
        name = "slot-%d" % k
        fd = os.open(os.path.join(d, name), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            holders.append((name, os.read(fd, 32).decode(errors="replace").strip()))
            os.close(fd)
            continue
        os.ftruncate(fd, 0)
        os.write(fd, b"%d\n" % owner)
        unmark()
        hold(("burst " if k > n + 1 else "slot ") + name)
    mine = lineage(owner)
    for name, pid in holders:
        if pid.isdigit() and int(pid) in mine:
            print("nested " + name, flush=True)
            sys.exit(0)
    if not told:
        sys.stderr.write("jg-test-run: waiting for a test-run slot: all %d on this machine are in use (runner pids %s)\n"
                         % (n + (1 if trunk else 0), ", ".join(pid or "unknown" for _, pid in holders)))
        told = True
    time.sleep(2)
unmark()
'

# Appends one load record line for this run's slot (see "Run slots"); never fails the run.
jg_test_host_record_load() {  # <dir> <event> <slot name>
  local load psi
  load=$(cut -d' ' -f1 "${JG_TEST_HOST_LOADAVG_FILE:-/proc/loadavg}" 2>/dev/null) || load=
  psi=$(sed -n 's/^some .*avg10=\([0-9.]*\).*/\1/p' "${JG_TEST_HOST_PRESSURE_FILE:-/proc/pressure/cpu}" 2>/dev/null) || psi=
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$2" "$3" "$$" "${load:-unknown}" "${psi:-unknown}" \
    "$(ps -o ni= -p $$ 2>/dev/null | tr -d ' ')" "$JG_TEST_HOST_WAITED_MS" >>"$1/load.tsv" 2>/dev/null || :
}

# Lowers this run's CPU priority so that every process it starts inherits it; never raises priority.
jg_test_host_lower_priority() {
  local want=${JG_TEST_NICE:-10} cur
  case $want in ''|*[!0-9]*) return 0 ;; esac
  [ "$want" -gt 0 ] || return 0
  cur=$(ps -o ni= -p $$ 2>/dev/null | tr -d ' ')
  case $cur in ''|*[!0-9-]*) return 0 ;; esac
  [ "$cur" -lt "$want" ] || return 0
  renice -n "$want" -p $$ >/dev/null 2>&1 || log "warning: could not lower this run's cpu priority to nice $want, so its tests run at nice $cur"
}

jg_test_host_shard_dir() {
  if [ -n "${JG_TEST_HOST_SLOTS:-}" ]; then
    printf '%s/shards\n' "$JG_TEST_HOST_SLOTS"
  else
    printf '/tmp/jg-test-shards-%s\n' "$(id -u)"
  fi
}

# A gate launched by a running test must schedule serially even if a clean environment lost the pool marker.
jg_test_host_nested_shard() {
  local dir
  dir=$(jg_test_host_shard_dir)
  [ "${JG_TEST_SHARD_POOL:-}" != "$dir" ] || return 0
  [ -d "$dir" ] && python3 -c "$_JG_TEST_HOST_KEEPER_PY" "$dir" 0 "$$" shard-nested 0
}

jg_test_host_admit_shard() {
  local cap=${JG_REQUIRED_SHARD_PARALLEL:-4}
  case $cap in
    *[!0-9]*) cap=1 ;;
    *) cap=${cap#"${cap%%[!0]*}"} ;;
  esac
  case $cap in
    '') cap=1 ;;
    [1-8]) ;;
    *) cap=8 ;;
  esac
  jg_test_host_admit "$cap" 0 shard
}

jg_test_host_admit() {  # <max> [<burst>] [shard]
  local max=$1 burst=${2:-0} mode=${3:-${JG_TRUNK_GATE_OUTPUT:+trunk}} dir fifo line begin keeper
  JG_TEST_HOST_WAITED_MS=0
  if [ "$mode" = shard ]; then
    dir=$(jg_test_host_shard_dir)
    [ "${JG_TEST_SHARD_POOL:-}" != "$dir" ] || return 0
    command -v python3 >/dev/null 2>&1 || { log "python3 is required to take a host shard token"; return 1; }
  else
    [ -z "${JG_TEST_RUN_SLOT:-}" ] || return 0
    command -v python3 >/dev/null 2>&1 || { log "warning: no python3, so this run takes no test-run slot and is not queued"; return 0; }
    dir=${JG_TEST_HOST_SLOTS:-$(jg_scratch_root || echo /tmp)/jg-test-runs-$(id -u)}
  fi
  if ! (umask 077; mkdir -p "$dir") || ! fifo=$(mktemp -u "${TMPDIR:-/tmp}/jg-test-admit.XXXXXX") || ! mkfifo -m 600 "$fifo"; then
    [ "$mode" != shard ] || { log "cannot open the host shard token pool $dir"; return 1; }
    log "warning: cannot use the test-run slot directory $dir, so this run is not queued"
    return 0
  fi
  begin=$(now_ms)
  python3 -c "$_JG_TEST_HOST_KEEPER_PY" "$dir" "$max" "$$" "$mode" "$burst" >"$fifo" &
  keeper=$!
  IFS= read -r line <"$fifo" || line=
  rm -f -- "$fifo"
  JG_TEST_HOST_WAITED_MS=$(( $(now_ms) - begin ))
  if [ "$mode" = shard ]; then
    case $line in
      'shard '*) JG_TEST_SHARD_KEEPER=$keeper ;;
      'nested shard') ;;
      *) log "the host shard token keeper stopped before granting a token"; return 1 ;;
    esac
    export JG_TEST_SHARD_POOL="$dir"
    return 0
  fi
  JG_TEST_HOST_KEEPER=$keeper
  case $line in
    'slot '*|'burst '*)
      export JG_TEST_RUN_SLOT="$dir/${line#* }"
      jg_test_host_lower_priority
      JG_TEST_HOST_RECORD_DIR=$dir
      case $line in burst*) jg_test_host_record_load "$dir" admit-burst "${line#* }" ;; *) jg_test_host_record_load "$dir" admit "${line#* }" ;; esac
      ;;
    'nested '*) export JG_TEST_RUN_SLOT="$dir/${line#nested }"; JG_TEST_HOST_KEEPER= ;;
    *) JG_TEST_HOST_KEEPER=; log "warning: the test-run slot keeper stopped without a slot, so this run is not queued" ;;
  esac
  [ "$JG_TEST_HOST_WAITED_MS" -lt 2000 ] || log "got test-run slot ${JG_TEST_RUN_SLOT##*/} after waiting ${JG_TEST_HOST_WAITED_MS}ms"
}

jg_test_host_release() {
  if [ -n "$JG_TEST_SHARD_KEEPER" ]; then
    kill "$JG_TEST_SHARD_KEEPER" 2>/dev/null || :
    wait "$JG_TEST_SHARD_KEEPER" 2>/dev/null || :
    JG_TEST_SHARD_KEEPER=
  fi
  [ -n "$JG_TEST_HOST_KEEPER" ] || return 0
  [ -z "${JG_TEST_RUN_SLOT:-}" ] || jg_test_host_record_load "${JG_TEST_HOST_RECORD_DIR:-${JG_TEST_RUN_SLOT%/*}}" release "${JG_TEST_RUN_SLOT##*/}"
  kill "$JG_TEST_HOST_KEEPER" 2>/dev/null || :
  wait "$JG_TEST_HOST_KEEPER" 2>/dev/null || :
  JG_TEST_HOST_KEEPER=
}

jg_test_host_arch() {
  case $(uname -m) in aarch64|arm64) echo arm64 ;; *) echo x86_64 ;; esac
}

jg_test_host_runner_slot() {  # <jg-home> <runner id>; claims a free slot on the runner and prints its directory, else fails
  local home=$1 id=$2 record slots free cap n slot owner dir
  dir=${JG_TEST_HOST_SLOTS:-$(jg_scratch_root || echo /tmp)/jg-test-runs-$(id -u)}
  record=$("$JG_TEST_HOST_ROOT/core/runners/registry.sh" get "$home" "$id" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$record" | sed -n 's/^arch=//p')" = "$(jg_test_host_arch)" ] || return 1
  slots=$(printf '%s\n' "$record" | sed -n 's/^slots=//p')
  free=$(awk -F'\t' -v id="$id" '$2 == id { f = $4 } END { print f + 0 }' "${JG_STATE_OVERRIDE:-$home/state}/runner-health.tsv" 2>/dev/null)
  cap=$slots
  [ "$free" -ge "$cap" ] || cap=$free
  mkdir -p "$dir" 2>/dev/null || return 1
  for ((n = 1; n <= cap; n++)); do
    slot=$dir/runner-$id.slot-$n
    if ! mkdir "$slot" 2>/dev/null; then
      owner=$(cat "$slot/owner" 2>/dev/null) || owner=
      case $owner in ''|*[!0-9]*) continue ;; esac
      kill -0 "$owner" 2>/dev/null && continue
      rm -f -- "$slot/owner"
      rmdir "$slot" 2>/dev/null || continue
      mkdir "$slot" 2>/dev/null || continue
    fi
    printf '%s\n' "$$" > "$slot/owner"
    printf '%s\n' "$slot"
    return 0
  done
  return 1
}

jg_test_host_run_shard() {  # <jg-home> <k> <commit> <base> <out-json> -- <jg-test-run.sh arguments>
  local home=$1 k=$2 commit=$3 base=$4 out=$5 runner slot rc
  shift 6
  JG_TEST_HOST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  for runner in $("$JG_TEST_HOST_ROOT/core/runners/registry.sh" usable "$home" 2>/dev/null); do
    slot=$(jg_test_host_runner_slot "$home" "$runner") || continue
    log "shard $k goes to runner $runner"
    rc=0
    "$JG_TEST_HOST_ROOT/core/runners/run-shard.sh" "$home" "$runner" "$commit" "$base" "$out" -- "$@" || rc=$?
    rm -f -- "$slot/owner"
    rmdir "$slot" 2>/dev/null || :
    [ "$rc" -ne 3 ] && return "$rc"
    log "runner $runner was lost for shard $k, which is not a red: the shard runs here"
    break
  done
  rc=0
  bash "$JG_TEST_HOST_ROOT/bin/jg-test-run.sh" "$@" --json "$out" || rc=$?
  return "$rc"
}
