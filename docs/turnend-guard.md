# Primary turn-end supervision guard

This doc explains the check that stops a primary Juggernaut session from ending a turn while its work has no live supervision, and how each harness enforces that check at its turn boundary.
It is for operators working out why a turn end was blocked or followed up, and for anyone changing a harness turn-end hook.

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/jg-turnend-guard.sh`.
Primary scope lives in `bin/jg-primary-scope-lib.sh`, shared with the native session-start adapters in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Find a topic

| Question | Start here |
| --- | --- |
| What the guard enforces | [Current invariant](#current-invariant) |
| A correction no rule or ticket captured | [Owner-correction capture rule](#owner-correction-capture-rule) |
| Which sessions are in scope and what counts as supervision need | [Primary scope](#primary-scope) and [supervision need](#supervision-need) |
| How the turn-end check and the mid-turn pull warning judge watcher health | [Strict watcher check at the turn boundary](#strict-watcher-check-at-the-turn-boundary) and [pull-warning verdict by supervision model](#pull-warning-verdict-by-supervision-model) |
| Away and quiet mode | [Away and quiet mode daemon ownership](#away-and-quiet-mode-daemon-ownership) |
| How long a beacon stays fresh | [Guard grace and the poll cadence](#guard-grace-and-the-poll-cadence) |
| How each harness blocks or follows up | [Harness integrations](#harness-integrations) |
| Claude's Stop auto-arm cooperation, block budget, and fail-open | [Claude cooperative mode](#claude-cooperative-mode) |
| Cursor's parked hook | [Cursor park](#cursor-park) |
| Known gaps | [Compatibility limits](#compatibility-limits) |
| Tests and live evidence | [Regression coverage](#regression-coverage) |

## Current invariant

`bin/jg-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.

The guard acts at that boundary when both of these hold:

- Work, a process-event source, a registered custom check, or Relay polling needs supervision.
- No identity-matched watcher has a fresh beacon.

