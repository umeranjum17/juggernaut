#!/usr/bin/env bash
# The loss-claim check: one shell pass over a plan or report, never a model call.
#
# Usage: jg-loss-claim-check.sh <report.md>...
#
# A plan or report never says a capability is lost without naming how to get it
# back (captain, 5 Nov: "we can build our own pi extensions and copy good
# extensions from the community"). This check reads each file in blocks and
# flags a block that asserts a loss with no replacement path or no effort.
#
# Block: a run of lines ended by a blank line, a heading, a table row, or the
# next top-level list item. Indented lines belong to the block above them.
#
# Loss line: a line containing one of "we lose", "loses", "lost", "no longer
# available", "drop", "drops", "dropped" (any case). "nothing lost", "not lost"
# and "never lost" are not loss claims.
#
# A loss block passes only when the SAME block also holds both:
#   path:   a named way to replace it - a community or npm package, extension
#           or plugin; "copy"; "port"; "build our own" / "build ourselves"; or
#           "our own extension|package|plugin"; or the words "replacement path".
#   effort: an estimate such as "2 days", "~4h", "1-2 weeks", "30 min", or
#           "effort: S|M|L|small|medium|large".
#
# Exit 0 and one line when every file passes. Exit 1 and one line per flagged
# loss line (file:line: what is missing) otherwise. Exit 2 on a usage error.
set -u

[ "$#" -ge 1 ] || { echo "usage: jg-loss-claim-check.sh <report.md>..." >&2; exit 2; }
for f in "$@"; do
  [ -f "$f" ] || { echo "jg-loss-claim-check: no file at $f" >&2; exit 2; }
done

bad=0 losses=0
for f in "$@"; do
  out=$(awk -v file="$f" '
    function flush(   i, miss) {
      if (nloss > 0) {
        miss = ""
        if (!haspath) miss = "a replacement path (copy a package, port it, or build our own)"
        if (!haseffort) miss = miss (miss == "" ? "" : " and ") "an effort estimate"
        for (i = 1; i <= nloss; i++) {
          total++
          if (miss != "") print file ":" lossline[i] ": loss claim without " miss ": " losstext[i]
        }
      }
      nloss = 0; haspath = 0; haseffort = 0
    }
    function lossy(s) {
      if (s ~ /(nothing|not|never)[ ]+(is |was |be )?lost/) return 0
      return s ~ /(^|[^a-z])(we lose|loses|lost|no longer available|drops?|dropped)([^a-z]|$)/
    }
    function pathy(s) {
      return s ~ /(community|npm|upstream|open-source)[ -]+(package|extension|plugin|library)/ \
        || s ~ /(^|[^a-z])(copy|copying|port|porting|ported)([^a-z]|$)/ \
        || s ~ /build[ ]+(it[ ]+)?(our own|ourselves)/ \
        || s ~ /our own[ ]+(pi[ ]+)?(extension|package|plugin)/ \
        || s ~ /replacement path/
    }
    function effortly(s) {
      return s ~ /[0-9]+([.][0-9]+)?([-–][0-9]+)?[ ]*(minutes?|mins?|hours?|hrs?|days?|weeks?|h|d|w)([^a-z]|$)/ \
        || s ~ /effort:?[ ]*(xs|s|m|l|xl|small|medium|large)([^a-z]|$)/
    }
    {
      line = $0; low = tolower(line)
      if (line ~ /^[ \t]*$/ || line ~ /^#+ / ) { flush(); next }
      if (line ~ /^[ \t]*\|/ || line ~ /^([-*+]|[0-9]+[.)])[ ]/) flush()
      if (lossy(low)) { nloss++; lossline[nloss] = NR; t = line; sub(/^[ \t]+/, "", t); losstext[nloss] = t }
      if (pathy(low)) haspath = 1
      if (effortly(low)) haseffort = 1
    }
    END { flush(); print "TOTAL " total + 0 }
  ' "$f")
  n=$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p')
  losses=$((losses + n))
  flagged=$(printf '%s\n' "$out" | grep -v '^TOTAL ' || true)
  if [ -n "$flagged" ]; then
    printf '%s\n' "$flagged"
    bad=1
  fi
done

if [ "$bad" -ne 0 ]; then
  echo "jg-loss-claim-check: refused: name a replacement path and an effort in the same block as each loss claim" >&2
  exit 1
fi
echo "loss claims ok: $losses loss line(s), each with a replacement path and an effort"
