# Contract tests for the checks-lint rule: one case per branch of the decision, driven through its public
# document (decision) with the fact document supplied. The thresholds come from policy/gate/rules.json, so the
# same data the lint runs on is what these cases prove. Run: opa test policy
package gate.checks_lint

import future.keywords.if

good_fields := {
	"outcome": "a user can do x",
	"repro": "n/a: no bug",
	"proof": "no verify skill - bash tests/x.test.sh",
	"evidence": "a.txt",
}

file(over) := object.union({"path": "/e/a.txt", "present": true, "older": false, "fresh": true, "sha256": "aa", "fix": ""}, over)

facts(over) := object.union(
	{
		"author": "me",
		"title": "feat: thing",
		"size": {"added": 10},
		"checks": {"fields": good_fields},
		"evidence": {"folder": "/e", "tokens": ["a.txt"], "files": {"a.txt": file({})}},
	},
	over,
)

with_fields(over) := facts({"checks": {"fields": object.union(good_fields, over)}})

verdict(input_doc) := d if d := decision with input as input_doc

test_a_complete_claim_passes if {
	d := verdict(facts({}))
	d.ok
	d.kind == "evidence"
	d.why == "1 evidence files"
}

test_a_bot_passes_without_a_claim if {
	d := verdict(facts({"author": "dependabot[bot]", "checks": null}))
	d.ok
	d.why == "bot"
}

test_app_bot_login_passes if verdict(facts({"author": "app/renovate", "checks": null})).ok

test_a_lookalike_author_is_not_a_bot if not verdict(facts({"author": "dependabot-fan", "checks": null})).ok

test_no_checks_block_is_refused if {
	d := verdict(facts({"checks": null}))
	not d.ok
	d.why == "no \"## Checks\" block"
}

test_missing_fields_are_named_in_order if {
	partial := {"author": "me", "title": "t", "size": {"added": 1}, "evidence": {"folder": "/e", "tokens": [], "files": {}}, "checks": {"fields": {"outcome": "x", "repro": "n/a"}}}
	d := verdict(partial)
	d.why == "missing or empty Checks line: proof, evidence"
}

test_proof_must_name_a_command_or_path if {
	d := verdict(with_fields({"proof": "it works"}))
	d.why == "proof: names no command or path"
}

# Wording is never judged (owner, 1 Nov): no skill name in proof, no marker in repro.
test_proof_and_repro_wording_is_not_judged if verdict(with_fields({"proof": "bash tests/x.test.sh", "repro": "bash r.sh failed before"})).ok

test_na_repro_is_refused_on_a_fix_title if {
	d := verdict(facts({"title": "Fix: broken"}))
	d.why == "repro: is n/a on a fix PR"
}

test_not_proven_passes_and_skips_the_evidence_rules if {
	d := verdict(with_fields({"evidence": "not proven: no artifact"}))
	d.ok
	d.kind == "not-proven"
	d.why == "not-proven: not proven: no artifact"
}

test_trailing_separator_is_a_stray_comma if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt", ""], "files": {"a.txt": file({})}}}))
	contains(d.why, "has a stray comma")
}

test_a_name_written_twice_is_refused if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt", "a.txt"], "files": {"a.txt": file({})}}}))
	contains(d.why, "names \"a.txt\" twice")
}

test_a_line_naming_no_file_is_refused if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["the", "logs"], "files": {}}}))
	contains(d.why, "names no file")
}

test_a_missing_file_gets_its_fix if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt"], "files": {"a.txt": file({"present": false, "fix": "write evidence/a.txt"})}}}))
	d.why == "evidence: \"a.txt\" is missing (/e/a.txt); write evidence/a.txt"
}

test_the_first_bad_name_decides if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt", "b.txt"], "files": {
		"a.txt": file({"older": true}),
		"b.txt": file({"path": "/e/b.txt", "present": false, "fix": "x"}),
	}}}))
	d.why == "evidence file older than the lane launch: /e/a.txt"
}

test_reused_evidence_is_refused if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt"], "files": {"a.txt": file({"fresh": false})}}}))
	d.why == "every evidence file was already used by another PR"
}

test_one_fresh_file_is_enough if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt", "b.txt"], "files": {
		"a.txt": file({"fresh": false, "sha256": "aa"}),
		"b.txt": file({"path": "/e/b.txt", "sha256": "bb"}),
	}}}))
	d.ok
	d.why == "2 evidence files"
}

test_identical_files_are_refused if {
	d := verdict(facts({"evidence": {"folder": "/e", "tokens": ["a.txt", "b.txt"], "files": {
		"a.txt": file({}),
		"b.txt": file({"path": "/e/b.txt"}),
	}}}))
	startswith(d.why, "two evidence files are byte-identical")
}

test_size_is_advice_only if {
	d := verdict(facts({"size": {"added": 1500}}))
	d.ok
	count(d.advice) == 1
}

test_size_never_outranks_the_claim_rules if {
	d := verdict(facts({"size": {"added": 1500}, "checks": null}))
	d.why == "no \"## Checks\" block"
}

test_a_config_value_cannot_bring_the_refusal_back if verdict(facts({"size": {"added": 1500, "mode_raw": "refuse"}})).ok
