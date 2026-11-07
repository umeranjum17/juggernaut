# Captain voice

One markdown file says how a message to the captain must sound.
`defaults/captain-voice.md` is the seeded copy.
A home copies it to `config/captain-voice.md` to change the style for that home; the copy replaces the default whole.
`JG_VOICE_FILE` points at any other file, for a test or a trial.

## What the file holds

- Prose rules: STE100 sentence shape, outcome first, full pull request URLs, and who to address.
- A `## Settings` list: `mode` (`rewrite`, `warn`, `block` or `off`), `mode.<channel>` for one send point, and `max-sentence-words`.
- An `## Internal terms` table: a regular expression and the plain idea to say instead.
  The checker never swaps that wording into a sentence.
  It gives it to the rewrite step as guidance and shows it to an author whose message is refused.

`bin/jg-voice.py` reads the file on every run.
Editing a row, a setting or a mode changes the next message, with no code change.
The checker never touches a URL, a code span, a `[key=value]` tag or a `key=value` token.
A status line (`verb [key=..]: note`) keeps its framing, and only the note is checked.
If the voice file or python3 is missing, the message goes out as written.

## The ask block

A reply or report that answers an ask must tell the captain what his ask was: a `Your ask:` line that quotes his words and carries their date, then `Done:`, `Not done:` and `Next:` lines, and a proof link.
`bin/jg-voice.py` checks this shape itself, with no model call, because a rewrite cannot invent his words.
The rule is structure, so it is refused even in mode `rewrite`; mode `warn` reports it and sends the message, and mode `off` skips it.

Two triggers, both deterministic:

- The send point passes the ask: `--ask <his words> --ask-date <YYYY-MM-DD>`.
  A message in that context must carry the whole block, and at least 60% of the content words of its `Your ask:` line must occur in his words, so a paraphrase is refused and a quote passes.
  `bin/jg-inbox.sh reply` and `followup` pass the note they answer, which is his ask.
- The message carries a `Your ask:` line of its own.
  Then the block must be complete at every send point, so a half-written one is refused before it leaves.

A pure acknowledgement answers no ask and passes: 25 words or fewer, with no proof link, no `Your ask:` line and no `Done:`, `Not done:` or `Next:` line.
That keeps the standing `Captain, standing by.` working.
The check cannot tell a short claim from a greeting, so keep a claim short enough to pass only when it needs no reference.

## The rewrite step

A message with no banned term goes out unchanged.
A message with a banned term, in mode `rewrite`, is rewritten whole by a model against the voice file.
The checker then reads the result again.
It sends the result only when no banned term remains and every URL, code span and `key=value` token is still there.
Otherwise nothing is sent.
The checker then exits 1 with an instruction to re-draft the message in whole plain sentences.
A word is never swapped inside a sentence, so a message never ships half rewritten.

The rewrite command is `JG_VOICE_REWRITE_CMD`, else the first line of `config/voice-rewrite-command`, else `claude -p` on Haiku with no tools, run from an empty directory.
It reads the request on stdin and prints the new message.
`JG_VOICE_REWRITE_TIMEOUT` sets its limit in seconds (45 by default).
A test sets the command to a stub, so no test calls a real model.

## Layout

A chat message keeps its layout, so the checker sets it right on every send, in any mode except `off`.
It puts each list item on its own line.
It splits a numbered list that was run into one line when the numbers count up from 1.
It puts a blank line between a list and the prose around it.
It leaves a fenced code block and prose with no list as written.
The rewrite step is told to keep the layout, and a rewrite that turns a list of items into fewer items is refused with the same re-draft instruction.
A status line sent with `--line` keeps its one line.
A home with its own `config/captain-voice.md` keeps its own banned terms, so it copies new rows from `defaults/captain-voice.md` by hand.

## Role personality files

Each role has one more markdown file beside the shared voice file, which adds a personality and nothing else:

| Role | Default | Home copy |
|---|---|---|
| Overwatch | `defaults/captain-voice-overwatch.md` | `config/captain-voice-overwatch.md` |
| Squad Lead | `defaults/captain-voice-squad-lead.md` | `config/captain-voice-squad-lead.md` |
| Worker | `defaults/captain-voice-worker.md` | `config/captain-voice-worker.md` |

The captain edits a role file to change that role's tone, with no code change.
A home copy replaces the default whole, and `JG_VOICE_ROLE_FILE` points at any other file, for a test or a trial.
`bin/jg-voice.py` picks the role from `--role`, else `JG_VOICE_ROLE`, else the send point: the parent channel is the Squad Lead's, and the Telegram send and the chat reply are the Overwatch's, or the Squad Lead's in a Squad Lead home.

A role file cannot override or weaken the shared rules.
The checker reads only the `## Personality` section of a role file.
Every setting, mode, limit and banned term still comes from the shared file.
If a role file carries any other section, the checker ignores it, reports it on stderr, and `check` exits 1.
A personality over 40 lines is cut.
The default personalities pass the shared rules, and a test proves it.

A personality is text for the agent that writes the message, so it reaches the writer where the writer reads its context:

- `bin/jg-session-start.sh` prints the Overwatch or Squad Lead personality in the context digest.
- `bin/jg-brief.sh` adds the worker personality to every ship and Recon brief under `# Voice`.
- `jg-voice.py persona [--role R]` prints it on demand.

The checker then enforces the shared rules on whatever the writer sends, at the send points below.

## Send points

Covered, each calling the same checker:

| Send point | Where | Default mode | What a break does |
|---|---|---|---|
| Telegram, every text the gateway sends (replies, cards, outcomes, alerts, pushes) | `telegram.Send` in `core/bus/cmd/jg-bus/gateway_reply.go`, through `gateway_voice.go` | `rewrite` | The message is rewritten whole, or refused: the send fails with the re-draft instruction and the gateway records it as undelivered. A banned term is never sent |
| Chat reply | `jg-inbox.sh reply` | `block` | Refused with the list of terms to fix, so the author rewrites it |
| Squad Lead parent channel | `jg_parent_channel_append_once` in `bin/jg-parent-channel-lib.sh`, which every parent-channel publisher uses | `rewrite` | The note is rewritten whole before the dedupe check, so a retry stays one line; if the rewrite fails the line is still written as it is, because a line is never held back |

Not covered:

- The primary terminal chat. Nothing sends it: the harness prints the model's turn. The turn-end guards in [turnend-guard.md](turnend-guard.md) differ per harness and cannot rewrite text, so the prose rules in the voice file and `AGENTS.md` section 9 stay the only control there.
- The voice relay. It speaks text a person asked for, and a rewrite there would change what is read aloud.
- Telegram card edits, files and captions. Their text is not checked; a caption is the author's words.
- The machine escalation line in `bin/jg-pending-reply-lib.sh`. It is a fixed template for the supervising home, not a message to the captain.

## Tests

`tests/jg-voice.test.sh` runs the real checker through `jg-inbox.sh reply` and the parent-channel append.
It also proves the ask block: a reply that answers his note and carries no block is refused, the same reply with the block passes, a half-written block is refused at the check, and a pure acknowledgement still passes.
The same test proves each role file, the role choice per send point, that a role file with settings or rules cannot weaken the shared rules, and that a worker brief carries the worker personality.
The test runs both messages from the captain's screenshot through the path with a stub rewrite and asserts that no flagged term and no broken phrase reaches the captain.
`go test ./cmd/jg-bus -run TestGatewayVoice` (in `core/bus`) proves the Telegram send, a refused send and an edited file.
