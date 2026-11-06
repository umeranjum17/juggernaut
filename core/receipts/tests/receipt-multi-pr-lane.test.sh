#!/usr/bin/env bash
# E2E: one lane holding several ready pull requests lands each one with the receipt for its own head. The real
# bin/jg-pr-check.sh runs under JG_PR_CHECK_MERGE=1 (as bin/jg-pr-merge.sh calls it) against real commits in real
# repositories; only the forge read is stubbed. The lane's checkout sits at the LAST pull request's head, so the
# gate must bind the receipt to the head of the pull request being recorded, not the checkout's HEAD.
# Accepted: a PASS receipt at PR n's head that names PR n, for each n, whichever pull request the record carried.
# Refused: a receipt at another PR's head, a receipt naming another PR, and a FAIL receipt.
# Usage: core/receipts/tests/receipt-multi-pr-lane.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/multipr.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$HOME" "$d/home-jg/state" "$d/home-jg/config" "$d/home-jg/data" "$d/fakebin" "$d/guardroot/bin" "$d/project"
git init -q --bare "$d/origin.git"
git clone -q "$d/origin.git" "$d/wt" 2>/dev/null
g() { git -c user.email=t@example.com -c user.name=t -C "$d/wt" "$@"; }
g checkout -q -b main && g commit -q --allow-empty -m base && g push -q origin main 2>/dev/null
for n in 1 2 3; do
  g checkout -q -b "pr$n" main && g commit -q --allow-empty -m "pr$n" && g push -q origin "pr$n" 2>/dev/null
  head[n]=$(g rev-parse HEAD)
done
[ "$(g rev-parse HEAD)" = "${head[3]}" ] || fail "fixture: the checkout is not at the last pull request"
repo=https://github.com/o/r/pull
state=$d/home-jg/state
meta=$state/lane.meta
cat > "$d/fakebin/gh" <<GH
#!/usr/bin/env bash
case "\$*" in
  *"--json isDraft"*) echo '{"isDraft":false}' ;;
  *headRefOid*) case "\$*" in *pull/1\ *) echo ${head[1]} ;; *pull/2\ *) echo ${head[2]} ;; *pull/3\ *) echo ${head[3]} ;; esac ;;
esac
exit 0
GH
printf '#!/usr/bin/env bash\nexit 0\n' > "$d/guardroot/bin/jg-guard.sh"
chmod +x "$d/fakebin/gh" "$d/guardroot/bin/jg-guard.sh"
write_meta() {  # <recorded pr or empty>
  printf 'window=fm:t\nendpoint_task_id=lane\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\nspawn_gen=1\nreceipt_required=1\n' "$d/wt" "$d/project" > "$meta"
  [ -z "$1" ] || printf 'pr=%s\n' "$1" >> "$meta"
}
receipt() {  # <head> <pr> <verdict>
  printf '{"schema":1,"task":"lane","mode":"direct-PR","spawn_gen":"1","head":"%s","pr":"%s","verdict":"%s","evidence":"ran","at":1}\n' "$1" "$2" "$3" > "$state/lane.run-receipt.json"
}
arm() {  # <pr number>: the merge path's own recording call
  JG_PR_CHECK_MERGE=1 JG_ROOT_OVERRIDE=$d/guardroot JG_HOME=$d/home-jg JG_STATE_OVERRIDE=$state JG_CONFIG_OVERRIDE=$d/home-jg/config \
    PATH=$d/fakebin:$PATH "$ROOT/bin/jg-pr-check.sh" lane "$repo/$1" 2>&1
}
for n in 1 2 3; do
  # The record carries the last pull request armed (3), as after the lane reported them in order.
  write_meta "$repo/3"; receipt "${head[$n]}" "$repo/$n" PASS
  out=$(arm "$n") || fail "PR $n with its own receipt refused: $out"
  grep -qx "pr=$repo/$n" "$meta" || fail "PR $n was not recorded"
  grep -qx "pr_head=${head[$n]}" "$meta" || fail "PR $n recorded the wrong head"
done
write_meta ""; receipt "${head[2]}" "$repo/1" PASS
out=$(arm 1) && fail "PR 1 accepted with a receipt at PR 2's head"
case $out in *"completion receipt refused"*) ;; *) fail "wrong refusal for another PR's head: $out" ;; esac
write_meta ""; receipt "${head[1]}" "$repo/2" PASS
out=$(arm 1) && fail "PR 1 accepted with a receipt naming PR 2"
case $out in *"completion receipt refused"*) ;; *) fail "wrong refusal for a receipt naming another PR: $out" ;; esac
write_meta ""; receipt "${head[1]}" "$repo/1" FAIL
out=$(arm 1) && fail "PR 1 accepted with a FAIL receipt"
case $out in *"completion receipt refused"*) ;; *) fail "wrong refusal for a FAIL receipt: $out" ;; esac
echo "ok: one lane lands pull requests 1, 2 and 3 each with the receipt for its own head; another PR's head, another PR's name and a FAIL receipt are refused"
