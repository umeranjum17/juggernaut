#!/usr/bin/env bash
# A draft lint of a local report file must leave done-done's evidence-hash registry as it found it, so the PR's own
# lint is not told its files were "already used by another PR". Real pinned lint; skipped where it is unavailable.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
GATE=$ROOT/merge-on-green/checks-lint.sh
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
DD=${JG_DONE_DONE_BIN:-done-done}
if ! command -v "$DD" >/dev/null 2>&1 || ! "$DD" lint --help 2>/dev/null | grep -q 'checks.generated_paths:'; then
  echo 'ok - skipped: the pinned done-done lint is not installed here'
  exit 0
fi
export HOME=$d/home TMPDIR=$d JG_HOME=$d/fm JG_DONE_DONE_BIN=$DD
mkdir -p "$HOME" "$d/fm/data/lane-c/evidence" "$d/fm/state"
fails=0
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }
printf 'frame\n' >"$d/fm/data/lane-c/evidence/shot.png"
printf '## Checks\noutcome: the lane proves the screen\nrepro: n/a: no bug\nproof: no verify skill - bash fixture\nevidence: evidence/shot.png\n' >"$d/fm/data/lane-c/report.md"
reg=$d/fm/data/done-done-lint/lint.hashes

# 1. No registry before: the draft leaves none behind.
"$GATE" "$d/fm/data/lane-c/report.md" "$d/fm/data/lane-c" >/dev/null 2>&1 || bad 'the draft must pass'
if [ -e "$reg" ]; then bad 'a draft lint must not create the registry'; else ok 'a draft lint leaves no registry'; fi

# 2. A registry with an earlier lane's row: the draft leaves it byte for byte.
printf '%s other-lane\n' "$(printf '%064d' 1)" >"$reg"
cp "$reg" "$d/before"
"$GATE" "$d/fm/data/lane-c/report.md" "$d/fm/data/lane-c" >/dev/null 2>&1 || bad 'the second draft must pass'
if cmp -s "$reg" "$d/before"; then ok 'a draft lint leaves an existing registry unchanged'; else bad "the registry changed: $(cat "$reg")"; fi
[ "$fails" -eq 0 ]
