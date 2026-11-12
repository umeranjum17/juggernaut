# agent-cli

`bin/jg` is the one command an agent runs. It replaces the long shell lines of a brief: the
status line (a guard, a pipe and a ledger call), the inbox read and acknowledge, and the wait
declaration. Each verb calls the script that already owns the work; none restates a rule.

`jg` finds its home and ticket from the folder it runs in (`lib.sh`): the home that owns the
project clone of this worktree, and the one `state/<id>.meta` whose `worktree=` is this
worktree. `JG_HOME` and `JG_TASK` override both. No variable is needed in a worker copy.

Every output is short, and its last line is `Next: ...`.

## Verbs

```
jg status                         ticket, stage, last status line, wait, unread steers
jg done [text]                    the done line (a local lane needs no text); the guard refuses a done the landing would refuse
jg wait <who> <reason> <text> [--until <YYYY-MM-DDTHH:MMZ>]
                                  declare the one kind of wait (a paused line)
jg progress <text>                a beat of work that wakes nobody
jg inbox [ack <NNN> [--evidence <kind>:<pointer>]]
                                  read the unread steers; acknowledge one (and record it handled)
```

## Owners

- status line: `bin/jg-lavish-guard.sh --append` (refusals) and `bin/jg-fleet-ledger.sh`
- stage: `bin/jg-crew-state.sh`
- inbox and handled record: `bin/jg-task-inbox-lib.sh`, `bin/jg-delivery.sh`

Test: `tests/agent-cli.test.sh` runs `bin/jg` from a real worktree with no variable set.
