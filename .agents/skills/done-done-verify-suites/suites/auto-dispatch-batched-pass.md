# Auto-dispatch batched pass and pool cap

Auto-dispatch batched pass and pool cap: run `done-done run -- bash tests/jg-auto-dispatch-batch.test.sh` (it writes `auto-dispatch-batch.log` into `$DONE_DONE_EVIDENCE_ROOT`).
It proves `bin/jg-captain-hold.sh blocking --batch` matches per-row `blocking <id>` identically across held, gated, forward-linked, reverse-linked, parent-linked, unapproved/answered/signed `design-ux`, legacy-aliased, clear, absent, and fail-closed cases.
It proves a synthetic 138-row `core/auto-dispatch/dispatch.sh pass` with `config/item-store` enabled makes exactly one batched hold read and finishes in seconds.
It also counts one pool status read per eligible project across multiple candidates and one decision read per pass, including when the batch response is invalid.
A second pass reads both projects again and observes changed pool capacity and readability.
It proves `ready_backlog_stall_state` in `bin/jg-watch.sh` makes one batched hold read, a running dispatch pass never stalls fast checks or slow-sweep checks in `bin/jg-watch.sh`, and `jg_treehouse_clone_pool_prepare` in `bin/jg-wake-lib.sh` raises `treehouse.toml` `max_trees` to follow the home's lane-limit copy cap (screen: none).
