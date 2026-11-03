# Captain chat

The captain can text Overwatch from Telegram. The channel is optional: a home with no bot token file has no gateway, no service, and no message about it.

## Bring your own bot

Every user makes their own Telegram bot. Juggernaut ships no bot, no token and no user id. Setup is a command you choose to run; install and session start never run it or ask for it.

Run `bin/jg-bus.sh gateway setup` (stop the gateway service first if it runs). It takes about two minutes:

1. It explains the BotFather steps: open @BotFather in Telegram, send `/newbot`, choose a name and a username that ends in `bot`, copy the token.
2. You paste the token. Nothing shows as you type, and the token is never put in a command line, an environment variable or a log.
3. It asks Telegram `getMe` and prints your bot's username. If Telegram refuses the token, nothing is saved.
4. It stores the token in `config/captain-chat/telegram.token` with mode 600 (a group-readable file is refused). A token already stored is kept when you press Enter alone.
5. It pairs you: open the bot, send the printed code in a private chat within 10 minutes. The first person to do so becomes the owner, and their id is written as `telegram-allow-user` in `config/captain-channel`. No id is typed or shipped.
6. Run `bin/jg-stack.sh up`. It installs and starts the `jg-gateway` unit only where the token file exists.

`bin/jg-bus.sh gateway status` shows the owner, the bot (via `getMe`) and the answers sent. `gateway pair` repeats step 5 alone, for example to change the owner.

## Set up by hand

Save the token in `config/captain-chat/telegram.token` (mode 600), then run steps 5 and 6 above.

## How it works

- The owner's private text becomes an inbox note whose first line is `[chat telegram <chat>:<message>]`. Anyone else is dropped and counted by time and update id, never by text.
- `bin/jg-inbox.sh reply <id>` is the only way an answer reaches the chat. It is sent as a threaded reply, split at 4096 characters, and sent once.
- Add `--attach <path>` (repeatable) to `reply` to send files with the answer.
  The script only records the paths. The gateway sends them from disk, threaded on the owner's message.
  Pictures up to 10 MB go as photos, and Telegram falls back to a file if it refuses one. Other files go as files up to 50 MB.
  Up to 10 pictures, or up to 10 files, go as one album.
  The text is the caption of the first album when it fits 1024 characters.
- A file is never sent when it is under `config/`, the bus state or `~/.ssh`, is named `.env*` or ends `.token`, `.pass`, `.key` or `.pem` (checked after symlinks), is over 50 MB, or is gone.
  The owner gets a text line saying which file was not sent and why.
  A file Telegram refuses is named in text too.
- Remove the token file and run `bin/jg-stack.sh up` to retire the unit.
- The owner can send a photo, document, voice note, audio or video. Each is downloaded (Telegram allows up to 20 MB), stored once by content hash at `state/captain-chat/media/<day>/<sha256>.<ext>` (folders 0700, files 0600), and listed in the note as `[file <kind> <path> <size> <mime>]`. The `inbound` event on the bus carries the same files in an optional `media` list; older events have none. A caption becomes the note text.
- A file over 20 MB is not downloaded. The note says so and the bot tells the owner in the chat. A file that cannot be fetched is named in the note and the text is still filed. Files are deleted after `chat-media-days` (default 30).

## Pushes to the owner

`bin/jg-bus.sh gateway push <text>` (or the text on stdin) sends one message to the owner's private chat without a question.
It is not threaded, and a long text is split at 4096 characters.
With no token file, no paired owner or a channel that is not live it sends nothing and prints nothing.
`bin/jg-migration-card.sh live --quiet` uses it to send the migration live table whenever a row changes, and once a day when none did.

## The migration card row

The migration card has a `chat` row, "captain chat (Telegram)".
A home with no token file shows it `absent`, silently, and the probe builds and sends nothing.
With a token file, `bin/jg-bus.sh gateway status --row` measures it.
It makes one `getMe` call and never sends a message.

- The gateway records each leg it completes in `state/captain-chat/roundtrip.tsv` (epoch, leg, id).
  The inbound legs are the owner's text, picture and file, filed as notes.
  The outbound legs are a plain text, a picture and a file sent with `jg-inbox.sh reply` and accepted by Telegram.
  A caption on an album does not count as the text leg.
- A running gateway also sends the owner every card, outcome, alert and digest event from the bus, through the durable consumer `captain-gateway`.
  It starts at new events, so a first start sends no old ones.
  A send that fails is tried again for 10 minutes, and one the bot can never take (blocked, bad request) is not.
  An event not sent is named in `state/captain-channel-undelivered.jsonl`.
  When the bus refuses an event, the gateway's adapter sends it in-process, so the owner still hears it.
- `pending` names why: the service is not running (its heartbeat in `state/captain-chat/telegram.alive` is over two minutes old), `getMe` failed, or legs are missing.
  A missing-legs detail reads `in: text image - out: text - missing in file, out image file`.
- `live` needs all six legs inside the last 7 days: `6 of 6 legs, last <date>, <n> notes, <n> replies`.
  A merge alone never shows it live.
