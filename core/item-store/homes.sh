#!/usr/bin/env bash
# The homes a release reaches, one `<home id>\t<home path>` line each: `main` and the main home, then each local Squad Lead row of
# `data/squad_leads.md` (the same set as `squad_lead_local_homes` in bin/jg-release-readiness.sh). adapters/trunk.py opens one
# update item per line when a release of the homes' own repository merges.
# Usage: homes.sh <main home>
. "$(cd "$(dirname "$0")/../.." && pwd)/bin/jg-squad-lead-registry-lib.sh"
printf 'main\t%s\n' "$1"
[ -f "$1/data/squad_leads.md" ] || exit 0
while IFS= read -r l; do case $l in '- '*)
  squad_lead_registry_parse_line "$l" && [ "$SQUAD_LEAD_REGISTRY_REMOTE" != 1 ] &&
    printf '%s\t%s\n' "$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOME"
esac; done < "$1/data/squad_leads.md"
exit 0
