#!/usr/bin/env bash
# recon.sh - report-only observer of the recon machine (core/machines/tables/recon.tsv): the word of one Recon's handoff.
#
# Usage: recon.sh <task-id>   print drafted, critiqued, accepted or none
# This file holds none of the rules: bin/jg-recon-handoff.sh owns them (`phase` reads the one record). The command only reads.
set -u
id=${1:?usage: recon.sh <task-id>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
"$here/../../../bin/jg-recon-handoff.sh" phase "$id" 2>/dev/null || echo none
