#!/usr/bin/env bash
# The fork's real completion-receipt journey (tests/jg-pr-merge.test.sh lands a
# task PR and local branch) with acceptance and the
# publisher served from the feature through the step-B hook lines. Absent ->
# the guarded lines are a no-op. JG_TEST_FORK names a read-only Juggernaut checkout.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${JG_TEST_FORK:?set JG_TEST_FORK to a Juggernaut checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR"
git clone --shared "$JG_TEST_FORK" "$d/fork" >/dev/null
# The current fork already has the optional feature source and call-site hooks.
# Keep its scripts intact so the fork's executable journeys cover those hooks.
# shellcheck disable=SC2016 # the shim body expands when the shim runs
printf '#!/usr/bin/env bash\nJG_FORK_BIN="$(dirname "$0")" exec "$JG_ADDONS_DIR/receipts/bin/jg-run-receipt.sh" "$@"\n' > "$d/fork/bin/jg-run-receipt.sh"
chmod +x "$d/fork/bin/jg-run-receipt.sh"
bash -n "$d/fork/bin/jg-dod-lib.sh"

test=jg-pr-merge.test.sh
(cd "$d/fork" && env -u JG_TASK_ID JG_ADDONS_DIR="$addons" bash "tests/$test") > "$d/$test.out" 2>&1 \
  || { echo "FAIL: fork receipt hook journey $test" >&2; tail -20 "$d/$test.out" >&2; exit 1; }

# Helpers the spawn, promote and brief hooks call.
export JG_HOME=$d/home JG_ADDONS_DIR=$addons
mkdir -p "$JG_HOME"
# Source the real fork library so the feature helper runs with its real dependencies.
JG_ADDONS_DIR=$addons
# shellcheck disable=SC1091 # sourced from the private fork clone at runtime
. "$d/fork/bin/jg-dod-lib.sh"
printf 'x\nCompletion receipt: required\n' > "$d/brief"
[ "$(jg_receipts_inherit "$d/brief")" = receipt_required=1 ] || { echo "FAIL: inherit from brief" >&2; exit 1; }
[ -z "$(KIND=scout jg_receipts_inherit "$d/brief")" ] || { echo "FAIL: scout must not require" >&2; exit 1; }
printf 'receipt_required=1\n' > "$d/old.meta"; : > "$d/plain"
[ "$(jg_receipts_inherit "$d/plain" "$d/old.meta")" = receipt_required=1 ] || { echo "FAIL: relaunch inherit" >&2; exit 1; }
printf 'kind=ship\nreceipt_required=0\n' > "$d/tmp.meta"
jg_receipts_promote "$d/old.meta" "$d/tmp.meta"
[ "$(grep -c '^receipt_required=' "$d/tmp.meta")" -eq 1 ] && grep -qx 'receipt_required=1' "$d/tmp.meta" || { echo "FAIL: promote" >&2; exit 1; }
jg_receipts_brief demo-id | grep -q "$addons/receipts/bin/jg-run-receipt.sh demo-id PASS" || { echo "FAIL: brief contract" >&2; exit 1; }

# Done acceptance through the helper: a PASS receipt bound to the worktree head
# accepts; a FAIL receipt for the same head refuses.
w=$d/wt; mkdir "$w"; git -C "$w" init -q; git -C "$w" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c
h=$(git -C "$w" rev-parse HEAD); st=$d/state; mkdir "$st"; printf 'mode=direct-PR\nspawn_gen=1\nreceipt_required=1\n' > "$st/t.meta"
rcpt() { printf '{"schema":1,"task":"t","mode":"direct-PR","spawn_gen":"1","head":"%s","verdict":"%s","evidence":"ran","at":1}\n' "$h" "$1" > "$st/t.run-receipt.json"; }
rcpt PASS
jg_receipts_accept_done "$w" direct-PR "done: x" "$st" t "$st/t.meta" "" >/dev/null || { echo "FAIL: accept_done accept" >&2; exit 1; }
rcpt FAIL
! jg_receipts_accept_done "$w" direct-PR "done: x" "$st" t "$st/t.meta" "" >/dev/null || { echo "FAIL: accept_done refuse" >&2; exit 1; }

