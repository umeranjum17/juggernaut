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
- The owner's message is mirrored into the Overwatch session by the notification Overwatch already receives for the note: `check: captain inbox note <id> - [chat telegram <chat>:<message>] <text>`.
  It shows the source, the whole text (up to 400 characters) and each attached file as `[<kind> <size> <mime>]`, without the local path.
  It is sent once, because a replay of the same update adds no second notification, and a dropped message has none.
  This path needs no new channel, no typing into the pane and no model turn. Other notes keep their 100-character summary.
- `bin/jg-inbox.sh reply <id>` is the only way an answer reaches the chat. It is sent as a threaded reply, split at 4096 characters, and sent once.
- UI work lands with its pictures.
  A lead's review-ready or landed line for a UI task ends with `evidence=<path>,<path>` (`bin/jg-evidence-lib.sh`), read from `data/<task>/evidence.list`.
  `bin/jg-inbox.sh reply <id> --evidence-from "<that line>"` attaches those files, and `bin/jg-evidence-check.sh` (registered as a watcher check) flags a reply that names the PR and attaches nothing.
- Text messages and the mark on a tapped choice go out with Telegram HTML formatting.
  The gateway renders `**bold**`, `*italic*` or `_italic_`, `` `code` ``, fenced code, `[text](https://url)` and `> quote` lines to the matching tags.
  All other text has `&`, `<` and `>` escaped, and a marker with no partner stays text, so model text cannot break the markup.
  If Telegram answers "can't parse entities", the gateway sends the same text once as plain text.
  Tables and collapsible blocks stay off.
  File captions stay plain text.
- Add `--attach <path>` (repeatable) to `reply` to send files with the answer.
  The script only records the paths. The gateway sends them from disk, threaded on the owner's message.
  Pictures up to 10 MB go as photos, and Telegram falls back to a file if it refuses one. Other files go as files up to 50 MB.
  Up to 10 pictures, or up to 10 files, go as one album.
  The text is the caption of the first album when it fits 1024 characters.
- A note takes one `reply`. To send more on it, such as a later outcome or the pictures that came after the text, run `bin/jg-inbox.sh followup <id>` with the same arguments (`--attach`, text).
  Each followup is its own message threaded on the owner's note, sent once, in the order recorded.
- `reply` and `followup` print usage for `--help` or `-h` and record nothing.
  Text that opens with a dash is refused as an unknown option unless it comes after `--`, so a mistyped option is never sent to the owner.
  A note with no reply yet is refused: use `reply`.
- Add `--option <label>` (repeatable, 2 to 8, 60 characters each) to `reply` to ask the owner to choose.
  The pictures go as an album first. The text then goes as a message with one button per option.
  A choice never uses the text as an album caption, so the question stays beside the buttons.
  With no text the message reads "Choose one:".
  The owner taps a button. The gateway answers the tap at once, edits the message to add `Picked: <label>` and removes the buttons, and files a note.
  The note's first line is `[chat telegram <chat>:<message>]`, where the message is the one with the buttons. Its second line is `pick: <label> (<option set id>)`.
  A reply to the pick note is threaded on the message with the buttons.
- A button holds only `o:<option set id>:<n>`. The labels stay in `state/captain-chat/options.jsonl` and the picks in `state/captain-chat/picks.jsonl`.
- A tap is answered and not filed when it comes from anyone but the owner, names a set the gateway does not know, comes from another message, is older than `chat-option-days` (default 7), or repeats the pick.
  A second tap on a set that is already picked answers "Already picked: <label>" and files nothing.
  Add `--allow-change` to `reply` to let the owner change the pick: a tap on another button files a new pick note, and the message keeps its buttons with a ✅ on the current pick.
  A tap that Telegram sends again after a restart is the same note.
- A file is never sent when it is under `config/`, the bus state or `~/.ssh`, is named `.env*` or ends `.token`, `.pass`, `.key` or `.pem` (checked after symlinks), is over 50 MB, or is gone.
  The owner gets a text line saying which file was not sent and why.
  A file Telegram refuses is named in text too.
- When the gateway files a note it puts a 👀 reaction on the owner's message (`setMessageReaction`), so the owner sees it arrived. A reaction Telegram refuses is logged and never stops the note.
- While a note is open, the chat shows "typing…" (`sendChatAction`). It starts when the gateway files the note and repeats every 4 seconds, because Telegram shows it for about 5.
  It stops at once when `bin/jg-inbox.sh reply` answers the note, when the gateway stops, or after a hard cap of 10 minutes (`chat-typing-cap-seconds`) for a note nobody answers.
  A chat with several open notes gets one indicator. A refused action is logged once and never stops the note or its reply.
  A restarted gateway does not show it again for notes filed before the restart.
