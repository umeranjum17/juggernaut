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
`go test ./cmd/jg-bus -run TestGatewayVoice` (in `core/bus`) proves the Telegram send and an edited file.
