#!/usr/bin/env bash
# bin/jg-swarm-plan-check.sh checks the optional muster block of a plan (formats.md section 5 of the muster skill) with
# no store and no manifest: shape and order only. The plans are built from the two example charters the muster skill
# ships (the help desk project's docs/charter.md and the rating feature's change pack), one slice per charter ticket
# the way War Room's lanes would write them, then spoiled one way at a time. Whether a block is required is decided
# at build start, not here: a plan with no block passes as before.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLI="$ROOT/bin/jg-swarm-plan-check.sh"
EX="$ROOT/.agents/skills/muster/examples"
T=$(jg_test_tmproot jg-swarm-plan-muster)

rows() {  # <doc> <first header cell>: the rows of the Markdown table whose header starts with that cell, tab separated
  awk -v h="$2" -F'|' '
    /^\|/ { c = $2; gsub(/^ +| +$/, "", c)
            if (!on && c == h) { on = 1; next }
            if (on) { if (c ~ /^-+$/) next; out = ""; for (i = 2; i < NF; i++) { v = $i; gsub(/^ +| +$/, "", v); out = out (i > 2 ? "\t" : "") v }; print out; next } }
    { on = 0 }' "$1"
}
tsv() { jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))'; }  # tab rows to a JSON array of arrays

# plan_from <doc> <kind> <preserve ids, space separated>: the matching plan for a charter document.
plan_from() {
  local doc=$1 preserve=$2
  jq -n --argjson tk "$(rows "$doc" Ticket | tsv)" --argjson bt "$(rows "$doc" Batch | tsv)" \
    --argjson ms "$(rows "$doc" Milestone | tsv)" --arg preserve "$preserve" '
    def ids: split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0));
    def dep: if . == "-" or startswith("- ") then [] else ids end;
    ($bt | map({id: .[0], after: (.[1] | dep)})) as $batches
    | ($tk | map({ticket: .[0], batch: .[2], depends: (.[3] | dep), journeys: (.[5] | ids)})) as $rows
    | ($batches | map({key: .id, value: .after}) | from_entries) as $after
    | ($ms | map({id: (.[0] | split(" ")[0]), journeys: (.[2] | ids)})) as $miles
    | ($preserve | split(" ") | map(select(length > 0))) as $keep
    | (($rows | map(.journeys) | add) + ($miles | map(.journeys) | add) + $keep | unique) as $all
    | {plan: "jg-plan", title: "Run the muster plan", report: "/tmp/report.md", intent: "Run the probe.",
       prior_art: "Prior art: none needed - a plain check",
       muster: {ticket: "jg-1", depth: "full", manifest_sha: "0123456789ab",
                journeys: ($all | map({id: ., kind: (if $keep | index(.) then "preserve" else "new" end)})),
                batches: $batches,
                charter: ($rows | map({ticket, batch, depends})),
                milestones: $miles},
       slices: ($rows | map(. as $r | {id: ("s" + ($r.ticket | ascii_downcase)),
          title: ("Make part " + ($r.ticket | ascii_downcase) + " of it"), owner_home: "main", project: "proj", size: "S", risk: "Low",
          depends_on: (([$r.depends[]] + [$rows[] | select(.batch as $b | $after[$r.batch] | index($b)) | .ticket])
                       | unique | map("s" + ascii_downcase)),
          files: [("bin/s" + ($r.ticket | ascii_downcase) + ".sh (new)")], machine: null,
          order: ("s" + ($r.ticket | ascii_downcase) + ".md"), owner_word: null, gate: null,
          journeys: $r.journeys, charter: [$r.ticket]}))}
    | .slices[0].journeys += $keep'
}
HELP=$(plan_from "$EX/helpdesk/docs/charter.md" "")
RATE=$(plan_from "$EX/rated/docs/changes/rate-a-conversation.md" "user-confirms-resolved reopen-within-a-week")

