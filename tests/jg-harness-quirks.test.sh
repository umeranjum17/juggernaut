#!/usr/bin/env bash
# jg-harness-quirks: defaults/harness-quirks owns what a runtime does on a trust prompt,
# on composer submission, on interrupt, on resume, and what its pane shows. These pin the
# table shape, the accessors the core reads, the home override, and the unknown-harness
# answer: a warning and a documented refusal, never a break.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-harness-quirks-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-prompt-gate-lib.sh"

QUIRKS=$ROOT/defaults/harness-quirks
VERIFIED="claude codex opencode pi grok kimi cursor gemini muse rovo omp agy devin"

# One table per verified runtime, in the when/use/why shape, carrying every key the
# core reads, so no runtime can be silently missing a mechanic.
test_one_table_per_harness() {
  local h keys want missing=''
  for h in $VERIFIED; do
    [ -f "$QUIRKS/$h.json" ] || { missing+=" $h"; continue; }
    jq -e . "$QUIRKS/$h.json" >/dev/null 2>&1 || fail "$h table is not valid JSON"
    jq -e '[(.rules // [])[] | select((.when | type) != "string" or (.why | type) != "string" or (.use | type) != "object")] | length == 0' \
      "$QUIRKS/$h.json" >/dev/null || fail "$h table breaks the when/use/why shape"
    keys=$(jq -r '[.rules[].use] | add | keys | join(",")' "$QUIRKS/$h.json")
    # The eight keys every runtime answers. A runtime with no clear key, arm signal,
    # picker hazard, or resume form records that as an absent key, never as a guess.
    for want in trust_dialog submit_key interrupt_key interrupt_repeat interrupt_press_gap \
      interrupt_ack_source exit_command busy_sources; do
      case ",$keys," in *",$want,"*) ;; *) missing+=" $h:$want" ;; esac
    done
  done
  [ -z "$missing" ] || fail "a verified runtime is missing its table entry:$missing"
  pass "harness quirks: one when/use/why table per verified runtime carries all five behaviours"
}

# The expectation table, independent of the data so a silent edit to either side shows up
# here. Every verified runtime answers both accessors; the shapes that differ from the
# common "Escape once, empty composer" answer are pinned by name.
test_table_drives_the_control_accessors() {
  local h key repeat clear got
  while IFS=' ' read -r h key repeat clear; do
    [ "$clear" = - ] && clear=
    got="$(jg_control_interrupt_key "$h")/$(jg_control_interrupt_repeat "$h")/$(jg_control_interrupt_clear_key "$h")"
    [ "$got" = "$key/$repeat/$clear" ] || fail "$h should be '$key/$repeat/$clear', got '$got'"
  done <<'EOF'
grok C-c 1 -
opencode Escape 2 -
devin Escape 2 -
muse Escape 1 C-u
pi-signed Escape 1 -
EOF
  for h in $VERIFIED; do
    [ "$(jg_control_interrupt_key "$h")/$(jg_control_interrupt_repeat "$h")" = "Escape/1" ] \
      || [ "$h" = grok ] || [ "$h" = opencode ] || [ "$h" = devin ] \
      || fail "$h should interrupt with a single Escape, got '$(jg_control_interrupt_key "$h")'"
  done
  [ "$(jg_control_interrupt_arm_signal devin)" = 'esc again to interrupt' ] || fail "devin must keep its arm signal"
  [ "$(jg_control_interrupt_hazard_signal devin)" = 'Revert to step:|↵ revert' ] || fail "devin must keep its picker hazard"
  [ "$(jg_control_relaunch_resume_flag pi pi)" = --session ] || fail "pi must keep its resume flag"
  [ -z "$(jg_control_relaunch_resume_flag claude claude)" ] || fail "claude has no verified resume form"
  jg_prompt_gate_harness opencode || fail "opencode renders a permission dialog the gate reads"
  jg_prompt_gate_harness grok && fail "grok renders no trust dialog, so the gate is never consulted"
  pass "harness quirks: interrupt, resume and trust answers come from the table, not from a case arm"
}

# An unknown runtime warns, keeps its documented refusal, and is never guessed into
# another runtime's mechanics; a home's own copy of one table wins over the default.
test_reader_contract() {
  local home err
  err=$({ out=$(jg_hq_value someagent interrupt_key); printf 'rc=%s out=%s\n' "$?" "$out" >&2; } 2>&1 >/dev/null)
  assert_contains "$err" "no quirk table for harness 'someagent'" "an unknown harness must warn"
  assert_contains "$err" "rc=1 out=" "an unknown harness must print no value and return nonzero"
  jg_control_interrupt_key someagent 2>/dev/null && fail "an unknown harness must not borrow another runtime's key"
  jg_control_exit_command someagent 2>/dev/null && fail "an unknown harness must not borrow another runtime's exit"
  [ -z "$(jg_busy_sources_for_harness someagent 2>/dev/null)" ] || fail "an unknown harness must trust no busy source"
  home=$(jg_test_tmproot jg-harness-quirks-override)
  mkdir -p "$home/config/harness-quirks"
  printf '%s\n' '{ "rules": [ { "when": "a worker runs on this runtime", "use": { "interrupt_key": "Escape", "interrupt_repeat": "3" }, "why": "fixture" } ] }' \
    > "$home/config/harness-quirks/grok.json"
  [ "$(JG_HOME="$home" jg_hq_value grok interrupt_repeat)" = 3 ] || fail "the home's own table must win"
  pass "harness quirks: an unknown harness warns and refuses, and a home table overrides the default"
}

test_one_table_per_harness
test_table_drives_the_control_accessors
test_reader_contract
