# Muster pack fixtures

`example/` holds the committed example packs that `tests/jg-muster-gate.test.sh` runs `bin/jg-muster-gate.sh` against.
`example/helpdesk/` is a brand-new help desk bot at complete depth, with every pack document filled.
`example/skeleton/` holds the files that differ in that project's skeleton commit.
`example/rated/` is the same project after a feature muster at full depth, with its change pack `docs/changes/rate-a-conversation.md`.
`diff -r example/helpdesk example/rated` is the real change that the change pack must describe, line for line.
Both trees were copied byte for byte from the jg-6si example pack; edit them only together, because the rated change pack is checked against the help desk before it.
The test applies each planted fault to a throwaway copy, so nothing here is ever changed by a run.
Text adapted from Matt Pocock's skills (MIT) and MADR 4.0.0 (MIT OR CC0); the notices go in the muster skill's UPSTREAM-LICENSE.
