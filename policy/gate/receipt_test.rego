# Contract tests for the completion-receipt acceptance, one case per branch. Run: opa test policy
package gate.receipt

import future.keywords.if

head := "aaaa"

good := {"schema": 1, "task": "t", "mode": "direct-PR", "spawn_gen": "1", "head": head, "pr": "https://o/r/pull/1", "verdict": "PASS", "at": 1, "evidence": "ran"}

base := {
	"task": "t", "mode": "direct-PR", "spawn_gen": "1", "head": head, "head_valid": true, "required_lines": 1, "required": "1",
	"pr": "", "file": "file", "docs": [good], "next_pr_ok": null,
}

ask(over) := d if d := decision with input as object.union(base, over)

with_receipt(over) := {"docs": [object.union(good, over)]}

test_a_matching_pass_receipt_accepts if ask({}).ok

test_a_receipt_is_needed_only_when_required if {
	ask({"required_lines": 0, "required": "", "file": "absent", "docs": null}).ok
	ask({"file": "absent", "docs": null}).why == "missing"
}

test_a_requirement_line_that_is_not_one_is_malformed if {
	ask({"required": "0"}).why == "malformed"
	ask({"required": "yes"}).why == "malformed"
	ask({"required_lines": 2}).why == "malformed"
}

test_a_present_receipt_must_validate_even_when_optional if not ask({"required_lines": 0, "required": "", "docs": [object.union(good, {"verdict": "FAIL"})]}).ok

test_each_binding_field_is_checked if {
	every_field := [{"task": "u"}, {"mode": "local-only"}, {"spawn_gen": "2"}, {"head": "bbbb"}, {"verdict": "FAIL"}, {"schema": 2}]
	every over in every_field {
		not ask(with_receipt(over)).ok
	}
}

test_a_candidate_head_that_is_not_a_full_object_name_is_refused if not ask({"head_valid": false}).ok

test_evidence_must_be_nonblank_text if {
	not ask(with_receipt({"evidence": " \n\t"})).ok
	not ask(with_receipt({"evidence": ["x"]})).ok
	ask(with_receipt({"evidence": "  ok"})).ok
}

test_the_time_must_be_a_positive_number if {
	not ask(with_receipt({"at": 0})).ok
	not ask(with_receipt({"at": "1"})).ok
	ask(with_receipt({"at": 1.5})).ok
}

test_the_file_must_hold_exactly_one_regular_receipt if {
	not ask({"docs": [good, good]}).ok
	not ask({"docs": []}).ok
	not ask({"docs": null}).ok
	not ask({"docs": [1]}).ok
	not ask({"file": "other"}).ok
}

test_a_recorded_pull_request_must_be_the_one_named if {
	ask({"pr": "https://o/r/pull/1"}).ok
	d := ask({"pr": "https://o/r/pull/2"})
	not d.ok
	d.need == "next_pr"
}

test_the_lanes_next_pull_request_is_a_forge_fact if {
	ask({"pr": "https://o/r/pull/2", "next_pr_ok": true}).ok
	not ask({"pr": "https://o/r/pull/2", "next_pr_ok": false}).ok
}

test_a_receipt_without_a_string_pull_request_names_none if {
	d := ask({"pr": "https://o/r/pull/1", "docs": [json.remove(good, ["pr"])]})
	d.need == "next_pr"
}