# Merge-time binding: once meta records pr=, only a PASS receipt for the exact head
# and that same pull request accepts; missing, FAIL, stale-head, other-PR, unbound
# receipts and a posted evidence card all refuse.
pr1=https://github.com/o/r/pull/1; pr2=https://github.com/o/r/pull/2
printf 'mode=direct-PR\nspawn_gen=1\nreceipt_required=1\npr=%s\n' "$pr1" > "$st/t.meta"
bound() { printf '{"schema":1,"task":"t","mode":"direct-PR","spawn_gen":"1","head":"%s","pr":"%s","verdict":"%s","evidence":"ran","at":1}\n' "$2" "$3" "$1" > "$st/t.run-receipt.json"; }
stale=1111111111111111111111111111111111111111
gate() { jg_dod_receipt_accept "$st" t "$st/t.meta" "$h" >/dev/null; }
bound PASS "$h" "$pr1"; gate || { echo "FAIL: bound receipt accepts" >&2; exit 1; }
bound FAIL "$h" "$pr1"; ! gate || { echo "FAIL: FAIL receipt refuses" >&2; exit 1; }
bound PASS "$stale" "$pr1"; ! gate || { echo "FAIL: stale head refuses" >&2; exit 1; }
bound PASS "$h" "$pr2"; ! gate || { echo "FAIL: other PR refuses" >&2; exit 1; }
bound PASS "$h" ""; ! gate || { echo "FAIL: unbound receipt refuses" >&2; exit 1; }
# A refusal names the exact command that fixes it, including the PR the receipt must name.
msg=$( { bound PASS "$h" ""; jg_dod_receipt_accept "$st" t "$st/t.meta" "$h"; } 2>&1 || true)
case $msg in
  *"JG_RECEIPT_PR=$pr1"*"/receipts/bin/jg-run-receipt.sh t PASS"*) ;;
  *) echo "FAIL: refusal does not name the receipt command: $msg" >&2; exit 1 ;;
esac
rm "$st/t.run-receipt.json"; echo "evidence card: PASS $h $pr1" > "$st/t.evidence-card"
! gate || { echo "FAIL: card without receipt refuses" >&2; exit 1; }
msg=$(jg_dod_receipt_accept "$st" t "$st/t.meta" "$h" 2>&1 || true)
case $msg in
  *"receipt missing for t: publish one with: "*"/receipts/bin/jg-run-receipt.sh t PASS"*) ;;
  *) echo "FAIL: missing-receipt refusal does not name the publisher: $msg" >&2; exit 1 ;;
esac
rm "$st/t.evidence-card"

# Next PR of a lane: when meta pr= is merge-notified (jg-pr-merge's proof) and the
# receipt names a different open PR of the same repo, accept; keep every other
# mismatch refused (other repo, closed, or no merge marker).
umask 077
printf '%s\n' 'jg-pr-poll-merge-notified-v1' 'github' 'github.com' 'o/r' '1' > "$st/t.pr-poll-merge-notified"
chmod 0600 "$st/t.pr-poll-merge-notified"
mkdir -p "$d/fakebin"
# gh api graphql --jq emits the filtered lines; stub prints those for number=2 open.
cat > "$d/fakebin/gh" <<'GH'
#!/usr/bin/env bash
num=
prev=
for a in "$@"; do
  case "$prev" in
    -F) case "$a" in number=*) num=${a#number=} ;; esac ;;
  esac
  case "$a" in number=*) num=${a#number=} ;; esac
  prev=$a
done
case "$num" in
  2) printf 'state=OPEN\nmerged=false\n' ;;
  3) printf 'state=CLOSED\nmerged=false\n' ;;
  *) printf 'state=MERGED\nmerged=true\n' ;;
esac
GH
chmod +x "$d/fakebin/gh"
PATH="$d/fakebin:$PATH"
bound PASS "$h" "$pr2"; gate || { echo "FAIL: next PR of lane after merged meta accepts" >&2; exit 1; }
pr_other=https://github.com/o/other/pull/2
bound PASS "$h" "$pr_other"; ! gate || { echo "FAIL: next PR of other repo refuses" >&2; exit 1; }
pr_closed=https://github.com/o/r/pull/3
bound PASS "$h" "$pr_closed"; ! gate || { echo "FAIL: closed next PR refuses" >&2; exit 1; }
rm -f "$st/t.pr-poll-merge-notified"
bound PASS "$h" "$pr2"; ! gate || { echo "FAIL: next PR without merge marker refuses" >&2; exit 1; }
printf 'mode=direct-PR\nspawn_gen=1\nreceipt_required=1\n' > "$st/t.meta"

