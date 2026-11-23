#!/usr/bin/env bash
# jg-muster-drafts.sh - pull the early drafts of every Muster document at any stage, and send documents back for another round.
#
# Usage:
#   jg-muster-drafts.sh drafts <project|ticket> [--out <dir>] [--json]
#   jg-muster-drafts.sh revise <project|ticket> <document|all> --note <words> [--source captain|war-room|recon]
#   jg-muster-drafts.sh checked <project|ticket> <document>
#
# `drafts` keeps a version of each document that changed and shows its status, version, what is open and what changed since the
# last version, as a table, one board page and one folder of files. `revise` sends a document (or all) back with a note: it
# returns to discussion, the next draft round answers the note, and the documents written from it are flagged to re-check.
# `checked` closes one re-check with nothing to change. The method, the status rules and the ledger are owned by
# core/muster/drafts.py. Exit 0 done, 1 refused (one line), 2 usage.
set -u
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "jg-muster-drafts: python3 is required" >&2; exit 1; }
exec python3 -IB "$ROOT/core/muster/drafts.py" "$@"
