# Wake ledger

Wake ledger: run `done-done run -- bash tests/jg-wake-ledger.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `jg_wake_append` over a fixture home writes one `data/wake-ledger.tsv` row (epoch, home, kind, key, class) per wake in every class, the log shows an urgent heartbeat, a silent heartbeat over an unchanged fleet and a batched fleet-heartbeat check all present, a ledger whose first row is a week old moving to `wake-ledger.tsv.1`, and a home with no data directory getting no ledger while its wake still succeeds (screen: none).
