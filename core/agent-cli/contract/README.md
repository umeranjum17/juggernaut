# The command contract

`jg` and `juggernaut-axi` read one contract: one JSON fragment per slice in this folder.
`core/agent-cli/dispatch.sh` is the one dispatcher behind both names.
`jg help` (and `juggernaut-axi help all`) lists every entry of every fragment on one page.

## A fragment

```json
{"area": "muster", "owner": "m3", "entries": [
  {"path": ["muster", "depth", "record"], "meaning": "one plain line", "roles": ["overwatch"],
   "args": [{"name": "ticket", "type": "text", "required": true}], "changes": true, "method": "POST",
   "form": "bin/jg-muster-depth.sh record --ticket <ticket> [--backfill]", "repeat_key": "ticket",
   "exits": {"0": 0, "2": 2}, "schema": "muster.depth.record.v1",
   "script": "bin/jg-muster-depth.sh", "operation": "record", "aliases": []}]}
```

- `path` is the command words; the longest path that matches the line wins (`muster depth record` over `muster depth`).
- `changes` is the truth about the script, and `method` is `GET` exactly when it is false.
- A read form and a change form of one script get two paths.
- `form` is the script's own usage line, copied from `core/agent-cli/operations.tsv` when the script has a row there.
- `operation` is the script's own operation word (`-` for a script with one action).
- The pair (`script`, `operation`) is in exactly one entry of one fragment, and that fragment's `owner` is the slice `operations.tsv` names for the pair.
- Paths and aliases are unique across all fragments.
- An alias is another spelling, for example `plan swarm start` for `plan blitz start`.
  The dispatcher matches the longest path or alias.
  The old standalone commands, such as `juggernaut-axi lanes`, keep their historical output.
- `bash core/agent-cli/dispatch.sh check` validates every fragment, and `run` does it first.
  The shape it checks is `example-pack/formats.md` section 6 of the jg-6si report.
  The owner check reads `core/agent-cli/operations.tsv` when it is there.

## How a line is run

The `form` is read as the script's usage line.

| In the form | Meaning |
|---|---|
| `<name>` | a positional argument |
| `<name...>` or `<name>...` | the rest of the line |
| `--x <name>` or `--x NAME` | an option; `--x` alone inside `[ ]` is a flag |
| `[--x <name>]...` | a repeatable option; each supplied value stays a separate flag and argument |
| `--x <argv>... --y <argv>...` | two argument vectors; the next vector's flag ends the first |
| `[ ... ]` | optional |
| `(a \| b)` or `[a \| b]` | one required or optional alternative |
| any other word | literal, passed as written (the operation word, `--json`) |

- The caller's environment goes to the script unchanged.
  The dispatcher never sets `JG_HOME`, so a script that refuses without an explicit home refuses the same way here.
- New paths print one line, the `jg.v1` envelope `{schema, ok, data, next}`.
  `data` is the script's JSON result, or `{"stdout": "<text>"}` for a script that prints text.
  A refusal has `ok` false and the script's stderr in `data.error`.
  The script's stderr also goes to the caller's stderr.
- Exit codes of a new path: 0 done, 1 refused by a rule, 2 usage, 3 still waiting, 4 not found, 5 a dependency missing.
  `exits` maps the script's own exit codes to these; a code it does not name is a 1.
- An unknown word exits 2.

## Repeats

An entry that declares an `again` argument runs once per key.
The key is the sha256 of the entry's `schema` and the values `repeat_key` names (`a+b` for two), or of `--key <value>`.
A repeat prints `already processed` in the envelope and exits 0, and `--again` runs it anyway.
The key is written after the script succeeds, in `<state>/.jg-repeat/`, where `<state>` is `JG_STATE_OVERRIDE` or `JG_HOME/state`.
With neither set there is no guard and the script decides, so a send with no home is refused by the script.
An entry with no `again` runs every time, and its `repeat_key` only names what would identify a repeat.

## The acknowledgement reference

Two entries carry a reference that holds the sequence, the recovery generation and, when owed, the pages sequence.
`radio drain` (`"emits": "ack-ref"`) puts it in `data.ack_ref` and in `next`, as `<sequence>:<generation>[:<pages>]`.
`radio ack <ref>` (an argument of type `ack-ref`) turns it back into `--ack-through <sequence> --recovery-generation <generation> [--pages-ack <pages>]`.
A reference the drain would not recognise is a usage error.
An acknowledgement the drain answers with exit 0 but did not finish (a newer recovery episode is pending, or no presented row is at or below the sequence) is a refusal, exit 1, with `next` `jg radio drain`.

## What the fields add to the frozen shape

Optional, and ignored by a reader that does not know them: `next` (the command to run after a refusal), `emits` (`ack-ref`) and the argument type `ack-ref`.

## Owners

- `core.json` (slice e1) holds the `juggernaut-axi` names and the notification queue and steering sends.
- The worker verbs stay in `bin/jg` until slice e2 adds `worker.json`.
- `hold answer` and `ticket add` in `core.json` run `bin/juggernaut-axi`; the area slices that own `jg-captain-hold.sh answer` and `jg-backlog.sh add` take those paths over with their own entries.

Test: `core/agent-cli/tests/contract.test.sh`.
