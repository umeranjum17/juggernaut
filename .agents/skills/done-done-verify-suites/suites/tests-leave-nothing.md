# Tests leave nothing behind

Run `done-done run -- bash tests/jg-test-leaves-nothing.test.sh`.
The journey builds a fixture home that links to a real tree, drives `bin/jg-lint.sh` on a plain and an `ln -sn` fixture link, and compares the repository listing before and after a link-building test.
It proves that a second link cannot nest inside the real tree and that the lint refuses a plain `ln -s` of the same-name form.
