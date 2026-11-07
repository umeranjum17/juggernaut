#!/usr/bin/env bash
# jg-tool-models: config/tool-models.json moves a tool's model with a file edit alone. These run the real
# bin/jg-harness.sh (the squad lead launch), bin/jg-supervision-engine-lib.sh and bin/jg-tool-models.sh on a
# disposable home and print each answer before and after the edit, so nothing changes until the file does,
# the next call reads the new file, and a bad entry says why in one line and keeps today's default.
# journeys/tool-models.sh is the done-done journey that runs this file, so this test owns that journey.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lead() { # the squad lead's harness, model and effort as the real launch path reads them
  printf '%s %s %s' "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad_lead 2>&1)" \
    "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad-lead-model 2>&1)" "$(JG_HOME=$1 "$ROOT/bin/jg-harness.sh" squad-lead-effort 2>&1)"
}
engine_model() { # the supervision engine's default claude model, read the way a supervised launch reads it
  bash -c '. "$1"; JG_HOME=$2 jg_supervision_engine_default_model claude' _ "$ROOT/bin/jg-supervision-engine-lib.sh" "$1"
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
  out=$(engine_model "$home")
  echo "before: supervision engine model = $out"
  [ "$out" = sonnet ] || fail "no file: the supervision engine must keep its built-in model, got [$out]"
  rules supervision-engine '{"harness":"claude","model":"claude-haiku-5-5"}' >"$home/config/tool-models.json"
  out=$(engine_model "$home")
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

# The gateway chat sites: the voice rewrite, the inbox speech and side-question models, and the voice relay. Each runs
# the real script with a fake model command (a fake claude and a fake aws) that records the model it was given.
test_gateway_chat_follows_the_file() {
  local home fb out
  home=$(jg_test_tmproot jg-tool-models-gateway)
  mkdir -p "$home/config" "$home/state" "$home/data"
  fb=$(jg_fakebin "$home")
  printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "$*" >>"%s/claude.log"\nexit 1\n' "$home" >"$fb/claude"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/aws.log"\necho answer\n' "$home" >"$fb/aws"
  chmod +x "$fb/claude" "$fb/aws"
  printf 'us-east-1\n' >"$home/config/inbox-region"
  printf 'file-ask-model\n' >"$home/config/inbox-ask-model"
  printf 'voice-region\n' >"$home/config/voice-region"
  printf 'file-voice-model\n' >"$home/config/voice-model"
  local env=(env -u JG_VOICE_REWRITE_CMD -u JG_INBOX_ASK_MODEL -u JG_VOICE_MODEL -u JG_INBOX_PROFILE
    "PATH=$fb:$PATH" "JG_HOME=$home" "JG_CONFIG_OVERRIDE=$home/config" "JG_STATE_OVERRIDE=$home/state" "JG_DATA_OVERRIDE=$home/data")
  rewrite_model() { : >"$home/claude.log"; "${env[@]}" python3 "$ROOT/bin/jg-voice.py" apply --channel telegram 'The worktree is clean.' >/dev/null 2>&1; grep -o -e '--model [^ ]*' "$home/claude.log" | head -1; }
  ask_model() { : >"$home/aws.log"; "${env[@]}" "$ROOT/bin/jg-inbox.sh" ask hi >/dev/null 2>&1; grep -o -e '--model-id [^ ]*' "$home/aws.log" | head -1; }
  relay_model() { "${env[@]}" python3 -c '
import argparse, importlib.util, sys
spec = importlib.util.spec_from_file_location("relay", sys.argv[1] + "/bin/jg-voice-relay.py")
relay = importlib.util.module_from_spec(spec); sys.path.insert(0, sys.argv[1] + "/bin"); spec.loader.exec_module(relay)
print(relay.resolve_settings(argparse.Namespace(home=None, region=None, model=None, profile="", voice="v")).model)' "$ROOT" 2>&1; }

  out=$(rewrite_model); echo "before: voice rewrite = $out"
  [ "$out" = "--model claude-haiku-5-5" ] || fail "no file: the voice rewrite must keep Haiku, got [$out]"
  out=$(ask_model); echo "before: inbox ask = $out"
  [ "$out" = "--model-id file-ask-model" ] || fail "no file: the inbox ask must keep config/inbox-ask-model, got [$out]"
  out=$(relay_model); echo "before: voice relay = $out"
  [ "$out" = file-voice-model ] || fail "no file: the voice relay must keep config/voice-model, got [$out]"

  printf '{"rules":[%s,%s,%s]}\n' \
    '{"tool":"voice-rewrite","when":"fixture","use":{"harness":"claude","model":"sonnet"}}' \
    '{"tool":"inbox-ask","when":"fixture","use":{"harness":"pi","model":"amazon-bedrock/tm-ask-model"}}' \
    '{"tool":"voice-relay","when":"fixture","use":{"harness":"pi","model":"amazon-bedrock/tm-relay-model"}}' >"$home/config/tool-models.json"
  out=$(rewrite_model); echo "after the file names Sonnet: voice rewrite = $out"
  [ "$out" = "--model sonnet" ] || fail "the file edit alone must move the voice rewrite, got [$out]"
  out=$(ask_model); echo "after: inbox ask = $out"
  [ "$out" = "--model-id tm-ask-model" ] || fail "the file edit alone must move the inbox ask, got [$out]"
  out=$(relay_model); echo "after: voice relay = $out"
  [ "$out" = tm-relay-model ] || fail "the file edit alone must move the voice relay, got [$out]"
  : >"$home/aws.log"; "${env[@]}" JG_INBOX_ASK_MODEL=env-ask "$ROOT/bin/jg-inbox.sh" ask hi >/dev/null 2>&1
  out=$(grep -o -e '--model-id [^ ]*' "$home/aws.log" | head -1)
  echo "environment variable set: inbox ask = $out"
  [ "$out" = "--model-id env-ask" ] || fail "JG_INBOX_ASK_MODEL must still win over the file, got [$out]"

  # A bad entry says why in one line and keeps today's model.
  printf '{"rules":[{"tool":"voice-rewrite","when":"fixture","use":{"harness":"codex","model":"gpt-5.6-sol"}}]}\n' >"$home/config/tool-models.json"
  out=$("${env[@]}" python3 "$ROOT/bin/jg-voice.py" apply --channel telegram 'The worktree is clean.' 2>&1 >/dev/null)
  assert_contains "$out" "TOOL_MODELS: voice-rewrite needs harness claude" "a harness the site cannot run must say why"
  [ "$(rewrite_model)" = "--model claude-haiku-5-5" ] || fail "a harness the site cannot run must keep Haiku"

  rm -f "$home/config/tool-models.json"
  [ "$(rewrite_model)" = "--model claude-haiku-5-5" ] && [ "$(ask_model)" = "--model-id file-ask-model" ] && [ "$(relay_model)" = file-voice-model ] ||
    fail "removing the file must restore every default"
  echo "after removing the file: voice rewrite, inbox ask and voice relay are back to their defaults"
  pass "tool models: one file edit moves the voice rewrite, the inbox models and the voice relay, and removal restores each default"
}

test_squad_lead_follows_the_file
test_gateway_chat_follows_the_file
test_other_tools_read_the_same_file
test_bad_entries_report_and_fall_back
