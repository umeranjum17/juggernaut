# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Verified on 2026-07-27 with Pi and Pi-signed 0.82.0 unless a fact gives another version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Juggernaut-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; this covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit`. |
| Resume | `--session <path-or-id>` resumes that exact session, and creates it at that path when the file is gone. `../../../bin/jg-spawn.sh` passes it on a relaunch so a Herdr pane's already-bound status authority keeps applying (`../../../bin/jg-control-lib.sh`'s `jg_control_relaunch_resume_flag`; `../../../docs/herdr-backend.md` "Agent status authority and relaunch"). There is still no `resume` control verb. |
| Interrupt | Single Escape. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <model>`; under a home's worker account pin the model must be `<provider>/<id>` and Juggernaut also passes `--provider <provider>` (`../../../docs/configuration.md` "Worker account pin"). |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; both identities expose the same levels and completed the same model-qualified max-thinking smoke. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/jg-spawn.sh`; it is separate from Pi's thinking levels.
Pi has no permission system, so workers are always autonomous.
Fullscreen can bury steering messages by rewriting scrollback, so Juggernaut avoids it when the installed CLI supports the override.
`../../../bin/jg-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity verified on version 0.82.0.
Juggernaut records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for either selected executable.
The installed plain `pi` command also execs that signed launcher.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog can appear on the first Pi run in any not-yet-trusted directory that holds a trust-requiring resource such as `.pi/extensions/`, including a clean worktree and a freshly seeded Squad Lead home.
Accept it with Enter and verify the instructions begin processing.
The decision persists per path in `~/.pi/agent/trust.json`, or in the pinned root's `trust.json` under a worker account pin, so later spawns in the same pooled slot under that root skip it.
An unattended launch never leaves that dialog to chance: `../../../bin/jg-spawn.sh --help` owns the capability-gated project-trust approval mechanics, which send `--approve` for a seeded Squad Lead launch and for a worker launch whose copy is a managed fleet Treehouse pool slot, and never for a copy outside the fleet pool.
That launch also proves its first turn started - the busy record moving past the `jg-spawn` seed - retries the submit once, and raises one `worker-stopped` alert naming the task when it did not; [runtime verification](../../../../../docs/verification/runtime-backends.md#pi-seeded-squad-lead-project-trust) owns the regression evidence.
Never answer the dialog blind from a launch path: Enter on it can select the exit option and kill the worker.

## Worker turn-end extension

`../../../bin/jg-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
Ordinary Pi text, thinking, and tool-call streaming deltas and native-adapter progress use the separate generation-bound marker owned by `../../../bin/jg-busy-event.sh`; [watcher architecture](../../../../../docs/architecture.md#event-driven-supervision) owns activity consumption.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/jg-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/jg-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
On native Windows, the extension runs its session-start, both PreToolUse, turn-end, and operational-input Bash helpers through `bash`; macOS and Linux invoke those helpers directly.

The same turn-end extension forwards a typed (`source: "interactive"`) prompt to `../../../bin/jg-overwatch-kpi.sh hook pi`, so a captain approval typed in a Pi primary files a signed chat note; `../../../docs/verification/runtime-backends.md` owns the audit of every primary harness.

The primary watcher protocol also requires `.pi/extensions/jg-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `jg_watch_arm_pi` tool, never through a foreground shell arm.
Native-harness adapters can discover the same guarded Juggernaut tools and operational message allowlist through the public Pi event-bus contract in `.pi/extensions/lib/jg-native-contract.ts`; no Pi built-in tools cross that contract.
The tool result and clean-exit fallback are owned by `../../../docs/supervision-protocols/pi.md`.
`../../../bin/jg-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a Squad Lead is launched on Pi or Pi-signed, `../../../bin/jg-spawn.sh --squad-lead` launches the selected executable with `-e .pi/extensions/jg-primary-turnend-guard.ts`, `-e .pi/extensions/jg-primary-pi-watch.ts`, and `-e` of the parent home's `state/<id>.pi-ext.ts` busy extension.
Both primary files already exist in the Squad Lead home's git worktree.
The busy extension lives outside that home, so Pi's project-trust gate does not see it, and its turn-end handler does not touch the parent's turn-ended marker.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
