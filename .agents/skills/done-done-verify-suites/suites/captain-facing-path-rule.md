# Captain-facing path rule

Captain-facing path rule: run `done-done run -- bash tests/jg-path-guard.test.sh` with the suite log written into `$DONE_DONE_EVIDENCE_ROOT`; it drives `bin/jg-path-guard.sh` and the real `jg_parent_channel_append_once`, and proves a prose path is refused or withheld, a board key (`#reports/`, `#decide/`, `#designs/`) or "picture attached" lets the line pass, a line with both passes, a URL and a `report=` pointer are not paths, and a withheld line is still delivered to the parent channel.
