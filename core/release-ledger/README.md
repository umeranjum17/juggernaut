# release-ledger

One dated ledger of what became of each landing: Built, Landed, In use, Released, and reverted (`docs/trunk-flow.md` names the stages).
It answers "which approved change is where" from the records the lander and the release already write; it adds no record of its own that a writer reads.

`ledger.sh build [--dry-run]` rewrites `data/release-ledger.tsv` from those records. A second build on unchanged records is byte-equal. `--dry-run` prints the ledger and writes nothing.

| Column | Source |
|---|---|
| `ticket`, `project`, `commit`, `landed` | one row per non-revert row of `data/trunk-landings.tsv` |
| `built` | `done=<epoch>` of the landing's row in `data/trunk-landing-proofs.tsv`, else the ready time of the older `data/trunk-latency.tsv` |
| `in_use` | the first `live` row of `data/trunk-in-use.tsv` whose commit holds the landing |
| `released`, `release` | the first row of `data/trunk-versions.tsv` whose cut commit holds the landing, and that version's branch |
| `reverted`, `reverted_by` | the `revert-<lane>` row whose `reverts-<12 hex>` mode names the landing's commit, and its commit |

Times are epoch seconds. An empty column means the stage was not reached or not recorded, never a guess.
"Holds" is git ancestry in `projects/<project>`, found once per distinct commit with one incremental `rev-list`.
The release time is the cut of the version, the nearest record of the release merge.

Later slices of `jgp-r1-ledger` add the replay and reconcile, publication timing, owner involvement and proof regime, and the view.
