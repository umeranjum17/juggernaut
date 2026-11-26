Mode: agy background-task supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `jg radio drain`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the `jg radio ack` command when provided in the drain result; until then the work remains durable for idempotent re-handling after interruption.
2. Source `__JG_X_MODE_ENV__` first when Relay is active.
3. First cycle: arm with agy's tracked background command, as its own call:

   `run_command` with `WaitMsBeforeAsync` 500 and `IsDaemon` left false, on:
   `[ -f __JG_X_MODE_ENV_SH__ ] && . __JG_X_MODE_ENV_SH__; exec jg radio watch-arm`

4. Trust only the arm's one-line status, which agy returns before the command moves to the background or, once it is a background task, in the task log the tool result names.
5. `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the background task follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The background arm remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent.
9. Never use shell `&` for Juggernaut supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (script: `bin/jg-arm-pretool-check.sh --agy`) registered in this project's `.agents/hooks.json`.

agy wakes the session with a `<SYSTEM_MESSAGE>` naming the arm's task (`Task id "<id>" finished with result:`) and carrying its output when the background arm exits.
When you see that message for the arm:
1. Run `jg radio drain` first.
2. Read the reason line from the task output in the message, or from the task log it names.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same background `jg radio watch-arm` call if the home still needs supervision, as `bin/jg-supervision-lib.sh` defines it.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records, the drain's `QUEUED`, `PAGES` and `OPEN DECISIONS` entries, or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

The `.agents/hooks.json` Stop hook runs script: `bin/jg-turnend-guard-agy.sh` as a backstop, not the normal wake path.
When supervision is needed and no live watcher holds this home, it keeps the turn going once with the repair line as a system message; [`turnend-guard.md`](../turnend-guard.md) owns that contract.
After that forced continuation, arm the watcher with the background protocol above.

The interactive TUI is the supported agy primary surface; do not run the primary Juggernaut as a one-shot `agy -p` process.
