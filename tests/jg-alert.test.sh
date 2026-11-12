#!/usr/bin/env bash
# Behavior test for the alert table and its raise function (bin/jg-alert.sh, core/machines/styles/alert-table.tsv, core/machines/tables/alert.tsv;
# slice J10 of the state-machine plan). Everything runs through the real command in a fixture home: a stuck wait raises one alert with the
# right precedence and rung in each of the four delivery modes; with supervision-down open it raises none; the quiet facts, the limits
# by kind, the ladder top, rule I5, rule I6 and the four states are each driven once.
# shellcheck disable=SC2016,SC2034
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AL="$ROOT/bin/jg-alert.sh"; JM="$ROOT/bin/jg-machine.sh"
T=$(cd "$(jg_test_tmproot jg-alert)" && pwd); H=$T/home
mkdir -p "$H/state"
export JG_HOME="$H" JG_STATE_OVERRIDE="$H/state"
al() { OUT=$(bash "$AL" "$@" 2>&1); RC=$?; }
rec() { bash "$AL" show "$1" | sed -n "s/^$2=//p"; }


# The cases: one file each in tests/jg-alert.d/, run in name order in this shell. A new case is a new file, so two lanes never meet.
for c in "$(dirname "${BASH_SOURCE[0]}")/jg-alert.d"/*.sh; do
  # shellcheck source=/dev/null
  . "$c"
done
