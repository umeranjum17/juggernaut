#!/usr/bin/env bash
# alert.sh - report-only observer of the alert machine (core/machines/tables/alert.tsv): the state of one alert key.
#
# Usage: alert.sh <alert>--<subject>   print open, acknowledged, inhibited or resolved; print nothing when the key has no record
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
bash "$here/../../../bin/jg-alert.sh" word "${1:?usage: alert.sh <alert>--<subject>}" 2>/dev/null || true
