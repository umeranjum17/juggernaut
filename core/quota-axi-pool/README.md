# quota-axi-pool

PATH wrapper so dispatch's `quota-axi --json` reports every registered Claude and Codex account, not the ambient login alone. It reads `claude-accounts/bin/jg-quota-view` (the one quota view the quota wake and the Lookout dashboard read too) and emits schema 6: `accountKey default` is the worker account with the most room (exhausted when none has any), `<id>` is each worker, and `main` is Main's own login, reserved and never counted toward `default`. A provider with no registered workers keeps the upstream row. Upstream quota-axi is unchanged. The quota wake judges a provider on its `default` row only. Non-JSON calls exec upstream with `CLAUDE_CONFIG_DIR` from a Claude pick.

One trip through the pool per call: a call that is already inside a delegation carries `JG_QUOTA_AXI_POOL_DEPTH` above 0 and execs the upstream directly, so a tool the pick runs cannot recurse back through this wrapper.

```sh
bash quota-axi-pool/wiring.sh          # links ~/.local/bin/quota-axi; --dry-run ok
bash quota-axi-pool/unwiring.sh
bash quota-axi-pool/tests/quota-axi-pool.test.sh
bash quota-axi-pool/tests/quota-axi-pool-recursion.test.sh   # the wrapper cannot recurse
bash quota-axi-pool/run-proof.sh        # done-done journey quota-axi-pool (screen: none)
```

Needs `account-pool` (`jg-model-pool`) and `state/claude-accounts.json` from the `claude-accounts` reader.

## The two routes upstream cannot read

The shared route chain leads with two providers upstream quota-axi either omits or misreads, so the wrapper reports
them truthfully instead of passing the wrong answer on:

- **Ollama** has no provider row upstream at all. When the home's allow-list (`model-gate`'s `config/model-allow-list.json`)
  names `ollama-cloud`, the wrapper adds an `ollama-cloud` row from Ollama's own balance API (`/api/balance`, the same read
  model-gate uses; key from `$OLLAMA_API_KEY_FILE` or `~/.config/ollama-cloud/api_key`, never printed): `credits.remaining`
  in USD, one `credit` window as a percentage of the monthly allowance, and `quotaSemantics.effectiveAvailability` with
  `exhausted_now` at zero credit, so the pipeline's own quota pre-check reads it like any other provider. A successful read
  is reused for `JG_QUOTA_AXI_POOL_OLLAMA_SECONDS` (default 60). A read that fails adds **no** row: never a healthy row for a
  provider we could not read.
- **Command Code** is usable with the fleet's key even while upstream says `auth_required`: upstream reads that key only
  from `COMMANDCODE_API_KEY` (env), `~/.commandcode/auth.json`, or a `commandcode` entry in pi's `auth.json`, and this
  fleet keeps it in `$JG_HOME/config/commandcode-api-key`. The wrapper reads that file into the child's environment
  (`JG_QUOTA_AXI_POOL_COMMANDCODE_KEY` overrides the path; nothing is printed, copied or logged), so upstream reports the
  real Command Code state - fresh, with its 5-hour and weekly windows.
