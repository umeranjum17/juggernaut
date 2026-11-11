# Version branch carry and sealed-head guard

Version branch carry and sealed-head guard: run `bash tests/jg-version-branch-sync.test.sh`; it drives `bin/jg-version-branch-sync.sh` against a lab origin and a stub forge and proves the version branch follows the default branch, a landed release reaches every open feature pull request as a real merge commit, and a pull request whose proof block is sealed at its head keeps that head while a branch whose proof names another head is still carried (screen: none).
Live, read-only: `gh pr view <number> --json body,headRefOid` on a real open pull request, then the guard's own rule over that body and the head it carries, then over the same body and an older head, shows one sealed verdict and one stale one; no branch is pushed.
