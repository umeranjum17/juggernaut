# Merge gate rule: does a pull request's "## Checks" claim hold up. The lint
# (core/merge-on-green/jg-checks-lint.sh) gathers the facts and this package decides, so the rule reads
# only the frozen fact document and the thresholds and patterns in policy/gate/rules.json.
#
# input.author, input.title   the pull request's author login and title ("" for a local report file)
# input.size.added            added non-generated lines, input.size.mode_raw the first word of config/checks-size
# input.checks                null when there is no "## Checks" block, else {fields: {outcome, repro, proof, evidence}}
# input.verify_skills         the verify skills of the repository under test, sorted
# input.evidence.folder       the folder evidence names resolve in
# input.evidence.tokens       the words of the evidence line, in order ("" marks a stray separator)
# input.evidence.files[name]  {path, present, older, fresh, sha256, fix} for each non-empty token
#
# decision is {ok, why, kind, advice}: the first failing rule in rank order refuses, kind names what a pass
# rested on (bot, not-proven, evidence), and advice lists lines that never change the verdict.
package gate.checks_lint

import future.keywords.contains
import future.keywords.if
import future.keywords.in

rules := data.gate.rules.checks_lint

fields := object.get(object.get(input, "checks", {}), "fields", {})

proof := object.get(fields, "proof", "")

repro := object.get(fields, "repro", "")

evidence_line := object.get(fields, "evidence", "")

is_bot if {
	some pattern in rules.bot_authors
	regex.match(pattern, input.author)
}

refuse_size if input.size.mode_raw == rules.size_refuse_mode

over_size if input.size.added >= rules.size_guidance

size_text := sprintf("%d added non-generated lines (moved and upstream lines excluded)", [input.size.added])

not_proven if regex.match(rules.not_proven_pattern, evidence_line)

repro_is_na if regex.match(rules.repro_na_pattern, repro)

has_block if input.checks != null

# failures is every rule that refuses, each with its rank; the lowest rank is the reason given.
failures contains {"rank": 10, "why": sprintf("%s: split it (limit %d)", [size_text, rules.size_guidance])} if {
	over_size
	refuse_size
}

failures contains {"rank": 20, "why": "no \"## Checks\" block"} if not has_block

missing := [k |
	some k in rules.required_fields
	object.get(fields, k, "") == ""
]

failures contains {"rank": 30, "why": concat("", ["missing or empty Checks line: ", concat(", ", missing)])} if {
	has_block
	count(missing) > 0
}

all_present if {
	has_block
	count(missing) == 0
}

failures contains {"rank": 40, "why": "proof: names no command or path"} if {
	all_present
	not regex.match(rules.proof_command_pattern, proof)
}

failures contains {"rank": 50, "why": sprintf("proof: does not name the verify skill this repository has (%s); name the skill you ran", [concat(", ", input.verify_skills)])} if {
	all_present
	regex.match(rules.proof_command_pattern, proof)
	count(input.verify_skills) > 0
	not names_a_skill
}

names_a_skill if {
	some skill in input.verify_skills
	contains(proof, skill)
}

failures contains {"rank": 51, "why": "proof: does not name the verify-<app> skill run (or \"no verify skill\")"} if {
	all_present
	regex.match(rules.proof_command_pattern, proof)
	count(input.verify_skills) == 0
	not contains(proof, rules.verify_skill_marker)
	not regex.match(rules.no_verify_skill_pattern, proof)
}

failures contains {"rank": 60, "why": "repro: a real repro must say \"systematic-debugging used\" (brief step 2)"} if {
	all_present
	not repro_is_na
	not contains(repro, rules.repro_debug_marker)
}

failures contains {"rank": 70, "why": "repro: is n/a on a fix PR"} if {
	all_present
	regex.match(rules.fix_title_pattern, input.title)
	repro_is_na
}

# Evidence rules apply only when the claim is not an honest "not proven".
tokens := input.evidence.tokens

names := [t |
	some t in tokens
	regex.match(rules.evidence_name_pattern, t)
]

eline := sprintf("evidence: %s", [evidence_line])

check_evidence if {
	all_present
	not not_proven
}

failures contains {"rank": 100, "why": sprintf("%s has a stray comma; separate the names with one space and no trailing comma", [eline])} if {
	check_evidence
	"" in tokens
}

repeated := [n |
	some n in names
	count([m | some m in names; m == n]) > 1
]

failures contains {"rank": 110, "why": sprintf("%s names \"%s\" twice; name each file once", [eline, repeated[0]])} if {
	check_evidence
	count(repeated) > 0
}

failures contains {"rank": 120, "why": sprintf("%s names no file; write each one relative to the evidence folder %s (e.g. shot.png), or change it to \"evidence: not proven: <cause>\"", [eline, input.evidence.folder])} if {
	check_evidence
	count(names) == 0
}

failures contains {"rank": 200 + (2 * i), "why": sprintf("evidence: \"%s\" is missing (%s); %s", [n, f.path, f.fix])} if {
	check_evidence
	some i, n in names
	f := input.evidence.files[n]
	not f.present
}

failures contains {"rank": 201 + (2 * i), "why": sprintf("evidence file older than the lane launch: %s", [f.path])} if {
	check_evidence
	some i, n in names
	f := input.evidence.files[n]
	f.present
	f.older
}

failures contains {"rank": 300, "why": "every evidence file was already used by another PR"} if {
	check_evidence
	count(names) > 0
	not any_fresh
}

any_fresh if {
	some n in names
	input.evidence.files[n].fresh
}

hashes := [input.evidence.files[n].sha256 | some n in names]

failures contains {"rank": 310, "why": "two evidence files are byte-identical: capture each claimed state separately, or write \"not proven: <cause>\""} if {
	check_evidence
	count(names) > 0
	count({h | some h in hashes}) < count(hashes)
}

first_rank := min({f.rank | some f in failures})

decision := {"ok": true, "why": "bot", "kind": "bot", "advice": []} if is_bot

decision := d if {
	not is_bot
	count(failures) > 0
	d := {
		"ok": false,
		"why": [f.why | some f in failures; f.rank == first_rank][0],
		"kind": "refused",
		"advice": advice,
	}
}

decision := d if {
	not is_bot
	count(failures) == 0
	not_proven
	d := {
		"ok": true,
		"why": concat("", ["not-proven: ", substring(evidence_line, 0, rules.not_proven_keep)]),
		"kind": "not-proven",
		"advice": advice,
	}
}

decision := d if {
	not is_bot
	count(failures) == 0
	not not_proven
	d := {
		"ok": true,
		"why": sprintf("%d evidence files", [count(names)]),
		"kind": "evidence",
		"advice": advice,
	}
}

advice contains line if {
	over_size
	not refuse_size
	line := sprintf("advisory: %s is over the %d-line guidance: a smaller slice lands faster", [size_text, rules.size_guidance])
}

advice contains line if {
	over_size
	not refuse_size
	input.size.mode_raw != ""
	input.size.mode_raw != "advisory"
	line := sprintf("note: %s holds '%s', not %s: staying advisory (accepted: advisory, %s)", [input.size.mode_file, input.size.mode_raw, rules.size_refuse_mode, rules.size_refuse_mode])
}
