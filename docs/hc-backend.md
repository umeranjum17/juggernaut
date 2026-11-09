# Herdr Core (hc) runtime backend

Herdr Core is the headless terminal core behind the `hc` command.
Juggernaut knows `hc` as a backend name, but it cannot spawn tasks on it yet.
[`configuration.md`](configuration.md#runtime-backend-configbackend--jg_backend) owns shared backend selection and metadata semantics.

## Current support

`hc` is in `JG_BACKEND_KNOWN` and absent from `JG_BACKEND_SPAWN` (`bin/jg-backend.sh`).
Selecting it for a spawn stops with the ordinary "does not support task spawning yet" refusal.
It becomes spawn-capable only after its verify plan and required CI lane land.

The adapter, `bin/backends/hc.sh`, provides the core primitives:

- a tool check that needs `hc`, `jq` and `python3`, and refuses an `hc` older than 0.1.18;
- task terminal creation with `hc run --bg`, labelled `jg.task=<task-id>`;
- bounded history capture, screen-only visible capture, text submit, and named keys (Enter, Escape, C-c, C-u, BSpace);
- kill, which ends and then removes the terminal;
- existence, absence, and agent-liveness verdicts.

These parts are not in the adapter yet, so callers refuse or degrade for `hc`:

- busy state and the event-driven wait;
- workspace and tab placement, workspace moves, and agent naming;
- spawn, interrupt, exit, and relaunch through `bin/jg-control.sh`, which refuses `hc` today;
- nudge withdrawal, which reports `not-withdrawable`.

## Requirements

- Herdr Core 0.1.18 or newer, with `hc` on `PATH` or named by `JG_BACKEND_HC_BIN`; its installer is `https://releases.herdr.dev/core/install.sh`.
- `jq` and `python3`.

## Endpoint record

A task target is `<hc-session>:<terminal>`, for example `jg-main:t4`.
The terminal is a local address such as `t4`; a remote address such as `box/t4` is refused.
An `hc` task record carries `backend=hc`, `endpoint_task_id=<task-id>`, `hc_session=`, `hc_terminal=`, and `window=<hc-session>:<terminal>`.
Endpoint validation refuses a record whose `window` disagrees with `hc_session` and `hc_terminal`, or whose task binding is missing.

## Reads never start a core

Every `hc` client call starts a core for its session when none is running.
The adapter therefore checks that the session's socket accepts a connection before any read.
With no core listening, absence reads `uncertain`, liveness reads `unreadable`, and kill refuses, because a stopped core does not prove its programs ended.

The socket path follows Herdr Core: `HC_SOCKET`, else `$XDG_RUNTIME_DIR/herdr-core/<session>.sock`.

## Signals

A core inherits the ignored signals of the process that started it, and passes them to every program it runs.
A core started from a background job would therefore run every task with SIGINT ignored, so C-c could never stop one.
The adapter and the lab helper run every `hc` call with all signals at their default action, so a core they start never carries that state.

## Agent liveness

A finished terminal reads `dead`.
A live terminal reads `alive`, `dead`, or `ambiguous` from its foreground process, classified by `bin/jg-agent-process-lib.sh` (an agent, a bare shell, or another program).

## Isolated lab

`bin/jg-hc-lab.sh` is the only supported lifecycle helper for verification against a real Herdr Core.
Its header owns the commands and rules; in short, it:

- provisions only non-default sessions named `jg-hclab-*`;
- runs each lab core with a private runtime directory, so the socket stays inside a disposable root and the core never registers with the user's service manager;
- gives every lab terminal a disposable HOME, XDG directories, and agent credential roots, and sheds inherited Claude, Anthropic, OpenAI, Pi, and Codex overrides;
- refuses `server`, `update`, `machine`, and `connect` through `run`, and stops a core only through its own `stop` and `teardown`;
- records the user's default Herdr Core socket before provisioning and fails teardown if it changed.

`bin/jg-herdr-lab.sh` remains the lab helper for the Herdr TUI backend.
It moves fully to `HC_SESSION` in the change that retires the Herdr TUI backend; that change owns this debt.

## Verification

`tests/jg-backend-hc-live-e2e.test.sh` is the live journey.
It runs by default wherever `hc`, `jq` and `python3` are installed, and spends no model tokens.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr-core-hc) holds the dated result.
