# wait-timers

The live watcher sources this timer library and calls it on each poll.
The escalation workflow delivers the first owner wake.
A parked lane (a pause to the placeholder date) and a finished lane whose open decision waits on its owner are quiet: they arm no episode and ring nothing. A real future deadline is honoured.

## Layout

- `bin/jg-wait-timers-lib.sh` — the timer library the watcher sources once per
  poll: one durable episode per waiting lane under `state/.waiting-timers/`,
  an escalation to Main when the owner has not cleared the wait, the board
  card, and the re-alert cadence. The owner recheck and the paused wait's
  recheck are the escalation workflow definition's rungs
  (`core/bus/workflows/escalation-wait-timers.json`, delivered by
  `bin/jg-escalation-workflows.sh`). A blocked or needs-decision wake names its
  decision as `key=<key>` after the verb; paused waits carry none.
- `bin/jg-wait-actions-lib.sh` — the owner table and the steps the ladder takes
  itself (see "Known next steps"), sourced by the timer library.
- `tests/jg-wait-timers.test.sh` — the watcher/drain journey that proves the
  timers (owner alert, escalation, deduplication, resolution, re-arm).
- `tests/jg-wait-timers-tmux-e2e.test.sh` — the live-terminal end-to-end
  journey; moved verbatim, run only against a real terminal session.

## Contract

The escalation chain changed this contract after the move below, so the
provenance table now records history, not the current bytes.

- Entry: `jg_wait_timers_tick` (no arguments; reads `JG_HOME` and `STATE`).
  Called once per watcher poll.
- `jg_wait_timer_quiet <task> <wait-state> <wait-source>` — true for a wait
  that already has an owner: a pause parked to the placeholder date, or a lane
  whose last status line is `done` with an open decision. Such a lane arms no
  episode (as for a captain hold). A wait source, a lane still working under an
  open decision, a blocked lane and a pause with a real date keep their rungs
  (`tests/jg-wait-quiet.test.sh`).
- `jg_wait_timer_push_delivered <task> <window>` — records that an immediate
  native push already told the owner about this blocked lane, so the poll
  timer skips its duplicate owner wake. Called from the push-transition path.
- `jg_wait_timer_source_delivered <task> <window> <declaration>` — the same for
  a wait source the watcher already woke the owner about (a permission prompt,
  a lead whose own supervision is down).
- `jg_wait_timer_save <record> <signature> <since> <owner> <parent> <key>
  <misses> [card] [last]`, `jg_wait_timer_report <status-line>` — episode
  persistence and parent reporting.
- The owner rung and the pause cadence are not this library's any more.
  The escalation workflow definition decides and delivers them
  (bin/jg-escalation-workflows.sh, live on every poll) and stamps the episode's
  owner time, which the escalation, the board card and the re-alert rungs below
  read.
  This library reads `JG_WAIT_ALERT_SECS` and `JG_PAUSE_RESURFACE_SECS` from
  that definition (`bin/jg-escalation-workflows.sh timers`) rather than
  defaulting them, so each number has one owner.
- Timers: the alert table owns them (`bin/jg-alert.sh timers`, from the
  stuck-wait ladder and the ready-idle row); the library writes no number. An
  environment override still wins: `JG_WAIT_ESCALATE_SECS` for Main's rung,
  `JG_WAIT_CARD_SECS` (above the escalation threshold) for the
  board card, and `JG_PROMPT_REALERT_SECS` for how often a
  reached rung is checked and raised again until its source clears (see
  "Re-raise until the wait is handled"). A declared pause rechecks at the
  `JG_PAUSE_RESURFACE_SECS` cadence instead and never escalates.
- Wait sources: the watcher writes `state/.wait-sources/<task>.prompt` for an
  unanswered permission prompt (rewritten on every sighting; a record older
  than three polls plus 30 seconds is ignored, so a prompt on a dead pane
  lapses) and
  `<task>.supervision` for a Squad Lead with work under way whose own watcher
  is not running. A wait source outranks an open decision and a pause.
  The watcher also writes `<task>.question` (a picker or question dialog on
  screen, for any harness, whatever status the terminal shows),
  `<task>.quota` (a provider rate-limit or usage-limit banner as the bottom of
  the visible screen: the banner and the prompt or status line under it. Text
  higher up is transcript, and a transcript can hold a sentence a test printed,
  so it never raises this source; nor does it for a lane whose own status line
  says done or failed, because a finished lane declares no wait),
  `<task>.errors` (one provider or API error line, such as an
  unknown user, a bad key or an unknown model, repeated three or more times in
  the pane: a runtime that fails every turn keeps changing the pane, so neither
  silence nor quota sees it) and `<task>.silent` (no status line, no native progress and no
  pane text change for `JG_SILENT_SECS`, default 900; a future-dated pause, a
  finished worker, an idle lead and a running validation are exempt), from
  `bin/jg-stuck-gate-lib.sh`. They are fresh-bounded like the prompt source and
  ride the same rungs, so a worker that ignores its own question still climbs.
  The silent source is the exception to the bound: a late scan on a loaded host
  has not ended the silence, so its record lapses only after the definition's
  `silence` timer (`JG_SILENT_SECS`) unread, for the ladder and the owner rung
  alike, and its episode keys on the window alone, keeping its clock and rung
  while the stated silence age grows on every scan.
