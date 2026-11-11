# Receipt rebind to a superseded copy

Receipt rebind to a superseded copy: run `done-done run -- bash core/receipts/tests/receipt-superseded-copy.test.sh`; it builds real commits in real repositories (forge read stubbed) and proves a rebased copy of a closed-unmerged pull request is accepted while an altered, incomplete, still-open or merged predecessor is refused.
