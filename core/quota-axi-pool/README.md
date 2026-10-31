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
