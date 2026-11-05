#!/usr/bin/env bash
# jg-tool-models: config/tool-models.json moves a tool's model with a file edit alone. These run the real
# bin/jg-harness.sh (the squad lead launch), bin/jg-supervision-engine-lib.sh and bin/jg-tool-models.sh on a
# disposable home and print each answer before and after the edit, so nothing changes until the file does,
# the next call reads the new file, and a bad entry says why in one line and keeps today's default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lead() { # the squad lead's harness, model and effort as the real launch path reads them
  printf '%s %s %s' "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad_lead 2>&1)" \
    "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad-lead-model 2>&1)" "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad-lead-effort 2>&1)"
}
rules() { # <tool> <profile-json>
  printf '{"rules":[{"tool":"%s","when":"fixture for %s","use":%s}]}\n' "$1" "$1" "$2"
}

test_squad_lead_follows_the_file() {
  local home out
  home=$(jg_test_tmproot jg-tool-models-lead)
  mkdir -p "$home/config"
  printf 'claude opus max\n' >"$home/config/squad-lead-harness"
  out=$(lead "$home")
  echo "before: squad lead = $out"
  [ "$out" = "claude opus max" ] || fail "no tool-models file: the squad lead must keep config/squad-lead-harness, got [$out]"

  rules squad-lead '{"harness":"claude","model":"sonnet","effort":"high"}' >"$home/config/tool-models.json"
  out=$(lead "$home")
  echo "after the file names Sonnet: squad lead = $out"
  [ "$out" = "claude sonnet high" ] || fail "the file edit alone must move the squad lead to Sonnet, got [$out]"

  rules squad-lead '[{"harness":"pi","model":"ollama-cloud/deepseek-v4.1-flash","effort":"medium"}]' >"$home/config/tool-models.json"
  out=$(lead "$home")
  echo "after the file names DeepSeek: squad lead = $out"
  [ "$out" = "pi ollama-cloud/deepseek-v4.1-flash medium" ] || fail "the next edit must move the squad lead to DeepSeek, got [$out]"

  rm -f "$home/config/tool-models.json"
  [ "$(lead "$home")" = "claude opus max" ] || fail "removing the file must restore today's default"

  mkdir -p "$home/config/squad_leads/alpha"
  printf 'claude haiku low\n' >"$home/config/squad_leads/alpha/harness"
  rules squad-lead '{"harness":"claude","model":"sonnet","effort":"high"}' >"$home/config/tool-models.json"
  out=$(JG_HOME=$home "$ROOT/bin/jg-harness.sh" squad-lead-model alpha 2>&1)
  [ "$out" = haiku ] || fail "a per-lead pin must still win over the shared file, got [$out]"
  pass "tool models: one file edit moves the squad lead to Sonnet then DeepSeek, removal restores the default, a per-lead pin still wins"
}

test_other_tools_read_the_same_file() {
  local home out
  home=$(jg_test_tmproot jg-tool-models-tools)
  mkdir -p "$home/config"
  out=$(. "$ROOT/bin/jg-supervision-engine-lib.sh"; JG_HOME=$home jg_supervision_engine_default_model claude)
  echo "before: supervision engine model = $out"
  [ "$out" = sonnet ] || fail "no file: the supervision engine must keep its built-in model, got [$out]"
  rules supervision-engine '{"harness":"claude","model":"claude-haiku-5-5"}' >"$home/config/tool-models.json"
  out=$(. "$ROOT/bin/jg-supervision-engine-lib.sh"; JG_HOME=$home jg_supervision_engine_default_model claude)
  echo "after: supervision engine model = $out"
  [ "$out" = claude-haiku-5-5 ] || fail "the file must move the supervision engine model, got [$out]"
  [ -z "$(JG_HOME=$home "$ROOT/bin/jg-tool-models.sh" resolve voice-rewrite 2>&1)" ] || fail "a tool with no rule must print nothing"
  JG_HOME=$home "$ROOT/bin/jg-tool-models.sh" check | grep -q '^supervision-engine' || fail "check must list each tagged rule"
  pass "tool models: another tool reads its own tagged rule from the same file, and an untagged tool keeps its default"
}

test_bad_entries_report_and_fall_back() {
  local home out err
  home=$(jg_test_tmproot jg-tool-models-bad)
  mkdir -p "$home/config"
  printf 'claude opus max\n' >"$home/config/squad-lead-harness"

  rules squad-lead '{"harness":"notaharness","model":"x"}' >"$home/config/tool-models.json"
  out=$(JG_HOME=$home "$ROOT/bin/jg-harness.sh" squad-lead-model 2>"$home/err"); err=$(cat "$home/err")
  [ "$out" = opus ] || fail "an unknown harness must fall back to today's model, got [$out]"
  assert_contains "$err" "TOOL_MODELS:" "an unknown harness must say why"
  assert_contains "$err" "must name a verified harness" "the reason must be plain"

  rules squad-lead '{"harness":"claude","model":"sonnet","effort":"turbo"}' >"$home/config/tool-models.json"
  err=$(JG_HOME=$home "$ROOT/bin/jg-harness.sh" squad-lead-model 2>&1 >/dev/null)
  assert_contains "$err" "effort must be supported" "an effort the harness refuses must say why"

  printf 'not json' >"$home/config/tool-models.json"
  err=$(JG_HOME=$home "$ROOT/bin/jg-harness.sh" squad-lead-model 2>&1 >/dev/null)
  assert_contains "$err" "not valid JSON" "a file that is not JSON must say so"

  # The spawn allow-list is the model list: the first profile it allows wins, and none allowed keeps the default.
  printf '{"claude":["opus"]}\n' >"$home/model-allow-list.json"
  rules squad-lead '[{"harness":"claude","model":"sonnet"},{"harness":"claude","model":"opus","effort":"low"}]' >"$home/config/tool-models.json"
  out=$(JG_MODEL_ALLOWLIST="$home/model-allow-list.json" JG_HOME=$home "$ROOT/bin/jg-tool-models.sh" resolve squad-lead 2>"$home/err"); err=$(cat "$home/err")
  [ "$out" = "claude opus low" ] || fail "the first allowed profile must win, got [$out]"
  assert_contains "$err" "claude sonnet skipped" "a refused profile must be named"
  rules squad-lead '{"harness":"claude","model":"sonnet"}' >"$home/config/tool-models.json"
  out=$(JG_MODEL_ALLOWLIST="$home/model-allow-list.json" JG_HOME=$home "$ROOT/bin/jg-harness.sh" squad-lead-model 2>"$home/err"); err=$(cat "$home/err")
  [ "$out" = opus ] || fail "no allowed profile must keep today's model, got [$out]"
  assert_contains "$err" "no profile for squad-lead is allowed" "the fallback must be reported"
  pass "tool models: a bad harness, effort, file or off-list model prints one plain reason and keeps today's default"
}

test_squad_lead_follows_the_file
test_other_tools_read_the_same_file
test_bad_entries_report_and_fall_back
