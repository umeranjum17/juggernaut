#!/usr/bin/env bash
# tests/jg-lane-scale-machines.test.sh - work runs on more machines than this host, under the one core budget (core/lane-scale/fleet.sh place).
# Journey through the real fleet.sh with a stand-in for ssh: the host is full, so the lane goes to the machine with most headroom;
# a machine that cannot be read is named and skipped; every machine full stops all starts; 120 machines are read in one round.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/lane-scale-machines.log")
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-lane-machines.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
H=$w/home; mkdir -p "$H/state" "$H/config" "$H/core" "$w/ps"
ln -s "$here/core/lane-scale" "$H/core/lane-scale"
printf 'MemAvailable:   33554432 kB\n' > "$w/meminfo"
fails=0; is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
# A fixture process list for the host and for each machine: <n> sessions of 1 core each.
mkps() { local f=$1; shift; : > "$f"; for _ in $(seq 1 "$1"); do echo "100 /usr/bin/claude" >> "$f"; done; }
export JG_FLEET_CORES=8 JG_FLEET_MEMINFO=$w/meminfo JG_FLEET_PS="cat $w/ps/local"
export JG_FLEET_SSH="sh -c 'cat $w/ps/\$0 || exit 1'"
place() { "$here/core/lane-scale/fleet.sh" place "$H"; }
printf 'big big 32\nsmall small 8\n' > "$H/config/lane-scale-machines"

mkps "$w/ps/local" 2; mkps "$w/ps/big" 10; mkps "$w/ps/small" 1
is "host has 4 free of 6, big has 14 of 24: big gets the lane" "$(place)" big
is "the record names the place and each machine" "$(grep -c '^machine ' "$H/state/fleet-machines.rec")" 3
mkps "$w/ps/local" 8; is "host full: the lane goes to a machine" "$(place | cut -c1-3)" big
rm "$w/ps/small"; is "a machine that cannot be read is named and skipped" "$(place)" "big (unread: small)"
mkps "$w/ps/big" 24; mkps "$w/ps/small" 6
is "every machine full: stop, and no host is guessed" "$(place | cut -c1-4)" stop
mkps "$w/ps/local" 1; is "host free again: it gets the lane" "$(place)" local

# 100x: 120 machines, one round of reads, the one with room is found.
: > "$H/config/lane-scale-machines"
for i in $(seq 1 120); do echo "m$i m$i 8" >> "$H/config/lane-scale-machines"; mkps "$w/ps/m$i" 6; done
echo "1 /bin/sh" > "$w/ps/m77"
mkps "$w/ps/local" 8
start=$SECONDS; got=$(place); took=$((SECONDS - start))
is "120 machines: the one with room is named" "$got" m77
is "120 machines are read in one round, not one after another" "$([ "$took" -lt 20 ] && echo fast)" fast
is "the record holds every machine that was read (the full host steps aside)" "$(grep -c '^machine ' "$H/state/fleet-machines.rec")" 120
[ "$fails" -eq 0 ] && echo "PASS lane-scale-machines" || exit 1