- A message that is only `/status` is answered by the gateway itself, threaded on it: the owner, the answers sent and that the bot is answering. It files no note and wakes no one. It is the only command.
  The reply ends with the owner's open asks in his own words, grouped Needs you / Not done / Done (verified), from `bin/jg-owner-asks.sh`, which builds them from the records with no model. Done needs a recorded release that runs; a merge alone is Not done.
- Remove the token file and run `bin/jg-stack.sh up` to retire the unit.
- The gateway sends the owner only what a real home published.
  Every event carries a `home` field, set by the publishing command.
  A card, outcome, alert, digest or summary is sent when that home is the gateway's own home, or a member of the machine registry (`state/bus/homes`) whose home and state directories are not a throw-away location.
  Any other event is named once in `state/captain-channel.log` and dropped.
  A `card-close` from such a home cannot close a real card.
  A test home reaches the machine's one bus when its config falls back to the shipped `live` default, so this rule, not each suite's discipline, keeps a test card off the chat.
  An event with no `home` is from a publisher older than the field and is still sent.
  `TestGatewayRefusesCardsFromTestHomes` proves it.
- The owner can send a photo, document, voice note, audio, video or round video note. Each is downloaded (Telegram allows up to 20 MB), stored once by content hash at `state/captain-chat/media/<day>/<sha256>.<ext>` (folders 0700, files 0600), and listed in the note as `[file <kind> <path> <size> <mime>]`. The `inbound` event on the bus carries the same files in an optional `media` list; older events have none. A caption becomes the note text.
- A file over 20 MB is not downloaded. The note says so and the bot tells the owner in the chat. A file that cannot be fetched is named in the note and the text is still filed. Files are deleted after `chat-media-days` (default 30).

## Voice notes

With a local speech engine installed, each voice, audio or video note the owner sends is turned into words on this machine, and the words go in the filed note on a line under the file line: `transcript: <text>`.
The `inbound` event carries them in the file's optional `transcript` field.
No audio leaves the machine, and nothing costs money.
Without an engine the gateway does exactly what it did before and says nothing extra.

- Install it once, by choice: `bin/jg-chat-transcribe.sh setup`. It downloads Hex (MIT, about 72 MB, checked against a pinned sha256) and its Parakeet English model (NVIDIA Open Model License, about 730 MB) into `state/captain-chat/stt`, which git ignores. Linux x64 only. Install and session start never run it. `bin/jg-chat-transcribe.sh status` says whether it is there.
- To use another engine, set `chat-transcribe-cmd` to a program that takes a 16 kHz mono wav and prints the words on stdout. The gateway converts the audio with `ffmpeg` first.
- The 👀 reaction is sent before the engine starts, so the owner sees the note arrived without waiting for the words.
- The audio is cut at `chat-transcribe-max-seconds` (default 300), and the line then reads `transcript (first 300 s only, the limit): <text>`. The whole run is stopped after `chat-transcribe-timeout` seconds (default 120).
- When the engine is missing, times out or fails, or the audio cannot be read, the note is still filed with its file line and one fixed line: `transcript: unavailable (<reason>)`.
- The words are never written to a log, and no engine output is, only the fixed reason.

## The voice file

Every text the gateway sends to the owner, and every `jg-inbox.sh reply`, goes through the editable voice file ([captain-voice.md](captain-voice.md)).
The gateway rewrites plain terms and always sends; a reply with an internal term is refused until it is rewritten.

## Main's turn summary

`bin/jg-captain-say.sh [--key <slug>] [--link <url>] <text>` (or the text on stdin) lets Main post a plain-words summary of its turn to the owner's chat.
It publishes a `summary` event to the `CAPTAIN` stream and never sends to the chat itself.
The `captain-gateway` consumer pushes the event to Telegram when it arrives, so the path has no polling and no file scan.
The same event is in `state/captain-channel.jsonl`, and a bus that refuses it falls back to the in-process send.
The script refuses, with exit 1 and the reason on stderr, text that holds a secret, text that is a raw status line, and text that the captain-facing rules reject (an internal id, a path or jargon, or no short first line).
`bin/jg-captain-card-lib.sh` owns those rules, and `AGENTS.md` section 9 owns the words.
Exit 2 is a usage error.
`--asks` appends the same owner-asks block under the text, so a status push lists what is left. Only the text above the block goes through the message rules; the whole message still goes through the secret check.
`tests/jg-captain-say-chat.test.sh` runs the whole path with a real Dapr sidecar, a real NATS server and a fake Bot API.

## Pushes to the owner

