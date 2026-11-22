# Muster machine formats (revision 7)

Every wave-1 order builds against these formats, so no order has to wait for another to define them. Order m1 copies
this file byte for byte to `.agents/skills/muster/formats.md`; every other order pins this frozen copy by hash.
Revision 4 (critic round 3): replies bind to what was shown (section 2); approval needs a passing pack check of the
same snapshot and binds through a home record, with plain card words (sections 3 and 4); the plan block carries the
charter's order (section 5); every fragment entry has one owner, one method and one form (section 6); every pack holds
a real decision record (section 7); the reviewed list of public operations (section 8).
Revision 5 (critic closure review): a reply that names no round binds only while one presentation exists (section 2);
the saved pack copy is complete and byte for byte, a feature also saves its baseline, and the ordinary check passes on
both (sections 3 and 4); a feature manifest holds the feature's own objectives and charter (section 3); a raise of the
depth is recorded with a reason (section 1); light and full need the change pack, `Lifecycle: none` needs a reason,
the vision delta is compared both ways (section 7); forms carry their positional arguments and GET marks verified
reads (sections 6 and 8).
Revision 6 (closure review of draft 6): once a round is revised, a reply names the revision or answers on the card
(section 2); no slice claims a ticket together with one it must follow (section 5); the glossary delta is compared by
definition both ways (section 7); a form keeps every continued usage group (section 8).
Revision 7 moves technical designs to `docs/architecture/` and reserves design paths for visual work (section 7).

