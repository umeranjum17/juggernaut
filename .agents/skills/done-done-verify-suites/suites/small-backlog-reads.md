# Small backlog reads

Small backlog reads: run `done-done run -- bash tests/jg-backlog-reads.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `jg_backlog_beads_read` over a stand-in bd proves a show asks bd for its one row, a plain list asks for open rows only, `--all` and `--state done` still read closed history, an unknown id still refuses, and the four reads of one cycle make one whole-store read through `JG_BACKLOG_SNAPSHOT` (screen: none).
