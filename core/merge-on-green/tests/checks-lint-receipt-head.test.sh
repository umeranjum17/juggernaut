#!/usr/bin/env bash
# The evidence lint publishes its receipt only for the head it judged. A lane member pushed from another copy
# leaves the task's recorded worktree on a different head; stamping the verdict there would overwrite the slot
# that head's own receipt holds. Fake gh, real lint, real publisher; no network.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LINT=$ROOT/merge-on-green/jg-checks-lint.sh
# shellcheck source=lib/policy-test-env.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/policy-test-env.sh"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home XDG_DATA_HOME=$d/xdg TMPDIR=$d PATH="$d/bin:$PATH" JG_HOME=$d/fm JG_CORE_DIR=$ROOT
mkdir -p "$HOME" "$XDG_DATA_HOME" "$d/bin" "$d/fm/bin" "$d/fm/state" "$d/fm/data/lane-h" "$d/wt"
fails=0
bad() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
ok() { printf 'ok - %s\n' "$1"; }
cp -a "$ROOT/../bin" "$ROOT/../core" "$ROOT/../policy" "$d/fm/"
git -C "$d/wt" init -q .
git -C "$d/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
wt_head=$(git -C "$d/wt" rev-parse HEAD)
other=$(printf '%040d' 7)
printf 'frame\n' >"$d/fm/data/lane-h/shot.png"
printf 'mode=direct-PR\nspawn_gen=1\nworktree=%s\npr=https://github.com/owner/repo/pull/9\nbranch=fm/lane-h\n' "$d/wt" >"$d/fm/state/lane-h.meta"
# The fake forge reports the head named in $PR_HEAD.
cat >"$d/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view'*)
    printf '%s\n' "{\"author\":{\"login\":\"umer\"},\"body\":\"## Checks\\noutcome: the lane proves the screen\\nrepro: n/a: no bug\\nproof: no verify skill - bash fixture\\nevidence: shot.png\\n\",\"title\":\"feat: x\",\"files\":[{\"path\":\"a.txt\",\"additions\":1}],\"headRefOid\":\"$PR_HEAD\",\"headRefName\":\"fm/lane-h\",\"baseRefOid\":\"base\"}" ;;
  *) echo "unexpected gh: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$d/bin/gh"
slot=$d/fm/state/lane-h.run-receipt.json

# 1. The PR head is not the worktree's head: the lint verdict stands, but no receipt is stamped on the wrong head.
set +e
out=$(PR_HEAD=$other "$LINT" 'https://github.com/owner/repo/pull/9' "$d/fm/data/lane-h" 2>&1)
set -e
if [ -e "$slot" ]; then bad "a head the worktree is not on must not publish a receipt: $(jq -r .head "$slot")"; else ok 'no receipt is published for a head the worktree is not on'; fi
case $out in
  *'receipt not published: the lint judged '*"$other"*) ok 'the skip names the judged head' ;;
  *) bad "the skip must be named: $out" ;;
esac

# 2. The PR head is the worktree's head: the receipt is published bound to it.
rm -f "$d/fm/data/checks-gate.hashes"
set +e
out=$(PR_HEAD=$wt_head "$LINT" 'https://github.com/owner/repo/pull/9' "$d/fm/data/lane-h" 2>&1)
set -e
if [ -e "$slot" ] && [ "$(jq -r .head "$slot")" = "$wt_head" ]; then ok 'the receipt binds the head the lint judged'; else bad "the receipt must bind $wt_head: $out"; fi

[ "$fails" -eq 0 ]
