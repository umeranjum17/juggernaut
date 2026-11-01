# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Juggernaut-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/jg-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue`, under the same `OPENCODE_DB` (see Session store), to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Session store | Most launches set a per-task `OPENCODE_DB`, so a manual `--continue` must run with that launch's `OPENCODE_DB=` value or it finds no session; the rule is owned by [crew dispatch profiles](../../../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson). |
| Model flag | `--model <provider/model>`. |
| Effort flag | None for Juggernaut's interactive `opencode --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and the permission-only launch is unchanged. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | For Juggernaut-generated launches, see the [OpenCode launch permission policy](../../../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson). |
| Resume by hand | A bare `opencode --session <id>` (the exit banner's resume command) carries no launch env, so it loses the permission grant; a Squad Lead's persistent `.opencode/opencode.json` keeps its inbox access (verified on 1.18.25: OpenCode loads that file from the cwd, and matches an outside read on its parent directory, so only directories can be granted, never one file). Prefer `../../../bin/jg-control.sh <task-id> relaunch`. |
| Permission prompt | Without that grant, such as after a hand restart, an outside path renders "△ Permission required" and "← Access external directory <dir>" over "Allow once   Allow always   Reject"; Enter selects the highlighted "Allow once". The same dialog serves a Read, a Write, and a bash `rm`, so only the pending tool line above it names the call; `../../../bin/jg-prompt-gate.py` owns what supervision may answer. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/jg-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `jg_composer_queued_enter_verdict` policy in `../../../bin/jg-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/jg-tmux-submit-busy.test.sh`, `../../../tests/jg-composer-lib.test.sh`, and `../../../tests/jg-backend-herdr.test.sh`.
The live Herdr guard is `JG_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/jg-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/jg-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/jg-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/jg-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/jg-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
