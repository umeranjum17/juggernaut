# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 4. The diagram in the docs is the one the tables draw.
assert_equals "$(diagram_block)" "$(sed -n '/<!-- diagram:begin/,/<!-- diagram:end -->/p' "$DOC")" "docs/ticket-statechart.md drifted: run bash tests/jg-machine-ticket.test.sh --write"
pass "the documented diagram is generated from the tables"
