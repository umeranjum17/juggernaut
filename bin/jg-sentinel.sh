#!/usr/bin/env bash
# jg-sentinel.sh - forwarder to the one sentinel, core/sentinel/bin/jg-sentinel.sh.
#
# The sentinel has one copy: the core one, which core/sentinel/wiring.sh installs
# on the host. This forwarder keeps the bin/ name that bin/jg-inbox.sh,
# bin/jg-session-start.sh, bin/jg-unit-claim.sh and the bootstrap install advice
# run, and execs the core copy with JG_BIN set to this checkout's bin/, so it runs
# this checkout's scripts and libraries and `unit` names this forwarder. The core
# copy's header owns usage, state files and knobs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../core/sentinel/bin/jg-sentinel.sh"
if [ ! -f "$TARGET" ]; then
  echo "jg-sentinel: the sentinel is missing at $TARGET" >&2
  exit 1
fi
JG_BIN="$SCRIPT_DIR" exec bash "$TARGET" "$@"
