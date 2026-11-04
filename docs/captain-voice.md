# Captain voice

One markdown file says how a message to the captain must sound.
`defaults/captain-voice.md` is the seeded copy.
A home copies it to `config/captain-voice.md` to change the style for that home; the copy replaces the default whole.
`JG_VOICE_FILE` points at any other file, for a test or a trial.

## What the file holds

- Prose rules: STE100 sentence shape, outcome first, full pull request URLs, and who to address.
- A `## Settings` list: `mode` (`rewrite`, `warn`, `block` or `off`), `mode.<channel>` for one send point, and `max-sentence-words`.
- An `## Internal terms` table: a regular expression and the plain words that replace it.
  A replacement that starts with `?` is advice only: the checker reports the term and leaves it.

`bin/jg-voice.py` reads the file on every run.
Editing a row, a setting or a mode changes the next message, with no code change.
The checker never touches a URL, a code span, a `[key=value]` tag or a `key=value` token.
A status line (`verb [key=..]: note`) keeps its framing, and only the note is checked.
If the voice file or python3 is missing, the message goes out as written.

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
| Telegram, every text the gateway sends (replies, cards, outcomes, alerts, pushes) | `telegram.Send` in `core/bus/cmd/jg-bus/gateway_reply.go`, through `gateway_voice.go` | `rewrite` | Plain terms are replaced; the message is always sent |
| Chat reply | `jg-inbox.sh reply` | `block` | Refused with the list of terms to fix, so the author rewrites it |
| Squad Lead parent channel | `jg_parent_channel_append_once` in `bin/jg-parent-channel-lib.sh`, which every parent-channel publisher uses | `rewrite` | The note is rewritten before the dedupe check, so a retry stays one line; a line is never held back |

Not covered:

- The primary terminal chat. Nothing sends it: the harness prints the model's turn. The turn-end guards in [turnend-guard.md](turnend-guard.md) differ per harness and cannot rewrite text, so the prose rules in the voice file and `AGENTS.md` section 9 stay the only control there.
- The voice relay. It speaks text a person asked for, and a rewrite there would change what is read aloud.
- Telegram card edits, files and captions. Their text is not checked; a caption is the author's words.
- The machine escalation line in `bin/jg-pending-reply-lib.sh`. It is a fixed template for the supervising home, not a message to the captain.

## Tests

`tests/jg-voice.test.sh` runs the real checker through `jg-inbox.sh reply` and the parent-channel append.
The same test proves each role file, the role choice per send point, that a role file with settings or rules cannot weaken the shared rules, and that a worker brief carries the worker personality.
`go test ./cmd/jg-bus -run TestGatewayVoice` (in `core/bus`) proves the Telegram send and an edited file.
