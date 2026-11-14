# owner-rules

Three brief-time rules are enforced when a lane's brief is created, not left as prose. The merge gate and publication check are described below.

1. **Owner ask.** A lane (ship or scout) must serve a named owner ask: its backlog item (the entry whose
   id equals the task id in the backlog) has a title starting `[captain-ask]`, or its title or body
   names a `MainNNN` order.
2. **Hierarchy.** Every non-scout lane item whose title does not start `[captain-ask]` needs a body line
   `parent: <backlog item id>` naming an item in the same backlog, or `parent: upkeep` for true upkeep.
   Owner asks are epic roots; scout lanes and squad lead charters are exempt from this rule.
   `bin/jg-owner-rules-tree.sh <backlog-file>` prints each parent chain and lists items with absent,
   missing, or cyclic parents.
3. **Risk reason (now core).** The no-mistakes risk reason is `bin/jg-brief.sh`'s own rule: `--risk <reason>`
   is required for `--mode no-mistakes`, and a lane with no such risk briefs direct-PR plus a done-done check
   (docs/configuration.md "Delivery risk"). This feature no longer checks it, so one rule has one owner.
   Scouts are exempt; squad lead charters are exempt from the brief-time rules.

A refusal exits 1 before `jg-brief.sh` writes `data/<id>/brief.md`, with a one-line reason on stderr.

- `bin/jg-owner-rules-lib.sh` - `jg_owner_rules_check <data> <id> <mode> <kind>`; it reads the item into facts and `policy/gate/brief_rules.rego` decides.
- The merge-gate step, `bin/jg-owner-rules-gate.sh`, judges nothing (pcp-s7): it exits 0, so an older home's `config/merge-gate` keeps working. Its `init-key` and `sign` commands stay. A local-trunk landing does not run it (`docs/trunk-flow.md`) and records the signature after the landing when it exists.
- `bin/jg-owner-rules-tree.sh <backlog-file>` - read-only hierarchy report for every backlog item.
- Seam: `brief-inherit`'s `jg_brief_inherit_shared` (already called by the fork's `jg-brief.sh`) calls it when
  `config/owner-rules` exists. Without that file the check is a no-op, so an unmodified upstream Juggernaut is
  unaffected. A marker whose lib is missing stops the scaffold. Needs the brief-inherit seam.
- `wiring.sh [--dry-run] <jg-home>` writes `config/owner-rules` and wires the merge gate below into the home's single `config/merge-gate`
  entry point, after the owner-details scan and before the home's own previous gate (`addons/lib/merge-gate-lib.sh` owns that file and keeps
  the home's gate at `config/merge-gate.pre-chain`); `unwiring.sh` removes the marker, drops the proof gate, and leaves the other steps running.
- Design flag: a backlog body line `design: required` or `design: none`. `required` adds `Design discovery: required` to the brief; a design-like line with any other value is refused (`owner-rules: design: must be required or none (backlog item for <id>)`); no line on design-sounding work only prints a stderr note. Nothing blocks at merge time. Test: `tests/design-flag.test.sh [<juggernaut-checkout>]` (the checkout adds the real `jg-brief.sh` journey).
- Test: `tests/owner-rules.test.sh <juggernaut-checkout>` drives the checkout's real `jg-brief.sh`.
- Done-done proof: `JG_TEST_FORK=<juggernaut-checkout> done-done run owner-rules-hierarchy` records the real brief journey and hierarchy report.

## Owner proof signature (was the merge gate, slice 2)

The merge gate used to refuse a merge for a missing receipt, signature, checks-lint row or Evidence card. That generic proof compliance is deleted (pcp-s7): the gate step passes, and the owner's real boundaries stay with their owners - an open decision (`bin/jg-captain-hold.sh blocking`), the owner-guard scan for private details, and the merge authority of `bin/jg-pr-merge.sh`.
The signature stays as a record the owner can make:

- Run `jg-owner-rules-gate.sh init-key` once in the captain's home to create its local key pair.
- After a passed-proof recipe, `jg-owner-rules-gate.sh sign <id> <head> <pr-url|->` signs the normalized receipt (`merge-card receipt-json <id> <head>`) with the private key at `${JG_MAIN_HOME:-$JG_HOME}/config/owner-rules-proof.key`; in a lead home with `JG_MAIN_HOME` unset, that is Main's home found through the parent binding, and the signature lands in the lead's own data. The key is never copied.
- The signature binds the task, PR scope, exact head and receipt contents. Keep both keys out of the repository; the private key stays on the captain's machine.
- Test: `owner-rules/tests/owner-rules-gate.test.sh` proves that the wired step passes with no receipt, signature, lint row, card or board, that the chained previous gate still decides, and that `init-key` and `sign` work.

## Lavish refusal: squad lead notes and merge-card posts

With `config/owner-rules` present, `status-wait-check` checks squad lead report notes before append, and `merge-card` checks decoded card strings before posting or restoring a card.
`bin/jg-owner-rules-text-check.sh` reads proposed text on stdin and refuses HTTP(S) links to port 4387 or a `lavish-axi` publish command (`lavish-axi publish` or `lavish-axi <file>.html` at the start of a command or after a shell separator), ignoring case.
A bare mention of the package name passes.
It exits 1 and prints `owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead`.
Other text, including clean sign-off links, passes; read errors retain their diagnostics and exit code.
This feature covers squad lead notes and merge-card posts.
The Juggernaut core now refuses the same publication on the generated status line (`bin/jg-lavish-guard.sh` piped from the status command `bin/jg-brief.sh` scaffolds) and in a squad lead report note, with or without this feature, so the feature is defense in depth for card text rather than the only check.
A `lavish-axi` command typed outside those channels is a text guard's limit, not an interception.
Retiring existing registrations and removing old files remain outside this publication check.

Existing homes need no reinstall when their feature checkout is updated: the report hook and merge-card shims execute files from that checkout, and the existing owner-rules marker enables the checks.
Homes without the marker enable it with `wiring.sh <jg-home>`; the report helper still needs the existing status-wait-check fork hook.
Run `bash tests/no-lavish.test.sh` from this directory for the executable contract, note hook, and real sign-off board journey.
Set `JG_TEST_FORK=<Juggernaut checkout>` to also prove the real squad lead helper refuses before writing status; `JG_TEST_KEEP=1` preserves isolated fixtures for diagnosis.
Capture the real commands and their outputs with `JG_PROOF_FORK=<Juggernaut checkout> done-done run owner-rules-publication`, then check its `publication.txt` with done-done.

## Leads skill (slice 3)

`skill/SKILL.md` tells the leads both rules, the exact refusal lines and the one-step fix for each. No feature installs skills, so
there is no installer; link it into a home once: `ln -s <juggernaut-addons>/owner-rules/skill <jg-home>/.agents/skills/juggernaut-addons-owner-rules`.
A home that linked the old name relinks with one line: `ln -sfn <juggernaut-addons>/owner-rules/skill <jg-home>/.agents/skills/juggernaut-addons-owner-rules && rm <jg-home>/.agents/skills/owner-rules`.
`tests/owner-rules.test.sh` fails if a refusal line quoted in the skill stops matching the lib or the gate.
