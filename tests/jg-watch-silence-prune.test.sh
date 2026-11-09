#!/usr/bin/env bash
# The phantom-pane prune removes every marker a vanished pane owns, including the two silence markers.
# A pane the backend reports absent loses all of them; a pane the backend still lists keeps all of them.
# The prune also reports its move to the markers table in shadow (data/machine-shadow.log): nothing for a
# legal move, one line for an illegal one, and the prune itself is the same either way.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
WATCH="$ROOT/bin/jg-watch.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-silence-prune)
KINDS="hash count churn-since dead-reported truth-read truth-raised activity activity-observed silent-seen silent-working"

seed_pane() { # <state> <window> <key>: a tracked pane with no task record and one marker of every kind
  local state=$1 window=$2 key=$3 kind
  printf '%s\ttmux\n' "$window" > "$state/.tracked-$key"
  for kind in $KINDS; do printf 'x' > "$state/.$kind-$key"; done
}

seed_table() { # <dir> <observed state>: a markers table whose only legal prune is orphan -> removed
  mkdir -p "$1/tables"
  printf 'machine\tmarkers\tm\tx\nstate\torphan\tinitial\tO.\t-\nstate\towned\tnormal\tW.\t-\nstate\tremoved\tterminal\tR.\t-\nedge\torphan\tprune\tremoved\tw:f\t-\tg\tt\nedge\torphan\tjoin\towned\tw:f\t-\tg\tt\nobserver\techo %s\n' "$2" > "$1/tables/markers.tsv"
}

test_prune() ( # <observed state> <shadow lines wanted>
  local dir state pid='' i kind
  dir=$(make_case "prune-$1")
  state="$dir/state"
  trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; wait 2>/dev/null || true' EXIT
  seed_pane "$state" crew:gone crew_gone
  seed_pane "$state" crew:live crew_live
  seed_table "$dir" "$1"
  PATH="$dir/fakebin:$PATH" JG_FAKE_TMUX_WINDOWS=live JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_MACHINES_TABLES="$dir/tables" \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  for ((i=0; i<150; i++)); do
    [ -e "$state/.tracked-crew_gone" ] || break
    sleep 0.1
  done
  [ ! -e "$state/.tracked-crew_gone" ] || fail "the prune did not run for the absent pane: $(cat "$dir/watch.err")"
  for kind in $KINDS; do
    [ ! -e "$state/.$kind-crew_gone" ] || fail "the absent pane kept its .$kind marker"
    [ -e "$state/.$kind-crew_live" ] || fail "the present pane lost its .$kind marker"
  done
  [ -e "$state/.tracked-crew_live" ] || fail "the present pane lost its tracking sidecar"
  [ "$( [ -f "$dir/data/machine-shadow.log" ] && wc -l < "$dir/data/machine-shadow.log" || echo 0)" -eq "$2" ] \
    || fail "wanted $2 shadow lines for a $1 marker: $(cat "$dir/data/machine-shadow.log" 2>/dev/null)"
  pass "an absent pane loses every marker, including both silence markers; a present pane keeps them ($1 marker: $2 shadow lines)"
)

result=0
test_prune orphan 0 || result=1
test_prune owned 1 || result=1
exit "$result"
