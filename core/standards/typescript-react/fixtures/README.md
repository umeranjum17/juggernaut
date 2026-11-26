# Fixtures for the TypeScript and React standards pack

Two small projects on ordinary bulletproof-react paths, each with one fault file per rule and the allowed uses beside them.

- `project-a/` uses the base preset (`../../base.js`): R1, R1b, R3, R4, R5, R6a, R6b, R7, and the allowed uses, including `src/shared/api/client.ts`, the shared api client that may call `fetch`.
- `project-b/` uses the base preset plus the useEffect ban: R2 (`ping.tsx`), R2b (`tick.tsx`) and the allowed `count.tsx`.
- `project-a/eslint.noresolver.config.js` is the lab-only control: the shipped preset with the `import-x/resolver` setting stripped in memory. It lives here and never in the preset. R6a and R6b report nothing under it, and the test requires that.
- `project-*/biome.json`, `biome.project.json` and `.oxlintrc.json` are the same rules written for Biome and oxlint, kept for the comparison in `../README.md`; the test does not run them.
- `score.py <raw-dir> [--check]` reads the linters' JSON output, prints per-file diagnostics and the score table, and with `--check` prints `faults 10/10, allowed 8/8, inert check ok` or exits non-zero. Extra diagnostics on a fault file are printed, not counted as catches.

Run it all with `bash tests/standards-typescript-react.test.sh` from the repository root.
The test copies the pack into a throwaway folder, installs from the lockfile there, and lints the fixtures from that copy, so no `node_modules` appears in the repository.
