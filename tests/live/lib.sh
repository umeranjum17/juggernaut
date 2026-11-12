#!/usr/bin/env bash
# shellcheck disable=SC2034 # STATE, DATA and CONFIG are read by the checks that source this file.
# Shared base of the live fleet checks (tier `live`, slice H20). Sourced by each check in this folder.
# A live check reads the real home once, runs no agent (model-turn is the one named exception: one short turn), ends inside its own
# bound, and prints exactly one row: `PASS <name>: <detail>` (exit 0) or `RED <name>: <detail>` (exit 1). A red row is the input of
# an alert row (bin/jg-alert.sh), never a failed landing. Home: JG_HOME, state and data may be moved by JG_STATE_OVERRIDE and
# JG_DATA_OVERRIDE. JG_LIVE_NOW is the test seam for the clock.
LIVE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
JG_HOME=${JG_HOME:-$LIVE_ROOT}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
export JG_HOME
LIVE_NAME=${LIVE_NAME:-$(basename "${0%.sh}")}
live_now() { echo "${JG_LIVE_NOW:-$(date +%s)}"; }
live_pass() { printf 'PASS %s: %s\n' "$LIVE_NAME" "$*"; exit 0; }
live_red() { printf 'RED %s: %s\n' "$LIVE_NAME" "$*"; exit 1; }
live_mtime() { stat -c %Y -- "$1" 2>/dev/null || echo 0; }
