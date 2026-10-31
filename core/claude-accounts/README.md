# claude-accounts

A quota reader for every Claude account signed in on this machine.

`bin/claude-accounts-quota.sh` reads the account list from the muxr registry (`~/.muxr/plans/accounts-v1.json`, or `JG_CLAUDE_ACCOUNTS_REGISTRY`), takes only the `id`, `name` and `folder` of each Claude account, and runs `quota-axi --provider claude --profile-only --json` with `CLAUDE_CONFIG_DIR` set to that folder. It resolves the real upstream `quota-axi` (`JG_QUOTA_AXI_REAL`, then the target `quota-axi-pool` recorded, then `PATH` without the wrapper) and never the `quota-axi-pool` wrapper itself, which delegates to the account pick and would come back here for another reading. It never opens, copies, links or edits anything inside a login folder, and changes nothing about how accounts sign in.

It writes `<home>/state/claude-accounts.json` (atomic replace):

```json
{"schema":1,"generated_at":1792566241,"accounts":[
  {"id":"found-claude","name":"default","folder":"/path/to/profile",
   "five_hour":{"left":63,"resets_at":"2026-10-21T08:39:59+00:00"},
   "seven_day":{"left":34,"resets_at":"2026-10-26T12:59:59+00:00"},"problem":null}]}
```

`left` is percent remaining; a window that could not be read is `null` and the account's `problem` names the cause. Exit 0 when at least one account was read. Run it on a timer (a few minutes apart); `--print` also shows the file.

The file remains an input to account dispatch. Lookout does not display Claude quota data.

Test: `bash claude-accounts/tests/claude-accounts.test.sh`.

## Automatic account choice for new workers

`bin/claude-accounts-pick` is a `config/account-pool` command used by jg-spawn and relaunch.
It spreads new Claude and Codex assignments in proportion to headroom; its header documents the smooth weighting, recent-assignment window, locking, quota floor and quota-verified rest policy.
Each provider uses its own registry accounts and `<provider>-accounts.json` reading, with `account-assignments.json` in the pool state folder shared by callers.
The reader accepts `JG_ACCOUNTS_PROVIDER=codex` to refresh Codex quota, including its weekly window.
`--prefer <id>` still requires an eligible account, running workers stay on their current account, and Pi remains ambient.
Codex falls back to its ambient folder only without any registered Codex accounts.

A reader that cannot answer never refuses a launch. The roster is the registry (id, name, folder), and the numbers come from the last good reading on disk, in `<home>/state` or in the pool state folder named by `config/account-pool`, whichever is newer and still holds a window. So `JG_HOME` unset, a vendor outage, or a reading nobody refreshed is not a refusal: a reading older than an hour is ranked on its 7-day side alone, an account with no reading at all ranks last but is still picked, and the answer says where its numbers came from (`read.source`: `reading`, `last-good` or `none`) and how old they are (`read.age`). An account whose last reading says it must sign in again is skipped however much runway it shows, so a signed-out profile never wins on a stale number. Only a pool with nothing to offer still refuses: every account resting, or every known runway under the low mark.

Wire in: `claude-accounts/wiring.sh <home>` writes `<home>/config/account-pool`; remove with `claude-accounts/unwiring.sh <home>`. It refuses to replace a different account-pool file, and it never touches a pin file (`config/claude-account`). Install from merged main only.

Test: `bash claude-accounts/tests/claude-accounts-pick.test.sh`.

## Refresh timer

`install-timer.sh [--dry-run] <home>` installs a systemd user timer (`jg-claude-accounts-quota.timer`) that runs the reader every 5 minutes for that home, so `state/claude-accounts.json` stays current for dispatch; `--dry-run` prints what would be written. It copies the reader to `~/.local/share/jg-claude-accounts/` and enables the timer only when something changed. Remove with `uninstall-timer.sh`. Install from merged main only.

Test: `bash claude-accounts/tests/claude-accounts-timer.test.sh`.
