#!/usr/bin/env bash
# hold.sh - report-only observer of the hold machine (core/machines/tables/hold.tsv): the word of one captain hold.
#
# Usage: hold.sh <task-id>   print raised, deferred, answered, closed or none
# This file holds none of the rules: bin/jg-captain-hold.sh owns them (`phase` reads the one record). The command only reads.
set -u
id=${1:?usage: hold.sh <task-id>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
hold="$here/../../../bin/jg-captain-hold.sh"
"$hold" phase "$id" 2>/dev/null || true
