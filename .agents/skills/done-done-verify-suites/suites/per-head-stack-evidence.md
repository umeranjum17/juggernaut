# Per-head stack evidence

Per-head stack evidence: run `done-done run -- bash core/merge-on-green/tests/checks-lint-cases.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `jg-checks-lint.sh` proves an evidence file named for the PR's own head (or inside a subfolder named for it) passes even when a sibling PR already used its bytes, while the same bytes under another head's name still fail with `every evidence file was already used by another PR` (screen: none).
