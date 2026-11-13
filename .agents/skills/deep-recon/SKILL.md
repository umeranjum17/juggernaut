---
name: deep-recon
description: >-
  Load when a Recon brief carries a `# Recon depth` section naming standard or deep, before starting its research, and before intake picks the depth for a Recon or dispatches the critic worker of a deep one.
  Owns the seven stages, the source budgets, the stop rules, the critic rubric and the 13-section report template that bin/jg-recon-gate.sh checks before a standard or deep Recon may report done.
user-invocable: false
metadata:
  internal: true
---

# deep-recon

A Recon has three depths.
`bin/jg-brief.sh --depth quick|standard|deep` names the depth in the brief as `Recon depth: <level>`.
`bin/jg-recon-gate.sh <task>` refuses `done` for standard and deep, and `quick` is exempt.
Method only: the stages follow Anthropic's multi-agent research effort scaling, GPT Researcher, Open Deep Research and STORM, as recorded in section 5 of `data/captain-ask-deep-recon-design/report.md`.
No code is copied, so no licence constraint applies.

## Levels

| | quick | standard | deep |
|---|---|---|---|
| Use | one fact, a status, a small "why" | a normal Recon | discovery, design, "in depth", any plan with slices |
| Sources (min) | 2 | 8 over 3 source kinds | 20 over 5 source kinds |
| Claim ledger | no | yes | yes |
| Fact check | none | each load-bearing claim against its own source | each load-bearing claim: a second source or a hands-on run; numbers re-measured |
| Critic | no | 1 round, written by the researcher | rounds until one finds nothing new, cap 3, by a separate critic worker |
| Template | none | 13 sections | 13 sections, and sections 8 and 11 are real |
| Workers | 1 | 1 | 1 researcher and 1 critic |

## The seven stages

Each stage writes a file under `data/<task>/`, so the work can resume and every step can be checked.

1. Brief, `brief-research.md`: the question, scope and non-goals, "Done when", and the depth.
   Ask Overwatch once if something is unclear, then go on.
2. Outline, `outline.md`: the template sections to fill, and 3 to 6 perspectives (user, maintainer, operator, security, cost, competitor) with the questions each would ask.
   Say whether the work is depth-first or breadth-first.
3. Sweep, `sources.jsonl`: one JSON object per line with `id` (`S-n`), `kind`, `title`, `link`, `read` (date), and `licence` when the source is code.
   The kinds are `code`, `docs`, `upstream`, `oss`, `community` and `run`.
   Stop a line of search when its last 2 searches add nothing.
   Mark speculation, aggregators and sales talk with `"quality": "low"`.
4. Claim ledger, `claims.jsonl`: one object per claim the report will make, with `id` (`C-n`), `text`, `kind` (`fact`, `measure`, `inference`, `opinion`), `sources` (ids), and `load_bearing` (true when the recommendation or a slice depends on it).
   The report cites claims as `[C-n]`.
5. Fact check, `checks.jsonl`: a separate pass over each load-bearing claim.
   One object per check: `claim`, `status`, `method` (`reread` or `run`), and `note`.
   Re-open the source and confirm the exact words or number.
   `status` is `verified`, `single-source`, `unverified` or `refuted`; the last row for a claim wins.
   A deep Recon marks a claim `verified` only with 2 or more sources on the claim, or `"method": "run"`.
   When sources disagree, record both.
   A refuted claim leaves the report.
   A claim that is not `verified` goes to section 7, "Not checked".
6. Critic, `critic.md`: see the rubric below.
7. Write, `report.md`, in the template below.

## Critic rubric

The critic reads the draft with fresh eyes and checks:

- every item of the ask is covered;
- ambiguity, duplicates and conflicts;
- questions nobody asked, taken from sources read but not used;
- five scores from 0 to 1, each with pass or fail: factual accuracy, citation accuracy, completeness, source quality, tool efficiency;
- a proof and a risk for every slice, and every decision with its options;
- every claim cited and every number dated.

`critic.md` format, which the gate reads:

```
Critic: <task id of the critic worker, or self for standard>
Round 1: new gaps 3 report <sha256sum of report.md as read>
- gap one
Round 2: new gaps 0 report <sha256sum of report.md as read>
```

The last `Round` line names the report it read (`report <sha256 of report.md>`, 12 or more digits): the gate refuses a report changed after that round until the critic reads the new draft and writes a new round.
The last `Round` line must say `new gaps 0`, or be followed by `Closure check: <k> closed by <critic>`, where `<k>` is that round's gap count and `<critic>` is the same id as the `Critic:` line.
The closure line is the critic's word that the researcher fixed every gap of the last round; `self` and the researcher's own task id never close a gap.
A deep Recon allows 3 rounds that found new gaps; the clean round or closure line after them does not count.
Gaps the critic finds go back to stage 3 as the next sweep round.

## Deep: one researcher, one critic

The researcher never spawns the critic and never writes `critic.md` for a deep Recon.
It finishes the draft, then reports `done: draft ready for the separate critic` and stops: the gate (`bin/jg-recon-gate.sh --step`) lets that done through while only the critic is open, and the ticket is in the step `critic` of its stage `proving`, with no decision and no wait.
Overwatch dispatches exactly one critic worker with a fresh isolated copy, the draft, and these rubric lines.
The critic worker writes the `critic.md` content with `Critic: <its own task id>`, and Overwatch installs it as `data/<researcher-task>/critic.md`.
When the critic finds gaps, the researcher closes them and appends `done` again with the new draft, and Overwatch steers the same critic for the next round. Cleanup still needs the plain gate to pass, so a Recon whose critic is open is not cleanable.
A second critic worker never starts, and neither does a fan-out.
The gate refuses a deep `critic.md` whose `Critic:` is `self`, empty, or the researcher's own task id.

## The 13-section template

Both standard and deep reports use these headings, in this order, as `## <n>. <name>`.
The gate matches the number and the name's first words.

| # | Heading | Holds |
|---|---|---|
| 1 | Answer | 1 to 5 plain lines; `bin/jg-report-opening-check.sh` owns the opening |
| 2 | What was asked | the ask, and "Done when" |
| 3 | Method and depth record | level, sources by kind, claims checked, critic rounds and scores |
| 4 | Prior art and options | a table with licences, the pick and why |
| 5 | Findings | each finding with its claim ids and confidence |
| 6 | Design | a diagram, guide level first, then reference level |
| 7 | Not checked | every claim and area not verified, by `C-n` |
| 8 | Implementation plan | a slice table: slice, user outcome, proof, size, risk, depends-on; MVP first |
| 9 | Risks and mitigations | with rollout and rollback |
| 10 | Open decisions | question, options, consequences, recommendation, how it is confirmed |
| 11 | Acceptance test | one test for the whole change |
| 12 | Sources and evidence | the numbered sources, commands, output, file:line |
| 13 | Revision log | what changed between versions |

A standard Recon may write `Not applicable - <reason>` under 8 and 11.
A deep Recon may not.

## What the gate refuses

`bin/jg-recon-gate.sh <task>` is the owner of these checks; its header lists them.
A missing section, a load-bearing claim that is neither verified nor named in section 7, a missing critic or a critic whose last round found new gaps with no closure line, and a missed source budget each refuse.
A "board link missing" refusal is not built yet: it waits for the board report surface.
