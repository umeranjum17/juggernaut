---
status: draft   # draft | approved | delivered
muster: <ticket id>
depth: <light | full>
base: <the released version this changes>
---
# Change pack: <feature>

What this feature changes in the agreed documents, as a delta (after OpenSpec's ADDED, MODIFIED, REMOVED). The gate
compares every line below with the real difference between the documents before and after. Light depth keeps
Objects changed (invariants only if they change), Glossary changes, Decisions (one short record), Objectives and
Changelog.

## Objects changed
| Object | Behaviour added | Behaviour changed | Invariants added or changed |
|---|---|---|---|

## State machine changes
| Object | Transition (from -> to) | ADDED, MODIFIED or REMOVED | Trigger | Guard | Journey |
|---|---|---|---|---|---|

## Glossary changes
| Term | ADDED, MODIFIED or REMOVED | New meaning |
|---|---|---|

## Vision changes
<Lines this feature adds or changes in docs/vision.md, or "None".>

## Decisions (real ADRs, never idea notes)
- New: [ADR NNNN](../adr/NNNN-<slug>.md) <title> (<status>).
- Superseded: <NNNN, or none>.

## Screens changed
<Each changed screen with its design card pick, or "None: <why>".>

## Objectives
- <journey id> (new)
- <journey id> (preserve)

## Charter
<Full depth: the milestone, batch and ticket tables of templates/charter.md for this feature.>

## Changelog
- Added: <...>
- Changed: <...>
