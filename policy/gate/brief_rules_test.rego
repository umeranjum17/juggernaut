# Contract tests for the brief-time owner rules, one case per branch. Run: opa test policy
package gate.brief_rules

import future.keywords.if

header := "- [ ] t - [captain-ask] Fix it (kind: ship)"

base := {"id": "t", "kind": "ship", "title": "[captain-ask] Fix it (kind: ship)", "entry_lines": [header], "ids": ["t", "p"]}

ask(over) := d if d := decision with input as object.union(base, over)

lines(extra) := {"entry_lines": array.concat([header], extra)}

test_a_captain_ask_needs_no_parent if ask({}).ok

test_an_item_with_no_ask_is_refused if ask({"title": "Fix it", "entry_lines": ["- [ ] t - Fix it"]}).why == "no_ask"

test_an_order_name_counts_as_an_ask if {
	ask({"title": "Fix it", "entry_lines": ["- [ ] t - Fix it", "  parent: p", "  for Main7"]}).ok
	ask({"title": "Fix it", "entry_lines": ["- [ ] t - Fix it", "  parent: p", "  Main7 asked"]}).ok
}

test_an_order_name_must_stand_alone if {
	ask({"title": "Fix it", "entry_lines": ["- [ ] t - Fix it", "  xMain7"]}).why == "no_ask"
	ask({"title": "Fix it", "entry_lines": ["- [ ] t - Fix it", "  Mainline"]}).why == "no_ask"
}

test_a_non_ask_ship_needs_a_known_parent if {
	item := {"title": "Fix it", "entry_lines": ["- [ ] t - Fix it Main7"]}
	ask(item).why == "no_parent"
	ask(object.union(item, {"entry_lines": ["- [ ] t - Fix it Main7", "  parent: nope"]})).why == "no_parent"
	ask(object.union(item, {"entry_lines": ["- [ ] t - Fix it Main7", "  parent: p"]})).ok
	ask(object.union(item, {"entry_lines": ["- [ ] t - Fix it Main7", "  parent: upkeep"]})).ok
	ask(object.union(item, {"entry_lines": ["- [ ] t - Fix it Main7", "    parent:   p  "]})).ok
	ask(object.union(item, {"entry_lines": ["- [ ] t - Fix it Main7", "  parent:"]})).why == "no_parent"
}

test_a_parent_edge_counts_and_beats_the_body_line if {
	item := {"title": "Fix it", "entry_lines": ["- [ ] t - Fix it Main7"]}
	ask(object.union(item, {"parent": "p"})).ok
	ask(object.union(item, {"parent": "upkeep"})).ok
	ask(object.union(item, {"parent": "nope"})).why == "no_parent"
	ask(object.union(item, {"parent": "", "labels": []})).why == "no_parent"
	ask(object.union(item, {"parent": "nope", "entry_lines": ["- [ ] t - Fix it Main7", "  parent: p"]})).why == "no_parent"
	ask(object.union(item, {"parent": "", "entry_lines": ["- [ ] t - Fix it Main7", "  parent: p"]})).ok
}

test_a_scout_needs_no_parent if ask({"kind": "scout", "title": "Fix it", "entry_lines": ["- [ ] t - Fix it Main7"]}).ok

test_a_squad_lead_is_not_checked if ask({"kind": "squad_lead", "title": "", "entry_lines": [""]}).ok

test_a_design_flag_must_be_exact if {
	ask(lines(["  design: required"])).include == "Design discovery: required"
	ask(lines(["  design: required   "])).include == "Design discovery: required"
	ask(lines(["  design: none"])).include == ""
	ask(lines(["  design: maybe"])).why == "bad_design"
	ask(lines(["  Design: required"])).why == "bad_design"
	ask(lines(["  desing: required"])).why == "bad_design"
	ask(lines(["  design discovery: required"])).why == "bad_design"
}

test_two_design_lines_are_refused if {
	ask(lines(["  design: required", "  design: none"])).why == "bad_design"
	ask(lines(["  design: none", "  design: none"])).why == "bad_design"
}

test_design_sounding_work_with_no_flag_gets_a_note if {
	ask(lines(["  Needs a new screen"])).note
	ask(lines(["  A Mock-Up is wanted"])).note
	ask({"entry_lines": ["- [ ] t - Redesign the landing page"]}).note
	not ask(lines(["  Prototypes are elsewhere"])).note
	not ask(lines(["  design: none", "  new screen"])).note
}