## 1. The depth line on a ticket
`Muster: <skip|light|full|complete>[ survey-first][ backfilled][ review] - <reason>`
One line per ticket, written once by intake (or backfilled at War Room or Blitz start by
`jg-muster-depth.sh record --ticket <id>`). A ticket with no line is read as "not picked yet", never as skip.
`review` marks an ask whose intent the rule could not read (section 1 of the picker's output); Main reads it and
records the depth with `--depth <d> --reason <why>` before any refusal can fire. The same form is how Main raises a
depth the rule picked (`light` to `full` for a feature that changes a state machine); the line then reads
`Muster: <d> - <why>`, and a repeat of the same call changes nothing. A lower depth than the rule picked also needs the
reason.

## 2. The round record, `data/<ticket>/muster/rounds.tsv` (home, private)
Tab-separated, one row per question per revision, append only:
`round  revision  qid  gate  presented  qset  question_sha  answer  source  taken  at  doc_rev`
- `qid` is the readable id shown to the captain, `R<round>Q<k>`; `gate` is the id the backlog returned for that
  question (looked up right after the post by the exact question text, unique among the round ticket's open
  questions); only `gate` is ever fed to `jg-captain-hold.sh answers`.
- `presented` is the id of the thing he saw: the board card key, or the id of the chat message that showed the
  round. `qset` is the first 12 hex digits of the sha256 of the sorted `qid=question_sha` list of that presentation.
- A reply binds to the presentation it names: a board pick names its card; a chat reply to a question card's
  message is routed to that card by the chat gateway (`cardAnswered`, core/bus/cmd/jg-bus/gateway.go at d22be6441);
  a chat note names its round with an explicit `R<round>` or `R<round>.<revision>` prefix, or with a question id
  `R<round>Q<k>`, which also binds a group part of the same note ("yes to the rest") to that round only. The gateway
  at d22be6441 keeps no reply reference and no send time on an ordinary note, so neither is used.
- A reply that names no round binds only while the ticket has shown exactly one presentation (one round, one
  revision): only then can its delivery not span presentations. Once a second presentation exists (a later round
  or a revised card), it closes nothing, whatever is open when it arrives; it is stored with `answer=unbound` and
  Main asks which round he meant, quoting it. A note naming two rounds is unbound too. Arrival order never decides.
- Inside a round the same rule holds: a round-only prefix (`R<round>`) names a unique presentation only while that
  round has been shown at one revision, and a question id with no revision (`R<round>Q<k>`) only while that
  question's words (its `question_sha`) have not changed between revisions. Once the round is revised, a
  round-only group part closes nothing, and a question id for a question whose words changed closes nothing; the
  note is stored with `answer=unbound` and Main asks. A note naming a revision the round never showed binds nothing.
  Every presentation after the first says how to answer: reply to a question card, or start with
  `R<round>.<revision>`.
- A reply that names a revision older than a question's newest revision does not close that question
  (`answer=stale`); the question stays open on its newest card.
- `source` is board, chat, default or agent; `taken` is owner, default or agent; only `taken=owner` counts for an
  irreversible question and for approval.
- `doc_rev` is the document revision written for the answer (empty until written; `jg muster round-status` redoes a
  row whose gate is closed and whose `doc_rev` is empty).

## 3. The pack manifest, `data/<ticket>/muster/manifest-<sha12>.tsv` (home, immutable once asked)
Lines, sorted:
`check <depth> <change slug|-> pass <gate sha12>`, `file <path> <sha256>`, `raw <path> <sha256>`,
`base <path> <sha256>`, `journey <id> <new|preserve>`, `batch <id> <after, comma separated|->`,
`charter <ticket> <batch> <depends, comma separated|->`, `milestone <id> <journeys, comma separated>`,
`adr <number> <status>`.
- The `check` line is written only after `jg muster gate` passed on the project and again on the saved copies below,
  at that depth and change slug; `<gate sha12>` is the hash of the gate script that passed it. No `check` line, no ask.
- Two copies are saved beside the manifest, complete and byte for byte, so the ordinary checker reads them:
  `pack-<sha12>/` (every pack file of the project, status lines kept) and, for a feature, `base-<sha12>/` (every
  pack file of the documents before it). `raw` lines hash each file of `pack-<sha12>/` and `base` lines each file of
  `base-<sha12>/`; a file added to, removed from or changed in either copy is a tampered copy.
- `file` lines hash normalized text and decide which edits keep an approval: in a spec, the frontmatter lines
  `status:` and `updated:` and the `## Revisions` section are left out; rendered views (`*.html`,
  `docs/specs/index.html`) are not pack files.
- Scope lines: for a project (change `-`), `journey` lines come from every spec's Objectives table and `batch`,
  `charter` and `milestone` lines from `docs/charter.md`; for a feature, `journey` lines come from the change pack's
  Objectives list and the others from its `## Charter` section, never from the project's charter. One kind per
  journey: a journey with two kinds refuses the manifest.
- `<sha12>` is the first 12 hex digits of the sha256 of the manifest file itself.

## 4. The two owner questions and the approval record
The words he sees hold no ticket id, hash or file name (the card rule, `bin/jg-ask-gate-lib.sh`):
- Approval: `Approve the agreed documents for <project>, version <n>?`
- Exception: `Start planning <project> without agreed documents, request <n>?`
Each is held with `jg-captain-hold.sh hold <ticket> --reason <words>`; its card is the hold's yes/no card. `<n>` is
the ask number on that ticket, so two asks never share words. Right after the hold, the gate id the backlog returned
is written to `data/<ticket>/muster/approvals.tsv` (home, append only):
`ask  kind  manifest_sha12  gate  words  at` with `kind` approve or exception.
An action is approved only when all hold: the newest row of that kind on that ticket names the current manifest
(approve) or any manifest (exception); its gate is closed by the owner (resolution answered or released, never
reconciled); the stored answer is exactly the card's affirmative value `yes`; the ticket holds the signed
approved-by-captain line for those exact words; and, for approve, the manifest's `check` line is present and
`jg muster gate` passes again on `pack-<sha12>/` at that depth and change slug. Every other answer is recorded and
refuses. A worker (JG_TASK_ID set) can never ask or use the exception.
In full, for approve, at ask and again at verify: both saved copies match their `raw` and `base` lines; `jg muster
gate` passes on `pack-<sha12>/` at the manifest's depth and change slug, with `--before base-<sha12>/` for a feature;
at verify the gate also passes on the current documents (with the saved baseline for a feature) and their `check`,
`file`, `adr`, `journey`, `batch`, `charter` and `milestone` lines equal the manifest's. Depth, change slug and
baseline are read from the manifest, never from the caller.

## 5. The muster block of a plan file
```json
"muster": {"ticket": "<id>", "depth": "full|complete", "manifest_sha": "<sha12>",
           "journeys": [{"id": "<journey>", "kind": "new|preserve"}],
           "batches": [{"id": "B1", "after": []}, {"id": "B2", "after": ["B1"]}],
           "charter": [{"ticket": "C1", "batch": "B1", "depends": []}, {"ticket": "C4", "batch": "B2", "depends": ["C1"]}],
           "milestones": [{"id": "M1", "journeys": ["<journey>"]}]}
```
and on each slice `"journeys": ["<id>", ...]` and `"charter": ["C1", ...]`.
Shape rules (store-free, m9): every `new` journey and every charter ticket is claimed by at least one slice; a slice
names only ids in the block; no batch waits on itself.
Order rules (store-free, m9): for a slice S that claims ticket T, S must depend, directly or through other slices, on
every slice that claims a ticket T depends on, and on every slice that claims a ticket of a batch T's batch starts
after. So no slice claims a ticket together with a ticket it must follow (its dependency, or a ticket of a batch its
batch starts after): one slice cannot finish the first before the second starts. Nothing else is required: two
tickets that share a batch and do not depend on each other may start together, on two slices or on one. Every
milestone journey is claimed by some slice.
Approval rules (at build start, m2b and a1): the block's ticket, `manifest_sha`, journey set with kinds, batches,
charter rows and milestones equal the approved manifest's lines, so a feature plan carries the feature's charter
(R1, R2, F1 in the example) and never the project's (C1-C4, M1-M3).

At plan verification, every category from the requirements coverage map needs a closed outcome in the approved spec's Functional requirements or Non-functional requirements table.
The verifier reads the specs for the ticket, or the spec named for the change at full depth, from the approved pack.
For a complete pack without ticket-labelled specs, it checks the project's specs together.
A category with a missing row or any row without a closed outcome stays open.
An older spec without either requirements section can still use its existing plan format.

Plan verification reads the [engineering practices](templates/ways-of-working.md#engineering-practices) from the approved pack's `docs/ways-of-working.md`.
The plan is refused if that section is missing or any practice lacks a closed outcome.

The plan holds its decisions-and-assumptions table in `muster.decisions_and_assumptions`.
Use one row per decision or assumption that affects the work, or an empty table when no decision affects a slice.

```json
{"id": "export-format", "recommendation": "Export CSV by default.", "status": "accepted recommendation",
 "override": null, "slices": ["c2"]}
```

| Status | Direction given to the slice |
| --- | --- |
| `answered` | The owner's words from the row's `answer` field |
| `accepted recommendation` | The row's `recommendation` |
| `overridden` | The owner's words from the row's `override` field |

To change the direction before approval, fill the row's `override` line.
The override takes precedence and Blitz marks the row `overridden` in the frozen plan.
Every row names at least one affected slice in `slices`, and the recommendation, answer and override each fit on one line when present.
Blitz puts the selected direction for each decision into the affected slice's frozen work order.

## 6. A command contract fragment, `core/agent-cli/contract/<slice>.json`
```json
{"area": "<area>", "owner": "<slice id>", "entries": [{"path": ["muster", "depth"], "meaning": "<one plain line>",
  "roles": ["overwatch"], "args": [{"name": "ask", "type": "text", "required": true}], "changes": false,
  "method": "GET", "form": "<script> <ask>", "repeat_key": null, "exits": {"0": 0, "2": 2},
  "schema": "muster.depth.v1", "script": "bin/jg-muster-depth.sh", "operation": "-", "aliases": []}]}
```
- One path has one `changes` value: a read form and a change form of the same script get two paths
  (`muster depth` reads; `muster depth record` writes the depth line). `method` is GET exactly when `changes` is
  false, and GET is given only to a read verified by a run (section 8). `form` is the script invocation the entry
  runs, positional arguments in place, copied from the row's `form` in `operations.tsv`
  (`bin/jg-control.sh <task-id> interrupt`, never `bin/jg-control.sh interrupt <task-id>`).
- `operation` is the script's own operation word (`-` for a single-action script); the pair (`script`,
  `operation`) appears in exactly one entry of one fragment, and that fragment's `owner` is the slice named for the
  pair in `operations.tsv` (section 8). Paths and aliases are unique across all fragments.
Check every fragment has this shape with:
`jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
(.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
(.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))'`

## 7. What a muster run produces, by depth
| Output | complete (new project) | full (big feature) | light (small feature) |
|---|---|---|---|
| `GLOSSARY.md` core objects and terms | written | changes listed in the change pack | new terms only |
| `docs/domain/model.md`: entities and relationships, rich core objects, state machines | written | changes listed in the change pack | changed invariants only |
| `docs/vision.md` | written | changes listed in the change pack | - |
| `docs/adr/NNNN-*.md`, real decision records | one each for stack, storage and hosting | at least one | at least one, short form |
| `docs/ways-of-working.md` and lint, CI config | written and proven | - | - |
| `docs/architecture/<slug>.md` technical design | written | written | - |
| `docs/design/visual-direction.md` | direction board and key screens | changed screens, or "no screen changes" | one sketch if a screen changes |
| Root `DESIGN.md` visual design system | written when visual direction is picked | updated when the visual system changes | updated when the visual system changes |
| `docs/specs/<slug>.md` with Objectives, and journeys in `.done-done.yaml` | written | written | a spec section, 1-3 journeys |
| `docs/charter.md` (project) or the change pack's Charter section (feature) | written | written | - (one ticket) |
| `docs/changes/<slug>.md` change pack and `CHANGELOG.md` lines | - | written | objects, terms, objectives, changelog |

Use `templates/technical-design.md` for architecture and reserve `docs/design/` for visual direction.
Use first-draft and the picked visual direction to record colors, type, spacing and components in root `DESIGN.md`.
The gate accepts legacy technical designs in `docs/design/<slug>.md` with a warning that names the new path.
The gate refuses a document titled "Technical design" under `docs/design/`.

Every pack at every depth holds at least one real decision record: status, context, two or more considered options,
the decision, consequences and a confirmation. The short form (light) keeps the same six parts and allows one line
each. A record missing any part is an idea, and the gate refuses it; a pack with no record at all is refused. `skip`
writes no pack and no record. `full` and `light` check a feature: the gate needs its change pack and the documents
before it (`--change <slug> --before <dir>`) and refuses without them.
Every core object has a state machine or the line `Lifecycle: none - <reason>`; `none` without a reason is refused,
and an object whose Fields name `state` or `status` needs its state machine. The change pack lists every vision
sentence the real change adds or removes (`<section>, added: "<sentence>"` or `removed:`), and the gate compares both
ways; the vision's Decisions section is the round log (m5 writes and checks it) and is left out. The change pack's
Glossary changes table lists every term the real change adds, removes or redefines (any change to a term's
definition block), with that kind (`ADDED`, `REMOVED` or `MODIFIED`), and the gate compares both ways by definition.
Every edge of a state diagram,
including the start edge `[*] --> <state>`, has a row in its table, and every row has an edge. Every invariant names
the journey that tries to break it (`proved by`), and that journey expects the refusal and the unchanged state.

## 8. The reviewed public operations, `core/agent-cli/operations.tsv`
Tab-separated, one row per public operation, versioned in the repository and changed only by review:
`script  operation  form  path  method  changes  owner  aliases  review  area  source  note`
- `form` is the script's own usage line for the operation, positional arguments in place, with every indented
  continuation line of that usage (an optional `[...]` or a required `(...)` group) joined in order (481 of 694 at
  d22be6441); a row whose script has no usage line for it keeps `bin/<script> <operation>` and says `form=help-only`
  in `note` (213), and its owning order renders it against the real parser before it serves it.
- `method` is GET only for a read verified by a run on a fixture home with data to act on (no file change, no call
  to an outside program); the run is the owning order's parity test (order e0).
- The list is the contract's coverage target. It is never derived from usage counts at run time, so a tree with no
  private logs and a tree with them check the same rows.
- `review` is `confirmed` (found by help and dispatch, or one source plus a run), `corrected` (fixed by hand or by a
  run, with the reason in `note`), or `pending` (one source only; served as a change; the owning slice confirms or
  removes it with a run).
- The extractor (order e0) finds drift: an operation in the tree that the list lacks, or a listed operation the tree
  no longer has. It reports; it never edits the list.
