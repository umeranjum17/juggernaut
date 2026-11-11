# machines

A machine table says which states a record can be in and which moves are legal.
`bin/jg-machine.sh` reads one table and answers for one record, so a person or an agent asks one command instead of reading the writers.
The records stay the truth: the table never stores a state, and the command never changes a record.

## Commands

- `jg-machine.sh show <machine> <id>` prints the state, its kind, its captain sentence and its required fields.
- `jg-machine.sh next <machine> <id>` prints the state and each legal move.
- `jg-machine.sh check <machine> [--corpus <file>]` lints the table, and with a corpus replays it against the table.
- `jg-machine.sh events <machine>` lists the events a table declares: event, from, to.
- `jg-machine.sh word <map> <list> <word>`, `replay <map> <corpus>` and `records <map> <records>` read a word map (below).
- `jg-machine.sh enum <name>` lints one enum file (below) and prints its value count.
- `jg-machine.sh coverage <machine>` lists each edge whose test id is empty or `-` and exits 1 when there is one.
- `jg-machine.sh diagram <machine>` prints a Mermaid state diagram generated from the table.
- `jg-machine.sh edge-check <machine> <from> <to>` prints `legal` with the event and writer, or `illegal`, and exits 1 for an illegal move; it only reads, so a writer may call it in shadow.

`show` and `next` print tab-separated `key<TAB>value` lines.
A move line is `move<TAB>event<TAB>to<TAB>writer<TAB>command<TAB>guard`, with `{id}` already replaced in the command.
A `-` command means the writer fires the move itself.
Run the command a `move` line names to take that move, then run `show` to see the new state.
The exit code is 0 on success, 1 on a finding, and 2 on a usage error.

## Table format

A table is `core/machines/tables/<machine>.tsv`, or `$JG_MACHINES_TABLES/<machine>.tsv`.
Each line has tab-separated columns, and its first column names the line kind.

| Line | Columns |
| --- | --- |
| `machine` | name, carrier (the record family), owner (the one file that owns it) |
| `state` | name, kind (`initial`, `normal`, `terminal` or `extension`), captain sentence, required fields (`-` for none) |
| `edge` | from, event, to, writer (`file:function`), command, guard in words, test id |
| `observer` | a shell command that prints the state word for the id in `$1` |
| `group` | name, then its members (states, groups or composite stages): an edge that leaves the group leaves each member |
| `inner` | a composite stage, then the table inside it |

A `state` of kind `composite` is a stage that holds the states of another table (`inner`), named `<stage>.<state>`.
An edge that leaves a composite stage leaves each state inside it, and an edge that enters it enters the inner table's initial state.
An edge whose from is `(none)` is the first event of the machine and must lead to its initial state.
`docs/ticket-statechart.md` is the worked example: `ticket.tsv` holds `delivering.tsv` and `proving.tsv`.

The observer is always an existing reader of the record.
The table holds each verb list once; no other file may repeat it.

## Enums

Each machine has one closed list of states in `core/machines/<name>.states` (override the folder: `JG_MACHINES_ENUMS`).
A line is `value<TAB>mark<TAB>kind<TAB>meaning`; a line starting with `#` is a comment.
The mark is `initial`, `final` or `-`; the kind is `active`, `waiting`, `rest` or `final`; a final mark and a final kind go together.
The meaning says what is true in that state; the entry action belongs to the table, not here.
A machine file has exactly one initial value. A side list of a machine (the wait, its reason, the health, the resolution, the delivery knob, the proof level) has no kind column and at most one initial value.
`enum <name>` refuses a file with a duplicate value, a bad mark or kind, a missing meaning, a ragged line, or two initial values, and names each defect.
A table opts in with an `enum<TAB><name>` line: each state it names (a composite stage too) must be a value of that file, and the lint names the value that is not, with the legal ones.
The tables `ticket` and `delivering` have opted in; the other files wait for their tables.
A tool keeps its own enum files in its own repository, not here.

## Lint

Every command lints the table first and refuses it, naming each defect, when it has any of these:

- a state no edge path from an initial state reaches;
- a terminal state with an exit edge;
- two edges with the same from and event;
- an edge with no writer;
- a state with no captain sentence;
- a state that is not in the table's enum;
- no initial state, no observer, a duplicate state, or an edge that names a state the table lacks.

## Corpus and baseline

A corpus file has one line per observation: a state name, or `from<TAB>event<TAB>to` for a move.
`check` reports each line the table lacks and exits 1.
A line listed in `known-baseline.tsv` (`machine<TAB>corpus line`) is reported as `baseline` and does not fail.

## Word maps

A map, `core/machines/maps/<map>.tsv`, says where each word of an older word list lands in a machine.
A `word` line is list, word, target, wait and health; a target is a state or stage of the machine, a comma list of them, `=` (unchanged), `-` (not a word of this machine) or `by-rule`.
A `rule` line decides by facts: pull request state, where the work is, superseded, last verb; the first match wins.
`word` prints the target, `replay` reads `list<TAB>word` lines and names each word with no target, and `records` checks a record file against the rules.
`core/machines/ticket-corpus.sh` builds the replay lines from the older tables, the status logs and the shadow log.

## Delivery: is a change live?

The `delivery` machine answers for one change, never one task: `jg-machine.sh show delivery <id>`.
Its states are `unlanded`, `landed` (on the trunk), `in-homes` (every home runs the commit), `in-homes-off` (every home has the code and its switch is off), `in-use` (switched on, with a proof that holds), `pinned-behind` and `reverted`.
`core/machines/observers/delivery.sh` reads the states from the trunk, `data/trunk-live.tsv` and `config/`, and `delivery.sh` also documents the `changes.tsv` registry format.
Every change that ships behind a switch gets a row in `core/machines/changes.tsv` in the same commit, which names the switch file in `config/` and the proof, and its commit carries the trailer line `Change: <id>`.
A report may say `live` or `done` only for `in-use`, and `bin/jg-live-claim.sh` enforces that for every registered change a claim names, by id or by switch name.
`in-homes-off` is reported as `in the homes, off`, with the switch file named.
The switch is read in the home that asks, so the same change can be `in-use` in one home and `in-homes-off` in another.

## Sealed proof

`core/machines/run-proof.sh` is the acceptance run: it runs the machine tests and checks every shipped table in a throwaway home.
`.github/workflows/core-suites.yml` runs it after the merge.

## Test

`tests/jg-machine-delivery.test.sh` walks a switched-off and a switched-on change through every delivery state and the live-claim verdict.
`tests/jg-machine.test.sh` generates a fixture machine, refuses each lint defect, matches the golden output, and walks a record to its terminal state using only `next` output.

## Delivery styles

`core/machines/styles/delivery-styles.tsv` has one row per mode word: the line, what the style adds in delivering, and how it joins main.
`bin/jg-delivery-style.sh <mode>` is the one reader (`--list` prints the modes; an unknown mode exits 1).
No row names a prover: done-done proves the commit in every mode.
`tests/jg-delivery-style.test.sh` is its test.
