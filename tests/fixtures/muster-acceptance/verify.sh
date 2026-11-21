#!/usr/bin/env bash
# Pass the project directory the status observer's default invocation omits. The verifier itself is real.
set -euo pipefail
exec "$ROOT/bin/jg-muster-approval.sh" verify "$1" "$JG_PROJECTS_OVERRIDE/helpdesk"
