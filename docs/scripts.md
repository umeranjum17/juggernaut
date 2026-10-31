# The bin/ toolbelt

The Overwatch drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the Juggernaut home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate lifecycle boundary is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent session-open hook use; `jg-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `jg-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `jg-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `jg-sessionstart-run.sh` | Route a native session-open hook to the full digest, a context re-emit, or the nudge |
| `jg-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `jg-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `jg-startup-network.sh`  | Run session start's network checks and inactive-outcome scan off its blocking path, retaining reports and durable findings |
| `jg-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `jg-fleet-snapshot.sh`   | Print structured fleet snapshot JSON and refresh only its parent-side remote-ledger cache (schema `jg-fleet-snapshot.v1`) |
| `jg-home-summary-refresh.sh` | Atomically publish this home's structured summary ledger                         |
| `jg-fleet-ledger.sh`     | Append the opt-in fleet activity ledger's records ([contract](fleet-ledger.md))      |
| `jg-comms-feed.sh`       | Export every fleet message across Main and its Squad Lead homes as one read-only, live, append-only JSONL feed for a channel-style reader |
| `jg-chat.sh`            | The one owner of the fleet chat store: one JSONL record per message with its thread (`#fleet`, a lead, or a worker task), its sender and kind, and a captain message's own status; written at the call site that already records the steer, the status line or the wake |
| `jg-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view, including the Overwatch KPI scorecard |
| `jg-fleet-heartbeat.sh`  | One no-model pass over this home and every local Squad Lead home: working lanes against the lane target, ready backlog, open waits and supervision age, as a MOVING, IDLE, GAP or STALLED verdict per home; bootstrap arms it on a primary home unless `config/fleet-heartbeat-off` exists, and `arm` registers a watcher check that wakes Main when a home turns GAP or STALLED and re-fires until it recovers; the same check names a lane whose work is done while its worker still answers, so the lead lands it and closes it |
| `jg-design-gate.sh`      | The no-model design gate: `size` applies the small-tweak rule (at most 40 changed UI lines, no new UI file), `handroll` writes the lead's or Main's approval that a small UI tweak needs to merge (the asking worker cannot write it), and `board` refuses a board post of design options unless the first-draft run record it names made or refined every one of them |
| `jg-live-claim.sh`       | The no-model fixed-means-live rule: a report that a user-visible change is fixed or done carries the released ref and where it is observable, or is downgraded to `merged-not-released: ...` |
| `jg-installed-drift.sh`  | The watcher check for the copies this fleet runs: for every installed copy under `$XDG_DATA_HOME/fm-*` and `$XDG_DATA_HOME/jg-*`, compare each file with its repo counterpart from `<copy>/.jg-origin` or `addons/<name>` and print one line per finding (`differ`, `missing`, or `unknown origin <copy>`), nothing when every copy matches, and exit 0 always; it never repairs or deletes a copy, and `arm` registers it as a watcher check |
| `jg-licence-check.sh`    | The watcher check for dependency licences: read `config/licences-allowlist` (shipped as `defaults/licences-allowlist`), then `package.json` with `package-lock.json` and `requirements.txt` under the root, and print one line per dependency whose licence is outside the allowlist or unknown plus a summary count; a dependency with no declared licence is reported, never passed, and `arm` registers it as a watcher check |
| `jg-flow.sh`             | Shim for the fleet-flow add-on: read fleet lifecycle and wait metrics as JSON ([reader reference](fleet-ledger.md#reading-lifecycle-metrics)) |
| `jg-task-outcome.sh`     | Append one durable per-task outcome row (models, timestamps, outcome, PR) at teardown ([per-model statistics](fleet-ledger.md#per-model-statistics)) |
| `jg-model-stats.sh`      | Shim for the fleet-stats add-on: read per-model merge rate, time-to-merge, first-pass and rework statistics as JSON ([per-model statistics](fleet-ledger.md#per-model-statistics)) |
| `jg-skill-stats.sh`      | Shim for the fleet-stats add-on: read per-skill fleet read counts as JSON ([skill statistics](fleet-ledger.md#skill-statistics)) |
| `jg-ticket.sh`           | Record one task's ticket truth on the fleet board now: stage, state, delivered PR and target release ([tickets](../addons/tickets-sync/README.md#writing-a-ticket-at-the-moment-it-changes)) |
| `jg-bearings-snapshot.sh` | Project the bounded remote-ledger fleet snapshot to compact TOON; `--include-prs` adds live GitHub enrichment |
| `juggernaut-axi`          | Read-only fleet facts for external tools: `status`, `tickets`, `decisions`, and `messages` as TOON, plus the guarded writes `answer`, `message`, and `ticket` or `--json` (`juggernaut-axi.v1`) |
| `jg-squad-lead-reconcile.sh` | Queue Bearings reconcile requests for later supervision delivery and ask each mismatched home through its durable inbox with a per-home cooldown |
| `jg-update.sh`           | Guarded self-update of Juggernaut and local or remote Squad Lead homes, reconciling redundant divergence and classifying every live mate left on the target commit for restart or fallback nudge |
| `jg-squad-lead-restart.sh` | Persist open conversational work, then restart eligible Squad Leads or report the fallback outcome |
| `jg-squad-lead-restart-lib.sh` | Shared Squad Lead restart capability and persistence-request contract |
| `jg-on.sh`               | Execute one tracked Juggernaut command in a configured remote Squad Lead home, using its job worker except for the doctor bootstrap |
| `jg-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `jg-remote-job-worker.sh` | Long-lived remote queue worker for tracked `jg-*.sh` commands in the account runtime |
| `jg-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `jg-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's Squad Lead readiness (remote job worker, Herdr, Aqua launch agents, PATH, and required tools) |
| [`jg-backlog-handoff.sh`](../bin/jg-backlog-handoff.sh) | Move queued backlog items into a Squad Lead home; its header owns route-specific wake outcomes and retries |
| `jg-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `jg-captain-hold.sh`     | Hold tasks for the captain, record the captain's answers, gate investigation completion, and report record divergence between the status log and the backlog |
| `jg-decision-hold.sh`    | One-release compatibility shim mapping the retired decision commands onto jg-captain-hold.sh |
| `jg-owner-rules.sh`      | Seed, extend, and audit the shared owner-rules surface the session digest prints, refusing an entry with no owner words, no scope, or no enforcement point |
| `jg-owner-correction.sh` | The owner-correction capture check the turn-end guard reads: is the recorded correction (the newest captain message tagged feedback or micromanagement) captured by an owner rule or an enforcement ticket |
| `jg-question-card.sh`    | Post the board card for a question to the owner through sign-off-axi and print its key so the reply can cite it; `--route <lead>` names the lead that owns the answer |
| `jg-proof-attach.sh`      | Find a task's done-done receipt and proof media, refuse a text-only card for UI or video work, and put the proof on the ready, review or merged board card and the PR body |
| `jg-overwatch-kpi.sh`    | Record each typed captain message, tag it new work, decision answer, feedback, or micromanagement, refuse a feedback or micromanagement tag without a link to a ticket or PR on this repository, and report the misses per day and per week against a target of zero |
| `jg-question-lib.sh`     | Shared question-rule predicate: does a reply end in a question, and does it cite an open board card |
| `jg-brief.sh`            | Scaffold ship (explicit `--mode`, plus the project's registered `--forge`), Recon, Squad Lead charter, and Herdr-lab briefs, with Captain's intent and Juggernaut spec subsections on ship/scout |
| [`jg-dod-lib.sh`](../bin/jg-dod-lib.sh) | Own ship/scout worker role scope, ship definitions of done, the named-head reachability gate on ship `done:` acceptance, and the no-mistakes `--intent` contract |
| `jg-brief-heading-lib.sh` | Single owner of reading a brief's sections, shared by the `--intent` contract, spawn and promotion validation, and `jg-dispatch-resolve.sh` |
| `jg-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `jg-herdr-lab-viewer.py` | The pty engine behind `jg-herdr-lab.sh viewer`: one real foreground Herdr client on a non-zero window grid |
| `jg-lab-home.sh`         | Mint disposable lab homes and manage their isolated tmux socket directories       |
| `jg-live-lab.sh`         | Build and operate a disposable live supervision lab; see its header for usage and readiness contract |
| `jg-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `jg-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `jg-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `jg-lab-*` sessions in the Herdr CI lane       |
| `jg-test-run.sh`         | Behavior-test runner: selection, portable lanes, bounded concurrency, budgets, coverage guard, timing/JSON; refuses to execute in the repository primary checkout when `JG_TASK_ID` marks a task worker |
| `jg-test-isolation-proof.sh` | Concurrent isolation harness and portable candidate set owner |
| `jg-ensure-agents-md.sh` | Manually initialize project agent-memory files (see the helper's header and help) |
| `jg-guard.sh`            | Warn on primary-checkout tangles, main-session pending wakes, and unhealthy supervision |
| `jg-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `jg-session-lock-lib.sh` | Shared session-lock ownership from harness ancestry or a trusted Claude session id for jg-lock.sh and the Claude Stop auto-arm, plus the read-only lock inspection behind `jg-lock.sh status` and `jg-inbox.sh ready` |
| `jg-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `jg-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `jg-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `jg-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `jg-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `jg-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `jg-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `jg-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `jg-home-seed.sh`        | Transactionally provision a local Squad Lead home and maintain `data/squad_leads.md` |
| `jg-remote-home-seed.sh` | Register and provision a whole Squad Lead home on an SSH-reachable host              |
| `jg-remote-readiness-lib.sh` | Shared remote Squad Lead readiness gate: check and, when needed, repair then re-check through `jg-remote-doctor.sh` |
| [`jg-project-origin-lib.sh`](../bin/jg-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `jg-spawn.sh`            | Spawn operators, Recon missions, `id=repo` batches, and Squad Leads on the resolved harness and runtime backend |
| [`jg-treehouse-protect.py`](../bin/jg-treehouse-protect.py) | Lease recorded Treehouse pool copies before allocation, without moving, resetting or returning them; its docstring owns the skip and refusal rules (called by spawn and home seed) |
| `jg-git-strip-ai-trailers.sh` | Strip known AI commit trailers at commit-msg time and install that hook for a fleet launch |
| `jg-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `jg-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `jg-composer-lib.sh`     | Single fleet-wide owner of composer shapes, capability-aware screen classification, and verdicts |
| `jg-agent-process-lib.sh` | Backend-neutral harness-process name classifier shared by the tmux and herdr adapters |
| `juggernaut-axi-serve.py` | `juggernaut-axi serve`: opt-in loopback read-only HTTP API (bearer token in `config/juggernaut-axi-token`, rate limited) |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Herdr session-provider adapter with its own required CI lane                         |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `jg-config-push.sh`      | Push declared inherited local material to live local or remote Squad Leads and send the placement-specific config reread when changed |
| `jg-project-mode.sh`     | Resolve a project's registered delivery posture, forge binding, or ship-branch prefix from `data/projects.md` for fleet sync, home seeding, and the forge agreement a ship spawn or Recon promotion applies |
| `jg-forge-detect.sh`     | Propose a clone's forge binding from its origin remote for project-add intake, never recording it |
| `jg-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `jg-review-diff.sh`      | Review an operator branch or resolved PR head against the authoritative base          |
| `jg-marker-lib.sh`       | Compatibility entry point for the from-juggernaut carrier owned by `jg-operational-input.sh` |
| `jg-task-inbox-lib.sh`   | Single owner of durable steering-inbox records, acknowledgement, doorbells, and the delivery-attempt ladder |
| `jg-pending-reply-lib.sh` | Parent-owned Squad Lead pending-reply expectations, recovery, and keyed escalation lifecycle |
| `jg-squad-lead-report.sh` | Optional helper that resolves the parent channel itself and appends a correlated status or document-pointer report |
| `jg-extension.mjs`       | Bind, inspect, verify, and strictly invoke trusted external process-event adapter packages |
| `jg-extension-launch-barrier.mjs` | Publish one exact static core-owned invocation group before package code runs |
| `jg-extension.sh`        | Expose extension binding commands through the tracked shell and remote-home command boundary |
| `jg-procevent.sh`        | Register, supervise, capture, classify, acknowledge, and safely retire built-in or explicitly bound process-event sources |
| `jg-procevent-remote-reply.sh` | Relay the remote Squad Lead status stream through non-destructive process-event deltas |
| `jg-procevent-quota.sh`  | Wake Juggernaut when tracked quota drops below a threshold, is exhausted, or cannot be polled |
| `jg-procevent-when.sh`   | Fire a trust-bound deterministic action at most once when its registered condition holds, then wake with the outcome |
| `jg-procevent-signoff.sh` | Bring sign-off board answers to captain holds as keyed answers, and raise a board card for each new hold once a home arms it (the signoff add-on raises it instead when installed) |
| `jg-gate-refuse-lib.sh`  | Shared gate-context lifecycle boundary for real and lab homes                      |
| `jg-addons-dir-lib.sh`   | Single owner of add-on resolution: `JG_ADDONS_DIR`, else the in-repo `addons/`, else the pre-fold `projects/juggernaut-addons` clone |
| `jg-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `jg-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `jg-watch.sh`            | Singleton-safe watcher: absorb benign wakes, detect stalled local Squad Lead wake queues, hand recorded asks to the ask-default add-on when installed, and exit on actionable ones |
| `jg-inactive-reconcile.sh` | Reconcile long-inactive direct operator terminal outcomes without forge access |
| `jg-afk-contract.sh`     | Own the away-or-quiet record's posture, schema, entry, read-back, archive, and cross-subsystem authority lock |
| `jg-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `jg-afk-launch.sh`       | Own away/quiet entry (same-turn record write, then read-back), exit, rollback, and any backend terminal lifecycle |
| `jg-afk-return.sh`       | Own deterministic return shutdown, the return brief, catch-up evidence, and the Juggernaut-actionable blocker gate |
| `jg-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `jg-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `jg-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `jg-nm-run-lib.sh`       | Single owner of shared no-mistakes run-attribution primitives and rules             |
| `jg-pipeline-spend.sh`   | Attribute a task's no-mistakes pipeline spend to the task and keep it in the private spend ledger |
| `jg-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `jg-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `jg-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `jg-sentinel.sh`         | Out-of-runtime recovery: detect an agent-runtime restart or a stale beacon with no turn running, reconcile direct reports, and wake the primary |
| `jg-tmp-sweep.sh`        | Report /tmp space and inode use and sweep stale allowlisted fleet scratch that no live process or lane holds; the sentinel warns at 80% and sweeps daily |
| `jg-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `jg-ff-lib.sh`           | Shared guarded fast-forward/reconcile helper for origin pulls and Squad Lead syncs, with durable divergence markers |
| `jg-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `jg-config-inherit-lib.sh` | Shared primary-to-Squad-Lead inherited local-material propagation and config-reread delivery |
| `jg-tasks-axi.sh`        | Run `tasks-axi` against this home's backlog from any working directory               |
| `jg-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `jg-backlog-transition-lib.sh` | Pair task-record changes with their backlog transitions and replay interrupted closes |
| `jg-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and quota snapshot schema validation           |
| `jg-project-capacity-lib.sh` | Per-project worker capacity: `config/project-capacity` parsing, what holds a place, and the spawn-time fit check ([configuration.md](configuration.md#project-capacity-configproject-capacity)) |
| `jg-exclude-tools-lib.sh` | Parse `config/crew-exclude-tools` and check launch-time runtime support for worker tool exclusions ([configuration.md](configuration.md#worker-tool-exclusions-configcrew-exclude-tools)) |
| `jg-launch-env-lib.sh`   | Single owner of the provider-credential shapes every launch strips from the worker environment, and of the `unset` prefix the pane runs ([configuration.md](configuration.md#provider-credentials-stripped-from-every-launch)) |
| `jg-quota-choose.sh`     | Choose the first candidate with known positive quota from an ordered harness:model list |
| `jg-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `jg-wake-drain.sh`       | Present and acknowledge the current actor's claimed wake rows alongside status, outcome-backstop, decision, divergence, supervision-host outcome, recovery, and supervision checks |
| `jg-wake-grant.sh`       | Serialize Pi supervision-branch wake-row claim activation, publication, release, and deactivation |
| `jg-wake-lib.sh`         | Shared durable wake queue, recovery generations, portable locks, and watcher identity/health helpers |
| `jg-path-lib.sh`         | Fork-free `dirname`/`basename` equivalents with no source-time side effects             |
| `jg-classify-lib.sh`     | Shared wake classification, durable keyed-decision folds and scans, unread status selection, home-owned status-append ranges, and bounded latest-event snapshots |
| `jg-send.sh`             | Steer a task via a durable inbox record plus doorbell, or send a supported key or typed harness invocation through the recorded backend |
| `jg-branch-prompt.sh`    | Emit the shared supervision branch's byte-stable system prompt ([pi-supervision-branch.md](pi-supervision-branch.md), [supervision-host.md](supervision-host.md)) |
| `jg-branch-outcome.sh`   | Own the supervision branch's append-only outcome store, cursors, bounded status-coverage indexes, and session-start replay |
| `jg-lease.sh`            | Claim, release, inspect, and sweep per-task supervision leases                       |
| `jg-lease-lib.sh`        | One owner of the supervision lease contract and the main-only role-partition guards  |
| `jg-control.sh`          | Agent lifecycle control plane: allowlisted `interrupt`, `exit`, and transactional `relaunch` verbs for an exact task id ([agent-control.md](agent-control.md)) |
| `jg-control-lib.sh`      | One executable owner of the control-plane verb allowlist, per-harness interrupt/exit mechanics, per-backend capability, and the endpoint-absence proof both `exit` and `relaunch` read |
| `jg-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `jg-busy-event.sh`       | The only writer of a task's semantic busy-state record and native-harness progress marker; arms an incarnation and applies lifecycle events |
| `jg-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `jg-peek.sh`             | Print a bounded tail of an operator endpoint                                          |
| `jg-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `jg-scratch.sh`          | Record a task's scratch directories so teardown reaps exactly those paths           |
| `jg-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
| `jg-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `jg-tokens-retro.sh` | Daily token retro watcher check: one `learn-from-mistakes-axi tokens retro` a day into `data/tokens-retro/`, reporting only a week-over-week change |
| `jg-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
| `jg-startup-growth-check.sh` | Daily metadata-only growth check for startup memory and tracked startup/instruction surfaces |
| `jg-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication, merge-notification identity, and retirement |
| `jg-pr-poll.sh`          | Provide the byte-static watcher program for validated pull-request, merge-request, and Gerrit-change poll sidecars |
| `jg-contributions.sh`    | Observe owned publications, retain exact-head judgments, measure required actors, and wake on maintainer signals |
| `jg-pr-check.sh`         | Record validated task `pr=` and `pr_head=` values, then atomically arm a static merge poll; refuses GitHub drafts and persistent Squad Lead records (see [architecture.md](architecture.md)) |
| `jg-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub, GitLab, or Forgejo URL, refuse a Gerrit change because Juggernaut never submits one, then refuse an outcome it cannot prove landed or queued |
| `jg-pr-state.sh`         | Read-only: print one line per GitHub pull-request blocker it can see, reporting on checks that have reported rather than verdicting merge-readiness |
| `jg-pr-reviewers.sh`     | Read-only: suggest reviewers from GitHub's own author mapping of recent commits on a pull request's changed files, never requesting one |
| `jg-merge-outcome-lib.sh` | Publish a confirmed merge's durable, role-routed supervision outcome |
| `jg-reaper-lib.sh` | Stop a browser left behind by a dead worker when its profile is a fleet temp or scratch folder and it is past the age limit; raise the machine load alarm |
| `jg-merge-authority-lib.sh` | Resolve merge authority at the gate, persist it against the accepted canonical PR, and identity-check its later poll consumption |
| `jg-role.sh`             | Report this home's Juggernaut role and check the self-repository publication gate ([configuration.md](configuration.md#juggernaut-role-configjuggernaut-role)) |
| `jg-role-lib.sh`         | Own the role parser, self-repository detection, and the publication gate the dispatch surfaces share |
| `jg-parent-channel-lib.sh` | Resolve a Squad Lead home's parent channel and append a captain-facing outcome line to it at most once |
| `jg-promote.sh`          | Promote a Recon task in place to a protected ship task with an explicit delivery mode, write the ship instructions carrying that mode's definition of done, and supersede the task's brief so a later relaunch cannot revive stale Recon delivery text |
| `jg-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed Recon deliverables, retire Squad Lead homes |
| `jg-harness.sh`          | Detect the running harness, resolve crew or Squad Lead harness, model, and effort, and validate the native-only `ultra` effort |
| `jg-lock.sh`             | Per-home Juggernaut session lock                                                      |
| `jg-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `jg-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions, emit their once-only wake, and raise queued public-followup rejection wakes at least once |
| `jg-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `jg-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `jg-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `jg-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `jg-public-followup-lib.sh` | Shared Relay gate, mirrored deliverable validation, open-loop state, locking, and private transport paths |
| `jg-public-followup.sh`  | Brief, reconcile, and deliver typed public commitments, surface refusals, then rechain or retire retained loops |
| `jg-public-followup-emit.sh` | Validate and report one typed terminal work result into its owning home, or stage it when that home is remote |
| `jg-public-followup-collect.sh` | Read and retire the typed terminal results a remote work home staged for the home that owes the public reply |
| `jg-inbox.sh`            | The captain's out-of-band capture surface: queue notes, ticket and list `[captain-ask]` notes, announce or repair wakes, record primary replies, and emit bounded receipts and readiness JSON |
| `jg-mail.sh`             | General-purpose mail plane: read unseen IMAP mail, send one SMTP message, or surface new mail as a `check` wake via `poll` (configuration in the home's gitignored `.env`) |
| `jg-mail.py`             | The IMAP/SMTP engine behind `jg-mail.sh` |
| `jg-board-answers.sh`    | Standing board-answer check: `arm` registers a watcher check that sends each routed answer straight to its lead's inbox (closing the lead's decision key, archiving the card once the lead acknowledges) and wakes Main only for unrouted answers; `route` records a card's owner |
| `jg-mail-check.sh`       | Standing received-mail poll: `arm` registers a watcher check that runs `jg-mail.sh poll` on the watcher cadence (new mail still wakes via the poll; the check's own line also wakes unless the poll is a proven no-op), `disarm` removes it |
| `jg-decisions-reconcile.sh` | Standing board reconcile on its own hourly interval: `arm` registers a watcher check that clears every open card a durable record already settles (a card built from a hold that is the captain's own instruction - parked work, his stop order, or a preserved branch - a recorded answer, a `resolved [key=...]` status line, the task's merged PR, or a task closed in the backlog), logs one line per cleared card with its evidence, and keeps every card whose record is missing or unreadable |
| `jg-voice-relay.py`      | Hold the spoken conversation on this host, answer from the records, and hand real work to `jg-inbox.sh` ([voice-relay.md](voice-relay.md)) |
| `jg-voice-client.py`     | The laptop end of the spoken interface: capture, playback, and turn timing over SSH; audio devices unverified |
| `jg_voice_frame.py`      | The wire format both machines share, copied to the laptop beside the client          |
| `jg_voice_records.py`    | What a spoken answer may read, and the handover that queues real work                |
| `juggernaut-name-gate.sh` | The Juggernaut rename's done gate. Its `--visible` scope fails on the old product name and the old role words in the prose a visitor reads, allowing only the upstream credit line and preserved git-given names; the default whole-tree scope also counts the internal names and file names that Phase 2 renames |
