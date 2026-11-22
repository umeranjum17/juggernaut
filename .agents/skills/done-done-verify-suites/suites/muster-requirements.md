# A Muster interview carries requirements into the approved spec

Run `done-done run muster-requirements` (`bash tests/jg-muster-requirements.test.sh`) from the repository root.
The scripted interview uses an isolated board and the real Muster round commands to turn a request for a fast reply into an accepted numeric performance target.
It fills the spec template, approves the pack and checks that changing the performance target requires fresh approval.
The run records its output in `$DONE_DONE_EVIDENCE_ROOT` (screen: none).
