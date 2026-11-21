# Main's turn summary in the chat

Main's turn summary in the chat: run `done-done run -- bash tests/jg-captain-say-chat.test.sh` (needs go and python3, and skips without them); the real `bin/jg-captain-say.sh`, `bin/jg-bus.sh publish` and the chat gateway deliver a summary, and one read from stdin, to a fake Bot API as the owner's message, and a raw status line, a secret, an internal id and jargon are refused and published nowhere; a pre-fix binary (`JG_BUS_BIN`) sends nothing.
