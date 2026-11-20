# Verification: the agy (Antigravity CLI) adapter

Active empirical facts for Juggernaut's agy adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy.md`](../../.agents/skills/harness-adapters/references/harness/agy.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.2.0`; the send-confirmation timing below was re-measured on `agy 1.2.1` (2026-09-12) |
| Verified | 2026-09-10 |
| Binary | `/home/andpod/.local/bin/agy`, an ELF 64-bit Go-compiled single executable |
| Platform | Linux x64 (Arch, kernel 7.2.3) |
| Backend | Herdr, in an isolated non-`default` lab session (`jg-lab-juggernaut-agy-ad-*` via `bin/jg-herdr-lab.sh`); the live `default` session was unchanged throughout |

Every command below ran inside the disposable Juggernaut task worktree or the named Herdr lab session.
No captain fleet state was touched.

## Detection: ancestry only, no marker

```
$ agy --version
1.2.0
```

A live TUI's `/proc/<pid>/environ` carries no `AGY_*` or `ANTIGRAVITY_*` variable.
It does carry `AGENT=1` and `CLAUDECODE=1`, both inherited from the launching environment, so neither is an agy identity and neither is promoted to a marker.
Herdr's `pane process-info` for the same pane reports the foreground process as `name=agy` with `argv=["agy", ...]`, and `ps -o comm=` reports `agy`.
`bin/jg-harness.sh` therefore matches the anchored process name `agy` alone, and the spawn clears `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `JG_PI_HARNESS` at the launch boundary.
`tests/jg-agy-harness.test.sh` pins the anchored match, the rejection of unrelated names containing the fragment, and that an inherited `CLAUDECODE` never outranks a real `agy` ancestor once the spawn clears it.

## Launch: positional prompt-interactive with auto-submit

```
$ agy --prompt-interactive "Reply with exactly AGY_LIVE_PROBE_OK and nothing else" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions
```

The brief submitted itself with no extra Enter, the turn ran, and the reply rendered in the pane.
A second launch into the same directory answered a fresh prompt the same way, so the shape is repeatable, not a first-run accident.
The footer rendered `Gemini 3.8 Flash · low`, proving both flags were accepted together.

## Trust dialog: pre-registered before launch, gated on a busy turn as the backstop

A first launch in a fresh worktree shows this dialog:

```
Accessing workspace:

