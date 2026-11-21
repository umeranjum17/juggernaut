# Design card carries mocks

Design card carries mocks: run `done-done run jg-design-card-mocks` to drive the real `bin/jg-question-card.sh post --must design-pick --mock <option>=<file>` into a real `sign-off-axi` board; a design-pick with three options and three mocks lists three mocks on the board record, and a card with a missing, stray or doubled mock, or a mock on a card that is not a design pick, is refused and posts nothing. The run's log in done-done's evidence directory is the proof.
