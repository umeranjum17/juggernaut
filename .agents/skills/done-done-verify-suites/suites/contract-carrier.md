# Contract carrier

Contract carrier: run `bash tests/jg-contract-carrier.test.sh` (screen: none), then `bash journeys/thin-context.sh` through done-done; the run's own output is the evidence.
The test and the journey run the real `bin/jg-contract-carrier.sh` and the real `bin/jg-session-start.sh` in fixture homes under a fake harness: `check` names one proof for each of the nine verified primary harnesses, `ensure` writes `CLAUDE.local.md` with its one import line and `AGENTS.override.md` for codex as a copy of the core file (never over text the owner wrote, never over 32 KiB), the digest holds the contract at the start and after a compaction when the proof is not `file`, harness `unknown` and a home above a worker copy get no file, and no verified primary may read `none` once `AGENTS.md` is the core file.
The journey's live step (a real Haiku session and a real Codex session reading the contract in their first request) is opt-in: set `JG_THIN_CONTEXT_LIVE=1`.
