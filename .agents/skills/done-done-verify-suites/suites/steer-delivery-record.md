# Steer delivery record

Steer delivery record: run `done-done run -- bash tests/jg-delivery-record.test.sh` (log into `$DONE_DONE_EVIDENCE_ROOT`); on a throwaway accounts server a steer written through the inbox library is `stored`, a ring that returned 0 is `rung`, moving the file to `handled/` shows only `read`, `handled` is refused without an evidence kind and pointer and then carries it, the claim reaches the bus as its own `inbox.handled` event and adds no wake row, `failed` keeps its reason, `overdue` lists a steer nobody answered, and a dead bus never blocks the worker (screen: none).
