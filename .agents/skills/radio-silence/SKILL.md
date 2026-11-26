---
name: radio-silence
description: Use when the captain invokes /radio-silence or asks for quiet mode, to stay in the session with fewer routine wake turns.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet supervision mode (kunchenguid/juggernaut#2356): the same token-saving
daemon tradeoff as `/watchover`, made explicit for a captain who is staying,
watching the session, and does not want to exit the mode just by chatting.

Where a daemon runs, this skill is a thin wrapper.
The `watchover` skill owns the daemon's injection, busy/composer guards, and reliability properties; quiet mode uses that machinery while the captain remains present.
For captain-held rechecks under quiet, see [architecture](../../../docs/architecture.md).

## What it does

0. **First check whether quiet mode needs anything here.**
   On Pi or pi-signed, enter nothing: the attended branch already keeps routine wakes out of this conversation (the `watchover` skill's step 2); tell the captain so.
   Everywhere else run `jg radio afk-launch quiet-check`; the launch script header's QUIET MODE owns what each result means.
   - Exit 0: enter nothing - no record, no flag, no daemon, and `/radio-silence off` then needs nothing either.
     Tell the captain in `AGENTS.md` section 9 language that supervision here already works that way: routine fleet events stay off this conversation, while decisions, failures, credentials, and review-ready work still reach them.
     When its line says the supervision session is paused, say instead that routine updates reach them until it recovers, and when it next retries.
   - Exit 2: an away record is live, so the captain has returned: run the `watchover` skill's return and clear its catch-up gate, then run `quiet-check` again and follow its new result.
   - Exit 1: go on to step 1; if it printed a line, first tell the captain plainly what keeps supervision from already being quiet here.

1. **Enter the lifecycle through `jg radio afk-launch enter`, exactly as `/watchover`
   does, with `JG_AFK_MODE=quiet` set first.**
   Follow the `watchover` skill's record entry, daemon launch, and announcement steps,
   except that on a home that runs the supervision host its `/watchover` no-daemon rule does not apply
   after `quiet-check` exits 1. Never arm a separate `jg-watch.sh`. Export
   `JG_AFK_MODE=quiet` in the shell that invokes `jg radio afk-launch enter`
   and `start` (or `start-native`), so the record notes quiet mode and
   `state/.afk`'s first line reads `quiet` instead of `away`.
   On a home that runs the supervision host, launch the daemon on the path
   this harness uses without the host; `start` and `start-native` take quiet
   mode from the record `enter` wrote.
   Keep `JG_AFK_MODE=quiet` on a quiet refresh: an `/watchover` entry, even without new words, replaces a quiet record with an away record and starts hold-for-return.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work - ordinary chat will not exit this, say
   `/radio-silence off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/watchover`, ordinary chat is never the exit signal - that is the entire
point of this mode (AGENTS.md section 8's away-mode stub, quiet branch).

- Only an explicit `/radio-silence off` (or the captain plainly asking to leave quiet
  mode / resume normal supervision) exits it: run `jg radio afk-return begin`
  unchanged, exactly the procedure `/watchover`'s "How to exit afk" section
  documents for its own return path (correct-ordered daemon shutdown,
  durable wake presentation and acknowledgement, escalation/wedge evidence,
  and the return-catch-up gate).
  That command does not read or care about the flag's mode, so it needs no
  quiet-specific variant.
- A marked daemon escalation, or a message beginning `/radio-silence` while already
  in quiet mode (refresh, not exit) -> stay in quiet mode and process it, the
  same two carve-outs `/watchover` documents for away mode.
- Every other message while in quiet mode is simply answered as ordinary
  work; the flag and daemon are left untouched.

## Orthogonal to approval authority

Quiet mode changes how aggressively Juggernaut surfaces things, never who approves what.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy.

The captain is present, so quiet mode holds nothing for a return.
The record a quiet entry writes carries quiet mode (`jg radio afk-contract mode`), and its entry, read-back, and session-start lines say so.
Every action the captain asks for or standing authority covers - landing local-only work, a merge, a dispatch - proceeds now exactly as it would without quiet mode; the `watchover` skill's away holds never apply to a quiet record.

## Must not hide a decision or a failure

Per the issue's own author triage: quiet mode is presentation only.
Progress, retries, and internal mechanics stay below deck exactly as in away
mode, but review-ready work, findings, decisions, failures, and credentials
escalate every time, through the same classification policy `/watchover` owns.
Quiet mode is opt-in and never the unconsented default; only an explicit
`/radio-silence` invocation enters it.
