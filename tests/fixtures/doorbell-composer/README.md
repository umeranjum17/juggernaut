# Doorbell composer frames

The Claude Code bare-composer frame (`❯` between two rules, `? for shortcuts`
below) replayed by `tests/jg-doorbell-composer.test.sh`, with the fleet's real
doorbell line substituted for `@DOORBELL@` and its first 40 characters for
`@DOORBELL_PART@`, because the line names the throwaway home's own inbox.

| file | what the composer holds |
| --- | --- |
| `stuck.txt` | the whole doorbell line, never submitted (a swallowed Enter) |
| `partial.txt` | a leading part of it: typing interrupted mid-line |
| `emptied.txt` | nothing: the composer after the doorbell was submitted or cleared |
| `draft.txt` | a human draft, which is never keyed |
| `glued.txt` | the prompt payload the captain submitted: a stuck doorbell line, then his own words |

The frames are the shape these tests need, not a fresh pane capture: this task
ran without a live harness pane. `glued.txt` is byte-for-byte the text the captain's
screenshot showed, with the doorbell line itself substituted in.
