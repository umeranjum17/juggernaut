#!/usr/bin/env bash
# The second third of tests/jg-public-followup.test.sh. Each case builds a home with a real Beads store, so the
# suite is split across three CI shards; this script runs the part the first one leaves out.
set -u
JG_PUBLIC_FOLLOWUP_PART=2 exec bash "$(dirname "${BASH_SOURCE[0]}")/jg-public-followup.test.sh"
