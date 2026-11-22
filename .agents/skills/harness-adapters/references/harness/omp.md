# omp (Oh My Pi)

Verified for crew, Recon, Squad Lead, and primary work on Herdr on 2026-09-05 with omp 18.1.11, building on the 2026-09-02 adapter investigation against 18.1.2.
omp is a Pi fork, so `references/harness/pi.md` is the nearest relative; every difference from Pi is stated here.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | script: `omp`, a single Bun-compiled executable resolved from `PATH` by `../../../bin/jg-spawn.sh`; a missing binary refuses the spawn. |
| Launch | Foreign markers cleared (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `JG_PI_HARNESS`, `GEMINI_CLI`, Cursor's), `JG_OMP_HARNESS=omp OMP_SKIP_SETUP=1`, then `omp --config <.omp/jg-worker-overlay.yml> --auto-approve --cwd <worktree> [--model] [--thinking] -e state/<id>.omp-ext.ts <one positional brief>`; a Squad Lead passes that same `-e` for the busy extension and still relies on auto-discovery for its primary extensions. |
| Busy state | `../../../bin/jg-busy-lib.sh` source `omp-ext`: the per-task extension marks busy at `agent_start` and idle at `agent_end` only when `willContinue` is not true; `ctx.isIdle()` is deliberately not consulted because it reads false at a natural TUI `agent_end` (`session_stop` is awaited before settle). |
| Exit command | `/quit` (`/exit` and `/q` are aliases). |
| Interrupt | Single Escape; the composer is left empty, no clear key. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <provider>/<id>` (fuzzy patterns are accepted by omp but bypass Juggernaut's pre-launch check). |
| Effort flag | `--thinking <off\|minimal\|low\|medium\|high\|xhigh\|max\|auto>`, a superset of the shared vocabulary, so every level including `max` maps straight across. |
| Model discovery | `omp models [--json]` lists built-in and auto-discovered providers only; extension-registered providers such as `claude-bridge` never appear, so those models pass through the spawn unvalidated with a stderr notice. `omp usage` shows provider windows; `quota-axi` covers the `claude` provider when the bridge is in use. |
| Marker | None of omp's own (verified: `PI_CODING_AGENT` absent from the binary, no `PI_CODING_AGENT_DIR` or `OMP_PROFILE` in the default profile). `JG_OMP_HARNESS=omp` is Juggernaut's launch marker; ancestry matches the exact process name `omp`. |
| Composer | Pinned to `composer.shape: borderless` by the overlay, a bare `❯` (U+276F) row the shared classifier already reads; busy text is `Working…` (U+2026), the only spelling the omp busy regex accepts (the three-dot form its headless `-p` mode writes never reaches a supervised pane), with the status row's braille spinner plus elapsed cell as the second signal. |
| Autonomy | `--auto-approve` owns approval (omp forces `tools.approvalMode: yolo` for the session under it); the overlay pins `plan.defaultOnStartup: false`, `prewalk.enabled: false`, `retry.usageReservePolicy: auto`. |
| Trust | No project-trust gate at all; a fresh profile shows a provider-login wizard instead, suppressed by `OMP_SKIP_SETUP=1`. |
| Resume | `-c/--continue` and `-r/--resume` exist but carry no verified pane-resume contract; use deterministic relaunch. |

Keep the instructions as one positional argument; a second positional never surfaced as a submitted message.
The openai-codex models reach an extension-registered tool through omp's `xd://` virtual-file bridge: the model reads `xd://jg_watch_arm_omp` for the description and writes `xd://jg_watch_arm_omp` to invoke it, so a transcript or rpc stream shows a `write` to that path rather than a direct `jg_watch_arm_omp` call; both are the same invocation (verified 18.1.11).
omp cold start is roughly twenty seconds to the first agent turn, paid once per worker.

## Detection

script: `../../../bin/jg-harness.sh` tests `JG_OMP_HARNESS=omp` before `CLAUDECODE`, like Cursor's markers, and its ancestry walk matches the anchored process name `omp` above the interpreter fallback.
script: The omp template in `../../../bin/jg-spawn.sh` clears every foreign marker at its own launch boundary, and `JG_OMP_HARNESS=omp` counts only under a real `omp` ancestor, so the marker inherited by any other launch is inert: an omp Squad Lead's workers keep their own identity and an inherited `CLAUDECODE` cannot outrank a worker that omp launched.
`../../../bin/jg-session-lock-lib.sh` matches the same anchored name for session-lock ownership, and `../../../bin/backends/tmux.sh` classifies it `agent` for liveness.
The optional claude-bridge extension runs a nested executable literally named `claude` as a sibling of tool execution, never an ancestor of it, so omp's own tool calls detect as omp; that subtree is never walked by a Juggernaut script.

## Worker posture overlay

The captain's own `~/.omp/agent/config.yml` is never written; the tracked `.omp/jg-worker-overlay.yml` is passed with `--config` for the one session and pins only the settings whose captain-level values would park an unattended worker on a prompt, change its pinned model, or make its composer unreadable.
script: `../../../bin/jg-spawn.sh`'s header owns the exact list and the reason for each pin.

## Extension loading

omp auto-discovers `<cwd>/.omp/extensions/*.ts` (top level only, cwd only, no ancestor walk, no trust dialog) and the active profile's `agent/extensions/`; `.pi/extensions/` is not a discovery root.
A file that is both auto-discovered and named with `-e` loads twice, so the per-task busy extension lives in `state/` and is the only `-e` a Squad Lead launch names.
The primary extensions stay auto-discovered and are not named again.
There is no `agent_settled` event; `agent_end` plus `willContinue` replaces it.

## Primary integration

script: The omp primary follows the Pi extension-owned watcher model through `../../../docs/supervision-protocols/omp.md`: `.omp/extensions/jg-primary-omp-watch.ts` arms `bin/jg-watch-arm.sh --restart` through the `jg_watch_arm_omp` tool and owns every successor, and `.omp/extensions/jg-primary-turnend-guard.ts` answers omp's blocking `session_stop` hook by forcing one continuation when `../../../bin/jg-turnend-guard.sh` returns 2, bounded per turn by omp's `stop_hook_active` flag.
The same file ports the `tool_call` seatbelts and delivers the session-start digest through `before_agent_start` on the Run tier; omp's `session_start` carries no reason, so the source is derived (first start `startup` or `resume` from the launch line, later in-process starts `clear`, `session_compact` as `compact`).
omp has no asynchronous Stop-hook equivalent, so the Claude auto-arm model does not apply; `jg_supervision_model` classifies omp as `extension`, and `jg_omp_extension_owns_supervision` in `../../../bin/jg-wake-lib.sh` is the ownership proof that tolerates the extension's own watcher hand-off.
The Pi supervision branch does not run on omp; without the supervision host every actionable wake is delivered to main, and in a home with `config/supervision-host` and no `config/supervision-host-off` the watch extension spawns the host instead of the arm, with Claude's print mode as its headless engine ([`supervision-host.md`](../../../../../docs/supervision-host.md)).
script: Launch a primary with plain `omp` inside the home (`JG_OMP_HARNESS=omp omp` when starting from a Claude pane); `../../../bin/jg-session-start.sh` prints `OMP_WATCH_EXTENSION: not loaded` when the running session has not loaded both tracked extensions.
`JG_OMP_LIVE_E2E=1 ../../../tests/jg-omp-primary-live-e2e.test.sh` is the opt-in live guard; `../../../tests/jg-omp-harness.test.sh` is the portable regression.
script: A Squad Lead registered with `remote=1` in `data/squad_leads.md`, spawned through the ordinary `../../../bin/jg-spawn.sh <id> <home> --squad-lead` path, is refused on omp until a remote host verifies it, as is `jg crew remote-squad-lead-control launch`; there is no `--remote` flag.
