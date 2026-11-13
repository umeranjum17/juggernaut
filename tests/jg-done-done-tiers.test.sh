#!/usr/bin/env bash
# Every journey entry of .done-done.yaml names a tier (ci, local or live), and the
# set of tier ci is the 17 contract scripts and the 13 static Core suites steps,
# each a real script with a measured time. The retired Core suites workflow is
# gone, and each of its 89 steps is accounted for: 5 set-up steps named in the
# config header, 84 entries that carry a "was Core suites step N" line.
# Reads the shipped config, the file done-done itself reads.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$ROOT/.done-done.yaml"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# name<TAB>tier<TAB>command<TAB>measured for each journey entry
rows="$(awk '
  /^journeys:/ {inj=1; next}
  /^[^ #]/ {if (inj) flush(); inj=0}
  inj && /^  [A-Za-z0-9_-]+:$/ {flush(); name=$1; sub(/:$/,"",name); tier=""; cmd=""; m=""; next}
  inj && /^    # measured / {m=$3" "$4; next}
  inj && /^    tier: / {tier=$2; next}
  inj && /^    command: / {cmd=$0; sub(/^    command: /,"",cmd); next}
  function flush() {if (name!="") printf "%s\t%s\t%s\t%s\n", name, tier, cmd, m; name=""}
  END {flush()}' "$CFG")"

total="$(printf '%s\n' "$rows" | grep -c .)"
if [ "$total" -gt 0 ]; then ok "read $total entries"; else bad "no entries read"; fi

notier="$(printf '%s\n' "$rows" | awk -F'\t' '$2!="ci" && $2!="local" && $2!="live"{print $1}')"
if [ -z "$notier" ]; then ok "0 entries with no tier"; else bad "entries with no valid tier: $notier"; fi

ci="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="ci"')"
n="$(printf '%s\n' "$ci" | grep -c .)"
if [ "$n" = 30 ]; then ok "30 entries in tier ci"; else bad "tier ci has $n entries, want 30"; fi

while IFS=$'\t' read -r name _ cmd m; do
  [ -n "$name" ] || continue
  f="$(printf '%s' "$cmd" | sed -En 's/^bash ((tests|journeys)\/[^ ]*\.sh).*/\1/p')"
  if [ -n "$f" ] && [ -f "$ROOT/$f" ]; then :; else bad "$name: command names no existing tests/ script"; fi
  case "$m" in [0-9]*" s") ;; *) bad "$name: no measured time" ;; esac
done <<<"$ci"
[ "$fail" = 0 ] && ok "each ci entry runs a real test file and records its time"

# The Core suites workflow is deleted and its 89 steps are all placed.
if [ ! -e "$ROOT/.github/workflows/core-suites.yml" ]; then ok "core-suites workflow is gone"; else bad "core-suites workflow still exists"; fi
steps="$(grep -o '^    # was Core suites step [0-9]*:' "$CFG" | sed 's/[^0-9]//g' | sort -n)"
setup="$(printf '%s\n' 1 2 3 4 49)"
placed="$(printf '%s\n%s\n' "$steps" "$setup" | grep . | sort -n | tr '\n' ' ')"
want="$(seq 1 89 | tr '\n' ' ')"
if [ "$placed" = "$want" ]; then ok "all 89 Core suites steps have an entry or a named set-up"; else bad "Core suites steps placed: $placed"; fi
# Only entries that carry a "was Core suites step" line count, so a journey added later does not move the 71.
nlocal="$(awk '
  /^  [A-Za-z0-9_-]+:$/ {if (placed && tier=="local") n++; placed=0; tier=""; next}
  /^    tier: / {tier=$2; next}
  /^    # was Core suites step [0-9]+:/ {placed=1}
  END {if (placed && tier=="local") n++; print n+0}' "$CFG")"
if [ "$nlocal" = 71 ]; then ok "71 Core suites entries in tier local"; else bad "$nlocal Core suites entries in tier local, want 71"; fi

# done-done still reads the config with every entry.
cnt="$(cd "$ROOT" && done-done 2>/dev/null | sed -n 's/^journeys\[\([0-9]*\)\].*/\1/p')"
if command -v done-done >/dev/null 2>&1; then
  if [ "$cnt" = "$total" ]; then ok "done-done reads all $total entries"; else bad "done-done reads '$cnt' entries, file has $total"; fi
fi
exit "$fail"
