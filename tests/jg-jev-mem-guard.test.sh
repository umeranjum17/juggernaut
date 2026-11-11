#!/usr/bin/env bash
# Exercise both entry points against synthetic host pressure and admission records.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
d=$(jg_test_tmproot jg-jev-mem-guard)
export JG_HOST_MEMORY_PROC="$d/proc" JG_HOST_MEMORY_CGROUP_ROOT="$d/cgroup"
app="$JG_HOST_MEMORY_CGROUP_ROOT/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice"
mkdir -p "$JG_HOST_MEMORY_PROC/pressure" "$app" "$d/state"
printf 'MemAvailable: 20971520 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$JG_HOST_MEMORY_PROC/meminfo"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$JG_HOST_MEMORY_PROC/pressure/memory"
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$app/memory.pressure"
wrapper="$ROOT/bin/jg-jev-mem-guard.sh"
python_guard="$ROOT/bin/jg-jev-mem-guard.py"
out=$(bash "$wrapper")
[[ "$out" == OK$'\t'* ]] || fail "calm host was not OK: $out"
printf 'some avg10=40 avg60=40 avg300=0 total=0\n' > "$app/memory.pressure"
if python3 "$python_guard" --admit sample --state "$d/state" > "$d/refusal"; then
  fail 'sustained pressure admitted a launch'
fi
[ -s "$d/state/admission-refused" ] || fail 'refusal record missing'
printf 'some avg10=0 avg60=0 avg300=0 total=0\n' > "$app/memory.pressure"
bash "$wrapper" --admit sample --state "$d/state" || fail 'calm host refused admission'
[ ! -e "$d/state/admission-refused" ] || fail 'stale refusal remained'
bash "$wrapper" --record "$d/samples" > "$d/output"
grep -q $'\tOK$' "$d/samples" || fail 'sample was not recorded as OK'
pass 'memory guard admits and refuses synthetic host pressure and records a sample'
