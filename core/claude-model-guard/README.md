# claude-model-guard

Keeps Claude Code off Fable on a host that chose that ban, while the tasks the captain lists may still run it.

- `refuse-model.sh` is the hook (UserPromptSubmit, and PreToolUse for Agent|Task): it refuses a prompt or subagent call that would run Fable, unless the session's `JG_TASK_ID` is in `allow-tasks`.
- `allow-tasks`, beside the installed hook (`wiring.sh --where` prints its path), is the one list of tasks that may run Fable: one task id per line, or a prefix ending in `*`. The captain writes it by hand; wiring never writes or removes it.
- `refuse-model.sh allowed <task-id>` answers from that list (exit 0 listed, 1 not), so the fleet pulse's Fable wake (`core/fleet-pulse/bin/fleet-fable.sh`) asks the guard instead of keeping a second list.
- `wiring.sh [--dry-run] [--install] [--config-dir <dir>]` maps the `fable` alias to Haiku and adds the hooks in Claude's user settings, at key level with a backup. The ban is a host's own choice: without `--install` a host that never installed the guard is left alone, and an installed one is brought up to date, so `bin/jg-host-wiring.sh` refreshes an install and never starts one.
- `unwiring.sh [--dry-run] [--config-dir <dir>]` removes the guard's settings keys, hook entries and executable; `allow-tasks` stays.

## Check

- `bash tests/claude-model-guard.test.sh` covers the opt-in wiring, idempotence, settings kept and never printed, the hook's refusals, the allow-tasks pass, the `allowed` query and unwiring, in throwaway HOME and XDG paths with no claude process.
