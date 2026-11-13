#!/usr/bin/env bash
# Live check 7 (stop 6, every 1 min): the host has room. The 1-min load per CPU stays under JG_LIVE_LOAD_PER_CPU (default 2) and free
# memory (MemAvailable) stays over JG_LIVE_MEM_MIN_MB (default 1024). JG_LIVE_LOADAVG and JG_LIVE_MEMINFO move the sources.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load=$(awk '{print $1}' "${JG_LIVE_LOADAVG:-/proc/loadavg}"); cpus=$(nproc 2>/dev/null || echo 1)
mem_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' "${JG_LIVE_MEMINFO:-/proc/meminfo}")
awk -v l="$load" -v c="$cpus" -v m="${JG_LIVE_LOAD_PER_CPU:-2}" 'BEGIN{exit !(l/c > m)}' && live_red "load $load on $cpus CPU(s) is over ${JG_LIVE_LOAD_PER_CPU:-2} per CPU"
[ "${mem_mb:-0}" -ge "${JG_LIVE_MEM_MIN_MB:-1024}" ] || live_red "${mem_mb:-0} MB free is under ${JG_LIVE_MEM_MIN_MB:-1024} MB"
live_pass "load $load on $cpus CPU(s), $mem_mb MB free"
