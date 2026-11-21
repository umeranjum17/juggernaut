#!/usr/bin/env bash
# muster.sh - report-only observer of the muster machine (core/machines/tables/muster.tsv): the word of one ticket's muster.
#
# Usage: muster.sh <ticket>   print triage, intent, lexicon, rules, terrain, sand-table, charter, objectives, check, approval,
#                             war-room, blitz, landed or secured; none for a ticket with no data/<ticket>/muster folder
# The state is read, never stored, from four places (report jg-6si 6.10):
#   the home      data/<ticket>/muster/: rounds.tsv, approvals.tsv, manifest-<sha12>.tsv, and `project` (one line: the project's
#                 folder, or its name under projects/; else the project= line of state/<ticket>.meta)
#   the project   its documents, and .done-done/runs/*.json, the done-done run records (the receipts): one names a journey, an
#                 exit, whether the tree was dirty and the commit it ran on
#   the release   bin/jg-live-claim.sh, the one owner of "Released" and "In use" (it reads data/releases)
#   the approval  bin/jg-muster-approval.sh verify <ticket> <project-dir> (exit 0 = his yes holds on the exact checked pack);
#                 the command can be replaced with JG_MUSTER_APPROVAL_VERIFY. Where it does not exist an approval cannot be
#                 read, so a checked pack stays in check or approval.
# Before the manifest the state is the latest stage whose output exists (a spec Objectives table, then docs/charter.md,
# docs/design/visual-direction.md, docs/domain/model.md or a record in docs/adr, docs/ways-of-working.md, GLOSSARY.md,
# docs/vision.md, rounds.tsv). The council leaves no record in the frozen formats, so it is never observed here.
# After approval: war-room until a manifest journey has a receipt (exit 0, clean tree) on the project's current commit; blitz
# while some do not; landed when all do and no release names the commit; secured when a release (or a home that runs it) names
# the commit and `bin/jg-muster-objectives.sh code` passes. This file holds none of the rules: the owners above do.
set -u
export LC_ALL=C
id=${1:?usage: muster.sh <ticket>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}; export JG_HOME
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}; STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
D=$DATA/$id/muster
[ -d "$D" ] || { echo none; exit 0; }

P=$(head -n 1 "$D/project" 2>/dev/null)
[ -n "$P" ] || P=$(sed -n 's/^project=//p' "$STATE/$id.meta" 2>/dev/null | tail -n 1)
case $P in '') ;; /*) ;; *) P=$JG_HOME/projects/$P ;; esac
[ -n "$P" ] && [ -d "$P" ] || { [ -f "$D/rounds.tsv" ] && echo intent || echo triage; exit 0; }

# --- the checked pack: the manifest the newest approve row names, else the newest manifest
manifest=
sha=$(awk -F'\t' '$2 == "approve" { s = $3 } END { print s }' "$D/approvals.tsv" 2>/dev/null)
[ -n "$sha" ] && [ -f "$D/manifest-$sha.tsv" ] && manifest=$D/manifest-$sha.tsv
# shellcheck disable=SC2012
[ -n "$manifest" ] || manifest=$(ls -t "$D"/manifest-*.tsv 2>/dev/null | head -n 1)

if [ -z "$manifest" ] || ! grep -q '^check ' "$manifest" 2>/dev/null; then
  has() { compgen -G "$P/$1" >/dev/null; }
  if grep -Eqs '^\|[^|]*\|[[:space:]]*(new|preserve)[[:space:]]*\|' "$P"/docs/specs/*.md 2>/dev/null; then echo objectives
  elif has docs/charter.md; then echo charter
  elif has docs/design/visual-direction.md; then echo sand-table
  elif has docs/domain/model.md || has 'docs/adr/[0-9]*.md'; then echo terrain
  elif has docs/ways-of-working.md; then echo rules
  elif has GLOSSARY.md; then echo lexicon
  elif has docs/vision.md || [ -f "$D/rounds.tsv" ]; then echo intent
  else echo triage; fi
  exit 0
fi

# --- a checked pack: asked, approved, built, landed, released
approved() {
  local v=${JG_MUSTER_APPROVAL_VERIFY:-}
  if [ -n "$v" ]; then bash -c "$v \"\$1\"" _ "$id" >/dev/null 2>&1; return; fi
  [ -x "$root/bin/jg-muster-approval.sh" ] && "$root/bin/jg-muster-approval.sh" verify "$id" "$P" >/dev/null 2>&1
}
if ! approved; then
  [ -n "$sha" ] && [ "$manifest" = "$D/manifest-$sha.tsv" ] && echo approval || echo check
  exit 0
fi

C=$(git -C "$P" rev-parse HEAD 2>/dev/null)
want=$(awk '$1 == "journey" { print $2 }' "$manifest" | sort -u)
have=
if [ -n "$C" ] && command -v jq >/dev/null 2>&1 && compgen -G "$P/.done-done/runs/*.json" >/dev/null; then
  have=$(jq -r --arg c "$C" 'select(.commit == $c and .exit == 0 and .dirty == false and (.journey | type == "string")) | .journey' "$P"/.done-done/runs/*.json 2>/dev/null | sort -u)
fi
[ -n "$want" ] || { echo war-room; exit 0; }   # a manifest with no journey proves nothing
missing=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))
if [ -n "$missing" ]; then
  [ -n "$(comm -12 <(printf '%s\n' "$want") <(printf '%s\n' "$have"))" ] && echo blitz || echo war-room
  exit 0
fi

# every objective is proven on this commit: is it released, and is the model's behaviour in the code?
claim=$root/bin/jg-live-claim.sh
released=0
for c in "fixed $C" "fixed; live: $C @ $(basename "$P")"; do
  out=$("$claim" 'done' "$c" 2>/dev/null)
  case $out in *"Released, "*|*"In use, "*) released=1; break ;; esac
done
if [ "$released" = 1 ] && "$root/bin/jg-muster-objectives.sh" code "$P" >/dev/null 2>&1; then echo secured; else echo landed; fi
