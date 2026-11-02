# Merge gate rule: the newest checks-gate row for this merge must be a pass. The lint appends one row per run
# to data/checks-gate.log, and a later fail takes an earlier pass back, so only the last matching row decides.
# A `card` row is not a verdict. A pull request matches on its url and the merge head; a local merge (no url)
# matches on the head, or on a report file inside the task's own data folder when the row has no head.
#
# input.pr      the pull request url, or "-" for a local merge
# input.head    the commit being merged
# input.task    the task id, whose data folder holds a local merge's report file
# input.rows    the log in order, each {src, head, verdict}
package gate.lint_row

import future.keywords.if
import future.keywords.in

rules := data.gate.rules.lint_row

in_task_folder(src) if {
	parts := split(src, "/")
	count(parts) >= 2
	parts[count(parts) - 2] == input.task
}

matches(row) if {
	input.pr != rules.no_value
	row.src == input.pr
	row.head == input.head
}

matches(row) if {
	input.pr == rules.no_value
	row.head == input.head
}

matches(row) if {
	input.pr == rules.no_value
	row.head == rules.no_value
	not regex.match(rules.url_pattern, row.src)
	in_task_folder(row.src)
}

verdict_rows := [row |
	some row in input.rows
	not row.verdict in rules.skipped_verdicts
	matches(row)
]

default decision := {"ok": false, "why": "no checks-lint row for this merge"}

decision := {"ok": verdict_rows[count(verdict_rows) - 1].verdict == rules.pass_verdict, "why": "the newest row decides"} if count(verdict_rows) > 0
