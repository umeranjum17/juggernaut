#!/usr/bin/env bash
# E2E: `jg` run the way a worker runs it: from its worktree, with no JG_HOME or JG_TASK set.
# Usage: core/agent-cli/tests/agent-cli.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
JG=$ROOT/bin/jg
d=$(mktemp -d "${TMPDIR:-/tmp}/agent-cli.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
jg() { (cd "$WT" && env -u JG_HOME -u JG_TASK -u JG_STATE_OVERRIDE "$JG" "$@" 2>&1); }

H=$d/home
mkdir -p "$H/state" "$H/projects/proj"
git -C "$H/projects/proj" init -q .
git -C "$H/projects/proj" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
WT=$d/wt
git -C "$H/projects/proj" worktree add -q -b feature/t1 "$WT" || fail "worktree"
WT=$(cd "$WT" && pwd -P)
printf 'worktree=%s\nkind=ship\nmode=local-only\nbranch=feature/t1\n' "$WT" > "$H/state/t1.meta"
printf 'worktree=/elsewhere\nkind=ship\nmode=local-only\n' > "$H/state/t2.meta"
S=$H/state/t1.status
inbox=$H/state/t1.inbox; mkdir -p "$inbox/handled"
printf 'first steer\n' > "$inbox/001.msg"; printf 'second steer\n' > "$inbox/002.msg"

out=$(jg status); has status "$out" "ticket: t1 · ship · local-only · branch feature/t1"
has status "$out" "inbox: 2 unread"; has status "$out" "Next: jg inbox"

out=$(jg inbox); has inbox "$out" "first steer"; has inbox "$out" "second steer"
out=$(jg inbox ack 1 --evidence status:x); has ack "$out" "steer 1 acknowledged and recorded handled"
grep -q '"handled"' "$inbox/.delivery.jsonl" || fail "no handled record in the delivery ledger"
[ -f "$inbox/handled/001.msg" ] && [ ! -e "$inbox/001.msg" ] || fail "ack did not move 001"
out=$(jg inbox ack 9) && fail "ack of a missing steer passed"; has ack-missing "$out" "no unread steer 9"

out=$(jg progress "built the parser"); has progress "$out" "Next:"
out=$(jg wait outside ci "CI run of the lane" --until 2099-01-01T00:00Z); has wait "$out" "wait declared"
out=$(jg wait nobody ci "x") && fail "bad wait word passed"
out=$(jg status); has status-wait "$out" "wait: paused [at="; has status-wait "$out" "[wait=outside] [reason=ci]"
out=$(jg done); has done "$out" "done recorded"
last=$(tail -n1 "$S"); case $last in "done [at="*"]: ready in branch feature/t1 (local-only)") ;; *) fail "done line: $last" ;; esac
[ "$(wc -l < "$S")" = 3 ] || fail "status file should hold 3 lines (progress, paused, done), got $(wc -l < "$S")"
out=$(jg bogus) && fail "unknown verb passed"; has verb "$out" "Next: jg help"
out=$(jg help); has help "$out" "jg inbox"

# a worktree no record names is refused with the way out
git -C "$H/projects/proj" worktree add -q -b feature/t3 "$d/wt3" || fail "worktree 3"
out=$(cd "$d/wt3" && env -u JG_HOME -u JG_TASK "$JG" status 2>&1) && fail "unnamed worktree passed"
has unnamed "$out" "Next: set JG_TASK"
echo PASS
