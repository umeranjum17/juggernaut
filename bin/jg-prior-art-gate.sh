#!/usr/bin/env bash
# The prior-art gate: one shell check on a brief, never a model call.
#
# Usage: jg-prior-art-gate.sh <brief>
#
# New or complex work starts from what already exists (AGENTS.md section 7), and
# bin/jg-brief.sh scaffolds every ship brief with a `# Prior art` section for the
# worker to fill before reporting done:
#
#   Prior art pick: <the product, project or library adopted>
#   Licence: <its licence and whether it can be used here>
#   Options: <the three to five real options compared, and the trade-off>
#
# or, when the change is neither new nor complex:
#
#   Prior art: none needed - <why>
#
# This gate refuses a brief whose section is missing, still holds the scaffold's
# `<...>` placeholder, or names a pick without its licence decision, and accepts
# either recorded form above. It prints one line and exits 0 on success, and one
# refusal line and exits 1 otherwise. `.agents/skills/prior-art/SKILL.md` owns the
# procedure the worker follows to fill the section.
set -u
die() { echo "jg-prior-art-gate: $*" >&2; exit 1; }

brief=${1:-}
[ "$#" -eq 1 ] || die "usage: jg-prior-art-gate.sh <brief>"
[ -f "$brief" ] || die "no brief at $brief"

section=$(awk '/^# Prior art$/{ found = 1; next } found && /^# /{ exit } found' "$brief")
[ -n "$section" ] || die "refused: $brief has no '# Prior art' section"

pick=$(printf '%s\n' "$section" | sed -n 's/^Prior art pick:[[:space:]]*//p' | head -1)
licence=$(printf '%s\n' "$section" | sed -n 's/^Licence:[[:space:]]*//p' | head -1)
none=$(printf '%s\n' "$section" | sed -n 's/^Prior art: none needed[[:space:]]*-[[:space:]]*//p' | head -1)

# A value that still carries the scaffold's <...> placeholder records nothing.
recorded() { [ -n "$1" ] && ! printf '%s' "$1" | grep -q '<[^>]*>'; }

if recorded "$pick"; then
  recorded "$licence" || die "refused: $brief records the pick '$pick' with no 'Licence: ...' line saying whether it can be used here"
  echo "prior art recorded: $pick (licence: $licence)"
  exit 0
fi
if recorded "$none"; then
  echo "prior art recorded: none needed - $none"
  exit 0
fi
die "refused: $brief records no prior art; fill its '# Prior art' section with a 'Prior art pick: ...' and 'Licence: ...' pair, or with 'Prior art: none needed - <why>'"
