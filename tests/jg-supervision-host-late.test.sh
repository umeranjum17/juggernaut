#!/usr/bin/env bash
# Run one case group from the shared supervision-host suite.
JG_SUPERVISION_HOST_PART=late exec bash "$(dirname "$0")/jg-supervision-host.test.sh"
