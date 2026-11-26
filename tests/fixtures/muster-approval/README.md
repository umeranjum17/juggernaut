# Fixtures of tests/jg-muster-approval.test.sh

- `helpdesk/` and `rated/`: the example pack, a complete project and a feature on it (byte for byte from the jg-6si
  example pack). `rated/` holds the change pack `rate-a-conversation`; its documents before it are `helpdesk/`.
- `pack-check.py` and `stand-in-gate.sh`: the stand-in for `bin/jg-muster-gate.sh` (the test sets `JG_MUSTER_GATE`).
  It is the prototype of that gate, so the refusals are the real ones (an idea-only decision record, a missing vision,
  an unlisted vision promise or glossary meaning).
- `plan-fixture.py`: writes the plan a lane would write for an approved manifest and its charter, in one of the
  variants the test names (formats.md section 5).
