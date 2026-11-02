# Completion-receipt acceptance: may this task's merge head land. A receipt is the task-owned record the worker
# publishes (schema 1) binding task, mode, spawn generation and exact candidate head to PASS with nonempty evidence.
# A task whose brief requires one needs it; an older task needs none, but any receipt that is present must validate.
# Once the merge path recorded a pull request, the receipt must name it, or name the lane's next open pull request
# after the recorded one merged (a forge read the caller makes only when asked).
#
# input.task, input.mode, input.spawn_gen   the task record's identity
# input.head, input.head_valid               the candidate head and whether it is a full hex object name
# input.required_lines, input.required       how many receipt_required= lines the record has, and its last value
# input.pr                                   the pull request the merge path recorded, "" before one is
# input.file                                 absent, file (a regular file) or other (a link, a directory)
# input.docs                                 the receipt file read as a list of JSON documents, null when unreadable
# input.next_pr_ok                           null until asked; then whether the receipt's pull request is the lane's next
# decision.why                               ok, malformed, missing or refused; need next_pr asks for the forge read
package gate.receipt

import future.keywords.if

rules := data.gate.rules.receipt

malformed if input.required_lines > 1

malformed if {
	input.required_lines == 1
	input.required != rules.required
}

receipt := input.docs[0]

valid if {
	input.head_valid
	input.file == "file"
	count(input.docs) == 1
	receipt.schema == rules.schema
	receipt.task == input.task
	receipt.mode == input.mode
	receipt.spawn_gen == input.spawn_gen
	receipt.head == input.head
	receipt.verdict == rules.pass_verdict
	is_string(receipt.evidence)
	regex.match(rules.nonblank_pattern, receipt.evidence)
	is_number(receipt.at)
	receipt.at > 0
}

default receipt_pr := ""

receipt_pr := receipt.pr if is_string(receipt.pr)

names_other_pr if {
	input.pr != ""
	receipt_pr != input.pr
}

decision := {"ok": false, "why": "malformed"} if {
	malformed
} else := {"ok": true, "why": "no receipt, none required"} if {
	input.file == "absent"
	input.required != rules.required
} else := {"ok": false, "why": "missing"} if {
	input.file == "absent"
} else := {"ok": false, "why": "refused"} if {
	not valid
} else := {"ok": true, "why": "ok"} if {
	not names_other_pr
} else := {"ok": false, "why": "refused", "need": "next_pr"} if {
	input.next_pr_ok == null
} else := {"ok": input.next_pr_ok == true, "why": "ok"}
