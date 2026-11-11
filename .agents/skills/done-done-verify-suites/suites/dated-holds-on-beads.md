# Dated holds on Beads

Dated holds on Beads: run `done-done run -- bash tests/jg-beads-native-n3.test.sh` with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` naming the pinned builds; on real stores a dated hold is a `deferred` row with a reason, a past date shows in `bd ready` with its linked work still stopped, `start` takes a due row in either form, every door that defers a row with no reason refuses, and export and import carry deferred rows.
