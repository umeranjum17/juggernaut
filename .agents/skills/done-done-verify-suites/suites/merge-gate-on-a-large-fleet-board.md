# Merge gate on a large fleet board

Merge gate on a large fleet board: run `done-done run -- bash core/owner-rules/tests/owner-rules-gate.test.sh` with the suite's log written into `$DONE_DONE_EVIDENCE_ROOT`; the real installed gate over a board whose items list is over 200 KB passes when the PR's card is there and names the missing card when it is not, with no tool error in the text, and an evaluator that cannot run or answers non-JSON refuses with its own reason as "cannot evaluate the merge gate" (screen: none).
