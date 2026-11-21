# Item store contention and compaction

Run `done-done run item-store-contention` from the repository root.
It drives [`journeys/item-store-contention.sh`](../../../../journeys/item-store-contention.sh): parallel `jg-item` and `bd_compat.py` writers behind a 16 s write-lock holder, the tick's compaction of `fleet.db`, and an older store's upgrade, in throwaway homes.
The run captures the test log and `steps.json` in its evidence directory.
The [feature](../features/item-store-contention.md) lists what it checks.
