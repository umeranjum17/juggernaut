#!/usr/bin/env bash
# jg-test-host-lib.sh - what one bin/jg-test-run.sh run shares with every other test run on this machine: the Go
# build cache and a run slot. Sourced by bin/jg-test-run.sh only, which decides when each function runs; the
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
# Run slots.
#   jg_test_host_admit <max> lets at most <max> runs execute tests on this machine at once; the rest wait, printing one
#   line that names the runners holding the slots. A slot is a kernel lock on JG_TEST_HOST_SLOTS/slot-<k> (default
#   /tmp/jg-test-runs-<uid>) held by a small keeper process that lives exactly as long as its runner: a killed runner
#   frees its slot within a second, and no test inherits the lock. A run started inside an admitted run (a shard, a
#   test of the runner) inherits JG_TEST_RUN_SLOT and takes no slot. One whose environment was cleared is recognised
#   while it waits: a slot held by one of its own ancestors admits it, so it never waits on the run that started it.
#   Time spent waiting is left in JG_TEST_HOST_WAITED_MS. Without python3 or a writable slot directory the run starts
#   without a slot and says so. jg_test_host_release frees the slot at once.

JG_TEST_HOST_KEEPER=
JG_TEST_HOST_WAITED_MS=0

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

# The keeper: takes the first free slot, prints "slot <name>" and holds the lock while its runner lives; prints
# "nested <name>" when an ancestor of the runner holds a slot; otherwise waits, saying so once.
# shellcheck disable=SC2016 # Python source, not shell
_JG_TEST_HOST_KEEPER_PY='
import fcntl, os, signal, subprocess, sys, time
d, n, owner = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
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
told = False
while alive(owner):
    holders = []
    for k in range(1, n + 1):
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
        print("slot " + name, flush=True)
        null = os.open(os.devnull, os.O_WRONLY)
        os.dup2(null, 1)
        os.dup2(null, 2)
        while alive(owner):
            time.sleep(1)
        os._exit(0)
    mine = lineage(owner)
    for name, pid in holders:
        if pid.isdigit() and int(pid) in mine:
            print("nested " + name, flush=True)
            sys.exit(0)
    if not told:
        sys.stderr.write("jg-test-run: waiting for a test-run slot: all %d on this machine are in use (runner pids %s)\n"
                         % (n, ", ".join(pid or "unknown" for _, pid in holders)))
        told = True
    time.sleep(2)
'

jg_test_host_admit() {  # <max>
  local max=$1 dir fifo line begin
  JG_TEST_HOST_WAITED_MS=0
  [ -z "${JG_TEST_RUN_SLOT:-}" ] || return 0
  command -v python3 >/dev/null 2>&1 || { log "warning: no python3, so this run takes no test-run slot and is not queued"; return 0; }
  dir=${JG_TEST_HOST_SLOTS:-/tmp/jg-test-runs-$(id -u)}
  if ! mkdir -p "$dir" 2>/dev/null || ! fifo=$(mktemp -u "${TMPDIR:-/tmp}/jg-test-admit.XXXXXX") || ! mkfifo -m 600 "$fifo"; then
    log "warning: cannot use the test-run slot directory $dir, so this run is not queued"
    return 0
  fi
  begin=$(now_ms)
  python3 -c "$_JG_TEST_HOST_KEEPER_PY" "$dir" "$max" "$$" >"$fifo" &
  JG_TEST_HOST_KEEPER=$!
  IFS= read -r line <"$fifo" || line=
  rm -f -- "$fifo"
  JG_TEST_HOST_WAITED_MS=$(( $(now_ms) - begin ))
  case $line in
    'slot '*) export JG_TEST_RUN_SLOT="$dir/${line#slot }" ;;
    'nested '*) export JG_TEST_RUN_SLOT="$dir/${line#nested }"; JG_TEST_HOST_KEEPER= ;;
    *) JG_TEST_HOST_KEEPER=; log "warning: the test-run slot keeper stopped without a slot, so this run is not queued" ;;
  esac
  [ "$JG_TEST_HOST_WAITED_MS" -lt 2000 ] || log "got test-run slot ${JG_TEST_RUN_SLOT##*/} after waiting ${JG_TEST_HOST_WAITED_MS}ms"
}

jg_test_host_release() {
  [ -n "$JG_TEST_HOST_KEEPER" ] || return 0
  kill "$JG_TEST_HOST_KEEPER" 2>/dev/null || :
  wait "$JG_TEST_HOST_KEEPER" 2>/dev/null || :
  JG_TEST_HOST_KEEPER=
}
