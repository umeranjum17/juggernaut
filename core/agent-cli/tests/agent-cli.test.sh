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
out=$(jg "done"); has "done" "$out" "done recorded"
last=$(tail -n1 "$S"); case $last in "done [at="*"]: ready in branch feature/t1 (local-only)") ;; *) fail "done line: $last" ;; esac
[ "$(wc -l < "$S")" = 3 ] || fail "status file should hold 3 lines (progress, paused, done), got $(wc -l < "$S")"
# alerts: only the ticket's own alerts show; a lead's --home shows all; ack is the machine's move
JG_HOME=$H JG_STATE_OVERRIDE=$H/state "$ROOT/bin/jg-alert.sh" raise lost-worker t1 --ticket t1 --note "no sign of life" >/dev/null || fail "raise own alert"
JG_HOME=$H JG_STATE_OVERRIDE=$H/state "$ROOT/bin/jg-alert.sh" raise lost-worker t2 --ticket t2 --note "other lane" >/dev/null || fail "raise other alert"
out=$(jg alert); has alert "$out" "alerts: 1"; has alert "$out" "lost-worker--t1"; has alert "$out" "Next: jg alert ack"
case $out in *lost-worker--t2*) fail "alert list shows another ticket's alert" ;; esac
out=$(jg alert --home); has alert-home "$out" "alerts: 2"
out=$(jg alert ack lost-worker--t2) && fail "ack of another ticket's alert passed"; has alert-other "$out" "does not name t1"
out=$(jg alert ack lost-worker--t1); has ack-alert "$out" "acknowledged"
[ "$(JG_HOME=$H JG_STATE_OVERRIDE=$H/state "$ROOT/bin/jg-alert.sh" word lost-worker--t1)" != open ] || fail "alert still open after ack"
out=$(jg alert ack lost-worker--t1) && fail "second ack passed"

# ask: one decision line with options and recommendation; a bad question is refused and writes nothing
before=$(wc -l < "$S")
out=$(jg ask "Keep the old name?" --option keep --option rename --recommend keep); has ask "$out" "decision asked"
last=$(tail -n1 "$S"); case $last in "needs-decision [at="*"]: Keep the old name? Options: keep | rename. Recommend: keep.") ;; *) fail "ask line: $last" ;; esac
out=$(jg ask "One option?" --option only) && fail "single option passed"; has ask-one "$out" "two options"
out=$(jg ask "Pick" --option a --option b --recommend c) && fail "recommend outside options passed"
[ "$(wc -l < "$S")" = $((before + 1)) ] || fail "a refused ask wrote a line"

out=$(jg bogus) && fail "unknown verb passed"; has verb "$out" "Next: jg help"
out=$(jg help); has help "$out" "jg inbox"

# a worktree no record names is refused with the way out
git -C "$H/projects/proj" worktree add -q -b feature/t3 "$d/wt3" || fail "worktree 3"
out=$(cd "$d/wt3" && env -u JG_HOME -u JG_TASK "$JG" status 2>&1) && fail "unnamed worktree passed"
has unnamed "$out" "Next: set JG_TASK"
echo PASS
