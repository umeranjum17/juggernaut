#!/usr/bin/env bash
# tests/jg-lane-place.test.sh - where a new lead home starts (core/lane-scale/place.sh, H30e).
# Journey through the real place.sh, fleet.sh verdict, runner registry and ledger on fixture host signals; only the remote seed
# command is a recorder (bin/jg-remote-home-seed.sh has its own tests). A host with room keeps the home; a full host sends it to the
# first usable runner, own machines first; a private repository goes only to a private_ok runner; a paid runner needs the ledger cap.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -z "${DONE_DONE_EVIDENCE_ROOT:-}" ] || exec > >(tee "$DONE_DONE_EVIDENCE_ROOT/lane-place.log")
w=$(mktemp -d "${TMPDIR:-/tmp}/jg-lane-place.XXXXXX") || exit 1
trap 'rm -rf -- "$w"' EXIT
H=$w/home; R=$w/root
mkdir -p "$H/state" "$H/config" "$R/bin"
ln -sn "$here/core" "$R/core"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s/seed.calls\n' "$w" > "$R/bin/jg-remote-home-seed.sh"; chmod +x "$R/bin/jg-remote-home-seed.sh"
printf 'MemAvailable: 33554432 kB\n' > "$w/meminfo"
export JG_FLEET_CORES=32 JG_FLEET_MEMINFO=$w/meminfo JG_ROOT_OVERRIDE=$R
printf 'cores_stop=24\n' > "$H/config/lane-scale"
fails=0; is() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: got [$2], want [$3]"; fails=$((fails + 1)); fi; }
busy() { printf '%s\n' "$(printf '100 /usr/bin/claude\n%.0s' $(seq 1 "$1"))" > "$w/ps"; export JG_FLEET_PS="cat $w/ps"; }
pick() { "$here/core/lane-scale/place.sh" pick "$H" "$@"; }
now=$(date +%s)
health() { printf '%s\t%s\t%s\t%s\t\n' "$now" "$1" "$2" "$3" >> "$H/state/runner-health.tsv"; }

busy 4
is "a host with room keeps the home" "$(pick)" local
busy 28
is "a full host with no runner stops and says so" "$(pick | cut -c1-39)" "stop this host is full and no usable ru"
printf 'own1 ssh=a root=/r home=/h arch=x86_64 cores=8 mem_gb=16 slots=2 cost_per_hour=0 private_ok=yes\ncloud1 ssh=b root=/rc home=/hc arch=x86_64 cores=8 mem_gb=16 slots=2 cost_per_hour=0.4 private_ok=no\nown2 ssh=c root=/r home=/h arch=x86_64 cores=8 mem_gb=16 slots=2 cost_per_hour=0 private_ok=no\n' > "$H/config/runners"
is "a runner with no passed probe gets nothing" "$(pick | cut -c1-4)" stop
health own1 ok 0; health cloud1 ok 4; health own2 ok 3
is "a runner with no free core is skipped; a paid one waits for the ledger cap" "$(pick)" "runner own2 c /r /h"
health own1 ok 2
is "own machines come first" "$(pick)" "runner own1 a /r /h"
health own1 failed 0; health own2 failed 0
is "a paid runner is refused at cap 0" "$(pick | cut -c1-4)" stop
printf 'paid_minutes_day=60\n' > "$H/config/fleet-scale"
is "a raised cap lets the paid runner take it" "$(pick)" "runner cloud1 b /rc /hc"
is "a private repository never goes to a runner that is not private_ok" "$(pick --private | cut -c1-70)" "stop this host is full and no owned runner (private_ok=yes) can take a"
health own1 ok 2
is "a private repository goes to the owned runner" "$(pick --private)" "runner own1 a /r /h"

out=$("$here/core/lane-scale/place.sh" seed "$H" lead9 --private projA=https://github.com/o/a.git)
is "seed starts the home on the runner" "$out" "runner own1"
is "the remote Squad Lead path gets the runner's route and a home under the runner home" "$(cat "$w/seed.calls")" "lead9 a /r /h/lead9 projA=https://github.com/o/a.git"
rm -f "$w/seed.calls"; busy 4
is "seed on a host with room starts nothing remote" "$("$here/core/lane-scale/place.sh" seed "$H" lead8 --no-projects)" local
[ ! -e "$w/seed.calls" ]; is "no remote seed ran" "$?" 0
[ "$fails" -eq 0 ] && echo "PASS lane-place" || exit 1