- Episode record: one tab-separated line per lane at
  `state/.waiting-timers/<task>` holding signature, first-observed time,
  owner-delivery time, Main-rung time (0 before it fires), report key, miss
  count, board-card time, and last re-fire time. The report key is the wait's
  identity, `waiting-timer-<home>-<task>-g<generation>-<source key>`: home is
  a short hash of the Juggernaut home, generation is the arming second, and
  the source is the open decision key (or the pause key, `herdr-blocked`,
  `prompt`, `supervision`, `unkeyed`). Every line prints
  `id=<key> source=[<declaration>]`, so the exact unresolved source is named;
  a resolution closes only the wait it names. The `waiting-timer-` prefix is
  unchanged for the fork's reserved-key fold.
- Parent lines: `blocked [key=...]: waiting-timer-overdue: <task> (<verb>,
  observed <n>s, since=<epoch>); ...; source=[...]` on escalation and on every
  re-fire that raises (see "Re-raise until the wait is handled"), `resolved [key=...]: waiting-timer-cleared: ...` when the wait
  ends. A top-level wait with no parent escalates as a wake to the top level
  itself, never as a parent report.

## Escalation chain

A stuck worker never waits on the captain noticing it.
Every rung is checked again every `JG_PROMPT_REALERT_SECS` while the wait stays open.
An unresolved wait wakes its owner again at the recheck cadence (next section).

