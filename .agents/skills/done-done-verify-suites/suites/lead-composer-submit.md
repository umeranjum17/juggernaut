# Lead composer submit

Run `done-done run -- bash tests/jg-lead-composer-submit.test.sh` from the repository root.
A private tmux pane per worker runs the real delivery tick: a lead's composer text that stays unchanged past the bound is submitted once and the doorbell rings after it, a composer that keeps changing is left alone, and a non-lead draft is never submitted (screen: none).
