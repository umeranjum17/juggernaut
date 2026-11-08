# machines

A machine table says which states a record can be in and which moves are legal.
`bin/jg-machine.sh` reads one table and answers for one record, so a person or an agent asks one command instead of reading the writers.
The records stay the truth: the table never stores a state, and the command never changes a record.

## Commands

- `jg-machine.sh show <machine> <id>` prints the state, its kind, its captain sentence and its required fields.
- `jg-machine.sh next <machine> <id>` prints the state and each legal move.
- `jg-machine.sh check <machine> [--corpus <file>]` lints the table, and with a corpus replays it against the table.
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

The observer is always an existing reader of the record.
The table holds each verb list once; no other file may repeat it.

## Lint

Every command lints the table first and refuses it, naming each defect, when it has any of these:

- a state no edge path from an initial state reaches;
- a terminal state with an exit edge;
- two edges with the same from and event;
- an edge with no writer;
- a state with no captain sentence;
- no initial state, no observer, a duplicate state, or an edge that names a state the table lacks.

## Corpus and baseline

A corpus file has one line per observation: a state name, or `from<TAB>event<TAB>to` for a move.
`check` reports each line the table lacks and exits 1.
A line listed in `known-baseline.tsv` (`machine<TAB>corpus line`) is reported as `baseline` and does not fail.

## Sealed proof

`core/machines/run-proof.sh` is the acceptance run: it runs the machine tests and checks every shipped table in a throwaway home.
`.github/workflows/core-suites.yml` runs it after the merge.

## Test

`tests/jg-machine.test.sh` generates a fixture machine, refuses each lint defect, matches the golden output, and walks a record to its terminal state using only `next` output.
