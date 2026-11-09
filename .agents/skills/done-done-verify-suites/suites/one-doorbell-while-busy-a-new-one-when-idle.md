# One doorbell while busy, a new one when idle

One doorbell while busy, a new one when idle: run `done-done run -- bash tests/jg-send-inbox.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `bin/jg-send.sh` over a stubbed tmux and a real busy record (`bin/jg-busy-event.sh`) proves three steers to a busy worker ring once, while a worker whose turn ended (or that nothing proves busy) with an earlier rung steer still unhandled is rung again and never told "already rung" (screen: none).
