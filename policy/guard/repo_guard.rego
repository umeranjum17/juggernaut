# Guard rule: a gh or gh-axi write whose target repository is not on the allow list is refused.
# The host gathers the facts and this package decides, so the rule reads only the frozen guard fact
# document: input.calls is every gh/gh-axi call the host found, with the repository it resolved for
# it (--repo, then GH_REPO, then this clone's own origin - never another remote, so a fork clone
# cannot fall back to its parent). "" means no repository resolved. The allow list is
# data.guard.data.allowed_repos, in policy/allowed_repos.rego, shared with repo-guard's binary shim.
package guard.repo_guard

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# repo-guard's write_command() set. Anything else is a read and passes untouched.
groups := {"pr", "issue", "release", "repo"}

verbs := {
	"create", "comment", "review", "edit", "merge", "close", "reopen", "delete",
	"ready", "update-branch", "revert", "lock", "unlock", "archive", "rename", "transfer",
}

# owner/repo matches exactly and owner/* matches that owner, both case-insensitively.
allowed(repo) if {
	some entry in data.guard.data.allowed_repos
	endswith(lower(trim_space(entry)), "/*")
	startswith(lower(repo), lower(trim_suffix(trim_space(entry), "*")))
}
allowed(repo) if {
	some entry in data.guard.data.allowed_repos
	lower(trim_space(entry)) == lower(repo)
}

write_call(call) if {
	call.group in groups
	call.verb in verbs
}
deny contains msg if {
	some call in input.calls
	write_call(call)
	call.repo != ""
	not allowed(call.repo)
	msg := sprintf(
		"repo-guard: refused: this %s %s targets %s, which is not an allowed repository. Allowed (%s): %s. Retry against one of those, or add it to that list. This refusal is final.",
		[call.group, call.verb, call.repo, "policy/allowed_repos.rego", concat(" ", data.guard.data.allowed_repos)],
	)
}

deny contains msg if {
	some call in input.calls
	write_call(call)
	call.repo == ""
	msg := sprintf(
		"repo-guard: refused: this %s %s names no repository this clone can resolve; pass --repo. This refusal is final.",
		[call.group, call.verb],
	)
}
