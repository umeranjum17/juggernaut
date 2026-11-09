# Core-suites run-all-failures condition

Core-suites run-all-failures condition: run `done-done run -- bash tests/core-suites-report-all.test.sh`; it walks every step of `.github/workflows/core-suites.yml` after the install steps and refuses one without `if: ${{ !cancelled() }}`, so one red run lists every failing suite.
