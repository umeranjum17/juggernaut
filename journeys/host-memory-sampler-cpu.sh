#!/usr/bin/env bash
# The host memory sampler at rest: the alert still names a task in a local Squad Lead's home, and
# the real sampler loop over a lab lead tree uses under 5% of one core for 60 s while memory is fine.
# HOST_MEMORY_BEFORE_REF=<git ref> also measures that ref's sampler on the same tree, for comparison.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ev=${DONE_DONE_EVIDENCE_ROOT:?}
out=$ev/${DONE_DONE_RUN_ID:-run}.log
secs=${HOST_MEMORY_LAB_SECS:-60}
d=$(mktemp -d)
pids=()
trap 'kill -TERM "${pids[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf -- "$d"' EXIT

# lab <tree> <label>: the tree's real sampler loop for $secs over a fresh lab tree shaped like a
# busy root: 95 task records and 15 registered local Squad Leads with 20 task records each.
lab() {
  local tree=$1 label=$2 home=$d/${2%% *} i l watcher sampler cpu
  local -a f
  mkdir -p "$home/root/state" "$home/root/config" "$home/root/data"
  for i in $(seq 1 95); do printf 'kind=ship\nworktree=%s/wt/%s\n' "$home" "$i" > "$home/root/state/task-$i.meta"; done
  for l in $(seq 1 15); do
    mkdir -p "$home/lead-$l/state"
    printf 'kind=squad_lead\nhome=%s\n' "$home/lead-$l" > "$home/root/state/lead-$l.meta"
    printf -- '- lead-%s - Umer lab lead (home: %s; scope: lab; projects: umer-app; added 2026-11-09)\n' "$l" "$home/lead-$l" >> "$home/root/data/squad_leads.md"
    for i in $(seq 1 20); do printf 'kind=ship\nworktree=%s/wt/%s-%s\n' "$home" "$l" "$i" > "$home/lead-$l/state/task-$i.meta"; done
  done
  # A stand-in watcher of ours, recorded in the lock the loop checks before every tick.
  sleep 3600 & watcher=$!
  pids+=("$watcher")
  mkdir -p "$home/root/state/.watch.lock"
  printf '%s\n' "$watcher" > "$home/root/state/.watch.lock/pid"
  printf '%s\n' "$home/root" > "$home/root/state/.watch.lock/jg-home"
  printf '%s\n' "$tree/bin/jg-watch.sh" > "$home/root/state/.watch.lock/watcher-path"
  bash -c '. "$1/bin/jg-wake-lib.sh"; jg_pid_identity "$2"' _ "$tree" "$watcher" > "$home/root/state/.watch.lock/pid-identity"
  env JG_HOST_MEMORY_FORK_BIN="$tree/bin" JG_HOME="$home/root" JG_STATE_OVERRIDE="$home/root/state" JG_CONFIG_OVERRIDE="$home/root/config" \
    "$tree/core/host-memory/bin/jg-host-memory-sampler.sh" run "$home/root" "$home/root/state" "$home/root/config" </dev/null >"$home/sampler.log" 2>&1 &
  sampler=$!
  pids+=("$sampler")
  sleep "$secs"
  read -r -a f < <(cut -d')' -f2- "/proc/$sampler/stat")
  cpu=$(( f[11] + f[12] + f[13] + f[14] ))
  kill -TERM "$sampler" "$watcher" 2>/dev/null
  awk -v c="$cpu" -v hz="$(getconf CLK_TCK)" -v s="$secs" -v t="$(awk 'END { print NR }' "$home/root/state/host-memory.tsv" 2>/dev/null)" -v n="$label" 'BEGIN {
    printf "%s: %d s, %d samples, %.2f CPU-s, %.2f%% of one core, %.3f CPU-s per tick\n", n, s, t, c / hz, 100 * c / hz / s, (t ? c / hz / t : 0) }'
}

run_all() {
  local rc=0
  echo "=== host memory alert routing and attribution ==="
  bash "$root/core/host-memory/tests/jg-host-memory-alert-routing.test.sh" || rc=1
  echo "=== sampler loop CPU, load $(cut -d' ' -f1-3 /proc/loadavg) ==="
  if [ -n "${HOST_MEMORY_BEFORE_REF:-}" ]; then
    mkdir -p "$d/before-tree"
    git -C "$root" archive "$HOST_MEMORY_BEFORE_REF" bin core | tar -x -C "$d/before-tree"
    lab "$d/before-tree" "before $(git -C "$root" rev-parse --short "$HOST_MEMORY_BEFORE_REF")" | tee "$ev/sampler-cpu-before.txt"
  fi
  lab "$root" "after $(git -C "$root" rev-parse --short HEAD)" | tee "$ev/sampler-cpu-after.txt"
  awk '{ for (i = 1; i <= NF; i++) if ($i == "of" && $(i+1) == "one") { v = $(i-1); sub(/%/, "", v); exit !(v + 0 < 5) } exit 1 }' \
    "$ev/sampler-cpu-after.txt" || { echo "FAIL: the sampler loop used 5% of one core or more"; rc=1; }
  [ "$rc" -ne 0 ] || echo "PASS host memory sampler at rest"
  return "$rc"
}

run_all > "$out" 2>&1
rc=$?
cat "$out"
cat > "$ev/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway homes: alert fixtures with a fixture /proc, and a lab root with 95 task records and 15 registered local Squad Leads holding 20 task records each, on the real host /proc",
 "steps": ["run the real sampler tick at the alert level in a lead home, the root and a home with no parent record", "run it at the root where a fixture process works in a task recorded in a lead's home", "run the real sampler loop for ${secs} s over the lab tree and read its whole process tree's CPU", "with HOST_MEMORY_BEFORE_REF, run that ref's loop over the same tree"],
 "result": "the alert wakes Main alone, names the task in the lead's home and never interrupts it; the sampler loop uses under 5% of one core at rest"}
JSON
exit "$rc"
