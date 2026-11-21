#!/usr/bin/env bash
# Run one case group from the shared supervision-host suite.
JG_SUPERVISION_HOST_PART=hook bash "$(dirname "$0")/jg-supervision-host.test.sh" || { echo "not ok - supervision-host suite, part hook" >&2; exit 1; }
echo "ok - supervision-host suite, part hook"
