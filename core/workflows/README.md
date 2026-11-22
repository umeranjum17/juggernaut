# workflows

Workflows are configuration.
A plain-text file names every workflow, and any spec of any steps, in any order and any count, parses into ordered stages with one command.
`bin/jg-workflow.sh <sub>` runs `core/workflows/<sub>.py`, so a later slice adds a subcommand by adding a file and the router never changes.

## The grammar

```
spec  := stage (">" stage)*          stages run one after another
stage := step ("+" step)*            steps in one stage run at once, in any mix
step  := word ["(" arg ")"] ["*" N]  N is a count; blanks are ignored
```

A word is a step kind or a workflow name.
A name is replaced by its spec, and a name may use other names; one that reaches itself is refused.
A one-stage name takes a count and may run beside other steps (`scout*2` is `recon(quick)*2`).
A name of two or more stages takes no count and runs beside nothing: write its stages out.
A bare kind is a one-step workflow named after it, so `parse worker` names `worker`.

| Kind | Argument | Reads |
|---|---|---|
| `worker` | none | builds one change |
| `recon` | `quick`, `standard` (default), `deep` | one scout; reports |
| `critic` | none | the Recons or war room of an earlier stage; with no `*N` it takes their count |
| `owner` | `plan-approval` (default, the only one built) | waits for the owner's yes |
| `fanout` | none | the slice plan selected by an earlier approval step and, when present, the latest approved Muster pack |
| `war-room` | `fast` (default), `full` | the council of variants and its plan |
| `muster` | `survey`, `light`, `full` (default), `complete` | survey or review findings, earlier approved decisions and the project's documents |

A new kind is one entry in `KINDS` in `wflib.py`, one route line and one kind file in `core/workflows/kinds/`.

## Which kinds can start

A kind runs when its module exists.
`worker` and `recon` write the brief and approve dispatch on the kind's route.
`muster` uses the [Muster round and pack method](../../.agents/skills/muster/SKILL.md) and publishes the signed pack or the completed survey.
`owner` binds a slice plan and its work orders to the owner's approval.
`fanout` starts Blitz with the approved plan after checking its match to the latest approved Muster pack.
A ready step of a kind with no handler is one `workflow-step-failed` alert naming the kind, never a silent skip.

## The two files

`defaults/workflows` ships the default names, in the same lines the owner's file uses.
`config/workflows` in a home adds or changes names; a name there wins.
`<name>: off` removes a shipped name in that home.
`limit count` and `limit steps` bound a count and the steps after expansion; `angles` and `pick` lines are read from the same files.
When the home file has any `pick` line, its pick lines replace every shipped one.
A line that breaks the rules is refused as `refused: <file>:<line>: <why>`.
`defaults/workflow-routes` and `config/workflow-routes` hold one `<kind> <harness> <model> <effort>` line per kind; `recon(quick)` reads `recon-quick`.

## Commands

- `parse <spec|name> [--by owner|main|lead] [--text]` prints `{name, spec, sha, stages}`, or one line per stage.
- `list` prints `<name>`, its canonical spec and `shipped` or `home` for every name, then the files it read.
  A name whose spec is refused prints its rule and the exit is 2, so every broken line shows at once.
  `list` reads a name as a building block, so `blitz` (`owner(plan-approval) > fanout`) is listed although it has no plan to start alone.
- `define <name> <spec|off> --by owner|main|lead` parses the spec with the names it will have after the change, then writes the line atomically.
  `--by main|lead` may only add a name the file does not hold; changing or removing a name is `--by owner`, the owner's own words through Main.

## The one rule

Only these are refused, each as `refused: <rule>` on stderr with exit 2 and nothing on stdout: an unknown word or argument, a count under 1, a count or step total over its limit, `goal`, what a step reads, and the owner rule.
The owner rule holds for every `--by`, because naming a shape is not approving a plan: a `worker` or `fanout` in a stage after the latest earlier stage that holds a `recon`, `critic` or `war-room` needs an `owner(plan-approval)` stage between them (owner rule 2026-11-05).
Each build after a report needs its own yes.
What a step reads: a `critic` needs a `recon(standard|deep)` or `war-room` in an earlier stage.
A `fanout` needs an earlier plan source (`muster`, `recon(standard|deep)` or `war-room`) and an intervening approval when it follows Muster or a report.
In workflows that include Muster, War Room before the first pack can publish discovery findings, and War Room or Recon after a pack can propose changes for the next Muster.
A later Muster step reads earlier survey findings and their decisions.
If several Muster invocations run in one stage, they present board rounds in configured order and later steps use the last invocation's approved pack.
Use `discovery-first`, `muster-first`, or `muster-only` as a workflow name or as a leading ticket title tag to pick that named workflow.

## How state is managed

A workflow has no state of its own.
The ticket row holds the spec and who chose it.
Each step is a child row whose links say what it waits for.
Whether a step is finished is read every pass from the record that already proves it: a landing line or a merged PR, a report and its done line, the recon gate and the critic's verdict, a board answer, or the swarm's own record.
Advance closes what is finished and starts a detached job for what is ready; the job writes the brief and the approval, and dispatch starts what is approved.
A restart loses nothing, because the next pass reads the same records again.
