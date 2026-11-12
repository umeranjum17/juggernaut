# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 3. Each defect of the hierarchy is refused by name.
copy_tables() { rm -rf "$T/t"; mkdir -p "$T/t"; cp "$TABLES"/{ticket,delivering,proving}.tsv "$T/t/"; }
defect() {  # <name> <table> <expected text> <line to append>
  copy_tables; printf '%s\n' "$4" >> "$T/t/$2.tsv"
  OUT=$(JG_MACHINES_TABLES="$T/t" JG_MACHINES_ENUMS="$ROOT/core/machines" bash "$JM" check ticket 2>&1); RC=$?; expect_code 1 "$RC" "lint should refuse: $1"; assert_contains "$OUT" "$3" "lint should name: $1"
}
defect "an event with two targets from one sub-state" ticket "duplicate edge proving.waiting answer" "$(tab edge proving.waiting answer closed w:f - g t)"
defect "a way out of an end inside the inner table" proving "terminal state sealed has an exit edge" "$(tab edge sealed again planned w:f - g t)"
defect "an unreachable sub-state" delivering "unreachable state orphan" "$(tab state orphan normal 'Nobody gets here.' -)"
defect "a composite with no inner table" ticket "composite state limbo has no inner table" "$(tab state limbo composite 'A stage with nothing in it.' -)"
defect "a first event that leads away from the initial state" ticket "entry event again does not lead to the initial state" "$(tab edge '(none)' again ready w:f - g t)"
pass "the lint names each defect of the hierarchy"
