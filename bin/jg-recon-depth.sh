#!/usr/bin/env bash
# Pick the depth of a Recon from the words of the ask: one no-model shell check.
#
# Usage: jg-recon-depth.sh <ask text>
#        jg-recon-depth.sh -            (read the ask from standard input)
#
# Prints one word, `quick`, `standard` or `deep`, and exits 0. It exits 2 on a
# usage error. `.agents/skills/task-dispatch/SKILL.md` owns how intake uses the
# answer: it passes the word to `bin/jg-brief.sh --scout --depth`, and the
# captain can name a level himself, which always wins over this guess.
#
#   explicit   an ask that names `quick`, `standard` or `deep` as a Recon level
#              ("a deep recon", "depth: quick") gets that level
#   deep       "in depth", "discovery", "deep", "research properly", "detailed
#              report", or a plan with slices
#   quick      one fact: "what is", "which version", "does X exist", with no
#              deep word and no more than one short sentence
#   standard   everything else - the default
#
# The method behind each level is `.agents/skills/deep-recon/SKILL.md`; the
# check that a finished Recon met its level is `bin/jg-recon-gate.sh`.
set -u
die() { echo "jg-recon-depth: $*" >&2; exit 2; }

[ "$#" -ge 1 ] || die "usage: jg-recon-depth.sh <ask text> | -"
if [ "$1" = "-" ]; then ask=$(cat); else ask="$*"; fi
[ -n "$ask" ] || die "the ask is empty"
text=$(printf '%s' "$ask" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')

# The captain names the level: "deep recon", "recon depth deep", "depth: quick".
level=$(printf '%s' "$text" \
  | sed -n -E 's/.*(^|[^a-z])(quick|standard|deep)[ -]+(recon|research|dive|look)([^a-z]|$).*/\2/p;
               s/.*depth[ :=]+(quick|standard|deep)([^a-z]|$).*/\1/p' | head -1)
if [ -n "$level" ]; then echo "$level"; exit 0; fi

if printf '%s' "$text" | grep -q -E \
  'in[ -]depth|discovery|(^|[^a-z])deep([^a-z]|$)|research (this )?properly|properly research|detailed (report|plan|write-?up)|implementation plan|(plan|design) .*slices|slices'; then
  echo deep; exit 0
fi

# One fact: a single short question with a lookup verb and nothing to compare.
words=$(printf '%s' "$text" | wc -w)
if [ "$words" -le 14 ] && printf '%s' "$text" | grep -q -E \
  '^(quick(ly)?[ ,:-]+)?(what|which|where|when|who|does|is|is there|how many)( |$)|(just|only) (check|confirm|tell me)|one fact'; then
  if ! printf '%s' "$text" | grep -q -E 'compare|options|alternatives|design|plan|audit|why'; then
    echo quick; exit 0
  fi
fi

echo standard
