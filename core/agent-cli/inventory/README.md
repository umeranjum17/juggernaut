# The action inventory

`core/agent-cli/operations.tsv` is the reviewed list of Juggernaut's public operations: one row per operation, with one owner, one canonical path, one method and one invocation form (the script's own usage line, positional arguments in place). The list is a contract target. Nothing calls it yet; the area orders that build the one command read it.

This folder holds the tools that keep the list honest. They read the tree, never a live home, and need no private log.

| File | What it does |
| --- | --- |
| `extract.py` | Finds every action of every `bin/*.sh` script from its header usage lines, its `case` arms and the text that names it. Drops a prose word (no usage-shaped line and no case arm), splits `reconcile list` and `reconcile close` into two operations, and classes each action `read`, `change` or `change?` by what its code writes. |
| `check.py` | Prints the drift between the list and the tree, both ways, and the list's own integrity (one owner, a unique path, GET exactly when nothing changes). It never writes the list. |
| `cases.tsv` | Hand-written cases (script, action, class, effect) read from the scripts, independent of the extractor. `extract.py --cases` fails on a missing case or one served with the wrong effect. |
| `parse.py` | Renders each form with fixture values and runs it through the real script on a throwaway home, with argument-recording stand-ins for `tmux`, `herdr`, `gh`, `ssh`, `systemctl`, `pkill`, `curl` and the agent CLIs. |

## Run them

```sh
python3 -I core/agent-cli/inventory/check.py                  # drift, for review
python3 -I core/agent-cli/inventory/extract.py . /tmp/found.tsv --cases core/agent-cli/inventory/cases.tsv
python3 -I core/agent-cli/inventory/parse.py all . core/agent-cli/operations.tsv /tmp/parse-lab
bash core/agent-cli/tests/inventory.test.sh
bash core/agent-cli/tests/forms.test.sh
```

## Rules the tools keep

- **Coverage never reads logs.** The optional `--usage` file (executed-script counts) only fills a discovery column. A script is public when an agent instruction names it, so a tree gives the same lines with or without private logs.
- **Drift is printed, never written.** A public operation the list lacks, or a listed operation the tree lost, goes to review. Only a reviewer edits the list.
- **A read is GET only after a run proves it.** `parse.py get` runs every GET row on a fixture with data to act on (an answered and an open hold) and fails on a file change or an outside call. `parse.py parity` reports a row listed POST whose script header calls it read-only and whose run changes nothing. A row's method changes only by review, with that run named in its note.
- **A form that does not parse fails.** `parse.py usage` fails a row whose rendered form gets the script's usage text or an unknown-verb refusal. A row whose note says `form=help-only` has no usage line to render: it is listed for its owning order and never served as GET.
- **A continued usage line keeps every group.** An indented `[...]` or `(...)` line under a usage line joins that line's form (`jg-control.sh <task-id> relaunch ... [--effort <level>] (--note <text> | --note-file <path>)`).
- **Every option a form names exists.** `parse.py names` finds each `--option` in the code of its script, or of a file the script hands its arguments to.

## Review the list

A reviewer reads the `check.py` drift lines, adds or removes the rows by hand, and keeps the columns: `script`, `operation`, `form`, `path`, `method`, `changes`, `owner`, `aliases`, `review`, `area`, `source`, `note`. A row changed from POST to GET names the `parse.py` run that proved it in its `note`.
