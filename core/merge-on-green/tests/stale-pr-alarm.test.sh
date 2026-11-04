#!/usr/bin/env bash
# End-to-end: drive stale-pr-alarm.sh against a fixture home whose clone has a github origin, with a gh-axi
# stub that answers from recorded PR fixtures in tests/fixtures/stale-pr-alarm/. Covers both reasons, a healthy
# PR that stays silent, no repeat alert on the second poll, a fresh alert after a PR heals and stalls again,
# an outside author's PR silent unless a task meta records it, a forge failure staying silent, and the alarm running from merge-on-green.sh check.
# Usage: merge-on-green/tests/stale-pr-alarm.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
FIX=$SRC/tests/fixtures/stale-pr-alarm
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d
FM=$d/fm
mkdir -p "$HOME" "$FM/state" "$FM/data" "$FM/projects/r"
printf -- '- r [direct-PR +yolo] - fixture project (ex/r) (added 2026-11-03)\n' > "$FM/data/projects.md"
git -C "$FM/projects/r" init -q
git -C "$FM/projects/r" remote add origin https://github.com/ex/r.git
export STUB_FIX=$d/fix STUB_FAIL=$d/fail
mkdir -p "$STUB_FIX"
sed -e "s/@STALE@/$(date -u -d '-30 hours' +%Y-%m-%dT%H:%M:%SZ)/" -e "s/@FRESH@/$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)/" \
  "$FIX/pulls-open.json" > "$STUB_FIX/pulls-open.json"
echo '{"login": "me"}' > "$STUB_FIX/user.json"
cp "$FIX"/check-runs-*.json "$FIX"/status-none.json "$FIX"/pulls-closed-*.json "$STUB_FIX/"
cat > "$d/gh-axi" <<'STUB'
#!/usr/bin/env bash
# gh-axi api <path> --jq <expr>, answered from the recorded fixtures
[ ! -e "$STUB_FAIL" ] || { echo "error: forge unreachable" >&2; exit 1; }
[ "$1" = api ] && [ "$3" = --jq ] || exit 2
case $2 in
  user) f=user ;;
  repos/ex/r/pulls\?state=open*) f=pulls-open ;;
  repos/ex/r/pulls\?state=closed\&base=main\&head=ex:release/c-5*) f=pulls-closed-merged ;;
  repos/ex/r/pulls\?state=closed*) f=pulls-closed-none ;;
  repos/ex/r/commits/sha102/check-runs|repos/ex/r/commits/sha104/check-runs) f=check-runs-some ;;
  repos/ex/r/commits/*/check-runs) f=check-runs-none ;;
  repos/ex/r/commits/*/status) f=status-none ;;
  *) echo "error: unrecorded request $2" >&2; exit 1 ;;
esac
jq -r "$4" "$STUB_FIX/$f.json"
STUB
chmod +x "$d/gh-axi"
export JG_STALE_PR_GH=$d/gh-axi
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
alarm() { JG_CHECK_TIMEOUT=30 "$SRC/stale-pr-alarm.sh" check "$FM" 2>&1; }
U=https://github.com/ex/r/pull

out=$(alarm)
check "first poll raises exactly two alerts" "$(printf '%s\n' "$out" | wc -l)" 2
check "no checks and no update for 24 h" "$(printf '%s\n' "$out" | grep "$U/101:")" "stale-pr-alarm: $U/101: no checks and no update for 24 h"
check "base is a release branch already merged" "$(printf '%s\n' "$out" | grep "$U/102:")" "stale-pr-alarm: $U/102: base branch release/c-5 is a release branch already merged into main"
check "fresh PR without checks stays silent" "$(printf '%s\n' "$out" | grep -c "$U/103" || true)" 0
check "stale PR with checks stays silent" "$(printf '%s\n' "$out" | grep -c "$U/104" || true)" 0
check "unmerged release base stays silent" "$(printf '%s\n' "$out" | grep -c "$U/105" || true)" 0
check "an outside author's stale PR raises no alarm" "$(printf '%s\n' "$out" | grep -c "$U/10[67]" || true)" 0
check "second poll repeats nothing" "$(alarm)" ""

# A PR by an outside author alerts once a task meta records its URL as pr=.
printf 'pr=%s/107\n' "$U" > "$FM/state/t.meta"
check "an outside PR recorded as a task pr= alerts" "$(alarm)" "stale-pr-alarm: $U/107: no checks and no update for 24 h"
rm "$FM/state/t.meta"; alarm >/dev/null

# 101 gets a head with checks and heals, then returns to a head without: the forgotten alert fires again.
sed -i 's#sha101#sha104#' "$STUB_FIX/pulls-open.json"
check "healed PR is silent" "$(alarm)" ""
sed -i 's#sha104", "ref": "lane-101#sha101", "ref": "lane-101#' "$STUB_FIX/pulls-open.json"
check "a PR that stalls again alerts again" "$(alarm)" "stale-pr-alarm: $U/101: no checks and no update for 24 h"

touch "$STUB_FAIL"
check "a forge failure is silent" "$(alarm)" ""
rm "$STUB_FAIL"
check "after the failure nothing repeats" "$(alarm)" ""

# merge-on-green.sh check runs the alarm too: a fresh memory makes both PRs alert through the one watcher check.
rm -rf "$FM/data/jg-merge-on-green/stale-pr-alarm"
out=$(JG_CHECK_TIMEOUT=30 "$SRC/merge-on-green.sh" check "$FM" 2>&1)
check "merge-on-green check carries the alarm" "$(printf '%s\n' "$out" | grep -c '^stale-pr-alarm: ')" 2

if [ "$fails" -eq 0 ]; then echo "PASS stale-pr-alarm"; else echo "$fails failed"; exit 1; fi