case_dir() {  # <name> <plan json> <jq filter>: a plan beside its order files; prints the plan path
  local d=$T/$1 s
  mkdir -p "$d"
  jq -c "${3:-.}" <<<"$2" > "$d/plan.json"
  for s in $(jq -r '.slices[].order' "$d/plan.json"); do printf 'order\n' > "$d/$s"; done
  printf '%s\n' "$d/plan.json"
}
run() { "$CLI" "$@" 2>&1; }
passes() {  # <name> <plan path> <expected output>
  local out
  out=$(run "$2") || fail "$1: the plan must pass: $out"
  assert_equals "$out" "$3" "$1: the ok lines"
}
refused() {  # <name> <expected refused line> <plan path>: exit 2 and exactly that one line
  local out rc=0
  out=$(run "$3") || rc=$?
  [ "$rc" = 2 ] || fail "$1: exit 2 expected, got $rc: $out"
  assert_equals "$out" "$2" "$1: one refused line"
}

# 1. A plan with no block passes as today; a slice that names journeys with no block to name them in does not.
NOBLOCK=$(jq 'del(.muster) | .slices |= map(del(.journeys, .charter))' <<<"$HELP")
passes "no block" "$(case_dir noblock "$NOBLOCK")" "wave 1: 2 slices can start at once
plan jg-plan: 4 slices ok"
refused "journeys with no block" "refused: sc1: names journeys or a charter ticket and the plan has no muster block" \
  "$(case_dir noblockclaims "$HELP" 'del(.muster) | .slices |= map(if .id == "sc1" then . else del(.journeys, .charter) end)')"
pass "muster: a plan with no block passes as before"

# 2. The help desk charter as a plan: C1 and C2 (one batch, no edge between them) start together; B2 follows B1.
passes "help desk plan" "$(case_dir help "$HELP")" "wave 1: 2 slices can start at once
plan jg-plan: 4 slices ok"
refused "C3 does not depend on C1" "refused: sc3: claims C3 and must depend on sc1, which claims C1, but does not" \
  "$(case_dir c3free "$HELP" '(.slices[] | select(.id == "sc3")).depends_on -= ["sc1"]')"
refused "a B2 slice skips a B1 slice" "refused: sc4: claims C4 and must depend on sc2, which claims C2, but does not" \
  "$(case_dir b2skip "$HELP" '(.slices[] | select(.id == "sc4")).depends_on -= ["sc2"]')"
passes "C1 and C2 in one slice" "$(case_dir c1c2 "$HELP" '
  .slices |= (map(select(.id != "sc1" and .id != "sc2"))
    | map(.depends_on |= (map(if . == "sc1" or . == "sc2" then "sc12" else . end) | unique)))
  | .slices = [{id: "sc12", title: "Make part c12 of it", owner_home: "main", project: "proj", size: "S", risk: "Low",
      depends_on: [], files: ["bin/sc12.sh (new)"], machine: null, order: "sc12.md", owner_word: null, gate: null,
      journeys: ["first-question-gets-answer", "follow-up-question", "answer-without-source-refused"], charter: ["C1", "C2"]}] + .slices')" \
  "wave 1: 1 slices can start at once
plan jg-plan: 3 slices ok"
pass "muster: the help desk charter keeps its dependencies and its batch order"

# 3. The rating feature's change pack: R1 in B1, R2 in B2 after R1, milestone F1, seven journeys (five new, two preserve).
passes "rating plan" "$(case_dir rate "$RATE")" "wave 1: 1 slices can start at once
plan jg-plan: 2 slices ok"
refused "R2 does not depend on R1" "refused: sr2: claims R2 and must depend on sr1, which claims R1, but does not" \
  "$(case_dir r2first "$RATE" '(.slices[] | select(.id == "sr2")).depends_on = []')"
refused "one slice claims R2 and R1" "refused: sr2r1: claims R2 together with R1, which it must follow: use one slice for each" \
  "$(case_dir combined "$RATE" '
    .slices = [{id: "sr2r1", title: "Make part r2r1 of it", owner_home: "main", project: "proj", size: "S", risk: "Low",
      depends_on: [], files: ["bin/sr2r1.sh (new)"], machine: null, order: "sr2r1.md", owner_word: null, gate: null,
      journeys: (.slices | map(.journeys) | add), charter: ["R2", "R1"]}]')"
