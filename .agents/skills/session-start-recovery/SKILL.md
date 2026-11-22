---
name: session-start-recovery
description: Load when the session-start digest reports unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
user-invocable: false
metadata:
  internal: true
---

# Session-start recovery

The digest itself makes no external-network call and never waits for one.
script: Every network check a session start owes - GitHub auth, dead Squad Lead relaunch, Squad Lead convergence, pending handoff delivery, and project clone refresh - runs off the digest's blocking path in a bounded worker owned by `bin/jg-startup-network.sh` and is reported in the digest's own `NETWORK CHECKS` section.
The locked startup inactive-outcome scan joins that worker so a slow local current-state read cannot block the digest; its findings use the ordinary durable wake queue.

1. **Lock** - acquires the per-home session lock first, before anything mutates shared state, then starts the deferred startup stage above.
2. **Bootstrap** - detect-only checks (tool/version problems, the worktree-tangle check, harness override, dispatch-profile validation) always run, but routine confirmations stay silent by default.
   When the lock could not be acquired, the worktree-tangle check uses read-only advisory wording without a checkout repair command.
   Home-local stale Herdr projection cleanup and the six bootstrap MUTATING sweeps - same-home backlog reconciliation, fleet sync, Squad Lead convergence, Squad Lead liveness, pending remote handoff retry, and Relay artifact writes - run only when this session actually holds the lock from step 1; the four network ones among them run in the deferred stage rather than in this section.
   script: The Squad Lead liveness sweep deterministically accounts for every registered Squad Lead: it relaunches only from the recovery-grade `dead` or `missing` states, preserves ambiguous, unreadable, or unreachable remote targets, and reports skipped or failed guarantees as `SQUAD_LEAD_LIVENESS:` lines (`bin/jg-bootstrap.sh`; `bin/jg-backend.sh`'s `jg_backend_agent_state`; `docs/remote-squad-leads.md`).
   Ordinary supervision continues the same guarantee through the watcher's cadence-gated liveness tick over the shared `bin/jg-squad-lead-liveness-lib.sh`, so a mate that dies mid-session is relaunched without waiting for the next session start.
3. **Wake queue** - when locked, drains and presents the durable wake queue without running the inactive-outcome scan inline, and prints the raw records prominently as this turn's first work queue; a clearly labeled status-event annotation may follow a valid `signal` record and includes every status line still unread at the presentation cursor, but never replaces the raw record or current-state reconciliation, and a lapsed watcher chain still surfaces here via the same guard alarm.
   Presented records remain durable until the handling turn runs the generation-bound acknowledgement printed by the drain.
   Every locked drain also prints a bounded `OPEN DECISIONS` section when decisions remain open (from the store's open questions where Main reads from the store, else folded from the status logs), including when the queue itself is empty; reconcile those entries before continuing.
   A main drain may also print a bounded, one-shot `STATUS OUTCOME BACKSTOP` when a task's newest captain-facing status event has no covering supervision-branch outcome; handle it as a recovered wake even when no queue row remains.
   Where Main reads from the store (`config/item-store-reads`), the drain lists each queued record's reason line under `QUEUED`, then prints Main's unread store pages under `PAGES` (`jg-item pages main`, at most 200 lines and 32 KiB from Main's cursor), the store's open questions under `OPEN DECISIONS`, and any disagreement between today's records and the store under `RECORD DIVERGENCE`; its one acknowledgement also moves the page cursor, so a page is never re-printed and weeks-old status lines do not come back. A home without that file prints every still-unread `note:` line and pending-reply resolution in an unbounded status section instead.
   When the lock could not be acquired and verified, the queue is left untouched because no session mutation is authorized, and the guard's tangle/watcher-liveness alarms still print in read-only advisory mode without drain, supervision repair, or checkout repair commands.
4. **Supervision operating instructions** - after the wake queue and before both digests, the digest emits exactly one operating block for the detected primary harness, followed by the read-once contract that governs them.
   The script itself never starts supervision; the emitted harness protocol owns the exact wait or wake mechanism.
5. script: **Fleet-state digest** - after that read-once contract and ahead of the context digest, the compact backlog listing owned by `bin/jg-session-start.sh`; every `state/<id>.meta`; a bounded tail of each task's `state/<id>.status` (labeled as wake-EVENT history, not current state, with the full log path printed for a deeper read); the away or quiet posture (`state/.afk-contract`, plus the `state/.afk` daemon flag where a daemon runs); and one cheap alive/dead read of each task's recorded backend endpoint.
   That liveness line is a fast presence check only, not a full state read - when you need a crew's actual current state (a run-step, not just "is the pane there"), read it with `jg crew crew-state <id>` as before; the digest deliberately skips that deeper, slower read for every task so it stays fast and bounded.
6. **Network checks** - after the fleet-state digest, the deferred stage's result, or an explicit statement of what it has not confirmed yet.
   A read-only session runs no network checks at all and says so.
7. **Context digest and next step** - last of the bulk sections, the full contents of `data/projects.md`, `data/squad_leads.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, each clearly delimited, followed by the closing reminder.
   A file that does not exist prints an explicit `ABSENT` marker, never confused with an empty-but-present file: absence is meaningful (`captain.md` absent means use the Juggernaut repo's built-in defaults, `projects.md` absent means rebuild it from the clones under `projects/`, etc.).
   The closing reminder points back to the emitted supervision block and preserves only the lock, afk, Relay, and read-once reminders.

Bootstrap detects first, asks for consent, and installs only after the captain approves in the current session.
script: Do not dispatch until the essential launch tools are present and GitHub authentication is good (not probed while every registered project is local-only, per `bin/jg-bootstrap.sh`); presentation availability follows `bootstrap-diagnostics` and does not block nonvisual work.
Use `gh-axi` for GitHub, `chrome-devtools-axi` for browser work, and compatible `sign-off-axi` for visual decisions or reports; consult current help rather than memorizing flags.
A silent bootstrap section needs no action; for any printed actionable diagnostic line, load `bootstrap-diagnostics` and follow its owner procedure.
`BOOTSTRAP_INFO:` lines are completed no-action facts and do not require loading a skill.
`squad-lead-provisioning` owns startup Squad Lead sync, liveness, and inherited local-material convergence.