/home/andpod/.treehouse/juggernaut-7bab20/1/juggernaut/agy-probe-tmp

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit
```
`agy --help` (1.2.0) lists no trust flag or pre-registration command, but agy honours a `trustedWorkspaces` entry written to `~/.gemini/antigravity-cli/settings.json` ahead of launch.
Verified under a throwaway `HOME` holding a copy of `~/.gemini` (the real settings file was never written): a folder appended to that array by hand launched `--prompt-interactive` straight into its turn and rendered the reply with no dialog, while an unregistered sibling folder launched the same way parked on the dialog.
agy compares the pane's logical working directory, not its resolved path: a symlinked cwd whose real path alone was registered still parked on the dialog, so `bin/jg-agy-trust.sh` records both the logical path and its resolved form when they differ.
`bin/jg-spawn.sh` runs that helper before launch at the same point it pre-registers claude trust; the helper applies the same structural scope test (a linked worktree of the spawning project, never a primary checkout, a subdirectory, a plain directory, or the home directory), preserves every other key in the store, and writes atomically with a fingerprint check.
A failed registration is a stderr warning rather than a refusal, because agy's dialog preselects the safe answer and the gate below can answer it.
Two supervised Herdr runs in treehouse worktrees completed file-writing turns while the dialog was still unanswered at observation time (worker file and `done:` status line both verified on disk before Enter was ever sent to those panes).
Isolated runs in untrusted `/tmp` directories never reached the workspace until Enter: the turn spun through exploratory tool calls in agy's own scratch directory instead, and only the queued prompt ran after the answer.
One run left unanswered for several minutes wrote its file to agy's scratch directory instead of the workspace once finally answered.
The mechanism behind the difference was not established; path, backend, and latency were all varied across runs without isolating a single cause.
The spawn therefore does not depend on it: after pre-registration, `bin/jg-spawn.sh` runs a post-launch readiness gate (`agy_wait_for_working`) in the rovo/kimi launch-then-confirm shape as the backstop.
It polls the pane capture, answers the dialog with a single Enter the first time the `Do you trust the contents of this project?` text renders, and reports success only once `jg_busy_classify` returns a busy verdict for the pane (Herdr's native `working` status or the pinned `esc to cancel` status row).
Because Herdr's native `working` verdict is known to coexist with an unanswered dialog, the gate is strict about order: a busy verdict counts as ready only when the worktree was pre-registered before launch or the dialog has already been seen and answered; on an unregistered path it keeps polling for the dialog instead of accepting the early busy verdict.
When the brief cannot be confirmed to run within the window (an answered dialog never turns busy, a pre-trusted pane never turns busy, or an unregistered pane never shows the dialog), the spawn fails, records `failed:` in the task status, and closes the endpoint so no orphan worker survives outside task control.
`tests/jg-agy-harness.test.sh` covers the helper's registration and scope refusals against a throwaway store, and drives a fake pane whose dialog decision reads the store the spawn just wrote: the pre-trusted launch with no dialog, a dialog that renders anyway answered exactly once, the premature busy verdict on an unregistered path waiting for the dialog, and both fail-and-close paths.

## Model and effort

```
$ agy models
Fetching available models...
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
...
```

`agy --help` documents `--effort` as `low|medium|high` and `--model` as the model for the session.
The bare `gemini-3.8-flash` id from this home's previous config is not listed; only the suffixed `-high`, `-medium`, and `-low` variants are.
`bin/jg-spawn.sh`'s `agy_model_validate` refuses a requested id a reachable `agy models` listing omits, and launches unvalidated with a stderr notice when the listing is unreachable.
The listing is a remote fetch (`Fetching available models...`), so the probe runs with stdin detached under the shared hard bound from `bin/jg-timeout-lib.sh` (15 seconds by default, `JG_AGY_MODELS_TIMEOUT`; a non-positive or non-numeric value clamps back to that default, because a non-positive bound is not a bound); a stalled fetch or a sign-in prompt is cut off and falls through to the unvalidated launch instead of blocking the spawn before any pane exists.
Print mode (`agy -p "Reply with exactly: AGY_PRINT_PROBE_OK" --model gemini-3.8-flash-low`) returned the exact reply with exit 0 in about 8 seconds, proving the credential path without a pane.

## Busy state: the pinned status row, unknown on absence

Mid-turn the pane rendered the status row and a spinner line at once:

```
⣯  Generating...
└ Tip: When reviewing a file edit, press f to see the full diff.
...
esc to cancel                                                           Gemini 3.8 Flash · low
```

The completed turn showed the reply, then the idle composer:

```
>
──────────────────────────────────────────────────────────────────────────────
? for shortcuts                                                         Gemini 3.8 Flash · low
```

`jg_busy_agy_tail_busy` and the delivery guard in `bin/jg-composer-lib.sh` match the `esc to cancel` token alone: the TUI pins that status row to the bottom of the pane for the whole turn, and the idle row replaces it with `? for shortcuts`.
The `Generating...` spinner word is deliberately not a signal: it is a free-floating output line, so ordinary worker output such as `Generating report...` would otherwise classify an idle worker as busy or acknowledge a submit that did not land.
No busy phase without the status row was observed live; every captured mid-turn frame carried it.
`jg_busy_classify` reports `unknown agy-regex` when the token is absent, because a long turn can scroll the marker out of the captured tail.
The signature is hardcoded with no environment override, so a stray variable can never change worker-state classification.
Herdr's own registry agreed throughout: `agent get` reported `agent_status=working` mid-turn and `idle` after, so on Herdr the native verdict carries busy with no new code.

## Interrupt and exit

A single `Escape` sent mid-turn through `herdr pane send-keys` cancelled it and printed this row, with the composer back at idle and no repolluted text:

```
  ⎿  Interrupted · What should Antigravity CLI do instead?
