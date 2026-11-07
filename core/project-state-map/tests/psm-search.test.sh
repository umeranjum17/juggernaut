#!/usr/bin/env bash
# Host test table for psm-search.sh over the fixture project (known states and parts).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
search=$here/../bin/psm-search.sh
fixture=$here/fixture-project
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail=0
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $2 want $3"; fail=1; fi
}
list() { jq -r '.hits[] | "\(.file):\(.line):\(.passes | join("+"))"' "$1" | paste -sd' '; }

KNOWN='.github/workflows/ci.yml:2:p4 .github/workflows/ci.yml:4:p4 .github/workflows/ci.yml:6:p4 app/board.js:1:p1+p2 app/board.js:2:p1+p2 app/board.js:3:p3 lib/contract.js:2:p1 lib/contract.js:3:p1 server.js:1:p4 server.js:3:p4 server.js:4:p4'

# A plain directory: the known hit list, nothing from the file with no state in it.
bash "$search" "$fixture" > "$d/plain.json"
want 'fixture gives the known hit list' "$(list "$d/plain.json")" "$KNOWN"
want 'schema and file count' "$(jq -r '"\(.schema) \(.files) \(.truncated)"' "$d/plain.json")" 'psm.hits.v1 5 0'

# A git repo gives the same hits, and its tree is the git tree. Files that must be skipped are added.
cp -R "$fixture" "$d/repo"
git -C "$d/repo" init -q && git -C "$d/repo" add -A && git -C "$d/repo" -c user.name=t -c user.email=t@t commit -qm fixture
printf 'SECRET_TOKEN=x\nstate: "open" | "closed"\n' > "$d/repo/.env"
mkdir -p "$d/repo/node_modules/dep" && printf "export const S = oneOf('x', 'y')\n" > "$d/repo/node_modules/dep/index.js"
printf "stage: oneOf('a')\n" > "$d/repo/app/skip.min.js"
git -C "$d/repo" add -A -f
before=$(cd "$d/repo" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
bash "$search" "$d/repo" > "$d/repo.json"
after=$(cd "$d/repo" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
want 'git repo gives the same hits, secrets and dependencies skipped' "$(list "$d/repo.json")" "$KNOWN"
want 'git tree is the tree of HEAD' "$(jq -r .tree "$d/repo.json")" "$(git -C "$d/repo" rev-parse 'HEAD^{tree}')"
want 'the project is never changed' "$before" "$after"

# The hit hash follows hit text only.
printf '\n// a comment with nothing to find\n' >> "$d/repo/app/note.js"
bash "$search" "$d/repo" | jq -r .hit_hash > "$d/h2"
want 'a non-hit edit keeps the hit hash' "$(cat "$d/h2")" "$(jq -r .hit_hash "$d/repo.json")"
sed -i "s/'done'/'finished'/" "$d/repo/app/board.js"
bash "$search" "$d/repo" | jq -r .hit_hash > "$d/h3"
if [ "$(cat "$d/h3")" != "$(jq -r .hit_hash "$d/repo.json")" ]; then echo 'PASS an edited hit line changes the hit hash'; else echo 'FAIL edited hit line kept the hit hash'; fail=1; fi

# Caps: the total cap drops later hits and counts them; the per-file cap bounds one noisy file.
bash "$search" "$fixture" --max-hits 4 | jq -r '"\(.hits | length) \(.truncated)"' > "$d/cap"
want 'total cap keeps 4 and counts 7 dropped' "$(cat "$d/cap")" '4 7'
bash "$search" "$fixture" --max-per-file 1 --out "$d/one.json"
want 'per-file cap keeps one hit per file and pass' "$(jq '[.hits[] | select(.file == "server.js")] | length' "$d/one.json")" '1'

# Bad input says what is wrong.
want 'missing directory refused' "$(bash "$search" "$d/none" 2>&1 >/dev/null || true)" "psm-search: not a directory: $d/none"
want 'unknown argument refused' "$(bash "$search" "$fixture" --bogus 2>&1 >/dev/null || true)" 'psm-search: unknown argument --bogus'
exit "$fail"
