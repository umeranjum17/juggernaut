# Codex held wake

Run `done-done run -- bash tests/jg-codex-held-wake.test.sh` from the repository root.
A private tmux pane exercises a swallowed direct wake, the real inbox send and delivery tick, a foreign draft, and a swallowed recovery; the test checks that only the recorded text receives one recovery attempt (screen: none).
