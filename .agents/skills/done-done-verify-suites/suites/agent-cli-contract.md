# Agent CLI command contract

Run `done-done run -- bash journeys/agent-cli-contract.sh release/v13` from the repository root to seal the inventory drift check, real script parse checks, and public command routing through `bin/jg` and `bin/juggernaut-axi`.
Use the lane's trunk branch for the last argument so the same run records the changed-test selection.
The journey tests repeated flags, separate argument vectors, optional operands, and matching durable records for the direct and dispatched board route.
The journey drives [the dispatcher](../../../../core/agent-cli/dispatch.sh), the [operations inventory](../../../../core/agent-cli/operations.tsv), and the [parser check](../../../../core/agent-cli/inventory/parse.py) with temporary homes.
The logs show accepted required and optional forms, the exact argument boundaries for aliases and script actions, and one saved stdin note across both public commands.
The [inventory test](../../../../core/agent-cli/tests/inventory.test.sh) starts two parser invocations with the same scratch parent and checks that both parse successfully, preserve the caller's file, and remove their temporary fixtures.
The landing command journey checks all 31 e6land2 forms and their results through the real scripts and `jg` in separate fixture homes.
The homes command journey compares direct and dispatched calls in isolated homes, including health verification with an explicit grace period and agent instructions written to an explicit project directory.
The contract test drives single-test runs, guarded spawn and key routing, home seed, backlog task and report forms, Relay link checks and cleanup, and away return from a Telegram note.
It observes a real fixture watcher's startup line before sending the wake that completes the command.
