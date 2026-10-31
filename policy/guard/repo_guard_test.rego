# Contract tests for the repo-guard rule: one case per branch of the decision, driven through its
# own public document (deny) with the fact document and the allow list both supplied. Run: opa test policy/guard
package guard.repo_guard

import future.keywords.if

one(item) := {"calls": [item]}

denied(item) := d if {
	d := deny with input as one(item) with data.guard.data.allowed_repos as ["me/*"]
}

test_off_list_write_is_refused if {
	d := denied({"group": "pr", "verb": "create", "repo": "them/project"})
	count(d) == 1
	some msg in d
	contains(msg, "them/project")
	contains(msg, "me/*")
}

test_own_origin_write_passes if {
	count(denied({"group": "pr", "verb": "create", "repo": "me/project"})) == 0
}

test_wildcard_admits_the_whole_owner if {
	count(denied({"group": "issue", "verb": "create", "repo": "me/anything"})) == 0
}

test_read_verb_is_not_judged if {
	count(denied({"group": "pr", "verb": "view", "repo": "them/project"})) == 0
}

test_a_group_outside_the_write_set_is_not_judged if {
	count(denied({"group": "search", "verb": "create", "repo": "them/project"})) == 0
}

test_unresolved_repository_is_refused if {
	d := denied({"group": "pr", "verb": "create", "repo": ""})
	count(d) == 1
	some msg in d
	contains(msg, "names no repository")
}

test_no_calls_means_no_denial if {
	d := deny with input as {"calls": []} with data.guard.data.allowed_repos as ["me/*"]
	count(d) == 0
}