```

Sending `/quit` plus Enter exited the process; the pane closed under the `exec` launch, and Herdr reported the pane gone.
`bin/jg-control-lib.sh` records `Escape` once, no clear key, no ack source, and `/quit` for agy.

## Backend liveness: Herdr recognizes agy, tmux names it

```
$ herdr agent get w2:p1 --session jg-lab-juggernaut-agy-ad-1599574-8823
{"result":{"agent":{"agent":"agy","agent_status":"idle",...,"agent_session":{"agent":"agy","kind":"id","source":"herdr:antigravity_cli",...}}}}
```

Herdr tracks agy natively (`antigravity-cli` integration, detected as `agent=agy`), so `jg_backend_herdr_pane_agent_state` returns `live` for every registered agy status and no exit-detection hardening was needed.
The tmux adapter classifies the anchored process name `agy` as `agent` through the shared name vocabulary in `bin/jg-agent-process-lib.sh`, the muse/omp precedent for short bare-word names.
agy stays out of the session-lock name vocabulary in `bin/jg-session-lock-lib.sh`, where the other operator-only adapters are also absent.

## Composer: unknown by design

Byte-level capture of the idle pane shows a bare unstyled `>` between two full-width `─` rules, with an unstyled `? for shortcuts` cell and a dim (`SGR 2`) model cell in the status row below.
The shared classifier reads that bare `>` as `unknown` under the dead-shell rule, never `empty`.
Steering still confirms delivery: the Herdr submit core leads with the native `idle`-to-`working` transition, which agy performs, and the delivery footer regex covers the tmux path.
agy renders the busy footer late for that confirm loop - about 1.5 s after Enter for a short steer and 4-5 s for a realistic longer brief, measured live on `agy 1.2.1` (2026-09-12) against the shared budget's 3 x 0.4 s - so `bin/jg-send.sh` gives agy typed targets a longer default submit-confirm budget (20 retries, about 8 s at the default cadence); an explicit `JG_SEND_RETRIES` still wins and every other harness keeps the shared 3-retry default.
`tests/jg-send-agy-confirm.test.sh` pins the raised default and `tests/jg-agy-harness.test.sh` pins the Herdr transition path.
This is the cursor precedent, not a gap to patch in shared code.

## Supervised task: spawn, steer, relaunch, and exit through the new path

A trivial Recon ran end to end through `bin/jg-spawn.sh --harness agy` against the same isolated lab session: `spawned agy-e2e1 harness=agy kind=scout` with a treehouse-provisioned worktree, `--model gemini-3.8-flash-low`, and `--effort low` all recorded in task metadata.
The worker wrote its worktree file and appended `done: agy e2e turn complete` to its status file, which lives outside the worktree, proving prompt processing, tool execution, outside-workspace file access, and a new completion event.
Durable steering held: a `bin/jg-send.sh` message landed in the task inbox, the worker appended the steered lines to both files, and its inbox record moved to `handled/`.
Same-copy relaunch held: `bin/jg-control.sh relaunch --note` replaced the worker in place on the identical worktree, model, and effort, the replacement verified both prior lines intact and appended `relaunched: done`.
Exit held: `bin/jg-control.sh exit` stopped the worker, the registry returned `agent_not_found`, and the pane remained a lone shell in the worktree with all work intact.
No automatic quota failover was exercised or claimed; every handoff above was an explicit supervised relaunch.

## Primary Overwatch

| Field | Value |
|---|---|
| Version | `agy 1.5.11` (`agy --version`) |
| Verified | 2026-11-21 |
| Platform | Linux x64 (Arch, kernel 7.1.8) |
| Model | `gemini-3.8-flash-high` for the live guard; `gemini-3.8-flash-medium` for the hook probes |
| Isolation | A marked lab home (`bin/jg-lab-home.sh create`) inside a `jg-test-run.*` directory, a private tmux server in that home's own socket directory, and the account's normal HOME for agy's sign-in |

Every surface below is a vendor-controlled agy behavior that the tracked `.agents/hooks.json` and its three adapters rely on.

### Hook loading and process shape

agy loads `.agents/hooks.json` from the workspace root only once the folder is trusted.
A prompt queued with `--prompt-interactive` runs before the trust answer, so that first turn runs without hooks; the primary is started as plain `agy` and the trust dialog is answered first.
Each hook runs as `sh -c "<command>"` with its working directory set to the folder holding `hooks.json`, as a direct child of the agy process; each `run_command` runs as `bash -c "<command>"`, also a direct child of agy.
A captured `run_command` ancestry, with only the CSRF token removed:

```
3603552 3603544 anc.sh          /bin/bash .../anc.sh
3603544 3553164 bash            bash -c .../anc.sh > .../anc.out 2>&1
3553164 2207341 agy             agy --prompt-interactive Step 1: with run_command run .../anc.sh > ...
```

The child environment carries `ANTIGRAVITY_AGENT=1`, `ANTIGRAVITY_CONVERSATION_ID` and `ANTIGRAVITY_LS_VERSION=cli-1.5.11`, but the TUI process itself carries none, so detection stays ancestry-only and the session lock takes the anchored name `agy`.
Under the run-tier session start, the SessionStart hook's own `bin/jg-harness.sh` call sits 11 parents below agy, which is why the harness walk shares the lock walk's 16-parent bound; `tests/jg-session-start.test.sh` pins it with a real agy-named process chain.

### Hook payloads and decisions

| Hook | Payload fact | Decision fact |
|---|---|---|
| `SessionStart` | camelCase JSON on stdin | `{"injectSteps":[{"systemMessage":{"systemMessage":"..."}}]}` lands in the conversation as a `SYSTEM_SDK` system message before the first model step |
| `PreToolUse` (`run_command`) | the command is `.toolCall.args.CommandLine`; the args also carry `WaitMsBeforeAsync` and `IsDaemon` | no output keeps agy's own policy; `{}`, an empty decision or a non-zero exit denies; `{"decision":"deny","reason":"..."}` with exit 0 denies with the reason shown |
| `Stop` | carries `executionNum` and `continuationActive` | `{"decision":"continue","reason":"..."}` keeps the turn going, and the reason reaches the model as the system message `Stop hook blocked termination: <reason>` |

The forced continuation's own `Stop` payload did not set `continuationActive`, contrary to agy's documentation; the captured pair was:

```
{"executionNum":0,"continuationActive":false,"hookEventName":"Stop"}
{"executionNum":1,"continuationActive":false,"hookEventName":"Stop"}
```

`bin/jg-turnend-guard-agy.sh` therefore lets the turn end on either signal, so it continues at most once per turn.

### Background-task wake

A `run_command` that outlives its `WaitMsBeforeAsync` becomes a background task, and the turn can end while it runs.
When the task exits, agy starts a new turn with a high-priority system message carrying the output:

```
[Message] timestamp=... sender=<conversation>/task-N priority=MESSAGE_PRIORITY_HIGH content=Task id "<conversation>/task-N" finished with result:
Command exited with code 0.
Command output:
...
```

A `sleep 900; echo LONG_BG_DONE` background task woke an idle session after 900 seconds, and the session replied `LONG_BG_DONE`; this is the wake path the watcher arm rides.
agy reads the home's `AGENTS.md` natively: a marker present only in a probe's `AGENTS.md` came back, and the same prompt without the file answered `NONE`.

### Live guard

```
JG_AGY_PRIMARY_LIVE_E2E=1 bin/jg-test-run.sh tests/jg-agy-primary-live-e2e.test.sh
```

Output on 2026-11-21:

```
harness: agy 1.5.11
ok - agy primary: the SessionStart hook takes the fleet lock as the agy process itself
ok - agy primary: the run-tier session start completes
ok - agy primary: the SessionStart system message carries the digest into model context
ok - agy primary: the Stop hook holds an unsupervised turn end and the session then arms the watcher
ok - agy primary: the arm runs as a tracked background task
ok - agy primary: a real status wake ends the arm, wakes the session, and it drains the signal and re-arms
ok - agy primary: the tracked .claude/settings.json hooks did not run under agy
ok - agy primary: no user unit names the lab home
# jg-agy-primary-live-e2e: all assertions passed (agy 1.5.11, gemini-3.8-flash-high, 174s)
```

The wake check requires the first background-task message after the status append to name the status file, so a wake from any other check cannot stand in for it.
The guard refuses to start unless the lab-home guard refuses the account's unit directory in the session's own empty environment, and it leaves the unit-claim script out of the staged home.

### Not proven for the primary

- A supervision host, and away-mode daemon delivery into an agy pane.
- A subagent guard, and context re-emit after a compaction.
- agy's headless `--prompt` mode as a primary; only the interactive TUI is supported.
- Any model other than the Gemini Flash tiers above.

## What is still unproven

The unauthenticated failure mode was never observed; this host's agy runs signed in, so any auth prompt is a fail-loud credential blocker, not a handled dialog.
No slash-skill invocation form was verified, so skill invocation stays natural language.
`--continue` and `--conversation` resume were never exercised; recovery uses deterministic relaunch from the brief on disk.
No Squad Lead launch on agy was built or tested, and none is claimed.
The primary's gaps are listed under [Primary Overwatch](#primary-overwatch).

## Refreshing this record

Run the portable suite and the live guard after any agy upgrade, because the process name, marker set, trust dialog text, and rendered busy/interrupt text are all vendor-controlled surfaces that the spawn gate and the busy fallback match verbatim:

```
bin/jg-test-run.sh tests/jg-agy-harness.test.sh
JG_AGY_SIGNALS_LIVE=1 bin/jg-test-run.sh tests/jg-agy-signals-live-e2e.test.sh
```

For the primary, also run the agy cases of the session-start and turn-end suites (the `agy-primary` done-done journey) and the primary live guard, because the hook payload fields, decision shapes, and background-task wake message are vendor-controlled too:

```
JG_AGY_PRIMARY_LIVE_E2E=1 bin/jg-test-run.sh tests/jg-agy-primary-live-e2e.test.sh
```
