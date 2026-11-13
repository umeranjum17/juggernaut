#!/usr/bin/env bash
# The four delivery words and the lint that keeps stage-sense "live" out of tracked text.
#
# core/stage-words/words.tsv is the one list. Its `word` rows are the four delivery words (Built, Landed, In use,
# Released); its `sense` rows are the other senses of "live" the lint accepts (a live test, a live pane). Nothing else
# in the repository defines either list.
#
# lint.sh [--strict] [--words] [file...]
#   no file      lints every tracked text file (git ls-files from the repository root)
#   --words      prints the four words and what each means, then exits
#   --strict     exits 1 when a stage-sense "live" is found; without it the lint is report-only and exits 0
# A finding is printed as `<file>:<line>: <text>`, one per use of "live" alone: not followed by an accepted noun, not
# inside a name (`jg-trunk-live`, `live/`, `live.tsv`) and not quoted as code (between backticks).
# Exit 2 when words.tsv does not hold exactly the four words.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TSV="$HERE/words.tsv"
ROOT=$(cd "$HERE/../.." && pwd)
strict=0 files=()
for a in "$@"; do
  case "$a" in
    --strict) strict=1 ;;
    --words) awk -F'\t' '$1 == "word" { printf "%s: %s\n", $2, $3 }' "$TSV"; exit 0 ;;
    -*) echo "lint.sh: unknown option $a" >&2; exit 2 ;;
    *) files+=("$a") ;;
  esac
done

[ "$(awk -F'\t' '$1 == "word"' "$TSV" | wc -l)" -eq 4 ] || { echo "lint.sh: $TSV must hold exactly four word rows" >&2; exit 2; }

if [ "${#files[@]}" -eq 0 ]; then
  # This directory holds the list itself, so it is never linted.
  mapfile -t files < <(git -C "$ROOT" ls-files -- . ':!core/stage-words' | sed "s|^|$ROOT/|")
fi

# shellcheck disable=SC2016
found=$(
  for f in "${files[@]}"; do [ -f "$f" ] && grep -Iq . "$f" 2>/dev/null && printf '%s\n' "$f"; done |
  xargs -r awk -v root="$ROOT/" -v tsv="$TSV" '
    BEGIN {
      FS = "\t"
      while ((getline line < tsv) > 0) { split(line, c, "\t"); if (c[1] == "sense") ok[tolower(c[2])] = 1 }
      FS = " "
    }
    function isname(ch) { return ch ~ /[A-Za-z0-9_-]/ }
    {
      low = tolower($0); pos = 1; rest = low
      while ((i = index(rest, "live")) > 0) {
        at = pos + i - 1; before = at > 1 ? substr(low, at - 1, 1) : " "; after = substr(low, at + 4, 1)
        next_ch = substr(low, at + 4, 2)
        skip = isname(before) || before == "." || before == "/" || isname(after) || after == "/" || next_ch ~ /^\.[A-Za-z0-9]/
        if (!skip) { t = substr($0, 1, at - 1); n = gsub(/`/, "", t); if (n % 2 == 1) skip = 1 }
        if (!skip) { w = substr(low, at + 5); sub(/[^a-z].*/, "", w); if (after == " " && ok["live " w]) skip = 1 }
        if (!skip) { f = FILENAME; sub("^" root, "", f); printf "%s:%d: %s\n", f, FNR, $0; break }
        pos = at + 4; rest = substr(low, pos)
      }
    }'
)
[ -z "$found" ] || printf '%s\n' "$found"
[ "$strict" -eq 0 ] || [ -z "$found" ]
