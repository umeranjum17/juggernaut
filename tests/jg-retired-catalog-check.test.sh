#!/usr/bin/env bash
# The retired catalog stays retired: a new path under addons/ is refused by name, a tracked one is
# refused outright, and a clean core tree passes. The one deferred slice keeps exactly ten named images
# under the retired directory, and a path outside that list is still refused. The check's own fixture
# journey proves the refusal.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
gate="$here/bin/jg-retired-catalog-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-retired-catalog.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

bash "$gate" --self-test >"$tmp/self.log" 2>&1 || { cat "$tmp/self.log" >&2; no 'the gate self-test failed'; }
pass 'the gate refuses a fixture file placed under addons/ and passes a clean tree'

# The real checkout is clean: the only paths left under the retired directory are the ten deferred images,
# which slice B moves, and the whole-tree scan names neither them nor anything else.
bash "$gate" >"$tmp/tree.log" 2>&1 || { cat "$tmp/tree.log" >&2; no 'this checkout still carries a retired path'; }
pass 'the whole-tree scan passes with only the ten deferred images left'

# An eleventh file arriving beside the deferred images is still refused: the exemption is exact paths, not a directory.
d2="$tmp/deferred"
git init -q "$d2"
mkdir -p "$d2/addons/tickets-sync/icons"
cp "$here/addons/tickets-sync/icons/sign-off.svg" "$d2/addons/tickets-sync/icons/sign-off.svg"
printf '<svg/>\n' >"$d2/addons/tickets-sync/icons/extra.svg"
git -C "$d2" add -A
git -C "$d2" -c user.email=fixture@example.invalid -c user.name=Fixture commit -q -m deferred
if out=$(bash "$gate" --root "$d2" 2>&1); then no 'a file beside the deferred images was accepted'; fi
case $out in *'retired path: addons/tickets-sync/icons/extra.svg'*) ;; *) no "the refusal did not name the extra file: $out" ;; esac
pass 'the deferred list exempts exactly the ten named images, not their directory'

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
