# Merge-gate lint lane identity and proof wording

Merge-gate lint lane identity and proof wording: run `bash merge-on-green/tests/checks-lint-lane-task.test.sh`; a lane whose follow-up PR reuses its own earlier frames (hashes recorded under the lane folder while the PR branch tip differs) must PASS, true cross-task reuse must still FAIL, and the `proof:` line is judged only for naming a command or path, never for a skill name.