The beacon is `state/.last-watcher-beat`, which `bin/jg-watch.sh` touches every cycle, as [Guard grace and the poll cadence](#guard-grace-and-the-poll-cadence) describes.
When the guard acts, the harness integration must do one of two things:

- Block the turn end.
- Force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.

The mid-turn pull warning uses the model-aware supervision verdict described below, while the turn-end guard keeps the PID-strict watcher predicate.

Away and quiet mode are the one place the turn-end guard accepts a different supervisor.
While `state/.afk` exists, in either mode (`bin/jg-wake-lib.sh`'s `jg_afk_mode`), the daemon owns supervision.
A live identity-matched daemon with a fresh beacon then satisfies that boundary in place of a watcher process holding the lock.

The guard remains a backstop.
[`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Overwatch KPI rule

The captain should come only for a major decision only he can take or to file new work, so every captain message is tagged in the turn it arrives.
At the same boundary, before the supervision predicate, the guard blocks while the newest captain message `bin/jg-overwatch-kpi.sh` recorded is untagged, with one exit-2 banner naming its `tag` command.
It is charged once per message, recorded in `state/.overwatch-kpi-flagged`, and a primary whose harness has no prompt hook records nothing, so it is never blocked.

## Owner-correction capture rule

The owner's standing rule (`data/owner-rules.md`) is that a correction he gives in chat must not stay a one-time fix, so the turn that follows one must leave something the whole system reads.
At the same boundary, after the KPI rule, the guard asks `bin/jg-owner-correction.sh` whether the recorded correction is captured, and blocks once per correction when it is not.
The correction is the newest captain message whose newest KPI tag kind is `feedback` or `micromanagement`.
That tag is the record this fleet already keeps for "he told us how to work", so the trigger is that record and never the guard's reading of his tone, and the KPI rule above has already required it.

Either artefact captures it, and both are commands that already exist:

- A rule: `data/owner-rules.md` was written at or after the correction, which `bin/jg-owner-rules.sh add` does, and that same call files the rule's enforcement ticket so the work does not sit in the surface alone.
- A ticket: the backlog holds a row created on or after the correction's UTC date, or `data/ticket-counters.tsv` was written at or after it, which `bin/jg-tasks-axi.sh add` does.

A turn that writes either artefact ends normally, and the charge (`state/.owner-correction-flagged`) keeps every harness bounded to one block per correction; a home whose harness records no captain message records no correction, exactly as for the KPI rule.
The check ships from this repository's own `bin/` with the guard, so a home that fast-forwards gets both, and a home whose guard runs without `bin/jg-owner-correction.sh` - or whose copy cannot answer - is never read as "nothing pending": the guard prints a `THIS HOME HAS NOT PICKED UP OWNER-CORRECTION CAPTURE` banner once (`state/.owner-correction-unavailable`) instead of pretending it ran.

## Guard predicates

The turn-end guard checks primary scope first, then supervision need, then watcher health.
The mid-turn pull warning in `bin/jg-guard.sh` judges watcher health differently, as described under [pull-warning verdict by supervision model](#pull-warning-verdict-by-supervision-model).

### Primary scope

The guard first calls the shared primary scope.
A Squad Lead home runs its own primary Juggernaut session, so a genuine `.jg-squad-lead-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must meet both of these conditions:

- It is a regular non-symlink file.
- Its whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.

An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps operator and Recon linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

### Supervision need

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
These sources also count toward supervision need:

- Registered `state/procevent/*.source` records require supervision even though they have no task metadata.
- Every mode treats `state/x-watch.check.sh` as supervision need, so Relay polling remains guarded without an in-flight task.
- A custom check registered with `bin/jg-check-register.sh` counts the same way, so an operator's home-level poll keeps running after the last task is torn down.

The default cross-harness mode exits silently with no supervision need.

### Strict watcher check at the turn boundary

Otherwise the guard calls `jg_watcher_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/jg-wake-lib.sh`.
It is the same PID-strict identity-matched lock and fresh-beacon check used by `bin/jg-watch-arm.sh`.
Under that check:

- A stale beacon blocks even when a watcher pid is live.
- A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

The turn-end guard needs that strict check because it fires at the turn boundary.
At that boundary the auto-arm is bringing a fresh watcher up for the upcoming idle period.
The guard cooperates with that arm rather than trusting a beacon left by the cycle that just ended.

### Foreign session-lock owner

When an active home instead has a live session lock held by a verified harness that the current session does not own, the Claude guard emits a read-only ownership diagnostic and allows the turn to end safely.

Ownership is the shared `jg_session_lock_owned_by_self` verdict in `bin/jg-session-lock-lib.sh`.
The current session owns the lock when either of these holds:

- The recorded pid is a member of the current session's contiguous harness ancestry.
- The trusted Claude session id recorded beside the lock in `state/.lock-session` matches this hook's own environment while the recorded pid is still a live harness.

That second signal keeps a background Claude session owning its own lock after the transient helper chain between its hooks and its recorded owner is recycled.
The library's header owns the trust gate (`CLAUDE_PID` must be a Claude-shaped member of the current run).
`bin/jg-lock.sh` owns the sidecar and the line-1 anchor it records for such a session.

A Claude session that does not own the lock cannot arm or repair the home without stealing the live owner's lock, so blocking it would create an unbounded loop.
The lock-owning session remains responsible for restoring supervision.

The exception has these limits:

- Malformed, absent, dead, or ancestry-uncertain lock records do not satisfy this Claude-specific exception and retain the ordinary guard behavior.
- A missing or mismatched sidecar or an untrusted id adds nothing to the verdict, so a live owner outside the ancestry still takes this exit exactly as before.

### Pull-warning verdict by supervision model

`bin/jg-guard.sh`, the pull warning, instead uses the model-aware `jg_watcher_supervision_verdict` from `bin/jg-wake-lib.sh`.
It needs a different verdict because it fires mid-turn, when the auto-arm model runs no watcher at all.
The verdict depends on the supervision model.

#### Claude Stop auto-arm model

Under the Claude Stop auto-arm model a beacon fresh within grace is healthy even with no live watcher process.
A stale beacon is still healthy while `jg_autoarm_midturn_healthy` in `bin/jg-wake-lib.sh` proves a Claude rewake explains the mid-turn gap.
That proof requires both of these:

- The rewake is bound to the current recovery generation and live session-lock owner.
- No later watcher beacon or exhausted-failure marker supersedes it.

The tolerance holds because that session's turn-end will re-arm.
Without that proof a stale or absent beacon is a genuine lapse and alarms.

#### Extension model

Under the extension model (Pi, pi-signed, and omp) a live identity-matched watcher is the ordinary healthy state.
A genuinely unheld lock with a beacon fresh within grace is also healthy while a live Pi or omp session provably owns continuity.
That hand-off is benign because `.pi/extensions/jg-primary-pi-watch.ts` and `.omp/extensions/jg-primary-omp-watch.ts` tear the watcher down on every actionable wake and spawn the replacement themselves.

A lock is genuinely unheld only in one of these cases:

- The lock directory or its symlinked owner directory is absent.
- The existing lock records no pid at all.

Any lock with a recorded pid remains down when its pid, home, watcher path, or process identity fails the strict watcher health check.

That ownership proof is `jg_extension_owns_supervision` in `bin/jg-wake-lib.sh`.
It accepts either the Pi pair (`jg_pi_extension_owns_supervision`) or the omp pair (`jg_omp_extension_owns_supervision`).
The proof requires all of these:

- Both primary extensions of one family must be recorded in their state markers at their current on-disk builds by the process named in `state/.lock`.
- That process must still be alive.
- Pi's watcher marker must additionally name an active generation rather than a retiring handoff.

omp never inherits the Pi tolerance because its proof is keyed on its own two files and markers.
Requiring the turn-end guard extension as well as the watch extension is deliberate, because a home without that structural backstop has no benign hand-off to tolerate.

Without that proof an unheld lock alarms exactly as it did before.
An unloaded, version-drifted, or exited Pi or omp session is therefore loud immediately.
A cycle the extension never restores is loud once the beacon passes grace.

#### Persistent-watcher harnesses

Under every persistent-watcher harness a live identity-matched watcher with a fresh beacon is still required, so the pull guard keeps the same strict semantics there.
Its banner names the true failing condition, either a missing live watcher process or a genuinely stale beacon with its real age.
It keys the once-per-episode dedup on that condition rather than the beacon mtime.

### Away and quiet mode daemon ownership

While `state/.afk` exists the daemon (`bin/jg-supervise-daemon.sh`) owns supervision and runs the watcher one-shot, in either away or quiet mode.
The watcher exits on every wake and the daemon starts its replacement.
A turn boundary therefore regularly lands in a hand-off where no watcher process holds the lock and nothing is wrong.

The turn-end guard therefore accepts `jg_afk_daemon_owns_supervision` from `bin/jg-wake-lib.sh` as proof of supervision on that path.
The proof requires both of these:

- `state/.afk` must exist; the predicate does not distinguish away from quiet mode.
- This home's `state/.supervise-daemon.lock` must name a live pid whose current process identity still matches the identity the daemon recorded for itself.

That is the same identity discipline the watcher lock uses.
A recycled pid, a lock left behind by a killed daemon, and a daemon that never recorded its identity all fail it.

A daemon that cannot record its own identity at startup logs a warning and keeps running, because a supervisor must not refuse to run over an unreadable `ps`.
That warning is what names the cause when the guard then keeps blocking away/quiet-mode turn boundaries for the rest of that daemon's life.

The proof covers ownership only, never freshness.
The guard still requires a fresh beacon, with these results:

- A daemon that stops restarting its watcher still blocks once the beacon passes grace.
- A home with no daemon and no watcher blocks exactly as it did before.

That beacon check uses the poll-derived grace described below rather than the flat `JG_GUARD_GRACE` default.
It uses that grace because the daemon starts a fresh one-shot watcher only after it finishes handling the previous wake.
That handling can legitimately outrun a fixed 300-second window under load (a slow registered check, a busy supervisor pane) with the daemon perfectly healthy throughout.

With `state/.afk` absent the daemon lock proves nothing and the strict watcher predicate is unchanged.

### State directory, grace, and missing input

- `JG_STATE_OVERRIDE` wins over `JG_HOME/state`, and `JG_HOME` wins over repository-root `state/`.
- `JG_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds.
- If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

### Guard grace and the poll cadence

Only `bin/jg-watch.sh` publishes `state/.last-watcher-beat`: it clears the predecessor's beacon when it acquires the singleton and publishes a fresh one after completing its supervision scan, immediately before its terminal wait (`event_wait_or_sleep`), or as it exits on a delivered actionable wake.
Startup confirmation therefore requires resumed supervision.
That exit beacon is written after the cycle releases the singleton lock and only when the wake was delivered, so a busy home whose every cycle ends early still reads as supervised for one grace window; a killed or evicted watcher leaves none.
The replacement clears that beacon at start like any other, so it never announces recovery while its checks are blocked.
A healthy watcher's beacon ages through the terminal wait and the following scan, so slow task checks also count toward its age.

A fixed 300-second grace default stops correctly bounding staleness once a home's `JG_POLL` reaches or exceeds it.
A perfectly healthy watcher mid-wait would then read stale at the edge of every full poll cycle by definition.
That is exactly what a long-poll home (`JG_POLL=300`) hit against the Claude Stop-hook auto-arm (`bin/jg-claude-stop-autoarm.sh`).

Two readers derive their default grace from the configured poll instead of a bare constant:

- That hook.
- `bin/jg-watch.sh`'s own pre-acquisition staleness check (the "lock held by live pid but heartbeat is stale" refusal).

Both use `max(300, JG_POLL + 60)`.
The default never drops below the historical 300-second floor for the common short-poll case, but grows with the poll cadence once that cadence would otherwise outrun it.
`jg_poll_derived_grace` in `bin/jg-wake-lib.sh` is the single owner of that formula.

That refusal has a ceiling.
Once the live holder's beacon is stale past `JG_WATCHER_STALL_BOUND` (default three times the grace), or its lock's PID record reaches that age without a first beacon, the re-arm takes these steps:

1. It re-verifies the holder against the lock's recorded identity.
2. It retires the holder and its recorded descendants, matching each child's PID and start identity even after reparenting; unrelated or reused PIDs are protected.
3. It permits replacement only after those identities are retired, keeping lock reclamation serialized through TERM-to-KILL escalation, concurrent re-arms, and retries after interrupted eviction.

The watcher records descendants while the holder is alive so a check timeout cannot erase ownership by orphaning a child before recovery.
`tests/jg-watcher-lock.test.sh` covers delayed recovery and resumed task checks; `tests/jg-watch-arm.test.sh` covers concurrent re-arms and interrupted child retirement.

A watcher wedged mid-cycle can therefore no longer refuse every replacement indefinitely.
`bin/jg-watch.sh`'s header owns the exact wording and the survives-TERM fallback.
Below that bound a stale beacon alone does not end an attached arm's watch of a live, identity-matched holder; a changed lock can end it sooner.
At the bound the arm reports a typed stalled-holder failure so its owner's retry can replace the holder.
`jg_watcher_stall_bound` in `bin/jg-wake-lib.sh` owns the shared derivation; `bin/jg-watch-arm.sh`'s header owns the exact attached-arm close behavior.

The auto-arm hook additionally exports its resolved `JG_GUARD_GRACE` when it forks `bin/jg-watch-arm.sh`.
The arm wrapper and the watcher it may start then judge staleness with the exact same value the hook just judged it with, whether that value came from an operator override or the poll-derived default.

`bin/jg-turnend-guard.sh`'s daemon-ownership branch (`jg_afk_daemon_owns_supervision`, above, covering both away and quiet mode) also derives its beacon grace from `jg_poll_derived_grace` rather than falling back to the bare 300-second default.
The reason is the same.
The daemon's watcher-restart cadence there is not a fixed poll loop, so a flat grace misreads a daemon that is genuinely still cycling as down.

Every other direct `JG_GUARD_GRACE` reader still falls back to the bare 300-second default unless `JG_GUARD_GRACE` is set explicitly in the environment.
Those readers are:

- `bin/jg-guard.sh`.
- The strict-watcher checks in `bin/jg-turnend-guard.sh` and its harness-specific wrappers.
- `bin/jg-wake-lib.sh`.

## Harness integrations

Each enabled primary harness adapts its own turn-end mechanism to the shared guard.

| Harness | Turn-end hook | How it enforces the guard |
| --- | --- | --- |
| Claude | Two `Stop` hooks in `.claude/settings.json` | Blocks with exit status 2, cooperating with the Stop auto-arm |
| Codex | `Stop` hook in `.codex/hooks.json` | Blocks with exit status 2 |
| OpenCode | `session.idle` in `.opencode/plugins/jg-primary-turnend-guard.js` | Passive callback that schedules one follow-up |
| Pi | `agent_settled` in `.pi/extensions/jg-primary-turnend-guard.ts` | Passive callback that schedules one follow-up |
| omp | `session_stop` in `.omp/extensions/jg-primary-turnend-guard.ts` | Blocking hook that compels one continuation |
| Cursor | `stop` hook in `.cursor/hooks.json` | Cannot block, so it parks and returns at most one follow-up |
| Grok | `Stop` hook in `.grok/hooks/jg-primary-turnend-guard.json` | Native blocking, or one legacy `grok --resume` fallback |

The registrations in detail:

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/jg-turnend-guard.sh --claude`, and `bin/jg-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
  In a Claude Squad Lead home, `bin/jg-spawn.sh` writes a `.jg-busy-stop` pointer and gives the mate no `Stop` busy hook, so `--claude` is the only Stop writer of the parent home's busy record for that generation.
  It records idle when it allows the Stop and busy when its exit 2 blocks it into a continuation, because Claude runs Stop hooks in parallel and that continuation fires no `UserPromptSubmit`.
  A home whose guard predates `.jg-busy-stop` cannot close the turn, so that launch keeps the ordinary `Stop` idle hook instead.
  [Runtime backend verification](verification/runtime-backends.md#squad-lead-busy-contract) owns the live evidence.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Juggernaut-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/jg-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/jg-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- omp answers its blocking `session_stop` hook in `.omp/extensions/jg-primary-turnend-guard.ts`, passing the payload's own `stop_hook_active` to the shared guard.
  When the guard returns 2, it returns `{ continue: true, additionalContext }`, so the continuation is compelled rather than requested.
  The continuation's stop carries `stop_hook_active: true`, which bounds it to one per turn, and omp's own cap of eight consecutive continuations is the second backstop.
  `session_stop` never fires for an interrupted turn or a task session, so those boundaries are deliberately unguarded.
- Cursor registers a `stop` hook in `.cursor/hooks.json` and delegates the whole turn boundary to `bin/jg-turnend-guard-cursor.sh`, the park described below.
  Cursor also loads `<project>/.claude/settings.json`, so every tracked Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload through `bin/jg-hook-host-lib.sh`.
  That predicate reads the delivered payload's own `cursor_version`, never the environment.
  Cursor exports `CURSOR_INVOKED_AS`, `CURSOR_PROJECT_DIR`, and `CURSOR_VERSION` into every child process, so an environment guard would also disable the hooks of a Claude session started by hand from a Cursor pane, which is the hazard the `GROK_SESSION_ID` exclusion below records.
  The guarded set is the `SessionStart` entry, the two `PreToolUse` Bash entries, and both `Stop` entries.
  Cursor 2026.08.11-e8db854 does not fire the Claude-shaped `Stop` entry at all, but it is guarded anyway because Cursor has no `asyncRewake`.
  If a later build did fire it, `bin/jg-claude-stop-autoarm.sh` would run synchronously inside Cursor's stop step and hold that turn open for its declared multi-hour timeout, exactly the wedge grok 1.0.0 produced.
- Grok registers a `Stop` hook in `.grok/hooks/jg-primary-turnend-guard.json` and delegates capability selection to `bin/jg-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` or `GROK_HOOK_EVENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.
  Both markers are required because Grok does not inject the same variables into every process kind.
  grok 0.2.73 set `GROK_AGENT` for child and tool processes, while grok 1.0.0 hook processes carry `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` but no `GROK_AGENT`.
  A guard keyed on `GROK_AGENT` alone therefore stopped firing on grok 1.0.0, and the resulting Claude-only auto-arm ran synchronously under Grok.
  Grok has no `asyncRewake`, so it waited on the foregrounded watcher for the declared 28800-second timeout and the Grok turn never ended.
  Do NOT widen this guard to `GROK_SESSION_ID`: Grok injects that into every child process, so it can survive into a Claude session that Grok launched and would silently disable Claude's own continuity.
  The same marker guard carries every tracked `.claude/settings.json` entry whose event Grok already covers through its own `.grok/hooks/` registration, which is both `Stop` entries, the `SessionStart` entry, and the two `PreToolUse` Bash entries.
  `bin/jg-subagent-pretool-check.sh` is the one deliberate unguarded exception because no Grok registration covers the subagent-spawn event, recorded in [`subagent-guard.md`](subagent-guard.md) "Known residual gap".
  `tests/jg-turnend-guard.test.sh` pins that inventory so neither the guarded set nor the exception can change silently.
- pi-code, Pi's Claude-hook compatibility extension, also loads `<project>/.claude/settings.json` and has no `asyncRewake`, so it awaits every Stop hook it delivers.
  `bin/jg-claude-stop-autoarm.sh` therefore stands down on a pi-code-delivered payload.
  Otherwise its foreground arm would run synchronously and hold Pi's turn open for the declared multi-hour timeout, exactly the wedge Cursor and grok 1.0.0 would produce (issue #3343).
  Pi's own native extensions own its supervision.
  The discriminator is the payload's own `transcript_path`, not the environment and not the shared foreign-host predicate above.
  pi-code stamps it with Pi's session file under `/.pi/`, a path component a Claude transcript never carries.
  The stand-down fails toward running, matching the guards above, so no payload, no `jq`, or no `transcript_path` still arms, and every other Claude-shaped hook pi-code delivers keeps running.

### Claude and Codex blocking

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

### Claude cooperative mode

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes.
Under the default one-shot behavior, that re-opened the 2026-07-21 blind window.

Before the Claude cooperative budget can re-block a Stop, the guard checks for a live foreign session-lock owner and takes the same safe diagnostic exit described under "Guard predicates" ([foreign session-lock owner](#foreign-session-lock-owner)).

The Claude mode waits up to `JG_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds).
It allows the stop when any of these holds:

- The watcher is healthy.
- The auto-arm's generation claim is open.
- `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.

#### Auto-arm generation claim

The claim is the ledger entry itself.
The ledger is `state/.claude-autoarm-epoch`:

- Its epoch sequence is a monotonic claim generation.
- Line 1 records the claim and terminal outcome.
- Line 2 records the claiming process's mandatory pid-identity.

`jg_autoarm_claim_open` and `jg_autoarm_claim_next` in `bin/jg-wake-lib.sh` own the format contract.

A claim is open while all of these hold:

- Its outcome is `arming`.
- Its owner pid is alive.
- Its recorded identity successfully recomputes and matches that pid.
- It is not stuck.

Stuck means the entry and the watcher beacon are both older than the guard grace, which proves the owner hung mid-arm.
A healthy hours-long foregrounded cycle keeps the beacon beating, and every arming phase with no watcher is bounded in seconds.

Anything else lets the next Stop-owned firing take the next generation and arm.
That covers a finished outcome, a dead or identity-mismatched owner, a stuck owner, an identityless entry, or no entry.
Taking a newer generation is the reclaim, and a steady-state predecessor is never signalled or revoked.

No mutex is held across arming or output.
`state/.claude-autoarm.lock` survives only as a micro-mutex serializing individual ledger writes.
A superseded owner goes completely silent.
Ownership is re-verified before every arm invocation, episode-state mutation, ledger write, and continuation.

#### Exit status as the commit point

The irrevocable commit point of a translation is the exit status, because the harness delivers the collected stderr banner only on exit 2.
An owned terminal commit therefore decides the exit:

- Markerless outcomes commit with the ledger write.
- The once-per-episode failure notice commits only when its marker is created after the winning failed write in the same critical section.

A generation whose required marker cannot be created is refused and exits 0 silently even after printing.
Its terminal ledger entry is superseded by a later firing, which retries the notice.

#### Why the claim boundaries exist

Without those boundaries, two failures occurred:

- A cycle that armed, delivered one rewake, and exited left both Stop participants deferring to its leftover lock indefinitely.
  On 2026-08-14 two tasks were in flight, a beacon was 40 minutes cold, and every turn was blind until an operator intervened.
- A hook that hung mid-arm kept a live pid on the lock, so the watcher was never auto-re-armed again (2026-08-26).

Two bounded residuals are accepted intent, each costing at most one extra continuation turn absorbed by the durable idempotent wake queue:

- An owner that dies between its owned terminal write and its own process exit.
- A hung old-build owner that resumes during the one legacy upgrade window.

A legacy build's lock-holding claim (recognizable by its `autoarm` role file) still defers or reclaims under the legacy abandonment proof.
A live identity-verified stuck legacy owner is retired via TERM before its lock is removed, and an unverified pid is never signalled.
An upgrade mid-session can therefore neither double-arm nor deadlock, and a failed reclaim re-blocks rather than allowing a blind stop.

#### Failure progression and block budget

Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.

The foreground arm legitimately follows a healthy watcher until its next wake.
The hook therefore catches HUP, TERM, and INT from host timeout or teardown and commits the ordinary durable failed outcome and failure-notice marker before exiting 2 for a recovery turn.
Claude drops that exit 2 when it terminated the hook at the configured timeout itself, so a park that outlives the timeout ends without a rewake (`bin/jg-claude-stop-autoarm.sh` header).

The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count.
Later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, the guard re-blocks up to `JG_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override).
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.

The block budget is charged by two rules:

- Each epoch identity is charged at most once per Stop under the budget lock.
- A re-block against an epoch the auto-arm did not advance past the previous re-block is charged as well.

That second rule still bounds an inert auto-arm when a hook never fires or fails before its generation claim and therefore leaves the ledger frozen at its last outcome.
Charging only epoch changes let the count freeze with that ledger, so the remaining inert-hook cases could re-block without limit and make the attended fail-open unreachable.
`budget_account_current_epoch` in `bin/jg-turnend-guard.sh` owns the rule.
A verified live foreign session-lock owner takes the earlier diagnostic safe exit instead and never reaches this budget path.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.

#### Attended fail-open

The one loud attended fail-open is available only when all of these hold:

- The auto-arm has recorded an exhausted failure.
- Its one notice is already consumed.
- The block budget is exhausted.
- A final check finds neither a healthy watcher nor an automatic continuation.

After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

### Passive adapters

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session.
When the predicate blocks, they schedule one bounded follow-up.
omp is the exception among the Pi-derived harnesses: its `session_stop` hook blocks like Codex's `Stop` hook, so no passive latch is needed and the `stop_hook_active` loop guard applies unchanged.

The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `JUGGERNAUT_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch:

- Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
- OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

### Grok capability selection

Grok makes exactly one typed capability decision from each running Stop payload:

- A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
- The camel-case field has precedence when both spellings appear.
- When it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
- When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
- Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.

The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`.
Genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

### Cursor park

Cursor cannot block a turn end at all.
Its blocked-response mapper returns an empty object for the `stop` step, so exit 2 is a silent no-op, verified both statically and live.
`bin/jg-turnend-guard-cursor.sh` therefore never exits 2 and never writes a banner expecting it to be read.
Every path exits 0, and its only channel is at most one `followup_message` on stdout.
Cursor runs that hook synchronously and awaits it, so one script owns both halves of the boundary.

While supervision is needed it PARKS:

1. It runs `bin/jg-watch-arm.sh` as its own tracked child.
2. It holds the boundary open until the watcher closes.
3. It returns an actionable close as one `watcher`-kind follow-up.

It spends no model tokens while parked.
This is the same between-turns shape as Claude's Stop auto-arm, so `jg_supervision_model` classifies Cursor as `autoarm` and the mid-turn pull guard accepts a fresh beacon without a live watcher.

#### Cursor park under a Pi host

The park stands down without arming when `PI_CODING_AGENT=true` and neither `CURSOR_AGENT` nor `CURSOR_INVOKED_AS` is set.
Pi-with-Cursor-provider sessions (pi-cursor-sdk) load project `.cursor/hooks.json` into the Pi process.
A Cursor park there would race Pi's extension-owned `jg_watch_arm_pi` continuity, resurface rearm wakes, and abort in-flight asks.
`jg-spawn`'s cursor launch clears `PI_CODING_AGENT`.
A hand-started cursor-agent may still inherit it.
When either Cursor identity marker is present, the park still runs despite a leaked `PI_CODING_AGENT`.

#### Cursor repair nag and loop bounds

When the park cannot establish a cycle it asks this shared guard with `--cursor` and renders a returned exit 2 as one bounded `turn-end-guard` follow-up.
Those nags are capped by `JG_CURSOR_TURNEND_BLOCK_BUDGET` (default 3) consecutive unproductive nags per session.
A delivered wake resets that budget because it is productive work.

The follow-up loop is bounded TWICE, because either bound alone is insufficient:

- `loop_limit` in `.cursor/hooks.json` is Cursor's own ceiling and the only one that still holds if the adapter is broken or replaced.
  Once `loop_count` reaches it Cursor stops invoking the hook, verified live.
- `JG_CURSOR_TURNEND_LOOP_CEILING` (default 180) bounds the payload's `loop_count` from inside and sits deliberately BELOW the registered `loop_limit`.
  Juggernaut's bound therefore bites first and emits one final loud notice instead of supervision going silently dark at Cursor's ceiling.

`loop_count` is Cursor's richer analogue of `stop_hook_active`.
Its behavior was verified live:

- It is 0 on the first stop after a real user message.
- It increases by +1 per follow-up-driven stop.
- The next real user message resets it to 0.

### Captain messages during a Cursor park

A captain message typed while the hook is parked is accepted and runs its turn immediately, and Cursor does NOT terminate the parked hook.
The older park remains the recorded owner until that captain turn ends and the next `stop` hook claims the baton.
An actionable watcher close in that window can therefore still be delivered by the older park as one follow-up.
That delivery is bounded and safe.
Only one park exists before the next `stop` claim, so it is a real wake and never a stale duplicate of another park's wake, while the durable wake queue makes handling idempotent.

Each invocation publishes its sequence in `state/.cursor-park-owner` under the short publication and commit lock `state/.cursor-park-owner.lock`.
The same bounded critical section covers the final owner and away-mode checks, follow-up output, and repair-budget commit.
The next `stop` claim therefore makes an older park that is still running stand down without emitting or changing shared state.
The lock is never held while the arm is sleeping, while the hook is polling, or while output is prepared.

The park revalidates session ownership while polling and again inside the final commit section.
It deliberately does not hold the fleet session lock across output, because an awaited hook must not block home-wide session acquisition.
The remaining microsecond takeover window can produce at most one harmless wake that drains the durable queue.
Without those records an older park still running after the next `stop` could leak one process and one stale duplicate wake.

Cursor's `beforeSubmitPrompt` step fires once on a real captain message and does not fire for hook-driven follow-ups, so invalidating the park baton there would close the pre-claim window exactly.
The step is now registered only for the [dialog mirror](supervision-host.md#the-dialog-mirror); it does not invalidate the park baton.
Baton invalidation and the `preCompact` surface remain deferred.

### Adapter failures in the pull guard

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `jg-guard.sh` call reports the problem.
That warning uses `bin/jg-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

## Compatibility limits

- Child operator and Recon worktrees are outside scope.
- A valid Squad Lead home is in scope.
  An idle Squad Lead endpoint with no Relay poll remains healthy because it has no supervision need.
- The blocking and bounded-follow-up mechanisms are limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Cursor's `stop` step does not fire in headless `cursor-agent -p`, the same class of limit as OpenCode headless; Juggernaut primaries run interactive.
- A Cursor primary must be launched with `--trust`, or its project hooks never load and the whole integration is inert.
- Cursor's `preCompact` step is deliberately unregistered.
  Its response can return only `user_message` and it is absent from Cursor's `additional_context` step set, so a post-compaction re-emit needs its own design and is deferred to a follow-up ([`sessionstart-nudge.md`](sessionstart-nudge.md) owns that uncovered surface).
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/jg-kimi-turnend-hook.sh` to edit only one marker-delimited Juggernaut region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Juggernaut's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/jg-turnend-guard.test.sh` covers:

- The predicate.
- Main and Squad Lead primary scope.
- Child-worktree exclusion.
- `JG_HOME` and `JG_STATE_OVERRIDE` precedence.
- The live-lock and fresh-beacon guard predicate.
- The cooperative `--claude` open-generation claim wait.
- Monotonic failed-epoch progression.
- Bounded attended fail-open.
- The same bound against a ledger frozen by an inert auto-arm with and without a verified failure episode.
- Post-alarm continuation suppression.
- Positive recovery reset.
- Generation and legacy claim cases that must block or clear instead of allowing a blind stop.
- Away-mode daemon ownership between watcher cycles and over a watcher lock left behind by an exited watcher, plus its dead, pid-reused, absent, stale-beacon, and away-mode-off negatives.
- The away-mode beacon's poll-derived grace widening for a live daemon still mid-cycle and its bound against a dead daemon, a beacon older than that wider grace, and JG_POLL's inapplicability with away mode off.
- Pi logical-run latching.
- Missing-`jq` behavior.
- All five primary registrations.
- Grok native and legacy selection.
- Typed field precedence.
- Malformed input.
- Exactly-one-path safety.

`tests/jg-owner-correction.test.sh` covers the correction rule: an uncaptured correction is flagged once with both exact commands named, an owner rule ends the turn, an enforcement ticket ends the turn, new work is never read as a correction, and a home without the shared check says so once.

`tests/jg-turnend-foreign-owner-arm-fix.test.sh` runs the extracted isolated executable reproduction against real auto-arm and turn-end guard scripts.
It proves that a live foreign owner still prevents arming while repeated non-owner Stops receive a diagnostic and exit safely.

`tests/jg-guard-stale-banner.test.sh` covers the pull-guard predicate for each supervision model:

- The persistent model's fresh-leftover-beacon negative control.
- The auto-arm model's healthy fresh-beacon-without-a-watcher case, session-and-recovery-bound long-turn rewake tolerance, independently broken tolerance signals, open-claim negative control, stale-beacon alarm, and isolation from other models.
- The extension model's live-watcher path, ownership-qualified fresh hand-off, held-lock failures, independently broken ownership signals, stale-beacon alarm, queued-wake warning, and Pi and pi-signed harness routing.

It also covers true-reason banner wording and reason-keyed episode dedup surviving a beacon mtime change.

`tests/jg-cursor-primary.test.sh` covers the Cursor park end to end over real processes with no harness installed:

- Each tracked Claude-shaped entrypoint standing down on a Cursor payload.
- Both follow-up sources.
- The bounded repair nag and its reset.
- The nested loop bounds.
- Supersession.
- Away-mode and lock-ownership inertness.
- Pi-host stand-down without Cursor identity and continued parking when `PI_CODING_AGENT` leaks alongside `CURSOR_AGENT` or `CURSOR_INVOKED_AS`.
- Child-worktree exclusion.
- That the adapter never exits 2.

`tests/jg-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/jg-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`tests/jg-omp-harness.test.sh` covers the omp extension pair over a fake omp API (forced continuation on exit 2, the `stop_hook_active` bound, the seatbelt block, the ownership proof).

The opt-in live tests are:

- `JG_CURSOR_PRIMARY_LIVE_E2E=1 tests/jg-cursor-primary-live-e2e.test.sh` is the opt-in guard that proves the Cursor park behavior covered by `tests/jg-cursor-primary.test.sh` against the installed cursor-agent and fails naming the harness and version.
- `JG_PI_LIVE_E2E=1 tests/jg-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
- `JG_OMP_LIVE_E2E=1 tests/jg-omp-primary-live-e2e.test.sh` is the opt-in isolated omp path.

[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the current Claude `asyncRewake` revalidation.
