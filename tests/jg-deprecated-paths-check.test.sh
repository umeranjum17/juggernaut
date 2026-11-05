#!/usr/bin/env bash
# A change to a deprecated path is refused, a deletion passes, a change to any other path passes, and the
# banner itself does not trip the check. bin/jg-lint.sh carries the refusal on a changed-file run.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
check="$here/bin/jg-deprecated-paths-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-deprecated-paths.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
pass() { printf 'ok - %s\n' "$*"; }
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
g() { git -C "$tmp/r" -c user.email=fixture@example.invalid -c user.name=Fixture "$@"; }

git init -q "$tmp/r"
mkdir -p "$tmp/r/bin" "$tmp/r/defaults" "$tmp/r/old/sub" "$tmp/r/live"
cp "$here/bin/jg-lint.sh" "$here/bin/jg-deprecated-paths-check.sh" "$here/bin/jg-ports-check.sh" "$tmp/r/bin/"
cp "$here/defaults/ports-adapters" "$tmp/r/defaults/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/r/bin/jg-lint-workflows.sh"
chmod +x "$tmp/r/bin/jg-lint-workflows.sh"
mkdir -p "$tmp/r/bin/backends" && printf '#!/usr/bin/env bash\n:\n' >"$tmp/r/bin/backends/stub.sh"
printf '# comment\nold/  the new thing\nlive/gone.sh  another thing\n' >"$tmp/r/defaults/deprecated-paths"
printf '#!/usr/bin/env bash\necho old\n' >"$tmp/r/old/run.sh"
printf '#!/usr/bin/env bash\necho nested\n' >"$tmp/r/old/sub/deep.sh"
printf '#!/usr/bin/env bash\necho gone\n' >"$tmp/r/live/gone.sh"
printf '#!/usr/bin/env bash\necho live\n' >"$tmp/r/live/ok.sh"
printf '# old\n' >"$tmp/r/old/README.md"
g add -A && g commit -q -m base && g branch -q -m main
reset_to_base() { g checkout -q main && g checkout -q -B cand; }
refused() {  # <label> <path>
  if out=$(bash "$check" --root "$tmp/r" --base main 2>&1); then no "$1 was accepted"; fi
  case $out in *"deprecated path: $2 "*"docs/deprecated-paths.md"*) ;; *) no "$1: the refusal did not name $2: $out" ;; esac
}
accepted() { bash "$check" --root "$tmp/r" --base main >"$tmp/out.log" 2>&1 || { cat "$tmp/out.log" >&2; no "$1 was refused"; }; }

reset_to_base
printf 'echo more\n' >>"$tmp/r/old/run.sh"
g commit -qam 'edit a deprecated file'
refused 'an edit under a deprecated directory' old/run.sh
pass 'an edit to a file under a deprecated directory is refused, naming the path and the doc'

reset_to_base
printf 'echo more\n' >>"$tmp/r/live/gone.sh"
g commit -qam 'edit a listed file'
refused 'an edit to a listed file' live/gone.sh
pass 'an edit to a file listed by exact path is refused'

reset_to_base
printf 'echo new\n' >"$tmp/r/old/sub/new.sh"
g add -A && g commit -qm 'add under a deprecated directory'
refused 'a new file under a deprecated directory' old/sub/new.sh
pass 'a new file under a deprecated directory is refused'

reset_to_base
g rm -q -r old live/gone.sh && g commit -qm 'delete the deprecated paths'
accepted 'a deletion'
pass 'deleting every deprecated path passes'

reset_to_base
printf 'echo more\n' >>"$tmp/r/live/ok.sh"
printf 'extra\n' >>"$tmp/r/old/README.md"
g commit -qam 'edit a live file and a deprecated directory doc'
accepted 'a change to a non-deprecated path and a doc edit'
pass 'a change to a non-deprecated file passes, and so does a Markdown edit inside a deprecated directory'

reset_to_base
sed -i '1a # DEPRECATED: replaced by the new thing; see docs/deprecated-paths.md. Do not change this file; delete it or change the replacement.' "$tmp/r/old/run.sh"
g commit -qam 'add the banner'
accepted 'the banner'
pass 'the banner line itself does not trip the check'

reset_to_base
sed -i '1a echo hidden # DEPRECATED: replaced by x' "$tmp/r/old/run.sh"
g commit -qam 'code that mentions the banner word'
refused 'code carrying the banner word' old/run.sh
pass 'a code line that only mentions DEPRECATED: is not a banner'

reset_to_base
printf 'echo more\n' >>"$tmp/r/old/run.sh"
printf '# comment\n' >"$tmp/r/defaults/deprecated-paths"
g commit -qam 'unlist and edit in one change'
refused 'unlisting and editing together' old/run.sh
pass 'the list is read at the base too, so unlisting a path and editing it together is refused'

# bin/jg-lint.sh refuses on a changed-file run, and passes once the change is a deletion.
cd "$tmp/r"
if out=$(bash bin/jg-lint.sh --changed-base main 2>&1); then no 'jg-lint accepted a change to a deprecated path'; fi
case $out in *'deprecated path: old/run.sh '*) ;; *) no "jg-lint did not name the path: $out" ;; esac
pass 'jg-lint.sh --changed-base refuses a change to a deprecated path'
reset_to_base
g rm -q old/run.sh && g commit -qm 'delete one'
bash bin/jg-lint.sh --changed-base main >"$tmp/lint.log" 2>&1 || { cat "$tmp/lint.log" >&2; no 'jg-lint refused a deletion'; }
pass 'jg-lint.sh --changed-base passes a deletion'

# The checked-in list covers real paths, and this checkout passes against itself.
bash "$check" --root "$here" --base HEAD >"$tmp/self.log" 2>&1 || { cat "$tmp/self.log" >&2; no 'the checkout fails against itself'; }
while IFS= read -r p; do
  [ -e "$here/${p%%[[:space:]]*}" ] || no "defaults/deprecated-paths names a missing path: $p"
done < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$here/defaults/deprecated-paths")
pass 'every path in defaults/deprecated-paths exists'
