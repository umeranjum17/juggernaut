# Muster discovery feeds round one

Run `done-done run muster-discovery` from the repository root.
The [helpdesk fixture journey](../../../../tests/jg-muster-discover.test.sh) drives the public Muster and War Room commands in an isolated home.
It supplies synthetic lens and critic output, verifies that the first round waits for review, and confirms that the published findings inform the first board card.
The run saves the journey output in its evidence folder.
