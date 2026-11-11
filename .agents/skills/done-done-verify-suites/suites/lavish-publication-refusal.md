# Lavish publication refusal (squad lead notes and merge-card posts only)

Lavish publication refusal (squad lead notes and merge-card posts only): run `bash owner-rules/tests/no-lavish.test.sh`; the executable checker and note hook refuse Lavish and accept sign-off links, and the real sign-off writer receives only the clean card on an isolated board.
Set `JG_TEST_FORK=<Juggernaut checkout>` to also prove the real squad lead helper writes no refused status line; raw status appends, report files and commands are outside this check.
Capture the real publishing commands with `JG_PROOF_FORK=<Juggernaut checkout> done-done run owner-rules-publication`; this records the actual refusals, absent status, unchanged board, and clean sign-off posts.
