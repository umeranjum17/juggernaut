# A workflow runs its war room to plan approval

Run `done-done run jg-workflow-war-room` (`bash tests/jg-workflow-war-room.test.sh`) from the repository root.
On an isolated home the real workflow command starts the configured council, advances on variant and dry-run status, sends critic gaps, and stops on a refusal.
The real council command and approval hold handle both sign-off adapters, with a stand-in for the board tool.
The run records the test output in `$DONE_DONE_EVIDENCE_ROOT` (screen: none).
