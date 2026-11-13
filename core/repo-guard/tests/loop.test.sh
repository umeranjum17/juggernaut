#!/usr/bin/env bash
# Fixture proof that the installed gh shim cannot call itself. The real gh here is a wrapper that runs "gh" by name, as mise's does, and the PATH puts the shim folder first, as a tick's does.
# Before the fix that call looped for ever; now it returns at once through the real caller (the installed shim), in a throwaway HOME.
# Usage: repo-guard/tests/loop.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'chmod -R u+w -- "$d"; rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/data TMPDIR=$d
mkdir -p "$HOME/.local/bin" "$d/pkg" "$d/other"
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
# The package's gh: a wrapper that finds "gh" through PATH, like mise x gh -- gh.
printf '#!/usr/bin/env bash\nexec gh "$@"\n' >"$d/pkg/gh"
printf '#!/usr/bin/env bash\necho "real gh $*"\n' >"$d/other/gh"
chmod +x "$d/pkg/gh" "$d/other/gh"
ln -s "$d/pkg/gh" "$HOME/.local/bin/gh"
PATH=$HOME/.local/bin:$PATH "$SRC/wiring.sh" >/dev/null
# The caller's PATH holds the shim folder first and no other gh (the host may have one), so only the fixture's gh exists.
mkdir -p "$d/tools"
for t in bash env dirname timeout cmp mktemp chmod cp mv rm grep cat; do ln -s "$(command -v "$t")" "$d/tools/$t"; done
export PATH=$HOME/.local/bin:$d/tools
call() { OUT=$(timeout 8 gh --version 2>&1) && RC=0 || RC=$?; }

# 1. No other gh on PATH: the second entry refuses at once; it does not loop (timeout would give 124).
call
check "a gh that calls itself refuses at once" "$RC" 1
check "the refusal names the cause" "$(printf '%s' "$OUT" | grep -c 'called itself')" 1

# 2. A real gh further down PATH: the second entry runs it by its full path and the call returns.
PATH=$PATH:$d/other call
check "a second entry runs the next gh on PATH" "$RC/$OUT" "0/real gh --version"

[ "$fails" = 0 ]
