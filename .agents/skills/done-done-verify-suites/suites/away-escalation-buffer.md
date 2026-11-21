# Away escalation buffer

Away escalation buffer: run `done-done run -- bash tests/jg-away-escalation-buffer.test.sh`; it sources the supervise daemon over a throwaway state root and a shimmed tmux, buffers 163 repeats of each of three routine checks and proves the buffer holds three entries, one injection carries each exactly once and the delivered entries leave the buffer; a new distinct event and a repeat of a delivered check both reach the next injection (screen: none). Its log in `$DONE_DONE_EVIDENCE_ROOT` is the evidence.
