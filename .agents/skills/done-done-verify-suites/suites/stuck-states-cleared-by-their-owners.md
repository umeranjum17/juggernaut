# Stuck states cleared by their owners

Stuck states cleared by their owners: run `bash tests/jg-escalation-chain.test.sh`; its scenarios `test_a_silent_worker_is_rung_and_clears_with_no_model_turn`, `test_an_unanswered_ring_is_relaunched_then_reaches_main` and `test_a_ready_recon_draft_is_forwarded_to_its_critic` prove the owner table in `core/wait-timers/bin/jg-wait-actions-lib.sh` with real watcher and drain cycles over a copied tree.
A silent worker is rung and clears with no model turn.
An unanswered ring is relaunched through `bin/jg-control.sh`, then its lead gets the owner wake, and Main hears only after that.
A ready deep Recon draft is forwarded to its critic and its decision is closed.
Each cleared wait adds its minutes to `data/metrics/escalations.tsv` (screen: none).
