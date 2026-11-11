#!/usr/bin/env bash
# bypass.sh - report-only observer of the bypass machine (core/machines/tables/bypass.tsv): standing or ended, per bypass id.
#
# Usage: bypass.sh <bypass-id>   print the state; print nothing when config/proof-bypass has no such bypass
# A standing bypass past its end time reads ended before the tick writes it. It only reads.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
bash "$here/../../../bin/jg-proof-bypass.sh" state "${1:?usage: bypass.sh <bypass-id>}" 2>/dev/null || true
