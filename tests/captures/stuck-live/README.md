# Live stuck-worker captures

Real pane captures from the three runtimes' own TUIs, taken with `journeys/stuck-live-captures.sh`
(pi 1.0.0 with `@juicesharp/rpiv-ask-user-question`, codex-cli 0.159.2 in Plan mode, OpenCode 1.18.25).
`tests/jg-escalation-chain-signals.test.sh` reads each through `jg_stuck_verdict` and requires the cause named in
the file name: `pi-question` and `codex-question` are open question dialogs, `opencode-quota` is OpenCode's
"Free usage exceeded" banner.
