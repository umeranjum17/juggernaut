# Pre-Beads drop

Pre-Beads drop: run `done-done run pre-beads-drop` (`bash core/tickets-sync/run-drop-proof.sh`) with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` naming the pinned builds. The real `sync.py --drop-pre-beads DATE` over a real Beads store plans every open ticket and changes nothing, a row filed on the cut date is not dropped, `--apply` closes each earlier row with the note `dropped by captain 11 Nov` and each board ticket no row answers to, keeps an owner ask, a captain hold and an asked board ticket, and a second run finds nothing to drop (`drop.log`).
