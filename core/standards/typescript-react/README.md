# TypeScript and React standards pack

A reusable ESLint preset for a React and TypeScript project, plus opt-in bans.
The preset carries no lab switch: it reads no environment variable and names no fixture file.
A project opts in when its rules step writes an `eslint.config.js` that imports it.

```js
// eslint.config.js of a project that adopts the pack (no ban)
import base from "<path to this pack>/base.js";
export default base;
```

The rules assume the bulletproof-react layout: `src/app`, `src/features/*` and `src/shared`, with the one api client in `src/shared/api`.
Type-aware rules need a `tsconfig.json` in the folder ESLint runs from.

## What each rule catches, and its allowed use

| Id | Rule | Catches | Allowed use stays clean |
| --- | --- | --- | --- |
| R1 | `no-restricted-globals` | a bare `fetch(...)` outside the api client | `fetch` inside `src/shared/api/**` |
| R1b | `no-restricted-properties` | `window.fetch(...)` and `globalThis.fetch(...)` outside the api client | the same folder |
| R2 | `no-restricted-imports` (ban) | `import { useEffect } from "react"` | `useState` and other hooks |
| R2b | `no-restricted-syntax` (ban) | `React.useEffect(...)` through the namespace | the same |
| R3 | `react-you-might-not-need-an-effect/no-derived-state` | state copied from props or state inside an effect | the value computed during render |
| R4 | `@typescript-eslint/no-explicit-any` | an explicit `any` | `unknown` with a narrowing check |
| R5 | `@typescript-eslint/no-floating-promises` | a promise that is neither awaited nor handled | `await`, or returning the promise |
| R6a | `import-x/no-restricted-paths` | a feature importing `src/app` | a feature importing `src/shared` |
| R6b | `import-x/no-restricted-paths` | `src/shared` importing a feature or `src/app` | `src/app` importing what it likes |
| R7 | `react-hooks/set-state-in-effect` | `setState` called directly in an effect body | `setState` from a timer or subscription inside the effect |

R1, R1b and R3 to R7 are in `base.js`; R2 and R2b are in `bans/no-use-effect.js`, because only a project whose owner banned `useEffect` wants them.
The preset also turns on the `typescript-eslint` strict and stylistic type-checked sets, the `react-hooks` recommended set and the `you-might-not-need-an-effect` strict set.

The folder rule (R6) needs its resolver setting, `import-x/resolver`, in the preset.
Without it ESLint reports nothing and the rule is inert: that is the failure `fixtures/` proves by running the lab-only config `fixtures/project-a/eslint.noresolver.config.js` and requiring it to fail.

## Add a ban

A ban is a flat-config object in `bans/<name>.js` with its own message, and a project adds it after the base.

```js
// eslint.config.js of a project that banned useEffect
import base from "<path to this pack>/base.js";
import noUseEffect from "<path to this pack>/bans/no-use-effect.js";
export default [...base, noUseEffect];
```

A ban ships with its proof, or it is not part of the pack:

1. A fault file on an ordinary project path that raises the ban's rule id, one per way the rule can be reached (an import, a namespace, `window.`, `globalThis.`), because a rule that catches only the first spelling is a rule that is half inert.
2. An allowed file that is the sanctioned alternative and raises nothing.
3. Both rows in `fixtures/score.py` (`EXPECT` and `ALLOWED`), so `bash tests/standards-typescript-react.test.sh` counts them.

## Install and prove

`package.json` and `package-lock.json` pin the exact versions, and the test installs them with `npm ci --ignore-scripts` into a throwaway folder.
`bash tests/standards-typescript-react.test.sh` ends with `faults 10/10, allowed 8/8, inert check ok`.
See `fixtures/README.md` for the two fixture projects and the scorer.

## Why Biome and oxlint are speed options only

The same ten faults and eight allowed uses ran through each linter at the pinned versions (Biome 2.6.8, oxlint 1.94.0):

| Linter | Faults caught | Allowed uses clean | Rules it missed |
| --- | --- | --- | --- |
| ESLint with this pack | 10 of 10 | 8 of 8 | none |
| Biome | 3 of 10, with and without its project domain | 8 of 8 | R1b R2b R3 R5 R6a R6b R7 |
| oxlint | 4 of 10 | 8 of 8 | R1b R2b R3 R5 R6a R6b |

One run outside this lab saw Biome's floating-promise rule fire where this run did not, so that count is not stable between hosts.
Use Biome or oxlint beside ESLint for fast feedback in an editor, never instead of it: a rule that does not fire is a standard that is not followed.
