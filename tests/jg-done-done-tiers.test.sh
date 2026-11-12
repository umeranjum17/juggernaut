#!/usr/bin/env bash
# Every journey entry of .done-done.yaml names a tier (ci or local), and the
# contract set of tier ci is the 17 keep scripts, each a real test file with a
# measured time. Reads the shipped config, the file done-done itself reads.
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

notier="$(printf '%s\n' "$rows" | awk -F'\t' '$2!="ci" && $2!="local"{print $1}')"
if [ -z "$notier" ]; then ok "0 entries with no tier"; else bad "entries with no valid tier: $notier"; fi

ci="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="ci"')"
n="$(printf '%s\n' "$ci" | grep -c .)"
if [ "$n" = 17 ]; then ok "17 entries in tier ci"; else bad "tier ci has $n entries, want 17"; fi

while IFS=$'\t' read -r name _ cmd m; do
  [ -n "$name" ] || continue
  f="$(printf '%s' "$cmd" | sed -n 's/^bash \(tests\/[^ ]*\.test\.sh\).*/\1/p')"
  if [ -n "$f" ] && [ -f "$ROOT/$f" ]; then :; else bad "$name: command names no existing tests/ script"; fi
  case "$m" in [0-9]*" s") ;; *) bad "$name: no measured time" ;; esac
done <<<"$ci"
[ "$fail" = 0 ] && ok "each ci entry runs a real test file and records its time"

# done-done still reads the config with every entry.
cnt="$(cd "$ROOT" && done-done 2>/dev/null | sed -n 's/^journeys\[\([0-9]*\)\].*/\1/p')"
if command -v done-done >/dev/null 2>&1; then
  if [ "$cnt" = "$total" ]; then ok "done-done reads all $total entries"; else bad "done-done reads '$cnt' entries, file has $total"; fi
fi
exit "$fail"
