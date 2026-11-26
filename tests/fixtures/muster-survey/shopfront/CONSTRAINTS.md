# Constraints

Last reviewed: 2026-09-01

## Floor (always enforced)

- No new `eslint-disable` comments
- No skipped tests without a reason in the commit message

## Thresholds

- Line coverage stays at or above 80 percent (`npm test -- --coverage`)

## Measured, not yet enforced

- Bundle size is 212 KB today; it becomes a gate on 2026-12-01

## Exceptions

- `src/billing/legacy.ts` may use `any` until 2026-12-31 (the owner's word, 2026-09-01)

## Reviews

- Every change to `src/billing/` needs a second reader