pass "muster: a feature plan carries the feature's own charter and refuses a reversed or combined pair"

# 4. Shape: what no slice claims, what a slice names outside the block, a block that is not well formed.
refused "a new journey no slice names" "refused: jg-plan: muster journey orphan-journey (new) is claimed by no slice" \
  "$(case_dir newjourney "$RATE" '.muster.journeys += [{id: "orphan-journey", kind: "new"}]')"
refused "a charter ticket no slice names" "refused: jg-plan: muster charter ticket R2 is claimed by no slice" \
  "$(case_dir noticket "$RATE" '(.slices[] | select(.id == "sr2")).charter = []')"
refused "a milestone journey no slice claims" "refused: jg-plan: milestone F1 journey keep-me is claimed by no slice" \
  "$(case_dir milestone "$RATE" '.muster.journeys += [{id: "keep-me", kind: "preserve"}] | .muster.milestones[0].journeys += ["keep-me"]')"
refused "a slice names a journey not in the block" "refused: sr1: names journey no-such-journey, which is not in the muster block" \
  "$(case_dir strayjourney "$RATE" '(.slices[] | select(.id == "sr1")).journeys += ["no-such-journey"]')"
refused "a slice names a charter ticket not in the block" "refused: sr1: names charter ticket Z9, which is not in the muster block" \
  "$(case_dir strayticket "$RATE" '(.slices[] | select(.id == "sr1")).charter += ["Z9"]')"
refused "a bad depth" "refused: jg-plan: muster depth is light, not full or complete" \
  "$(case_dir baddepth "$RATE" '.muster.depth = "light"')"
refused "a bad kind" "refused: jg-plan: muster journey rate-after-resolve has kind maybe, not new or preserve" \
  "$(case_dir badkind "$RATE" '(.muster.journeys[] | select(.id == "rate-after-resolve")).kind = "maybe"')"
refused "a bad manifest sha" "refused: jg-plan: muster manifest_sha is not 12 hex digits" \
  "$(case_dir badsha "$RATE" '.muster.manifest_sha = "nope"')"
refused "a batch that waits on itself" "refused: jg-plan: batch B1 waits on itself" \
  "$(case_dir selfbatch "$RATE" '(.muster.batches[] | select(.id == "B1")).after = ["B1"]')"
refused "a charter row in a batch not in the block" "refused: jg-plan: charter ticket R2 names batch B9, which is not in the block" \
  "$(case_dir nobatch "$RATE" '(.muster.charter[] | select(.ticket == "R2")).batch = "B9"')"
refused "a charter ticket that depends on itself" "refused: jg-plan: charter ticket R2 depends on itself" \
  "$(case_dir selfticket "$RATE" '(.muster.charter[] | select(.ticket == "R2")).depends = ["R2"]')"
refused "a block that is not an object" "refused: jg-plan: muster is not an object" "$(case_dir notobject "$RATE" '.muster = []')"
refused "a block with no journeys list" "refused: jg-plan: muster journeys is not a list of {id, kind}" \
  "$(case_dir nolist "$RATE" 'del(.muster.journeys)')"
pass "muster: a block that is not well formed, or a claim outside it, is refused with one line each"

# 5. Every problem is reported, with the existing checks, in one run.
out=$(run "$(case_dir both "$RATE" '(.slices[] | select(.id == "sr2")).depends_on = [] | .slices[0].depends_on = ["zz"]')") && fail "two problems must be refused: $out"
assert_equals "$(printf '%s\n' "$out" | grep -c '^refused: ')" 2 "a muster refusal and an existing refusal both print"
assert_contains "$out" "refused: sr1: depends_on names no slice: zz" "the existing check still runs"
assert_contains "$out" "refused: sr2: claims R2 and must depend on sr1" "the muster order check still runs"
pass "muster: the block is checked beside the existing rules"
