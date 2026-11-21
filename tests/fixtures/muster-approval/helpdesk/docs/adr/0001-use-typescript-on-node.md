---
status: accepted
date: 2026-11-22
decision-makers: the captain
kind: stack
muster: <ticket id>
---
# Use TypeScript on Node

## Context and problem
The bot needs one language for its domain, its command line and, later, its chat widget. The team's standards pack
exists for TypeScript and React, and the captain answered R1Q1 "TypeScript, one language with the widget".

## Considered options
- TypeScript on Node 24 or later, run with type stripping, checked by the TypeScript and React standards pack. (chosen)
- Python 3 with a web framework, and a separate TypeScript widget.
- Go for the server, and a separate TypeScript widget.

## Decision
We use TypeScript on Node, because one language covers the domain, the command line and the widget, and the
standards pack already proves its rules on real paths.

## Consequences
- Good: one toolchain; domain types are shared with the widget; lint rules are proven, not only written.
- Bad: Node's type stripping allows only erasable syntax (no enums, no parameter properties); the code avoids them.

## Confirmation
`npx tsc --noEmit` and the ESLint preset `core/standards/typescript-react/base.js` pass in CI; every journey runs as
`node journeys/run.ts` with no build step.
