# Home triage

`bin/jg-triage.sh` checks one Juggernaut home in one command and repairs the findings that are safe to repair.
It is a plain script and calls no model, so it still runs when the agent runtime is the part that is broken.
`JG_HOME` must be set, as for `bin/jg-send.sh`.

```
JG_HOME=<home> bin/jg-triage.sh [--fix] [--only <check>[,<check>]] [--porcelain]
                                [--context <file>] [--agent] [--offline]
```

## Check mode is the default

Without `--fix` nothing changes.
Each check reads the script that already owns the fact, and triage adds no probe of its own.

| Check | Source of truth | `--fix` repair |
|---|---|---|
| `session-lock` | `bin/jg-inbox.sh ready` | none |
| `wake-consumer` | `bin/jg-inbox.sh ready` | none (the live session re-arms its own supervision) |
| `stack` | `bin/jg-stack.sh status` | `bin/jg-stack.sh up` |
| `backlog-lock` | `data/backlog.md.lock`, a 0-byte file older than 60 seconds | `core/backlog-lock-reclaim/backlog-lock-reclaim.check.sh` |
| `squad-lead` | the read-only probe of `bin/jg-squad-lead-liveness-lib.sh`, one line per registered lead | the guarded relaunch of that library |
| `sentinel`, `tools`, `checkout`, `config` | the detect-only lines of `bin/jg-bootstrap.sh` | none |
| `login` | `gh auth status` (skipped with `--offline`) | none |
| `tmp` | `bin/jg-tmp-sweep.sh check` | `bin/jg-tmp-sweep.sh sweep --apply` |
| `stray-servers` | the dry run of `bin/jg-stray-nats-reap.sh` | none, the command is printed |

## What `--fix` never does

- It changes nothing while another live session holds the home lock, or when the lock cannot be read.
- It never forces, stashes, discards, installs, updates, signs in, or kills a process.
- It never touches `projects/`, a worktree, or unlanded work.
- It never relaunches a Squad Lead whose home is parked, which is dormant, whose endpoint is missing or ambiguous, or whose auto-relaunch is paused.
- A repair that does not make its check pass is reported as failed, and the finding becomes a job for a person.

Logins, installs, a primary checkout off its default branch, and installed-copy drift stay `HUMAN` findings with the exact step printed.

## Reading the result

A line is `ok`, `skip`, `INFO`, `FIX` (a repair exists), `HUMAN` (a person must act), or `??` (the source could not be read).
An unreadable source is never reported as dead, and it blocks every repair.
After a repair the check runs again, so each line shows the state after the repair.

Exit codes:

- `0`: healthy, or every finding fixed.
- `1`: a fixable or human finding remains.
- `2`: no `JG_HOME`, a bad flag, or a check could not read its source.

## Script output

`--porcelain` prints one fact per line:

```
mode=check|fix
check <name>[:<target>]=ok|fixable|human|skip|info|unknown: <detail>
fix <name>[:<target>]=applied|failed: <what happened>
action: <name>[:<target>]: <the exact step to take>
summary fixable=<n> human=<n> unknown=<n>
```

## Handing the facts to an agent

`--context <file>` writes the findings to a private file (mode 0600).
Home paths and values shaped like credentials are redacted, and no secret is read to make the file.

`--agent` starts the home's verified harness (`bin/jg-harness.sh crew`) on the findings the script could not repair.
It supports the `claude` and `codex` harnesses, and it starts nothing when no finding is left.
The playbook it hands over tells the agent to ask before each fix, never read a secret, use only the guarded Juggernaut scripts, and leave sign-ins and installs to the person.

## Limits of this version

- The sentinel check reports only; it does not tick the sentinel.
- The wake queue depth is not shown, because draining belongs to the handling session.
- Project clones behind origin and backlog rows out of step with their task records are not repaired here; `bin/jg-fleet-sync.sh` and the bootstrap reconcile own them.
- Vendor logins other than `gh` are not probed.
- It does not run unattended.
- Stray test servers are listed, never stopped.

Verification: `bash tests/jg-triage.test.sh`.
