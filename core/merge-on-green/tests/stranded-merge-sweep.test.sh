#!/usr/bin/env bash
# End-to-end: drive stranded-merge-sweep.sh against a fixture home whose clone has a github origin, with a gh-axi
# stub that answers the forge reads from files. Covers: ahead 0 silent, a stranded closed release silent before 48 h
# and alerting once after, no repeat until the count changes, a carried branch counted but never alarmed, the
# newest release never read, a forge failure silent and retried, the hourly throttle, the report listing, and the
# alarm running from merge-on-green.sh check.
# Usage: merge-on-green/tests/stranded-merge-sweep.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/projects/r" "$FM/config"
printf -- '- r [direct-PR +yolo] - fixture project (ex/r) (added 2026-11-03)\n' > "$FM/data/projects.md"
git -C "$FM/projects/r" init -q
git -C "$FM/projects/r" remote add origin https://github.com/ex/r.git
export STUB=$d/stub STUB_FAIL=$d/fail
mkdir -p "$STUB"
printf 'main\n' > "$STUB/default"
printf 'release/c-9\nrelease/c-10\nrelease/c-16\nfeature/x\n' > "$STUB/branches"
printf '0\n' > "$STUB/ahead-release__c-9"
printf '6\n' > "$STUB/ahead-release__c-10"
printf '99\n' > "$STUB/ahead-release__c-16"
cat > "$d/gh-axi" <<'STUB'
#!/usr/bin/env bash
[ ! -e "$STUB_FAIL" ] || { echo "error: forge unreachable" >&2; exit 1; }
[ "$1" = api ] && [ "$3" = --jq ] || exit 2
echo "$2" >> "$STUB/asked"
case $2 in
  repos/ex/r) cat "$STUB/default" ;;
  repos/ex/r/branches*) cat "$STUB/branches" ;;
  repos/ex/r/compare/main...*) b=${2#repos/ex/r/compare/main...}; cat "$STUB/ahead-${b//\//__}" ;;
  *) echo "error: unrecorded request $2" >&2; exit 1 ;;
esac
STUB
chmod +x "$d/gh-axi"
export JG_STRANDED_GH=$d/gh-axi
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
sweep() { JG_CHECK_TIMEOUT=30 "$SRC/stranded-merge-sweep.sh" check "$FM" 2>&1; }
M=$FM/data/jg-merge-on-green/stranded-sweep
stamps() { find "$M" -maxdepth 1 -name "$1" 2>/dev/null | wc -l | tr -d ' '; } # count files matching a name glob

check "the first sweep stamps the stranded branch and says nothing" "$(sweep)" ""
check "the newest release is never read" "$(grep -c 'release/c-16' "$STUB/asked" || true)" 0
check "a branch ahead by 0 is never stamped" "$(stamps '*c-9')" 0
check "the stranded branch is stamped" "$(stamps '*c-10')" 1

rm -f "$M/.last" "$STUB/asked"
check "inside 48 h the sweep stays silent" "$(sweep)" ""
now=$(date +%s)
printf '%s \n' "$(( now - 49 * 3600 ))" > "$M/ex__r.release__c-10"
rm -f "$M/.last"
out=$(sweep)
check "after 48 h one alert names the branch and the ahead count" "$(printf '%s\n' "$out" | sed 's/ (first seen.*//')" "stranded-merge-sweep: ex/r: release/c-10 is ahead of main by 6 commits and has been for 48 h or more"
rm -f "$M/.last"
check "the alert is not repeated at the same count" "$(sweep)" ""
printf '7\n' > "$STUB/ahead-release__c-10"; rm -f "$M/.last"
check "a new count alerts again" "$(sweep | grep -c 'ahead of main by 7 commits')" 1

rm -f "$M/.last" "$STUB/asked"
check "the throttle skips the forge inside the hour" "$( (sweep; sweep) >/dev/null; grep -c . "$STUB/asked")" "$(grep -c . "$STUB/asked")"
n=$(grep -c . "$STUB/asked"); sweep >/dev/null
check "a second sweep inside the hour asks nothing" "$(grep -c . "$STUB/asked")" "$n"

printf 'release/c-10\n' > "$FM/config/version-branch-carried"; rm -f "$M/.last"
check "a carried branch is never alarmed" "$(sweep)" ""
check "a carried branch forgets its stamp" "$(stamps '*c-10')" 0
check "report lists the carried count" "$("$SRC/stranded-merge-sweep.sh" report "$FM")" "$(printf 'ex/r release/c-9 ahead 0 of main (closed)\nex/r release/c-10 ahead 7 of main (carried)')"
rm "$FM/config/version-branch-carried"

touch "$STUB_FAIL"; rm -f "$M/.last"
check "a forge failure is silent" "$(sweep)" ""
check "a failed sweep does not start the hour" "$(stamps '.last')" 0
rm "$STUB_FAIL"

rm -rf "$M"; sweep >/dev/null
printf '%s \n' "$(( now - 49 * 3600 ))" > "$M/ex__r.release__c-10"
rm -f "$M/.last"
out=$(JG_CHECK_TIMEOUT=30 JG_STALE_PR_GH=$d/none "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "merge-on-green check carries the sweep" "$(printf '%s\n' "$out" | grep -c '^stranded-merge-sweep: ')" 1

if [ "$fails" -eq 0 ]; then echo "PASS stranded-merge-sweep"; else echo "$fails failed"; exit 1; fi
