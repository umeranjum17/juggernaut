# Account outage recovers itself

Account outage recovers itself: run `bash tests/jg-escalation-chain.test.sh`; its scenarios `test_a_dead_account_moves_the_lanes_to_the_recorded_fallback_with_no_model_turn`, `test_an_empty_fallback_list_raises_one_card_and_changes_nothing` and `test_a_working_account_is_not_treated_as_down` prove the `account-down` row of the owner table in `core/wait-timers/bin/jg-wait-actions-lib.sh` with real watcher and drain cycles over a copied tree and a fake Claude CLI.
A pane that shows a dead subscription moves the pin to the next account in `config/claude-account-fallbacks`, relaunches only the live lanes on the dead account, raises one card and adds its minutes to `data/metrics/escalations.tsv`, with no model turn.
An empty or absent fallback list raises one card, moves no pin and relaunches nothing.
An account that answers its probe is left alone (screen: none).
