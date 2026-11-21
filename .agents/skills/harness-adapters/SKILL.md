---
name: harness-adapters
description: Use before spawning or recovering a worker or Squad Lead, handling a trust dialog, invoking a skill, interrupting, exiting or resuming an agent, or verifying a new harness adapter.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Juggernaut operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Juggernaut home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch an operator or Squad Lead on an unverified adapter.
If `config/crew-harness` or `config/squad-lead-harness` names one, tell the captain under `../../../AGENTS.md` section 9 that the requested worker runtime is not verified, use Juggernaut's own verified runtime for current work, and ask only whether to verify the requested runtime for future work.
Do not pause current work for that choice.

On `unknown`, ask the captain instead of guessing.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/jg-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `jg-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
Muse, Gemini, and Devin are verified only for operator and Recon work, never a Squad Lead or primary.
AGY is verified for operator and Recon work and as the primary Overwatch, never a Squad Lead.

## Detection

`../../../bin/jg-harness.sh` prints Juggernaut's own harness from verified environment markers and process ancestry, and owns how they combine.
A marker names its harness, but a structural ancestor of a different harness outranks it, because a marker is ordinary environment state a child or a multiplexer can retain while ancestry is what proves who owns the process tree.
Only `JG_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
omp publishes no marker of its own; `JG_OMP_HARNESS=omp` is Juggernaut's launch marker and the anchored process name `omp` is its ancestry evidence, as `references/harness/omp.md` records.
`../../../bin/jg-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/jg-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means Juggernaut's own harness.
`../../../bin/jg-harness.sh squad lead <id>` resolves the mate-specific profile under [`configuration`](../../../docs/configuration.md#choose-the-squad-lead-harness).
`../../../bin/jg-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/jg-harness.sh`.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
Kimi establishes its unsupported primary boundary in its selected harness reference; Muse and Gemini follow Non-negotiable safety above.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "squad lead": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-squad-lead": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "claude": "references/harness/claude.md",
    "codex": "references/harness/codex.md",
    "opencode": "references/harness/opencode.md",
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "grok": "references/harness/grok.md",
    "kimi": "references/harness/kimi.md",
    "cursor": "references/harness/cursor.md",
    "gemini": "references/harness/gemini.md",
    "muse": "references/harness/muse.md",
    "rovo": "references/harness/rovo.md",
    "omp": "references/harness/omp.md",
    "agy": "references/harness/agy.md",
    "devin": "references/harness/devin.md"
  }
}
```