| rung | when | who acts |
|---|---|---|
| own-fleet read prompt | at once | the watcher approves it (`bin/jg-prompt-gate-lib.sh`) |
| secrets-path prompt (`.env`, `~/.config`, a home's `data/` or `config/`) | at once | the watcher rejects it and tells the worker why |
| any other prompt, question, decision, or blocker | first sight, then `JG_WAIT_ALERT_SECS` | the owning home is woken |
| still open | `JG_WAIT_ESCALATE_SECS` | a lead home reports `waiting-timer-overdue` to Main; Main steers the lead at once, never interrupting it (a busy lead reads the steer when its turn ends), naming the worker and its wait |
| still open | `JG_WAIT_CARD_SECS` | the main home posts a guarded board card, and dismisses it when the wait ends; a wait that is not a credential or login ask is recorded for Main to decide instead, because the board takes only a must ask (`bin/jg-ask-gate-lib.sh`) |

- A stuck state with a row in the owner table gets its owner's steps from the
  ladder before any of the model rungs above (see "Known next steps").
- A lead's own supervision not running is a Main wait from lead liveness, so a
  dead hop never goes silent; a dead lead rides its relaunch.
- A new supervisor session re-presents every open wait on its first tick, so a
  relaunched lead re-presents its stuck workers within one cycle.
- The main home reads only the overdue lines a lead appends to its own
  `state/<lead>.status`, never the lead's child records.
- The board card is raised from the main home only, even when Main has not
  read its wakes, so it still fires with Main absent.

## Known next steps

A stuck state names its owner, and the ladder itself takes that owner's automatic steps, in the watcher, with no model turn.
`JG_WAIT_OWNER_TABLE` in `bin/jg-wait-actions-lib.sh` is the one table (state, owner, steps in order, next owner), and its header owns the exact matching.
The first step is due at the owner alert and replaces the owner wake, and each later one is due where the Main rung would be.
A step stamps the episode's owner time, so the next rung times from the step.
When a row's steps are spent, its next owner, `lead`, gets the ordinary owner wake in its home (Main in the main home), and the Main rung follows as for any wait, naming the steps already taken.
A step that fails, or a stuck state with no row, climbs the ladder as before.

| state | owner | steps, in order | next owner |
|---|---|---|---|
| `silent`: the `silent` source on a worker whose own record declares no wait and holds no open decision | the worker | ring: one steer asking it to report where it is; relaunch: stuck-operator recovery's `bin/jg-control.sh <task> relaunch --note`, run detached with its outcome in `state/.waiting-timers/.acted/<task>.relaunch.log` | lead |
| `herdr-lab`: a ship or Recon whose open `blocked` line says it needs `--herdr-lab`, with no lab section in its brief | the watcher | rebrief: answer and close the decision, then relaunch the lane once with `bin/jg-control.sh relaunch --herdr-lab`, which adds the lab section to its brief | lead |
| `account-down`: the `account` source (the pane shows a subscription the runtime cannot use, or a failed sign-in) or the `quota` source (a usage or rate limit) on a Claude worker, in a home that pins `config/claude-account` | the watcher | recover: probe the pin once; if it is down, switch to the next account in the owner's `config/claude-account-fallbacks`, relaunch every live worker recorded on the dead account with `bin/jg-control.sh`, and raise one card (renew or not). No recorded fallback: raise the card and change nothing. An account that answers is not down, so the wait climbs the ladder as before | lead |
| `waits-for`: an open `blocked` or `needs-decision` line that says `waits-for: <ticket>` (the form `bin/jg-brief.sh` teaches), once that ticket has landed on the trunk | the landing | resume: one steer, with the blocker's key resolved in the same send, so the lane resumes and its decision closes | lead |

- `waits-for` ends with no timer: the landing check (`core/trunk-landing/trunk-landing.sh`) calls `jg_wait_waits_for_resume` the moment the ticket lands, so the lane is steered within the landing's own run; the table row is the backstop for a lane that declared its wait after the landing or whose send failed (the failure is in `data/jg-trunk-landing/resume.log`). While the ticket's own lane still runs and has not landed, the wait is quiet (`jg_wait_timer_quiet`): no owner wake, escalation or card. Once that lane is gone without landing, the wait rings as any blocker does.
- `account-down` never picks an account itself: only the owner's recorded list names one, and the pin changes only when a listed account answers its own probe (`bin/jg-account-outage-lib.sh`, state in `state/.account-outage/`). The card replaces the generic board card for that wait, and the cleared episode's minutes reach the ledger below as for any row.
- A worker that declared `blocked:`, `needs-decision:` or a pause is waiting on someone, so the silent steps never touch it.
- The steps live in `state/.waiting-timers/.acted/<task>` (state, time of the last step, steps taken, time of the first step), which outlives the episode on purpose: a ring changes the pane, so a silent wait clears and later re-arms, and the record tells the next episode the ring is spent.
- A status line written after the last step is progress and ends the record, as does the task's removal.

## Escalation minutes

Every episode whose first rung fired adds one row to the metrics ledger `data/metrics/escalations.tsv` when it clears: the clear time, task, key, first-fire time (the ladder's first step, else the owner wake), minutes from first fire to clear, the highest rung reached (`owner`, `main` or `card`), the ladder's own steps (or `-`), and why it ended.
A lead's `waiting-timer-cleared` report to Main carries the same minutes as `after <n> min`.

## Re-raise until the wait is handled

An unresolved blocker re-fires at every `JG_PROMPT_REALERT_SECS` recheck.
Reading or acknowledging its durable wake does not clear its source.
The owner must unblock, retry or reassign the work, or obtain a justified decision, and close the exact source key with evidence of that action.
Until the source clears, the existing ladder keeps raising the owner and Main hops, including after a session restart.
The one board card stays open on its existing cadence.

Expected pauses retain the change gate: a changed owner, reason, deadline or phase raises, while an unchanged pause is logged to `state/.waiting-timers/.unchanged.log`.
A pause also gets its existing bounded backstop raise.
The `[at=]` stamp moving does not count as a changed pause.
The gate's sidecar remains `state/.waiting-timers/.raised/<task>` and is removed with the episode.

## Green PR left unmerged

A recorded ready PR that is green and unmerged under yolo is a slow delivery, not a lane wait: it raises the `slow-delivery` alert of `bin/jg-alert.sh`, and the ladder above does not carry it.
`jg_wait_timers_green_pr` runs every tick for each ship task whose metadata holds `pr=` and `yolo=on` and whose merge poll is armed.
It reads the PR from the forge at most every `JG_GREEN_PR_POLL_SECS` (default 120).
Green means the forge reports the PR open, not a draft, with merge state `CLEAN`, which is the state `bin/jg-pr-merge.sh` merges on.
Only GitHub is read; any other forge, a missing `gh`, or an unreadable answer stays quiet, and an answer not refreshed for three reads lapses.
After the PR has stayed green at one head for `JG_GREEN_PR_SECS` (default 900), `jg-alert.sh raise slow-delivery <task> --deliver` raises one alert for the task; the alert table owns its rung and holder (rung 1 until the tick-driven climb exists), and a live alert is never raised twice.
- The alert resolves when the PR merges or closes, goes red or draft, gets a new head (the 15-minute clock re-arms), or yolo is off.
- A recorded hold also resolves it: a `paused:` or captain-held status line that is still the task's declared wait, or an open captain hold on the task.
- Merge authority is untouched: the alert only asks; the owner still merges through `bin/jg-pr-merge.sh`.
- Record: `state/.green-pr/<task>`, one tab-separated line holding last forge read time, first-green time at this head, head, and PR URL.

## Stalled ready backlog

A lead that ignores its ready-work wake (`bin/jg-watch.sh` `ready_work_waits_idle`) is the same ladder with the lead as the stuck party.
`jg_wait_timers_backlog` runs from a lead home's tick at most every `JG_READY_STALL_POLL_SECS` (default 60), and the watcher's `ready_backlog_stall_state` owns the condition.
The condition holds while a ready item with no open captain card could start now and the home has a free lane.
A free lane is fewer open lanes than `config/lane-target`, or than 4 without a usable one.
An item whose project's declared capacity is already held cannot start now, so it does not count (`bin/jg-project-capacity-lib.sh`).

| rung | when | who acts |
|---|---|---|
| ready work that could start | first sight | the existing ready-work wake asks the lead to dispatch |
| nothing started | `JG_READY_STALL_SECS` (default 600) | the lead is woken again, and it reports `waiting-timer-backlog-overdue` to Main naming the lead and the ready task ids, which is Main's event; Main's relay steers the lead without interrupting it (a busy lead reads the steer when its turn ends) |
| still nothing started | every `JG_PROMPT_REALERT_SECS` | both fire again |
| still open | `JG_WAIT_CARD_SECS` after Main's watcher first saw the report | the stalled backlog is recorded for Main to decide, not posted: a lead's own park-or-retry call is never the captain's |

A home with a pause record (`bin/jg-pause-lib.sh`, the one owner of that read) arms and escalates nothing: the same rule the ready-work check already honours for a declared pause.
An episode reported before the pause is closed with `waiting-timer-cleared` and the record dropped, so the clock starts again and the backlog rings again once the pause lifts.

- A start is a lane id that was not open before; it ends the episode and re-arms the clock.
- The condition clearing (no startable ready item, a free lane gone) ends the episode, and a reported one is closed with `waiting-timer-cleared`.
- An unreadable backlog leaves the episode untouched for that poll.
- While ready work waits but the condition does not hold, `state/.waiting-timers/.ready-backlog-why` holds one tab-separated line: when that reason began, the reason (`lanes-full` or `project-capacity`), and the open/target lane counts. It is the on-disk answer to why a waiting backlog raised no escalation, and it is removed when the condition holds or no ready work waits.
- Episode record: `state/.waiting-timers/.ready-backlog`, one tab-separated line holding first-observed time, open lane ids (comma-joined, `-` for none), report key (`waiting-timer-<home>-<lead>-g<generation>-ready-backlog`), first report time (0 before it), and last fire time.

## Provenance: byte-identical to the fork at the move

Every moved file was compared byte for byte against its fork source at
`0689b4b9d9ab3594f846cfe07c400edfa58244bf`; the sha256 manifest matched
across fork source and this directory. Treat any future diff against the fork
file as a contract change, not a refactor.

| moved file | fork source | sha256 |
|---|---|---|
| `wait-timers/bin/jg-wait-timers-lib.sh` | `bin/jg-wait-timers-lib.sh` | `5e4b399de21bdf47795dc9b0d52c12716be9b62bdb3422ad4d1f36878f0e0fd7` |
| `wait-timers/tests/jg-wait-timers.test.sh` | `tests/jg-wait-timers.test.sh` | `393b910d2bcafa41fa7b94a7f141e5c3652ab914b88b2d859545043a3938f08f` |
| `wait-timers/tests/jg-wait-timers-tmux-e2e.test.sh` | `tests/jg-wait-timers-tmux-e2e.test.sh` | `fc0f38458b02aa25efcf939bbf763bcdb01f57ce09fca888a6a68fc34c735fbf` |

## Side-by-side proof (re-run before the hook swaps the sourced path)

The acceptance proof runs the fork test and the moved test each against its
own library copy and diffs the verdicts. The library sources its two sibling
libraries from its own directory, so the moved side runs inside a throwaway
harness outside the moved files: a scratch copy of the fork tree at the
commit above whose `bin/` already holds those siblings, with only
`bin/jg-wait-timers-lib.sh` and `tests/jg-wait-timers.test.sh` replaced by
the moved bytes (verified identical first). Do not run the live-terminal
end-to-end test: it drives a real terminal session; it moves verbatim only.

1. Unpack the fork tree at the commit above into two scratch roots.
2. In the second root only, overwrite the timer library and its test with
   the moved files; `diff` both against the first root (must be empty) and
   re-check the sha256 table above.
3. Run `tests/jg-wait-timers.test.sh` in each root; both must exit 0 and
   print the same `ok` verdict lines (the harness's cycle-budget warnings
   carry process ids, so normalize digits before diffing).
4. Run the repo CI gate (the lint plus syntax check over every feature script)
   on the PR head.

Timing note: the journey gives each watcher cycle a small single-digit
budget, so run the proof on a quiet host — under heavy load a cycle can be
terminated before it records its delivery and the run fails on timing, not
on behavior.
