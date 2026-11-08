#!/usr/bin/env bash
# done-done journey: the local trunk flow. A lane with one commit and a PASS done-done receipt lands on a local
# trunk by compare-and-swap, by itself through the registered core/trunk-landing check, and never goes live; live
# and release refuse without the captain's recorded word; unsafe landings (no, FAIL or other-head receipt, a second
# commit, a moved tip, a conflict that names its paths, a failing gate, a failing lint, an owner-guard hit, an open
# linked decision, away mode, a protected path, a red trunk, a trunk a lane moved) refuse and leave the trunk
# unchanged; each open captain call changes behaviour only through config/trunk-policy; a smoke landing keeps the
# home on the last fully green commit until verify passes; the release is ONE pull request from the trunk itself
# with no release branch; and a red CI pins the home back to the last green commit.
# Real bin/jg-trunk.sh, bin/jg-trunk-live-home.sh, core/trunk-landing and the shared landing gates run over real git
# repositories, a bare origin and a recording forge (tests/jg-trunk.test.sh owns the cases; tests/jg-trunk-scope.test.sh
# proves direct-PR, no-mistakes and local-only projects are untouched; tests/jg-trunk-spawn.test.sh
# owns the spawn side: a project with a trunk takes no feature pull request and its lane starts on the trunk tip).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
# Match the lander's exact-head temporary clone, including its /tmp location:
# a Beads jail must retain the candidate code while replacing /tmp privately.
# shellcheck source=tests/lib.sh
. "$root/tests/lib.sh"
candidate=$(jg_test_tmproot jg-trunk-proof) || exit 1
git clone -q --shared --no-checkout "$root" "$candidate/tree" || exit 1
git -C "$candidate/tree" checkout -q --detach "$(git -C "$root" rev-parse HEAD)" || exit 1
rc=0
(cd "$candidate/tree" && bash bin/jg-test-run.sh \
  tests/jg-trunk.test.sh tests/jg-trunk-spawn.test.sh tests/jg-trunk-scope.test.sh \
  tests/jg-on.test.sh tests/migration-card-live.test.sh tests/jg-afk-inject-e2e.test.sh \
  tests/jg-wake-watcher.test.sh tests/jg-beads.test.sh tests/jg-beads-native-n6.test.sh \
  tests/jg-beads-native-n8.test.sh tests/jg-ticket-writeback.test.sh) > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a project, a local bare origin, a trunk created at the release tip, a recording hold reader, a recording live hook and a recording forge",
 "steps": ["land a lane with one commit and a PASS receipt: the trunk moves to it, one landing row is logged and the live hook does not run", "ask for live with no recorded word, then as a worker, then with an empty quote: each refuses; record the captain's word and live runs the hook at the green commit and spends the word", "land with the bundled hook against a clone of the project: landing leaves the home checkout alone, live fast-forwards it, a red CI moves it back, a dirty home exits 3 with the commit still landed", "try a lane with no receipt, a FAIL receipt, a receipt for another head, two commits, a moved tip, a conflicting change, a failing gate, a failing lint, an owner-guard hit, a linked open decision, away mode, a protected path, a red trunk and a trunk a lane moved: each refuses and the trunk does not move; the conflict names its paths", "change protected-landing, away-landing and trunk-owner in config/trunk-policy: behaviour changes with no code change", "land under a smoke gate: the home stays on the last fully green commit; a red verify sets the red flag; only a fixes-red commit lands; a green verify clears it", "release a batch with no word (refused), then with his word: origin trunk holds the tip, there is no release branch, exactly one pull request opens from the trunk, and a later release while it is open opens no second one", "write the trunk by hand with git (the project hook refuses it, even a branch -f), land a commit with no ticket reference (refused), and land one with it (the merged event is recorded, as the local merge records it)",
 "rewind, force or delete the trunk (even with the lander's own writer): the project hook refuses; while the release PR is open rollover refuses; once it merged the next trunk (trunk-v2) is cut from the default branch, recorded, landed on, with the old trunk untouched, and the landing check cuts it by itself",
 "clean up the old trunk: with a hotfix not carried into trunk-v2 and a worktree holding unsaved work everything is kept and listed; once the hotfix is carried the remote branch goes, the worktree stays while it holds unsaved work, then the worktree and the local branch go, all unforced",
 "report a red CI for the live commit: the home returns to the last green live commit, the red pin is written and landings stop except a fixes-red commit", "register direct-PR, no-mistakes and local-only projects with a stray trunk record: jg-trunk.sh refuses each subcommand naming the registered mode, the landing check and the spawn leave them alone, and each keeps its own behaviour (direct-PR opens its PR, no-mistakes runs its pipeline, local-only stops at a ready branch and merges locally)",
 "spawn on a project registered local-trunk: a direct-PR or no-mistakes lane is refused by name, a local-trunk lane retains its mode and starts on the trunk tip (legacy local-only stays compatible)",
 "publish the real local-trunk task receipt, sweep automatic landing and run real unforced cleanup with no remote release ref; the exact head is on trunk, the task record is removed and its board note retains local-trunk",
 "sweep the trunk-landing check (the watcher runs it on its 30-second tick): it lands the proved task by itself and cleans it up unforced, ignores the task with no receipt, reports a conflict once with its paths, retries a time-only refusal without repeating it, and never goes live",
 "prove same-clock and concurrent producer order before publication, legacy tie replay, and live watcher delivery; run real Beads and ticket journeys with the candidate code bound read-only into private jails and valid board descriptions",
 "prove the landing prerequisites through real probes on deterministic tool paths: the remote doctor reports missing and fixture-installed harnesses, the migration card measures absent and installed CLIs over a real private bus, and a private tmux fixture delivers exactly one notification after a swallowed Enter without reading host service bindings"],
 "result": "a proved commit lands on the local trunk with no human step and is never live until the captain says so, every unsafe landing is refused with the reason, the batch goes out as one trunk-to-main release PR on his word, and a red CI returns the home to the last green commit"}
JSON
exit "$rc"
