# Ask outcome delivery

Run `done-done run ask-outcomes` to drive `bin/jg-inbox.sh outcomes` and `bin/jg-bus.sh gateway --once` through `core/bus/cmd/jg-bus/gateway_asks.go` in an isolated product home on its own tickets tables and a loopback Telegram API.
The journey records its actual command output and assertions in `ask-outcomes.log` and `steps.json`.
It checks accepted report bytes, origin-bound platform receipts, replay after restart, report revision invalidation, failed task and cancellation delivery, unsupported/missing origins, revoked owner access, file security, API refusal/outage recovery, concurrent gateway exclusion, and ambiguous sends without a platform ID, network response or saved receipt.
It then seeds lab Squad Lead homes bound to that home and checks that a result filed there, and a failure on an ask moved there by the real `bin/jg-backlog-handoff.sh`, reach the origin chat from Main's gateway with receipts kept only in Main.
It also checks that a child home's private file is never sent, and that a home whose parent record names another home, or a remote registry entry, is listed as unreadable and sends nothing.
The same command runs the existing gateway and bus account-isolation regression suites, repository lint and documentation check, saving `gateway.log`, `accounts.log`, `lint.log` and `docs.log` beside the journey evidence.
It sends no live messages and uses no real account or credential fixture.
Primary outbound delivery, remote Squad Lead homes, inbox reply-ledger integration and receipt-bound Recon cleanup are outside these slices.
