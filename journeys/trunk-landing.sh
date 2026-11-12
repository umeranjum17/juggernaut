#!/usr/bin/env bash
# done-done journey: the local trunk flow. A done lane with one commit lands on a local trunk by compare-and-swap, by
# itself through the registered core/trunk-landing check, after one fast check (rebase, changed-file lint, changed-file
# tests against the tip's own result), and never goes live; three lanes ready at once land in order, a red one is refused,
# and a landing moves no green pin and runs no whole suite (the tick's verify moves the pin, one at a time, and a red it finds is traced to its commit, reverted, and raises line-red); live
# and release refuse without the captain's recorded word; unsafe landings (a second commit, a conflict that names its
# paths, a failing gate, a failing lint, an owner-guard hit, an open
# linked decision, away mode, a protected path, a trunk a lane moved) refuse and leave the trunk
# unchanged, and a red trunk never stops a landing; each open captain call changes behaviour only through config/trunk-policy;
# the changed tests run once for each batch on the trunk, off the landing path; the release is ONE pull request from the trunk itself
# with no release branch; and a red CI pins the home back to the last green commit.
# Real bin/jg-trunk.sh, bin/jg-trunk-live-home.sh, core/trunk-landing and the shared landing gates run over real git
# repositories, a bare origin and a recording forge (tests/jg-trunk.test.sh and its -adopt, -refusal, -live, -gate, -queue, -retry and
# -verify parts own the cases; tests/jg-trunk-scope.test.sh
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
  tests/jg-trunk.test.sh tests/jg-trunk-adopt.test.sh tests/jg-trunk-refusal.test.sh tests/jg-trunk-live.test.sh tests/jg-trunk-gate.test.sh tests/jg-trunk-sealed-ran.test.sh tests/jg-trunk-queue.test.sh \
  tests/jg-trunk-retry.test.sh tests/jg-trunk-release-open-pr.test.sh tests/jg-trunk-release-merge-first.test.sh tests/jg-trunk-two-gates.test.sh tests/jg-trunk-publish.test.sh tests/jg-trunk-cancel.test.sh tests/jg-trunk-cleanup-at-land.test.sh \
  tests/jg-trunk-verify.test.sh tests/jg-trunk-verify-milestone.test.sh tests/jg-trunk-judge.test.sh tests/jg-trunk-spawn.test.sh tests/jg-trunk-scope.test.sh \
  tests/jg-on.test.sh tests/migration-card-live.test.sh tests/jg-afk-inject-e2e.test.sh \
  tests/jg-wake-watcher.test.sh tests/jg-beads.test.sh tests/jg-beads-native-n6.test.sh \
  tests/jg-beads-native-n8.test.sh tests/jg-ticket-writeback.test.sh) > "$out" 2>&1 || rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a project, a local bare origin, a trunk created at the release tip, a recording hold reader, a recording live hook and a recording forge",
 "steps": ["a green release pull request under the standing release word is merged by the merge check through the guarded merge path and the next trunk is cut in the same pass; a red or unreported head, or a removed rule, is not merged", "sweep an idle trunk after a forward move or a released forward move: the check adopts the tip and records both tips; rewind it and the check raises an alarm", "land a done lane with one commit: the trunk moves to it, one landing row is logged and the live hook does not run", "ask for live with no recorded word, then as a worker, then with an empty quote: each refuses; record the captain's word and live runs the hook at the green commit and spends the word", "land with the bundled hook against a clone of the project: landing leaves the home checkout alone, live fast-forwards it, a red CI moves it back, a dirty home exits 3 with the commit still landed", "try a lane with two commits, a conflicting change, a failing gate, a failing lint, an owner-guard hit, a linked open decision, away mode, a protected path and a trunk a lane moved: each refuses and the trunk does not move; the conflict names its paths", "verify a tip that fails with no failed test: it warns and runs once more, pins nothing and reverts nothing, and a ready lane lands on it with no hand step; the trunk with no green for 15 minutes raises one alarm, not two", "land lanes with no receipt, a FAIL receipt, a receipt for another head and a merge gate that refuses every merge: all land, the lane based on a moved tip is rebased by the lander and the lane follows it, and each landing records which seal, merge-card and signature existed", "leave four lanes ready at once, one red: three land in the order they were done with no human step, each cleaned up unforced, the red one is refused and reported once, each landing moves the green pin to its commit and no whole-suite run starts; a hand-run whole suite that charges a red to one commit reverts it, its ticket and Overwatch are told, and the green pin goes back below it, and the lane after it still lands; a revert that cannot apply raises one alert, takes the green pin back below the commit, and the next lane still lands", "change protected-landing, away-landing and trunk-owner in config/trunk-policy: behaviour changes with no code change", "land a commit: its own gate moves the green pin to it at once; after nine landings and a green pin left six hours behind, one more lane lands, the pin is its head and the landing check runs only that lane's tests", "release a batch with no word (refused), then with his word: origin trunk holds the tip, there is no release branch, exactly one pull request opens from the trunk, and a later release while it is open opens no second one; a release already pushed whose record is missing gets the record and its armed check with no second push, and a record of another kind under the id is refused", "write the trunk by hand with git (the project hook refuses it, even a branch -f), land a commit with no ticket reference (refused), and land one with it (the merged event is recorded, as the local merge records it)",
 "rewind, force or delete the trunk (even with the lander's own writer): the project hook refuses; while the release PR is open rollover refuses; once it merged the next trunk (trunk-v2) is cut from the default branch, recorded, landed on, with the old trunk untouched, and the landing check cuts it by itself",
 "clean up the old trunk: with a hotfix not carried into trunk-v2 and a worktree holding unsaved work everything is kept and listed; once the hotfix is carried the remote branch goes, the worktree stays while it holds unsaved work, then the worktree and the local branch go, all unforced",
 "report a red CI for the live commit: the home and the green pin return to the last green live commit, and the next lane still lands", "register direct-PR, no-mistakes and local-only projects with a stray trunk record: jg-trunk.sh refuses each subcommand naming the registered mode, the landing check and the spawn leave them alone, and each keeps its own behaviour (direct-PR opens its PR, no-mistakes runs its pipeline, local-only stops at a ready branch and merges locally)",
 "spawn on a project registered local-trunk: a direct-PR or no-mistakes lane is refused by name, a local-trunk lane retains its mode and starts on the trunk tip (legacy local-only stays compatible)",
 "publish the real local-trunk task receipt, sweep automatic landing and run real unforced cleanup with no remote release ref; the exact head is on trunk, the task record is removed and its board note retains local-trunk",
 "sweep the trunk-landing check (the watcher runs it on its 30-second tick): it lands the done task by itself after one fast check and cleans it up unforced, ignores the task that is not done, reports a conflict once with its paths, retries a time-only refusal without repeating it, lands three lanes ready at once in order, starts no whole-suite run after a landing, and never goes live",
 "prove same-clock and concurrent producer order before publication, legacy tie replay, and live watcher delivery; run real Beads and ticket journeys with the candidate code bound read-only into private jails and valid board descriptions",
 "prove the landing prerequisites through real probes on deterministic tool paths: the remote doctor reports missing and fixture-installed harnesses, the migration card measures absent and installed CLIs over a real private bus, and a private tmux fixture delivers exactly one notification after a swallowed Enter without reading host service bindings",
 "land a stack whose lander prints one landed line per lane: each lane is cleaned up at its own landed line while the lander still runs; a refusal that only needs time is retried on the 15 s, 1, 2 and 5 minute ladder and cleaned on the retry; any other refusal gets one closed-list reason and one alert, and a time-only refusal that never clears is final after the ladder with one alert",
 "publish under the standing release word: the green pin is pushed once the trunk holds enough, never forced; a trunk with fewer commits, no waiver, an open batch pull request or a CI run in flight pushes nothing; after a red the tip is pushed once as a candidate and its green result moves the pin past the red; the landing check starts the publish step within one tick",
 "ready four lanes with gate-slots and heavy slots at 3: three gate at once on a chain of fronts, each on the commit below it, the fourth waits for a position and all land in order after one gate each; a red lane in the middle is returned and the lane above it is gated once more"],
 "result": "a done commit lands on the local trunk after one fast check with no human step and is never live until the captain says so, every unsafe landing is refused with the reason, the batch goes out as one trunk-to-main release PR on his word, and a red CI returns the home to the last green commit"}
JSON
exit "$rc"
