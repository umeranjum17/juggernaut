# One lane, several pull requests

One lane, several pull requests: run `done-done run -- bash core/receipts/tests/receipt-multi-pr-lane.test.sh`; it runs the real `bin/jg-pr-check.sh` under `JG_PR_CHECK_MERGE=1` with the lane checkout at the last pull request's head, and proves each pull request lands with the receipt for its own head while another PR's head, another PR's name and a FAIL receipt are refused.
