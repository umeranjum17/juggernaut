# Item store contention and compaction

Source: `.done-done.yaml`, `journeys/item-store-contention.sh`, `tests/item-store-contention-e2e.test.sh`, `core/item-store/store.py`, `core/item-store/itemdb.py`, `core/item-store/jg-item`, `core/item-store/tickets.sql`, `core/item-store/tickets.sha256`, `core/item-store/adapters/tickets.py`, `core/item-store/adapters/bd_forms/create.py`, `core/item-store/adapters/bd_forms/link.py`, `core/item-store/adapters/bd_forms/read.py`.

## Drive and capture

Run `done-done run item-store-contention`.
The journey runs the contention and compaction test with the store's proofs and the ticket-log readers, and writes the log and steps.json into $DONE_DONE_EVIDENCE_ROOT.

## Checks

While one process holds the write lock for 16 s, 80 `jg-item open` writes and 12 ticket comments all land, and no refused-write intake item opens.
Compaction erases only aged superseded changes of closed and dropped tickets; every ticket, link, comment, event, memory, item and move row is unchanged, and the ticket tables replay from the log that is left.
The free pages return to the disk, and a store with the old never-erase trigger and no auto-vacuum takes the new trigger on open and incremental auto-vacuum at its next tick.
