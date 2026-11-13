#!/usr/bin/env bash
# done-done journey: the brief of a local lane. The real jg-brief.sh scaffolds a local-trunk ship brief on a project registered
# local-trunk whose trunk branch is recorded, and the brief must name that branch, demand exactly one commit carrying the ticket
# reference, forbid push, pull request, going live and release, keep the landing and conflict rules, and carry the done line and
# the sealed-proof rule. A project that is not registered local gets no lane section, and a lane with a publishing mode is refused.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
home=$(mktemp -d) rc=0
mkdir -p "$home/data" "$home/config" "$home/state"
printf -- '- trunk-proj [local-trunk] - fixture (added 2026-11-09)\n- pr-proj [no-mistakes] - fixture (added 2026-11-09)\n' > "$home/data/projects.md"
printf 'trunk-v9\n' > "$home/state/trunk-branch-trunk-proj"
brief() { JG_HOME="$home" "$root/bin/jg-brief.sh" "$@" >/dev/null 2>&1; }
want() {  # <label> <file> <fixed text>
  if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: missing: $3"; rc=1; fi
}
{
  brief lane trunk-proj --mode local-trunk || { echo "FAIL scaffold lane"; rc=1; }
  b="$home/data/lane/brief.md"
  want "section heading" "$b" "# Local trunk lane"
  want "names the recorded trunk branch" "$b" "the \`trunk-v9\` branch of the project"
  want "exactly one commit" "$b" "exactly ONE commit on top of the local trunk tip"
  want "commit carries the ticket reference" "$b" "the commit message must carry its ticket reference"
  want "no feature pull request" "$b" "there is no feature pull request"
  want "landing check rebases, not the lane" "$b" "you never rebase for it"
  want "conflicts are the lane's own" "$b" "YOU resolve every conflict in your own change"
  want "never forced" "$b" "never force a landing"
  want "stale change refused" "$b" "is never landed dirty"
  want "never push, go live or release" "$b" "you never land, push, go live or release"
  want "done line" "$b" "ready in branch fm/lane (local-trunk)"
  want "sealed proof at the exact head" "$b" "a sealed done-done run holding them"
  want "nothing after the seal" "$b" "nothing may be committed after the seal"
  want "ship branch" "$b" "Ship branch: fm/lane"
  n=$(grep -c '^# Local trunk lane' "$b")
  [ "$n" = 1 ] && echo "ok   one lane section" || { echo "FAIL lane sections=$n"; rc=1; }
  # A project not registered local gets no lane section.
  brief pr pr-proj --mode direct-PR || { echo "FAIL scaffold pr"; rc=1; }
  if grep -q 'Local trunk lane' "$home/data/pr/brief.md"; then echo "FAIL direct-PR brief carries the lane section"; rc=1; else echo "ok   direct-PR brief has no lane section"; fi
  # A local lane on a project not registered local gets no lane section either.
  brief lo pr-proj --mode local-only || { echo "FAIL scaffold lo"; rc=1; }
  if grep -q 'Local trunk lane' "$home/data/lo/brief.md"; then echo "FAIL local mode on a non-local project carries the lane section"; rc=1; else echo "ok   non-local project gets no lane section"; fi
  # An unknown mode is refused.
  if brief bad trunk-proj --mode bogus; then echo "FAIL bogus mode accepted"; rc=1; else echo "ok   bogus mode refused"; fi
} > "$out" 2>&1
rm -rf -- "$home"
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped jg-brief.sh and a synthetic home with a local-trunk project on trunk-v9",
 "steps": ["scaffold a local-trunk brief", "check it names the trunk branch, one commit, the landing and conflict rules, the done line and the sealed proof", "scaffold briefs of a project not registered local and require no lane section", "ask for an unknown mode and require a refusal"],
 "result": "the lane brief carries every rule of a local lane and no other brief carries the lane section"}
JSON
exit "$rc"
