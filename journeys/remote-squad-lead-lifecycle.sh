#!/usr/bin/env bash
# done-done journey: a remote Squad Lead lifecycle. A remote spawn writes its inheritance, survives a
# restart and relaunches, each step on a disposable home with a fake remote host.
# tests/jg-remote-squad-lead-lifecycle-e2e.test.sh owns the cases; its waits bound a hang, so they are
# sized for a loaded runner and a failure means the work stopped, not that it was slow.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-remote-squad-lead-lifecycle-e2e.test.sh" > "$out" 2>&1 || rc=$?
printf 'journey result: %s checks ok, %s not ok, test exit %s\n' "$(grep -c '^ok' "$out")" "$(grep -c '^not ok' "$out")" "$rc" | tee -a "$out"
tail -n 40 "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a disposable home with a fake remote host and a fake launcher",
 "steps": ["spawn a remote Squad Lead and wait for its blocked inheritance write", "complete the first inheritance transaction", "respawn the Squad Lead and wait for its launch"],
 "result": "the remote Squad Lead reaches each lifecycle step within the wait bound and the test passes"}
JSON
exit "$rc"
