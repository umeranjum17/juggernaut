#!/usr/bin/env bash
# trunk-pulse.sh <home> <since-epoch> [<now-epoch>] - one home's trunk landings for the fleet pulse.
#
# A local-trunk home merges no feature pull request: a lane's commit lands on the trunk and the
# home moves to a go-live, so a merged-PR count reads 0 there however fast it lands.
# This reads the tickets' own stamps instead, from the home's store through `bin/jg-backlog.sh times --json`:
# landed_at, live_at and released_at, with pinned_back_at and reverted_at that undo them.
#
# Prints one TSV row: landed in_homes ready_min
#   landed     tickets whose landed_at is at or after <since-epoch>
#   in_homes   tickets whose live_at is at or after <since-epoch> (the homes moved; In use needs the delivery machine)
#   ready_min  whole minutes the oldest landed ticket has waited to reach the homes, or - when none waits.
#              A ticket waits while its landing stands (no later reverted_at), it has no live_at or a later
#              pinned_back_at undid it, and no release followed the landing.
# Exits 1 printing nothing when the home's store holds no stamped ticket or cannot be read: that is a merged-PR
# home, whose pulse keeps counting merged pull requests. Exits 2 on a usage error.
set -euo pipefail

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: trunk-pulse.sh <home> <since-epoch> [<now-epoch>]' >&2; exit 2; }
home=$1 since=$2 now=${3:-$(date +%s)}
case "$since$now" in *[!0-9]*) echo "trunk-pulse: since and now must be epoch seconds (got '$since' '$now')" >&2; exit 2 ;; esac
[ -x "$home/bin/jg-backlog.sh" ] || exit 1
stamps=$(JG_HOME=$home timeout 30 "$home/bin/jg-backlog.sh" times --json 2>/dev/null) || exit 1

STAMPS=$stamps python3 -I - "$since" "$now" <<'PY'
import datetime, json, os, sys

since, now = int(sys.argv[1]), int(sys.argv[2])
rows = json.loads(os.environ["STAMPS"])
if not rows:
    sys.exit(1)


def epoch(row, key):
    text = row.get(key)
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()) if text else None


landed = live = 0
oldest = None
for row in rows:
    at, lv, rel = epoch(row, "landed_at"), epoch(row, "live_at"), epoch(row, "released_at")
    pin, rev = epoch(row, "pinned_back_at"), epoch(row, "reverted_at")
    if lv is not None and lv >= since:
        live += 1
    if at is None:
        continue
    if at >= since:
        landed += 1
    in_use = lv is not None and (pin is None or pin <= lv)
    if in_use or (rev is not None and rev > at) or (rel is not None and rel >= at):
        continue
    oldest = at if oldest is None else min(oldest, at)
print("%d\t%d\t%s" % (landed, live, "-" if oldest is None else max(0, (now - oldest) // 60)))
PY
