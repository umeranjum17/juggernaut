# Captain chat

The captain can text Overwatch from Telegram. The channel is optional: a home with no bot token file has no gateway, no service, and no message about it.

## Set up

1. Make a bot with BotFather. Save its token in `config/captain-chat/telegram.token` (mode 600; a group-readable file is refused).
2. With the gateway service stopped, run `bin/jg-bus.sh gateway pair`. Send the printed code to the bot in a private chat within 10 minutes. The first person to do so becomes the owner: their id is written as `telegram-allow-user` in `config/captain-channel`. No id is typed or shipped.
3. Run `bin/jg-stack.sh up`. It installs and starts the `jg-gateway` unit only where the token file exists.
4. `bin/jg-bus.sh gateway status` shows the owner, the bot (via `getMe`) and the answers sent.

## How it works

- The owner's private text becomes an inbox note whose first line is `[chat telegram <chat>:<message>]`. Anyone else is dropped and counted by time and update id, never by text.
- `bin/jg-inbox.sh reply <id>` is the only way an answer reaches the chat. It is sent as a threaded reply, split at 4096 characters, and sent once.
- Remove the token file and run `bin/jg-stack.sh up` to retire the unit.
