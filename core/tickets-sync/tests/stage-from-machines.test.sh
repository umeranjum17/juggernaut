#!/usr/bin/env bash
# A ticket's stage is the word the task and delivery machines print for its lane, and the board's percent is gone:
# a lander refusal and a revert read rework, a finished lane waiting to land reads ready-to-land, a landed lane reads the
# delivery word of its change (in-homes-off, in-use), an item no worker has touched reads queued. Every record is
# generated here in the shape its writer prints, and the real observers of core/machines read it; no board is needed.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-stage.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
export GIT_CONFIG_COUNT=0 JG_HOME=$work/home JG_DELIVERY_CHANGES=$work/changes.tsv
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
repo=$JG_HOME/projects/juggernaut
mkdir -p "$repo" "$JG_HOME"/{state,data/jg-trunk-landing,config}
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
git init -q -b trunk "$repo"
commit() { printf '%s\n' "$1" >> "$repo/$1"; git -C "$repo" add -A; git -C "$repo" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false commit -q -m "$1"; git -C "$repo" rev-parse HEAD; }
off=$(commit off.txt) on=$(commit on.txt)
printf '%s' "$on" > "$JG_HOME/state/trunk-tip-juggernaut"
{ tab change-off juggernaut "$off" switch-off switch "ships behind a switch that is off"
  tab change-on juggernaut "$on" switch-on switch "ships behind a switch that is on"; } > "$JG_DELIVERY_CHANGES"
touch "$JG_HOME/config/switch-on"
tab juggernaut:primary "$on" "$(date +%s)" live >> "$JG_HOME/data/trunk-in-use.tsv"
# A finished local-trunk lane: its meta names the mode and its status log says done.
lane() { printf 'mode=local-trunk\n' > "$JG_HOME/state/$1.meta"; printf 'done [at=1700000000]: ready in branch fix/%s\n' "$1" > "$JG_HOME/state/$1.status"; }
for id in refused reverted waiting waiting-too; do lane "$id"; done
printf 'final gate lint failed\n' > "$JG_HOME/data/jg-trunk-landing/refused.0000000000000000000000000000000000000001.state"
tab "revert-reverted" juggernaut "$on" 1700000000 full >> "$JG_HOME/data/trunk-landings.tsv"
for id in delivered-off delivered-on; do
  printf 'mode=local-trunk\n' > "$JG_HOME/state/$id.meta"; printf 'done [at=1700000000]: ready\n' > "$JG_HOME/state/$id.status"
  printf 'landed\n' > "$JG_HOME/data/jg-trunk-landing/$id.0000000000000000000000000000000000000002.state"
done
tab delivered-off juggernaut "$off" 1700000000 full >> "$JG_HOME/data/trunk-landings.tsv"
tab delivered-on juggernaut "$on" 1700000000 full >> "$JG_HOME/data/trunk-landings.tsv"

got=$(python3 -I - "$root" "$JG_HOME" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'core/tickets-sync'))
from lane import stage
root, source = Path(sys.argv[1]), Path(sys.argv[2])
for item in ('refused', 'reverted', 'waiting', 'waiting-too', 'delivered-off', 'delivered-on', 'untouched'):
    row = dict(state='queued', title='Umer ' + item, body='', links='')
    said, board, done, link, event = stage(root, source, item, row, {}, lambda cmd: '')
    print(item, said, board, done)
PY
)
want='refused rework building False
reverted rework building False
waiting ready-to-land merging False
waiting-too ready-to-land merging False
delivered-off in-homes-off merging False
delivered-on in-use merging False
untouched queued queued False'
[ "$got" = "$want" ] || { printf 'FAIL: the stages read\n%s\nwanted\n%s\n' "$got" "$want"; exit 1; }
echo 'PASS: a lane reads the word of its machines (rework, ready-to-land, in-homes-off, in-use) and an untouched item reads queued'
