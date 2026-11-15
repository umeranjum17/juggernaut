#!/usr/bin/env bash
# switch-decl.sh - does a commit that adds a thing which ships behind a switch declare it?
#
# Usage: switch-decl.sh check <repo> <base> <commit>
#
# A commit is flagged when it adds one of these, whatever else it does:
#   (a) core/<x>/wiring.sh - the report also says when bin/jg-host-wiring.sh does not list <x> in its plan, because a fragment
#       outside the plan never runs;
#   (b) a key with an empty default to jg_trunk_policy in bin/jg-trunk-policy-lib.sh (`<key>) val='' ;;`): a switch that is off;
#   (c) a row to toolchain.versions;
#   (d) a file under core/machines/tables/.
# A flagged commit is declared when its message has a `Change: <id>` trailer and core/machines/changes.tsv at that commit has a
# row for each id (core/machines/README.md "changes.tsv"). Output, one line per finding, tab separated: `flag<TAB><what>` for each
# addition, then `missing<TAB><why>` when the declaration is not whole. Exit 0 when nothing is flagged or the declaration is whole
# (nothing printed), 1 when a flagged commit is not declared, 2 on a usage error. The landing check (bin/jg-trunk.sh) asks it
# under the `switch-decl` policy key: report (the default) says so and lands, refuse stops the landing, off does not ask.
set -u

die() { echo "switch-decl: $*" >&2; exit 2; }
[ "${1:-}" = check ] && [ $# -eq 4 ] || die "usage: switch-decl.sh check <repo> <base> <commit>"
repo=$2 base=$3 commit=$4
g() { git -C "$repo" "$@"; }
g rev-parse --verify --quiet "$base^{commit}" >/dev/null && g rev-parse --verify --quiet "$commit^{commit}" >/dev/null \
  || die "$base or $commit is not a commit of $repo"

flags=()
added=$(g diff --name-only --diff-filter=A "$base" "$commit")

# (a) a wiring fragment, and whether the plan runs it
while IFS= read -r p; do
  [[ $p =~ ^core/([^/]+)/wiring\.sh$ ]] || continue
  x=${BASH_REMATCH[1]}
  if g show "$commit:bin/jg-host-wiring.sh" 2>/dev/null | grep -Eq "^[[:space:]]+$x:[a-z-]+[[:space:]]*$"; then
    flags+=("adds $p")
  else
    flags+=("adds $p, and the plan array of bin/jg-host-wiring.sh does not list $x, so the fragment never runs")
  fi
done <<< "$added"

# (b) an empty-default key, (c) a toolchain row: lines the commit adds to the file
added_lines() { g diff -U0 "$base" "$commit" -- "$1" | sed -n 's/^+\([^+].*\)$/\1/p; s/^+$//p'; }
while IFS= read -r l; do
  [[ $l =~ ^[[:space:]]+([a-z0-9-]+)\)[[:space:]]+val=(\'\'|\"\")?[[:space:]]*\;\; ]] || continue
  flags+=("adds the policy key ${BASH_REMATCH[1]} with an empty default to jg_trunk_policy")
done < <(added_lines bin/jg-trunk-policy-lib.sh)
while IFS= read -r l; do
  [ -n "${l//[[:space:]]/}" ] && [[ $l != \#* ]] || continue
  flags+=("adds the toolchain.versions row ${l%%[[:space:]]*}")
done < <(added_lines toolchain.versions)

# (d) a machine table
while IFS= read -r p; do
  case $p in core/machines/tables/*) flags+=("adds the machine table $p") ;; esac
done <<< "$added"

[ "${#flags[@]}" -gt 0 ] || exit 0

ids=$(g log -1 --format=%B "$commit" | git interpret-trailers --parse | sed -n 's/^Change:[[:space:]]*//p')
missing=()
if [ -z "$ids" ]; then
  missing+=("the commit has no Change: trailer; add one with 'git commit --amend --trailer \"Change: <id>\"' and a row for <id> in core/machines/changes.tsv")
else
  rows=$(g show "$commit:core/machines/changes.tsv" 2>/dev/null | grep -v '^#')
  while IFS= read -r id; do
    printf '%s\n' "$rows" | cut -f1 | grep -Fxq -- "$id" || missing+=("Change: $id has no row in core/machines/changes.tsv at this commit")
  done <<< "$ids"
fi
[ "${#missing[@]}" -gt 0 ] || exit 0
for f in "${flags[@]}"; do printf 'flag\t%s\n' "$f"; done
for m in "${missing[@]}"; do printf 'missing\t%s\n' "$m"; done
exit 1
