#!/usr/bin/env bash
# done-done journey: agy (Antigravity CLI) holds the helm as the primary Overwatch.
# Step 1 (always): the agy cases of tests/jg-session-start.test.sh run the tracked .agents/hooks.json
#   SessionStart command under a real process named agy, so the session lock names agy and the injected
#   digest carries the agy protocol, and pin the anchored lock walk and the agy supervision block.
# Step 2 (always): the agy cases of tests/jg-turnend-guard.test.sh run the tracked Stop and PreToolUse
#   commands the way agy runs them: an unsupervised turn end continues once with the agy repair line, the
#   continuation stops on either loop signal, a worker copy stays silent, and a backgrounded arm is denied
#   on stdout while the standalone arm passes silently.
# Step 3 (opt-in, spends model tokens: JG_AGY_PRIMARY_LIVE_E2E=1): tests/jg-agy-primary-live-e2e.test.sh
#   starts the installed agy in a throwaway home and keeps its pane and conversation under live/.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ev=${DONE_DONE_EVIDENCE_ROOT:?}
out=$ev/${RUN_ID:-run}.log
# The suites build their own fixture homes; a caller's home must not leak into them.
unset JG_HOME JG_TASK_ID
{
  (cd "$root" && JG_SESSION_START_ONLY='test_agy_takes_the_lock_and_gets_its_supervision_block test_agy_session_lock_walk_matches_the_exact_name_only test_agy_sessionstart_hook_takes_the_helm_through_the_real_chain' \
    bash tests/jg-session-start.test.sh) \
  && (cd "$root" && JG_TURNEND_GUARD_ONLY='test_agy_stop_hook_continues_once_when_unsupervised test_agy_stop_hook_allows_the_continuation_on_either_signal test_agy_stop_hook_silent_when_supervised_scoped_or_unreadable test_agy_pretool_hook_denies_a_bundled_arm_and_is_silent_otherwise' \
    bash tests/jg-turnend-guard.test.sh)
} > "$out" 2>&1
rc=$?
live=skipped
if [ "$rc" -eq 0 ] && [ "${JG_AGY_PRIMARY_LIVE_E2E:-}" = 1 ]; then
  (cd "$root" && JG_AGY_PRIMARY_EVIDENCE="$ev/live" bash tests/jg-agy-primary-live-e2e.test.sh) > "$ev/live.log" 2>&1
  rc=$?
  live=ran
fi
cat "$out"
[ "$live" = skipped ] || cat "$ev/live.log"
cat > "$ev/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "fixture homes with one lane under way and no watcher, driven through the tracked .agents/hooks.json commands under a real process named agy; with the live run, a throwaway copy of this checkout opened in the installed agy",
 "steps": ["run the SessionStart registration and read the lock and the injected digest", "run the Stop registration on a first stop, on each continuation signal alone, with nothing in flight, on an unreadable payload, and in a worker copy", "run the PreToolUse registration on a backgrounded arm, the standalone arm, an ordinary command and an unreadable payload", "live run ($live): trust the folder, ask for the digest marker with no command, let the Stop hook force the arm, then append a status line and watch the session drain and re-arm"],
 "result": "the lock names the agy process and the digest names agy; an unsupervised turn end continues exactly once and a worker copy is never held; only the backgrounded arm is denied, as agy's stdout decision with exit 0"}
JSON
exit "$rc"
