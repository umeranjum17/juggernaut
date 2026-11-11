#!/usr/bin/env bash
# jg-report-page.sh - build a Recon's board page and card from its sources, or check that nobody edited them.
#
# Usage:
#   jg-report-page.sh build <task-id>   write board-report/page.html and board-report/report.json
#   jg-report-page.sh check <task-id>   exit 1 and name each file that was edited by hand or is stale
#
# Sources in data/<task-id>/: page.json (key, title, drawings, counts), report.md (its Answer and
# Implementation plan sections), ledger.tsv (one `key<TAB>value<TAB>source` line per count), and the
# machine tables read through bin/jg-machine.sh. core/report-page/README.md owns the details.
# The Recon gate (bin/jg-recon-gate.sh) runs `check`. Exit 0 ok, 1 a refusal, 2 a usage error.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec python3 -I -B "$root/core/report-page/report-page.py" "$@"
