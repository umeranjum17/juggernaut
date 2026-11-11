# Brief-time owner rules: before a lane's brief is written, its backlog item must name the owner ask it serves,
# a parent, and a well-formed design flag. The caller reads the backlog into facts; this decides.
#
# input.id          the task id
# input.kind        ship, scout or squad_lead
# input.title       the item's title (after "<id> - "), "" when the item is not in the backlog
# input.entry_lines the item's lines in the backlog, header first ([""] when absent)
# input.ids         every item id in the backlog, any status
# input.parent      the target of the item's parent-child edge, or upkeep for that label ("" or absent: none)
# input.labels      the item's labels
# The design flag is a body line "design: required|none": required adds the brief line, a design-like line that is
# not exact is refused, and design-sounding work with no line only gets a note.
# decision.why      no_ask, no_parent or bad_design when refused; note says the item reads like design work
#                   without a flag, include is the line the brief must carry
package gate.brief_rules

import future.keywords.if
import future.keywords.in

rules := data.gate.rules.brief_rules

body := array.slice(input.entry_lines, 1, count(input.entry_lines))

matching(pattern, lines) := [l | some l in lines; regex.match(pattern, l)]

captain_ask if startswith(input.title, rules.ask_prefix)

has_ask if captain_ask

has_ask if count(matching(rules.order_pattern, input.entry_lines)) > 0

parent_lines := [i | some i, l in input.entry_lines; regex.match(rules.parent_line_pattern, l)]

# The edge is the parent; the body line is the fallback for a row that has no edge.
parent := input.parent if {
	input.parent != ""
} else := p if {
	count(parent_lines) > 0
	p := regex.find_all_string_submatch_n(rules.parent_value_pattern, input.entry_lines[min(parent_lines)], 1)[0][1]
} else := ""

has_parent if parent == rules.upkeep_parent

has_parent if {
	parent != ""
	parent in input.ids
}

needs_parent if {
	not input.kind in rules.parent_exempt_kinds
	not captain_ask
}

design_lines := count(matching(rules.design_line_pattern, body))

design_exact := count(matching(rules.design_exact_pattern, body))

bad_design if design_lines != design_exact

bad_design if design_exact > 1

default design_note := false

design_note if {
	design_exact == 0
	count(matching(rules.design_like_pattern, input.entry_lines)) > 0
}

default design_include := ""

design_include := rules.design_required_line if {
	design_exact != 0
	count(matching(rules.design_required_pattern, body)) > 0
}

decision := {"ok": true, "why": "no rules for this kind"} if {
	input.kind in rules.skip_kinds
} else := {"ok": false, "why": "no_ask"} if {
	not has_ask
} else := {"ok": false, "why": "no_parent"} if {
	needs_parent
	not has_parent
} else := {"ok": false, "why": "bad_design"} if {
	bad_design
} else := {"ok": true, "why": "ok", "note": design_note, "include": design_include}
