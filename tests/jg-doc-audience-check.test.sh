#!/usr/bin/env bash
# jg-doc-audience-check.test.sh - the documentation audience check passes on
# the trunk and refuses the drift that broke it.
#
# The trunk grew unclassified prose files, kept inventory entries for deleted
# docs, and kept links to a deleted doc and to headings AGENTS.md no longer
# has, and nothing ran the check, so it stayed red. This suite checks:
#   1. bin/jg-doc-audience-check.sh passes on the real tracked tree.
#   2. In a lab copy of the tracked tree, each drift the check owns is refused
#      by name: a new unclassified prose file, an inventory entry for a file
#      that is gone, a link to a missing file and a link to a missing heading.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-doc-audience-check.sh"

out=$("$CHECK" --root "$ROOT" 2>&1) || fail "audience check on the tracked tree: $out"
pass "the audience check passes on the tracked tree: $out"

jg_git_identity
lab=$(jg_test_tmproot jg-doc-audience)/repo
mkdir -p "$lab"
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$lab" || fail "could not copy the tracked tree"
git -C "$lab" init -q
git -C "$lab" add -A
git -C "$lab" commit -qm base
base=$(git -C "$lab" rev-parse HEAD)

refused() {  # <label> <expected text>: the lab check must fail and name the drift
  local label=$1 want=$2 got
  if got=$("$CHECK" --root "$lab" 2>&1); then fail "$label: the check passed"; fi
  case $got in *"$want"*) pass "$label: refused, naming $want" ;; *) fail "$label: refusal did not name $want: $got" ;; esac
  git -C "$lab" reset -q --hard "$base"
}

printf '# New page\n' > "$lab/docs/lab-new-page.md"
git -C "$lab" add docs/lab-new-page.md
refused "a new prose file with no inventory entry" "unclassified: docs/lab-new-page.md"

git -C "$lab" rm -q docs/item-store.md
refused "an inventory entry for a file that is gone" "not tracked/in scope: docs/item-store.md"

printf '\nSee [gone](lab-missing-target.md).\n' >> "$lab/docs/item-store.md"
refused "a link to a missing file" "unresolved local link in docs/item-store.md"

printf '\nSee [gone](architecture.md#lab-missing-heading).\n' >> "$lab/docs/item-store.md"
refused "a link to a missing heading" "unresolved local anchor in docs/item-store.md"
