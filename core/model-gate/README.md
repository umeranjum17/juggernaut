# model-gate

One allow-list per provider: a model the list does not carry cannot be picked, spawned or paid for.

The list is one JSON file, `${JG_HOME:-~/juggernaut}/config/model-allow-list.json`, one key per provider: `{"ollama-cloud": ["deepseek-v4.1-flash"]}`. A provider the file does not name is not limited, so the gate only ever constrains what you write down. A pinned tag of a listed model (`deepseek-v4.1-flash:1017`) is that model; any other name is not. opencode offers exactly the names in the file, so list a pinned tag too if you want it pickable there. `jg-model-gate list` prints the file, `jg-model-gate allow|deny <provider> <model>...` edits it and prints the result.

Three seams read that one list:

- **Provider.** `wiring.sh` writes the list into opencode's own per-provider `whitelist` (`~/.config/opencode/opencode.json`, key level, with a backup), so an off-list model is not in `opencode models` and cannot be picked or run there. Other providers and every other key stay untouched.
- **Dispatch.** `jg-model-gate check <provider> <model>` exits 0 for an allowed model and refuses an off-list one with one line naming the provider, the model and the file. Any harness's spawn or pool pick can call it before it starts anything; `account-pool`'s `jg-model-pool` already does, for every route it emits.
- **Launch.** An explicit `jg-spawn --model <provider>/<model>` reaches the same `check` through `bin/jg-model-gate-lib.sh` (`jg_model_gate_hook spawn-validate`), which refuses the launch with that one line before anything starts. The lib header carries the exact Juggernaut lines it needs: the source beside the account-pool hook and one call beside `jg_account_hook spawn-validate` in `bin/jg-spawn.sh`. With the feature absent the hook is a no-op and no launch is blocked; with the gate unreachable it says so on stderr and does not block.
- **Watch.** `jg-model-gate` with no arguments (the fleet check) first restores the opencode whitelist if an opencode update or a config rewrite dropped it, saying so in one line, then reads Ollama's usage per model (`/api/usage?group_by=model`) and its credit left (`/api/balance`) at pulse cadence, and warns once per off-list sighting with the credit left in the line. One read per window (`JG_MODEL_GATE_MIN_SECONDS`, default 600) and one warning per model, never a repeat.

```sh
JG_HOME=<home> bash model-gate/wiring.sh --dry-run   # then without --dry-run; --remove takes it away
bash model-gate/tests/model-gate.test.sh
```

Another provider, another harness: add that provider's key to the list and have its spawn path call the same `check`; no per-provider code. Limit: the watch has one usage reader (ollama-cloud, key read from `$OLLAMA_API_KEY_FILE` or `~/.config/ollama-cloud/api_key` — never printed, never copied), so another provider needs its reader beside it.
