#!/usr/bin/env bash
# plan-gate watcher check: closes the gates whose condition now holds (a row of another home closed, a tool
# version installed), in this home and, in Main's home, in every local Squad Lead home. It writes a line only for
# a gate it closed, so a quiet beat wakes no one.
# Usage: check.sh <jg-home>
set -u
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: check.sh <jg-home>" >&2; exit 2; }
HOME_DIR=$(cd "$1" && pwd -P)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JG_HOME="$HOME_DIR" exec "$HERE/../../bin/jg-plan-gate.sh" close
