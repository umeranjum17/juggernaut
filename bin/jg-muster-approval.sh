#!/usr/bin/env bash
# jg-muster-approval.sh - the captain's approval of a muster pack, bound to the exact revision he saw.
#
# Usage:
#   jg-muster-approval.sh manifest <ticket> <project-dir> --depth <complete|full|light> [--change <slug> --before <dir>]
#   jg-muster-approval.sh ask <ticket> <project-name> <manifest-sha12>
#   jg-muster-approval.sh exception-ask <ticket> <project-name>
#   jg-muster-approval.sh verify <ticket> <project-dir>
#   jg-muster-approval.sh exception <ticket>
#   jg-muster-approval.sh verify-plan <ticket> <plan.json>
#
# `manifest` runs the pack gate (bin/jg-muster-gate.sh; JG_MUSTER_GATE overrides it for a test) and saves the pack
# byte for byte; `ask` and `exception-ask` hold the captain's plain-words question; `verify` and `exception` say
# whether his yes is on file; `verify-plan` checks requirements and the plan against the approved manifest.
# Blitz calls `verify-plan` with `--slice-directions` for the verified plan hash and selected directions by slice. Exit 0
# approved, 1 refused (one line), 2 usage. The method and the manifest format live in core/muster/approval.py and
# .agents/skills/muster/formats.md sections 3 to 5. The signed approved-by-captain line is still written only by
# bin/jg-captain-hold.sh answer.
set -u
ROOT="${JG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
command -v python3 >/dev/null 2>&1 || { echo "jg-muster-approval: python3 is required" >&2; exit 1; }
exec python3 -I "$ROOT/core/muster/approval.py" "$@"
