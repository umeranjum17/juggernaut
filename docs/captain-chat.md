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
- Remove the token file and run `bin/jg-stack.sh up` to retire the unit.
