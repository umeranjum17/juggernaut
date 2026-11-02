# Contract tests for the lint-row rule, one case per branch of its decision. Run: opa test policy
package gate.lint_row

import future.keywords.if

pr := "https://github.com/o/r/pull/7"

head := "aaaa"

row(src, h, v) := {"src": src, "head": h, "verdict": v}

ask(over, rows) := d if {
	d := decision with input as object.union({"pr": pr, "head": head, "task": "t", "rows": rows}, over)
}

test_a_pass_row_authorizes if ask({}, [row(pr, head, "pass")]).ok

test_a_later_fail_takes_the_pass_back if not ask({}, [row(pr, head, "pass"), row(pr, head, "fail")]).ok

test_a_later_pass_replaces_a_fail if ask({}, [row(pr, head, "fail"), row(pr, head, "pass")]).ok

test_a_card_row_is_not_a_verdict if ask({}, [row(pr, head, "pass"), row(pr, head, "card")]).ok

test_another_head_does_not_count if not ask({}, [row(pr, "bbbb", "pass")]).ok

test_another_pull_request_does_not_count if not ask({}, [row("https://github.com/o/r/pull/8", head, "pass")]).ok

test_no_row_refuses if not ask({}, []).ok

test_a_local_merge_matches_on_the_head if ask({"pr": "-"}, [row("/h/data/x/pr-body.md", head, "pass")]).ok

test_a_local_merge_matches_its_report_file_when_the_row_has_no_head if ask({"pr": "-"}, [row("/h/data/t/pr-body.md", "-", "pass")]).ok

test_a_local_merge_ignores_another_tasks_report_file if not ask({"pr": "-"}, [row("/h/data/other/pr-body.md", "-", "pass")]).ok

test_a_pull_request_row_without_a_head_never_answers_a_local_merge if not ask({"pr": "-"}, [row("https://github.com/t/x/pull/1", "-", "pass")]).ok
