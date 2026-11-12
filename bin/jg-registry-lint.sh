#!/usr/bin/env bash
# jg-registry-lint.sh - keeps a change to its own block of a registry file (slice H0 of the self-healing plan).
#
# Usage: jg-registry-lint.sh [--base <ref>] [<file>...]
#   A registry file is a path that .gitattributes marks `merge=union`: git merges it by taking both sides' added lines, so two lanes that
#   each add an entry never conflict. That is only safe while a lane adds its own entries and leaves the others alone. This lint compares
#   each file with <ref> (default HEAD~1, the commit under a one-commit lane) and refuses when an entry that was there is gone or changed.
#   An entry is one journey block in a .yaml file (a key at column 0 or 2 and the lines under it) and one line in any other file.
#   Without <file> arguments every registry file is checked. Blank lines are not entries. Exit 0 clean, 1 refused, 2 bad use.
set -u

base=HEAD~1; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || { echo "jg-registry-lint: --base needs a ref" >&2; exit 2; }; base=$2; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) echo "jg-registry-lint: unknown option $1" >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done
top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "jg-registry-lint: not inside a git work tree" >&2; exit 2; }
cd "$top" || exit 2
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "jg-registry-lint: no such ref $base" >&2; exit 2; }

if [ ${#files[@]} -eq 0 ]; then
  [ -f .gitattributes ] || { echo "jg-registry-lint: no .gitattributes, so no registry files"; exit 0; }
  while IFS= read -r f; do files+=("$f"); done < <(awk '$0 !~ /^[[:space:]]*#/ { for (i = 2; i <= NF; i++) if ($i == "merge=union") print $1 }' .gitattributes)
fi

# entries <yaml|line>: stdin to one entry per output line (newlines inside an entry become \001), blank lines dropped.
entries() {
  awk -v mode="$1" '
    function flush() { if (cur != "") print cur; cur = "" }
    /^[[:space:]]*$/ { next }
    mode == "yaml" && ($0 ~ /^[A-Za-z0-9_.-]+:/ || $0 ~ /^  [A-Za-z0-9_.-]+:/) { flush(); cur = $0; next }
    mode == "yaml" { cur = (cur == "") ? $0 : cur "\001" $0; next }
    { print }
    END { flush() }'
}

rc=0
for f in "${files[@]}"; do
  mode=line; case "$f" in *.yaml|*.yml) mode=yaml ;; esac
  old=$(git show "$base:$f" 2>/dev/null) || continue   # new file: nothing existed to damage
  [ -f "$f" ] || { echo "REFUSED $f: the file is gone; it existed at $base"; rc=1; continue; }
  gone=$(LC_ALL=C comm -23 <(printf '%s\n' "$old" | entries "$mode" | LC_ALL=C sort) <(entries "$mode" < "$f" | LC_ALL=C sort))
  [ -z "$gone" ] && continue
  rc=1
  echo "REFUSED $f: $(printf '%s\n' "$gone" | wc -l | tr -d ' ') entry(ies) of $base were changed or removed; add your own block and leave the others alone:"
  printf '%s\n' "$gone" | cut -c1-120 | tr '\001' '|' | sed 's/^/  - /'
done
[ $rc -eq 0 ] && echo "registry lint: clean (${#files[@]} file(s) against $base)"
exit $rc
