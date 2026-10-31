#!/usr/bin/env bash
# The retired catalog stays retired: a new path under addons/ is refused by name, a tracked one is
# refused outright, and a clean core tree passes. The check's own fixture journey proves the refusal.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
gate="$here/bin/jg-retired-catalog-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-retired-catalog.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

bash "$gate" --self-test >"$tmp/self.log" 2>&1 || { cat "$tmp/self.log" >&2; no 'the gate self-test failed'; }
pass 'the gate refuses a fixture file placed under addons/ and passes a clean tree'

# The real checkout is clean: the catalog directory is gone from the whole tracked tree.
bash "$gate" >"$tmp/tree.log" 2>&1 || { cat "$tmp/tree.log" >&2; no 'this checkout still carries a retired path'; }
pass 'no tracked path under addons/ remains in this checkout'

# A pull request that only adds core files passes; one that adds a catalog file is refused with the path named.
d="$tmp/pr"
git init -q "$d"
git -C "$d" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q --allow-empty -m base
git -C "$d" branch -q -m main
git -C "$d" checkout -q -b candidate
mkdir -p "$d/core/fleet-flow" "$d/tests"
printf 'core code\n' >"$d/core/fleet-flow/README.md"
printf 'proof\n' >"$d/tests/core.test.sh"
git -C "$d" add -A
git -C "$d" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q -m 'core only'
bash "$gate" --root "$d" --base main >"$tmp/core.log" 2>&1 || { cat "$tmp/core.log" >&2; no 'a core-only change was refused'; }
pass 'a change that adds only core paths passes'

mkdir -p "$d/addons/kill-guard"
printf '#!/usr/bin/env bash\n' >"$d/addons/kill-guard/install.sh"
git -C "$d" add -A
git -C "$d" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q -m 'bring the catalog back'
if out=$(bash "$gate" --root "$d" --base main 2>&1); then no 'a new file under addons/ was accepted'; fi
case $out in *'retired path: addons/kill-guard/install.sh'*) ;; *) no "the refusal did not name the path: $out" ;; esac
pass 'a new per-feature installer under addons/ is refused by name'
