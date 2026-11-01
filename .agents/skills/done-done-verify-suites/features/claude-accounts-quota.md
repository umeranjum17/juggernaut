# Claude accounts quota reader

## User outcome

`state/claude-accounts.json` carries each registered Claude account's 5-hour and 7-day quota for dispatch. Lookout does not display this data. Two logins with the same profile name are told apart by an ordinal ("default 2"), never by an id.

## Drive

Run `done-done run claude-accounts-quota` or `bash claude-accounts/tests/claude-accounts.test.sh` from the repository root. The fixture test proves both windows per account, a failing account's recorded cause, active rest expiry and its removal at 100/100 headroom, and that no secret field reaches the file. `bash quota-axi-pool/tests/quota-axi-pool-recursion.test.sh` proves the reader resolves the real upstream quota-axi and never the `quota-axi-pool` PATH wrapper that would send it back through the account pick.

## Evidence

The done-done journey retains the fixture test output and a real reading with account folder paths removed. Pass only profile folder paths to quota-axi; never open files inside a login folder.
