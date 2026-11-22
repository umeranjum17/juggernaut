# Quota failover screen matching

## User outcome

Claude's route remains available when a worker screen contains the failover wrapper's `quota exhausted` text.
Claude's own usage-limit banner removes the route only after its one-line probe confirms the limit.
An agy worker stopped by quota moves to an eligible configured fallback after an exhausted probe and a verified exit.

## Drive

Run `done-done run quota-failover-screen-match` from the repository root.
The journey drives `core/quota-failover/quota-failover`, `bin/jg-control.sh` and `bin/jg-composer-lib.sh` in fixture homes.
It keeps both Claude screen checks and verifies the agy-to-Codex move through a simulated tmux pane with provider probes and spawn stubbed.
The same task first refuses to type into a pending agy draft, then submits `/quit` and waits for the agent to stop before relaunching in the same worktree.

## Evidence

The Claude screen captures and `result.json` record when confirmed probe output removes the route.
The agy logs record the draft refusal, probe replies, terminal input, fallback spawn and successful switch to the configured Codex model.
