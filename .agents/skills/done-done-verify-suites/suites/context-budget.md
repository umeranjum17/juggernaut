# Context budget

Context budget: run `bash tests/jg-context-budget.test.sh` (screen: none); the run's own output is the evidence.
It holds each `ctx-` ceiling of `defaults/token-caps` at today's value on the shipped tree, fails a fixture file one byte over a line and names it, reads a made-up Claude Code transcript to its known total once per role and day into `data/context-load.tsv`, takes the brief lint's budget from `ctx-worker-brief`, and has the daily growth check report a line that is over.
Run `bash tests/jg-brief-lint.test.sh` with it, because the lint's budget moved from its rule table to the ceiling line.