`bin/jg-bus.sh gateway push <text>` (or the text on stdin) sends one message to the owner's private chat without a question.
It is not threaded, and a long text is split at 4096 characters.
With no token file, no paired owner or a channel that is not live it sends nothing and prints nothing.
`bin/jg-migration-card.sh live --quiet` uses it to send the migration live table whenever a row changes, and once a day when none did.

## Away mode reaches the owner by itself

Entering away mode arms `bin/jg-away-reach.sh`, and the return disarms it; `bin/jg-afk-contract.sh` calls `arm` on `enter` and `disarm` on `archive`, so no further command exists.
Arming writes `state/away-reach.check.sh` and binds it with `bin/jg-check-register.sh`; the watcher runs it every check interval, in shell, with no model turn.
Everything it needs is on disk, so a restart of the home changes nothing.
While an away record exists it sends through `bin/jg-bus.sh gateway push`:

- One update every 30 minutes (`JG_AWAY_REACH_INTERVAL`): worker counts, then the owner asks (`bin/jg-owner-asks.sh`). An update equal to the last one sent is skipped, so an unchanged fleet is not news.
- An urgent message as the event arises, at most one check interval late: a new `needs-decision`, `blocked` or `failed` status line, or a line that asks for a sign-in or a credential. Each line is sent once, and secrets are removed.

A quiet-mode record (the owner is present) never arms it. `tests/jg-away-reach.test.sh` fails if the clock or the urgent path is removed.

## The migration card row

The migration card has a `chat` row, "captain chat (Telegram)".
A home with no token file shows it `absent`, silently, and the probe builds and sends nothing.
With a token file, `bin/jg-bus.sh gateway status --row` measures it.
It makes one `getMe` call and never sends a message.

- The gateway records each leg it completes in `state/captain-chat/roundtrip.tsv` (epoch, leg, id).
  The inbound legs are the owner's text, picture and file, filed as notes.
  The outbound legs are a plain text, a picture and a file sent with `jg-inbox.sh reply` and accepted by Telegram.
  A caption on an album does not count as the text leg.
- A running gateway also sends the owner every card, outcome, alert, digest and summary event from the bus, through the durable consumer `captain-gateway`.
  The Dapr sidecar publishes each event inside a CloudEvent envelope, so the consumer and the reply router read the event from the envelope's `data`.
  A body that is no envelope is read as the event itself.
  It starts at new events, so a first start sends no old ones.
  A send that fails is tried again for 10 minutes, and one the bot can never take (blocked, bad request) is not.
  An event not sent is named in `state/captain-channel-undelivered.jsonl`.
  When the bus refuses an event, the gateway's adapter sends it in-process, so the owner still hears it.
  A card with no options ends with "Reply to this message to answer."
  A text reply to that message is published as the card's answer, and the router sends it to the board.
  When the bus refuses the reply, the board's own route takes it at once.
- A card with options (every card `jg-question-card.sh post` makes: its `--option value=label` entries, where a bare option is its own label, or Yes and No) is sent with one button per option, and a text reply still works.
  The two sides stay in step:
  - A tap on a button publishes the reply event with the option's value as the answer (the label rides along), like a text reply. The gateway answers the tap and edits the message to `Answered: <label>` with no buttons.
  - An answer on the board edits the message to `Answered on the board: <answer>` and removes the buttons. `jg-board-answers.sh` and `jg-question-card.sh answer` publish `jg-bus publish card-close <key> answered --answer <words>`. A text reply edits the message the same way.
  - A card closed without an answer: `jg-bus publish card-close <key> "<why>"` edits the message to that text and removes the buttons.
  - A card published again with the same key and other text or options is edited in place, not sent twice. A card that is answered or closed is not reopened.
  - A late tap on an answered card answers the tap with "Already answered." and a withdrawn or unknown card with "This card is closed." Neither publishes anything. A tap from anyone but the owner, or on another message, is dropped.
  - A button holds `c:<12 hex>:<n>` (under 20 bytes). The hash names the card in `state/captain-chat/cards.jsonl`, which maps each card to its chat and message id, so edits survive a gateway restart. The last line of a card wins.
  - An edit that fails is tried again every 2 seconds until it works. An edit Telegram can never take (400, 403) is logged and dropped. The bot token is never stored or logged.
- `pending` names why: the service is not running (its heartbeat in `state/captain-chat/telegram.alive` is over two minutes old), `getMe` failed, or legs are missing.
  A missing-legs detail reads `in: text image - out: text - missing in file, out image file`.
- `live` needs all six legs inside the last 7 days: `6 of 6 legs, last <date>, <n> notes, <n> replies`.
  A merge alone never shows it live.
