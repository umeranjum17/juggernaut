Mode: OpenCode TUI plugin background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `jg radio drain`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run `jg radio ack <ref>` with the reference from the drain; until then the work remains durable for idempotent re-handling after interruption.
2. First cycle: let `.opencode/plugins/jg-primary-watch-arm.js` arm supervision after the OpenCode session goes idle, when `jg_supervision_needed` in `bin/jg-supervision-lib.sh` says the home needs it (X-mode homes arm regardless, and away mode declines).
3. The plugin listens for `session.idle`, spawns `script: bin/jg-watch-arm.sh --restart` without awaiting it in the idle handler, and owns every later successor launch.
4. After an actionable child close, the plugin rechecks session-lock ownership and verifies one singleton successor before it calls `client.session.promptAsync`; its bounded fallback is defined in `docs/watcher-continuity.md`.
5. Ordinary wake: do not ask the model to re-arm because continuity is plugin-owned.
6. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
7. Failure or missing cycle only: if the plugin reports a watcher failure, drain queued wakes, inspect the failure text, and use `jg radio watch-arm` manually only as a short recovery probe.
8. Never use shell `&` for watcher supervision.
   The arm mechanism above is plugin-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`.opencode/plugins/jg-primary-pretool-check.js`, `script: bin/jg-arm-pretool-check.sh`).
9. Do not rely on this plugin in headless `opencode run`; Juggernaut primary supervision targets persistent OpenCode TUI sessions.

OpenCode's persistent TUI plugin runtime is the wake mechanism.
The plugin applies in the main primary checkout and a Squad Lead's own home, and stays silent only in child operator and Recon worktrees.
