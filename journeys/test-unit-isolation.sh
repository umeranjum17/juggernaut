#!/usr/bin/env bash
# A test never takes the machine: a throw-away home (a test's, under a temp root) never installs the account's own
# units, a remote update a suite drives runs as that suite's simulated host account, and every job a landing check
# detaches is stopped when the suite cleans up. The runner's real jg-sentinel unit is read, never written.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
real_unit="$(unset HOME; CDPATH='' cd ~ && pwd -P)/.config/systemd/user/jg-sentinel.service"
real_print() { if [ -e "$real_unit" ]; then printf 'mtime=%s sha256=%s\n' "$(stat -c %Y "$real_unit")" "$(sha256sum < "$real_unit" | cut -d' ' -f1)"; else echo absent; fi; }
before=$(real_print)
rc=0
(cd "$root" && bash bin/jg-test-run.sh tests/jg-remote-squad-lead-lifecycle-e2e.test.sh \
  core/sentinel/tests/jg-sentinel-install.test.sh tests/jg-trunk-queue.test.sh) > "$out" 2>&1 || rc=$?
after=$(real_print)
printf 'real jg-sentinel unit before: %s\nreal jg-sentinel unit after:  %s\n' "$before" "$after" >> "$out"
[ "$before" = "$after" ] || { echo "the real jg-sentinel unit changed during the run" >> "$out"; rc=1; }
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "this machine's real jg-sentinel unit as it is, a remote squad-lead fixture under a temp root whose simulated host has its own account (stub systemctl and systemd-run), and a local-trunk fixture home",
 "steps": ["update the remote squad lead's code root on its host, which runs the release's stack and host wiring for the throw-away root", "install the sentinel for a throw-away home into an account's own unit dir, then dry-run it against this account's real unit dir", "start the landing of a lane whose gate hangs, then let the suite clean up"],
 "result": "the update fast-forwards the remote home and installs no unit, no sentinel copy and changes no systemd state; both installs are refused with the reason and write nothing; the hung landing job and its process group are gone after cleanup; the real unit's mtime and bytes are unchanged"}
JSON
exit "$rc"
