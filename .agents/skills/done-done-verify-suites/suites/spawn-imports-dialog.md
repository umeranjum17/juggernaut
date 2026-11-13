# spawn imports dialog

Run `done-done run spawn-imports-dialog` (`bash tests/jg-spawn-imports-dialog.test.sh`, with `bd` and `dolt` on the path); it drives a real Claude spawn against a stand-in pane that shows Claude's external-imports dialog.
The run log proves the spawn sends no key to the dialog, fails with the cause, and leaves no decline in the owner's store, so a later spawn is not refused.
