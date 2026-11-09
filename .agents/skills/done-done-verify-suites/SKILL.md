---
name: done-done-verify-suites
description: Verify Juggernaut core changes through their executable integration journeys and capture output for review.
---

# Verify the Juggernaut core

## Suites

Each suite is one file in `suites/`, named for the feature it proves.
A suite file starts with `# <feature>`, then names the command that drives the feature's journey and the evidence that run captures.
From this skill's folder, `grep -m1 '^# ' suites/*.md` lists every suite, and `grep -il '<word>' suites/*.md` finds the suites that name a word.
Some suites link a longer write-up in [`features/`](features/README.md).

## Add or change a suite

Add a suite as one new file, `suites/<feature>.md`, named in lowercase words joined by `-`; never add suite text to this file.
Change a suite by editing only its own file.
`bash tests/jg-verify-suites-layout.test.sh` checks the layout: every suite file has its heading, names a command and has working local links, and this file holds no suite.

## Procedure

Run the feature's integration journey from the repository root and save its output under done-done's run evidence directory.

## Safety

Use synthetic transcript fixtures only.
Never use a real home or transcript directory for this proof.