# PR candidate hook: the policy through the real fork jg_dod_pr_outside_origin, then the
# real fork bin/jg-pr-check.sh driven with the feature's own library (gate stubbed to log
# the candidate it receives), so the hook output contract is exercised end to end.
sha=0123456789abcdef0123456789abcdef01234567
git -C "$w" remote add origin https://github.com/o/r.git
cand() { jg_receipts_pr_candidate "$w" "$1" direct-PR "$st/t.meta" "$2"; }
[ "$(cand https://github.com/o/other/pull/4 "$sha")" = "$sha" ] || { echo "FAIL: outside-origin PR must print PR_HEAD" >&2; exit 1; }
[ -z "$(cand https://github.com/o/r/pull/4 "$sha")" ] || { echo "FAIL: same-repo PR must print nothing" >&2; exit 1; }
[ -z "$(cand https://github.com/o/other/pull/4 "")" ] || { echo "FAIL: empty PR_HEAD must print nothing" >&2; exit 1; }
cand https://github.com/o/other/pull/4 "$sha" >/dev/null || { echo "FAIL: hook must exit 0" >&2; exit 1; }
hook_run() {  # <name> <pr-url> <want-candidate>
  local hd=$d/hook-$1 got
  mkdir -p "$hd/home/state" "$hd/home/data" "$hd/home/config" "$hd/wt" "$hd/addons/receipts/bin" "$hd/fakebin" "$hd/guardroot/bin"
  git -C "$hd/wt" init -q; git -C "$hd/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$hd/wt" remote add origin https://github.com/o/r.git
  git -C "$hd/wt" update-ref refs/remotes/origin/main "$(git -C "$hd/wt" rev-parse HEAD)"
  printf 'window=fm:t\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\n' "$hd/wt" "$hd/project" > "$hd/home/state/task-a.meta"
  { cat "$addons/receipts/bin/jg-receipts-lib.sh"
    # shellcheck disable=SC2016 # stub body expands when the gate runs
    echo 'jg_receipts_accept_done() { printf "%s" "${7:-}" > "$GATE_LOG"; }'; } > "$hd/addons/receipts/bin/jg-receipts-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hd/guardroot/bin/jg-guard.sh"
  printf '#!/usr/bin/env bash\ncase " $* " in *" --json isDraft "*) echo "{\\"isDraft\\":false}" ;; *headRefOid*) echo %s ;; esac\n' "$sha" > "$hd/fakebin/gh"
  chmod +x "$hd/guardroot/bin/jg-guard.sh" "$hd/fakebin/gh"
  JG_ROOT_OVERRIDE=$hd/guardroot JG_HOME=$hd/home JG_STATE_OVERRIDE=$hd/home/state JG_ADDONS_DIR=$hd/addons GATE_LOG=$hd/gate PATH=$hd/fakebin:$PATH \
    "$d/fork/bin/jg-pr-check.sh" task-a "$2" >"$hd/out" 2>"$hd/err" \
    || { echo "FAIL: jg-pr-check with feature hook ($1): $(cat "$hd/err")" >&2; exit 1; }
  got=$(cat "$hd/gate")
  [ "$got" = "$3" ] || { echo "FAIL: gate candidate ($1): want [$3] got [$got]" >&2; exit 1; }
}
hook_run outside https://github.com/o/other/pull/4 "$sha"
hook_run same-repo https://github.com/o/r/pull/4 ""

# Absent: source the real fork library with no feature and prove it defines no hooks.
( set -e; JG_ADDONS_DIR=$d/none JG_HOME=$d/absent-home
  unset -f jg_receipts_brief jg_receipts_inherit jg_receipts_promote jg_receipts_accept_done jg_dod_receipt_accept
  # shellcheck disable=SC1091 # sourced from the private fork clone at runtime
  . "$d/fork/bin/jg-dod-lib.sh"
  for fn in jg_receipts_brief jg_receipts_inherit jg_receipts_promote jg_receipts_accept_done jg_dod_receipt_accept; do
    if declare -F "$fn" >/dev/null; then exit 1; fi
  done ) \
  || { echo "FAIL: absent feature must be a no-op" >&2; exit 1; }
echo "ok: done-acceptance, local-delivery and both PR-merge suites pass with feature loaded; next PR of a lane after a merge-notified meta accepts when that PR is open in the same repo; the PR candidate hook prints PR_HEAD only outside the origin through the real jg-pr-check.sh; absent feature loads no hooks"
