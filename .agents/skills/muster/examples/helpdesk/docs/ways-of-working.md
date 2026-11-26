---
status: approved
muster: <ticket id>
---
# Ways of working: help desk bot

Every rule names its check. A rule with no check is refused by the muster gate; a check with no planted-fault proof
is refused too.

## Stack
- TypeScript on Node 24 or later, run with type stripping - decision 0001.
- One store file on the host - decision 0002.
- One small server - decision 0003.

## Rules
| Rule | Why | Enforced by | Proof (planted fault fails, allowed use passes) |
|---|---|---|---|
| Strict types, no `any` | refusals are typed, not guessed | typescript-eslint strictTypeChecked in `core/standards/typescript-react/base.js` | the pack's R4 fault fails; its allowed file passes |
| The domain imports no command line, file or network code | dependencies point toward the domain | `import-x/no-restricted-paths` with the resolver setting | the pack's R6 faults fail; with the resolver removed the pack test reports the rule inert |
| No raw fetch outside `src/shared/api` | one place for auth, retries and errors | `no-restricted-globals` and `no-restricted-properties` (window.fetch, globalThis.fetch) | the pack's R1 faults fail; `src/shared/api/client.ts` passes |

## Engineering practices

| Practice | Status | Direction |
|---|---|---|
| SOLID | Decision | Give Conversation the reply and resolution rules and Handoff the assignment rules. Keep storage and CLI commands in the adapter. |
| DDD | Decision | Use Conversation and Handoff as defined in the glossary and put state transitions and invariants in the object that owns them. |
| Testing | Accepted recommendation | Use the fast public CLI cases for behaviour and add focused unit checks only if the domain grows beyond them. Keep cited replies, handoff and resolution as core end-to-end journeys. Run lint and types in CI and seal the real CLI objective runs with done-done before release. |
| Error handling | Decision | Return rule-specific DomainError refusals with exit 1 and report operational failures with a nonzero exit. |
| Security | Decision | Validate command inputs at the CLI boundary and restrict the conversation store to the service account. |
| Observability | Accepted recommendation | Use the CLI exit status and refusal reason to distinguish failures, and inspect conversation and handoff state with the show command. |

## Floor (numbers)
| Measure | Threshold | Enforced by |
|---|---|---|
| type errors | 0 | `npx tsc --noEmit` in CI |
| lint errors | 0 | `npx eslint .` in CI with the preset |

## Measured, not yet enforced
- none

## Comments
Explain why, never what. A comment that repeats the code is removed in review; no rule enforces it.

## Folders
`src/domain/` (objects and their rules), `src/` (adapters such as the command line), `journeys/` (proof). After
bulletproof-react's one-way imports: adapters import the domain, never the reverse.

## Tests
Journeys only: each drives the public command line on a fresh store; no unit tests, no mocks.

## Done means
Every objective journey passes on the released build, with a done-done receipt on the landed commit.

## Exceptions (time-limited)
- none
