# Contract tests for the owner-rules merge gate's refusal order. Run: opa test policy
package gate.owner_proof

import future.keywords.if

head := "aaaa"

card(key, commit) := {"key": key, "kind": "evidence", "run": {"commit": commit}}

base := {
	"pr": "https://github.com/o/r/pull/9", "head": head, "none": false, "receipt_ok": true, "signature": "valid", "lint": "pass",
	"canary": {"readable": false, "listed": false}, "waiver": "", "now": "2026-11-02T06:00Z",
	"board": "ok", "items": [], "key": "merge-o-r-pull-9", "posted": false,
}

ask(over) := d if d := decision with input as object.union(base, over)

test_a_card_for_the_head_lets_it_land if ask({"items": [card("merge-o-r-pull-9", head)]}).ok

test_a_head_suffixed_card_matches if ask({"items": [card("merge-o-r-pull-9-aaaa", head)]}).ok

test_a_similar_prefix_does_not_match if ask({"items": [card("merge-o-r-pull-91", head)]}).why == "no_card"

test_a_card_for_another_commit_is_refused if ask({"items": [card("merge-o-r-pull-9", "bbbb")]}).why == "no_card"

test_an_evidence_commit_alone_is_enough if ask({"items": [{"key": "merge-o-r-pull-9", "kind": "evidence", "evidence": {"commit": head}}]}).ok

test_a_disagreeing_second_commit_is_refused if ask({"items": [{"key": "merge-o-r-pull-9", "kind": "evidence", "run": {"commit": head}, "evidence": {"commit": "bbbb"}}]}).why == "no_card"

test_a_card_with_no_commit_is_refused if ask({"items": [{"key": "merge-o-r-pull-9", "kind": "evidence"}]}).why == "no_card"

test_only_an_evidence_item_counts if ask({"items": [{"key": "merge-o-r-pull-9", "kind": "answer", "run": {"commit": head}}]}).why == "no_card"

test_no_receipt_refuses_first if ask({"receipt_ok": false, "signature": "missing", "lint": "fail"}).why == "no_receipt"

test_a_screen_free_merge_in_a_home_the_canary_has_not_reached_skips_the_receipt if {
	d := ask({"none": true, "receipt_ok": false, "canary": {"readable": true, "listed": false}})
	d.ok
}

test_a_screen_free_merge_in_an_enforced_home_needs_the_receipt if ask({"none": true, "receipt_ok": false}).why == "no_receipt"

test_a_screen_free_skip_still_needs_the_signature if ask({"none": true, "receipt_ok": false, "signature": "missing", "canary": {"readable": true, "listed": false}}).why == "no_signature"

test_a_missing_signature_refuses if ask({"signature": "missing"}).why == "no_signature"

test_a_wrong_signature_refuses if ask({"signature": "invalid"}).why == "bad_signature"

test_lint_comes_after_the_signature if ask({"signature": "invalid", "lint": "fail"}).why == "bad_signature"

test_a_failed_lint_refuses if ask({"lint": "fail"}).why == "no_lint"

test_a_lint_that_cannot_run_refuses if ask({"lint": "error"}).why == "lint_error"

test_a_local_merge_stops_after_lint if ask({"pr": "-", "board": "unset"}).ok

test_a_home_outside_the_canary_stops_after_lint if ask({"canary": {"readable": true, "listed": false}, "board": "unset"}).ok

test_a_listed_home_is_enforced if ask({"canary": {"readable": true, "listed": true}}).why == "no_card"

test_a_future_waiver_lifts_enforcement if ask({"waiver": "2999-01-01T00:00Z"}).ok

test_an_expired_waiver_does_not if ask({"waiver": "2000-01-01T00:00Z"}).why == "no_card"

test_a_waiver_that_is_not_a_time_does_not if ask({"waiver": "soon"}).why == "no_card"

test_no_board_path_refuses if ask({"board": "unset"}).why == "no_board_config"

test_an_unreadable_board_refuses if ask({"board": "unreadable"}).why == "bad_board"

test_a_screen_free_merge_with_a_receipt_asks_for_its_card_once if {
	ask({"none": true}).why == "post_card"
	ask({"none": true, "posted": true}).why == "no_card"
}

test_a_card_that_was_posted_lets_it_land if ask({"none": true, "posted": true, "items": [card("merge-o-r-pull-9", head)]}).ok
