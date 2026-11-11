# Merge-gate lint pin

Merge-gate lint pin: run `bash merge-on-green/tests/checks-lint-parity.test.sh`; it uses a fake gh and isolated homes, runs the pinned done-done-axi lint against size fixtures (plain, generated, routes, oversized) and proves its PASS/FAIL verdicts match the legacy lint.
