# Chat gateway HTML formatting

Chat gateway HTML formatting: run `done-done run -- bash -c 'cd core/bus && go test -count=1 ./cmd/jg-bus -run "TestTelegramHTML" -v'` (log into `$DONE_DONE_EVIDENCE_ROOT`); a fake Telegram Bot API proves a message goes out with `parse_mode` HTML, the bold, italic, code, fence, link and quote tags, and its buttons and thread; that `&`, `<`, `>` and unpaired markers are escaped and every rendered tag nests; that a "can't parse entities" refusal is resent once as plain text and any other refusal is not; and that the mark on a tapped choice follows the same rules.
