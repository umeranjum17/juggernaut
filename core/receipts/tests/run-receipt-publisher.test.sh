#!/usr/bin/env bash
# E2E: the completion-receipt publisher, run the way a worker runs it.
# The pull request a receipt records must not depend on how the caller passed
# JG_RECEIPT_PR (exported, or a one-shot command prefix), it must be read from
# the forge when the caller names none, and a value that was meant to name a
# pull request and went missing must be refused instead of recorded empty.
# Usage: core/receipts/tests/run-receipt-publisher.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
TOOL=$ROOT/core/receipts/bin/jg-run-receipt.sh
d=$(mktemp -d "${TMPDIR:-/tmp}/run-receipt.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
is() { [ "$2" = "$3" ] || fail "$1: want [$3], got [$2]"; }

H=$d/home
mkdir -p "$H/state" "$d/cand" "$d/bin"
printf 'id=t1\nmode=direct-PR\nspawn_gen=s1\nreceipt_required=1\n' > "$H/state/t1.meta"
printf 'id=t2\nmode=local-only\nspawn_gen=s2\n' > "$H/state/t2.meta"
printf 'id=t3\nmode=direct-PR\nspawn_gen=s3\npr=https://github.com/o/r/pull/13\n' > "$H/state/t3.meta"
printf 'id=t4\nmode=direct-PR\nspawn_gen=s4\nbranch=fm/lane-x\n' > "$H/state/t4.meta"
printf 'commands run, results and limitations\n' > "$d/evidence.txt"
git -C "$d/cand" init -q .
git -C "$d/cand" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m candidate
export JG_HOME=$H JG_FORK_BIN=$ROOT/bin JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data
unset JG_RECEIPT_PR
pr_field() { jq -r '.pr' "$H/state/$1.run-receipt.json"; }
# publish <task> [env assignment]...: the real publisher over this fixture, run in a command prefix as a worker does.
publish() {
  local task=$1 out rc; shift
  out=$(env -u JG_RECEIPT_PR "$@" JG_HOME="$H" JG_FORK_BIN="$ROOT/bin" \
    JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    "$TOOL" "$task" PASS "$d/evidence.txt" "$d/cand" 2>&1)
  rc=$?
  PUBLISH_OUT=$out
  return "$rc"
}

# The exported variable still records the pull request.
export JG_RECEIPT_PR=https://github.com/o/r/pull/11
"$TOOL" t1 PASS "$d/evidence.txt" "$d/cand" >/dev/null \
  || fail 'exported JG_RECEIPT_PR: the publisher refused'
is 'exported JG_RECEIPT_PR is recorded' "$(pr_field t1)" "$JG_RECEIPT_PR"
unset JG_RECEIPT_PR
rm -f "$H/state/t1.run-receipt.json"

# A one-shot command prefix reaches the publisher exactly as an export does,
# including a value that carried surrounding whitespace.
publish t1 JG_RECEIPT_PR=' https://github.com/o/r/pull/12 ' || fail "command-prefix JG_RECEIPT_PR: the publisher refused ($PUBLISH_OUT)"
is 'command-prefix JG_RECEIPT_PR is recorded' "$(pr_field t1)" 'https://github.com/o/r/pull/12'
rm -f "$H/state/t1.run-receipt.json"

# A prefix whose pull request went missing is refused, names the requirement,
# and publishes nothing rather than an empty pr the merge gate cannot accept.
publish t1 JG_RECEIPT_PR= && fail 'empty pull request: the publisher published a PASS receipt anyway'
case $PUBLISH_OUT in
  *JG_RECEIPT_PR*) ;;
  *) fail "empty pull request: the refusal does not name the missing JG_RECEIPT_PR ($PUBLISH_OUT)" ;;
esac
[ ! -e "$H/state/t1.run-receipt.json" ] || fail 'empty pull request: an empty receipt was published'

# Nothing passed: the task record's own pull request is read and recorded.
publish t3 || fail "recorded pull request: the publisher refused ($PUBLISH_OUT)"
is 'the recorded pull request is read' "$(pr_field t3)" 'https://github.com/o/r/pull/13'

# Nothing passed and no recorded pull request: a detached candidate cannot answer
# `gh pr view`, so the task's recorded branch is asked for its open pull request.
cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Forge stand-in: `pr view` cannot resolve a branch here, `pr list --head` can.
case " $* " in
  *' pr list '*)
    case " $* " in *' --head fm/lane-x '*) echo https://github.com/o/r/pull/21; exit 0 ;; esac ;;
esac
exit 1
STUB
chmod +x "$d/bin/gh"
PUBLISH_OUT=$(env -u JG_RECEIPT_PR PATH="$d/bin:$PATH" \
  JG_HOME="$H" JG_FORK_BIN="$ROOT/bin" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
  "$TOOL" t4 PASS "$d/evidence.txt" "$d/cand" 2>&1) \
  || fail "branch pull request: the publisher refused ($PUBLISH_OUT)"
is "the recorded branch's open pull request is read" "$(pr_field t4)" 'https://github.com/o/r/pull/21'

# A local-only task lands no pull request, so its receipt still publishes empty.
publish t2 || fail "local-only: the publisher refused a receipt that needs no pull request ($PUBLISH_OUT)"
is 'local-only records no pull request' "$(pr_field t2)" ''

echo 'ok: the receipt records its pull request from an export, a command prefix, the task record or the branch, and refuses a missing one'
