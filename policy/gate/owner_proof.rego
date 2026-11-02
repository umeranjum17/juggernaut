# Owner-rules merge gate: may this merge land. The gate gathers the facts and acts on the answer; this decides,
# in this order: a sealed clean done-done receipt at the head, the local proof signature over that receipt, a
# passing checks-lint row, and, for a pull request in a canary home, an Evidence card on the fleet board.
# A screen-free merge may skip the receipt on a home the canary rollout has not reached yet, and may have its
# text-only card posted for it: the answer then asks for that action once (why = post_card) and is asked again.
#
# input.pr, input.head   the pull request url ("-" for a local merge) and the commit being merged
# input.none             the change declares screen: none
# input.receipt_ok       a sealed clean done-done run exists at the head
# input.signature        valid, invalid or missing: the local signature over this task, scope, head and receipt
# input.lint             pass, fail or error: the newest checks-lint row for this merge (policy gate.lint_row)
# input.canary           {readable, listed}: the canary list exists, and names this home
# input.waiver, input.now  the canary waiver's expiry and the current time, both UTC "YYYY-MM-DDTHH:MMZ" ("" no waiver)
# input.board            unset, unreadable or ok; input.items the board's items; input.key the card's key
# input.posted           the text-only card was just posted
package gate.owner_proof

import future.keywords.every
import future.keywords.if
import future.keywords.in

rules := data.gate.rules.owner_proof

canary_excludes if {
	input.canary.readable
	not input.canary.listed
}

waiver_active if {
	regex.match(rules.waiver_pattern, input.waiver)
	input.now < input.waiver
}

enforced if {
	not canary_excludes
	not waiver_active
}

commit_of(item, field) := object.get(object.get(item, field, {}), "commit", null)

card_found if {
	some item in input.items
	item.key == input.key
	item.kind == rules.card_kind
	card_commit_ok(item)
}

card_found if {
	some item in input.items
	startswith(item.key, concat("", [input.key, rules.card_key_suffix_separator]))
	item.kind == rules.card_kind
	card_commit_ok(item)
}

# At least one of run.commit and evidence.commit is present, and every one present is the head.
card_commit_ok(item) if {
	commits := [c | some field in ["run", "evidence"]; c := commit_of(item, field); c != null]
	count(commits) > 0
	every c in commits {
		c == input.head
	}
}

needs_receipt if {
	not input.receipt_ok
	not input.none
}

needs_receipt if {
	not input.receipt_ok
	enforced
}

decision := {"ok": false, "why": "no_receipt"} if {
	needs_receipt
} else := {"ok": false, "why": "no_signature"} if {
	input.signature == "missing"
} else := {"ok": false, "why": "bad_signature"} if {
	input.signature != "valid"
} else := {"ok": false, "why": "lint_error"} if {
	input.lint == "error"
} else := {"ok": false, "why": "no_lint"} if {
	input.lint != "pass"
} else := {"ok": true, "why": "local merge"} if {
	input.pr == rules.no_value
} else := {"ok": true, "why": "not enforced"} if {
	not enforced
} else := {"ok": false, "why": "no_board_config"} if {
	input.board == "unset"
} else := {"ok": false, "why": "bad_board"} if {
	input.board != "ok"
} else := {"ok": true, "why": "card found"} if {
	card_found
} else := {"ok": false, "why": "post_card"} if {
	input.none
	input.receipt_ok
	not input.posted
} else := {"ok": false, "why": "no_card"}
