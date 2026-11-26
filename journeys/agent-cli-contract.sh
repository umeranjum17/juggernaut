#!/usr/bin/env bash
# Drive the public CLI and the inventory's real script parsers in isolated homes.
# With a trunk ref, require the named test for every changed e6 fragment or test.
set -euo pipefail

suites=(contract inventory forms e6land2 e6homes e6steer e6radio3)
parallel_count=${#suites[@]}
if [ "$#" -gt 0 ]; then
  base=$(git merge-base "$1" HEAD)
  changed=$(git diff --name-only --no-renames "$base" -- \
    ':(glob)core/agent-cli/contract/e6*.json' ':(glob)core/agent-cli/tests/e6*.test.sh')
  while IFS= read -r path; do
    case "$path" in
      '') continue ;;
      core/agent-cli/contract/*) suite=${path##*/}; suite=${suite%.json} ;;
      core/agent-cli/tests/*) suite=${path##*/}; suite=${suite%.test.sh} ;;
      *) printf 'Cannot map e6 path %s to its test\n' "$path" >&2; exit 1 ;;
    esac
    test_file="core/agent-cli/tests/$suite.test.sh"
    # contract.test.sh covers the shipped, partial e6steer fragment. A change to
    # that slice must supply its own test, just like any other changed e6 slice.
    if [ ! -f "$test_file" ] || [ ! -s "$test_file" ]; then
      printf 'Missing required e6 test %s for %s\n' "$test_file" "$path" >&2
      exit 1
    fi
    case " ${suites[*]} " in
      *" $suite "*) ;;
      *) suites+=("$suite") ;;
    esac
  done <<< "$changed"
fi

bash bin/jg-lint.sh bin/jg bin/jg-alert.sh bin/jg-board-gate.sh bin/jg-crew-state.sh bin/jg-migrate.sh \
  bin/jg-arm-pretool-check.sh bin/jg-test-run.sh \
  core/agent-cli/dispatch.sh core/agent-cli/send-key.sh core/agent-cli/tests/contract.test.sh \
  core/agent-cli/tests/forms.test.sh core/agent-cli/tests/inventory.test.sh journeys/agent-cli-contract.sh > "$DONE_DONE_EVIDENCE_ROOT/lint.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/lint.log" >&2; exit 1; }
bash bin/jg-doc-audience-check.sh > "$DONE_DONE_EVIDENCE_ROOT/doc-audience.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/doc-audience.log" >&2; exit 1; }
(
  set -euo pipefail
  root=$(pwd -P)
  jg=$root/bin/jg
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT INT TERM
  mkdir -p "$tmp/fakebin" "$tmp/home"/{config,data,state,projects} "$tmp/root"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/fakebin/tmux"; chmod +x "$tmp/fakebin/tmux"
  printf '#!/bin/sh\nexit 97\n' > "$tmp/fakebin/gh"; chmod +x "$tmp/fakebin/gh"
  export PATH="$tmp/fakebin:$PATH" JG_HOME="$tmp/home" JG_CONFIG_OVERRIDE="$tmp/home/config" JG_DATA_OVERRIDE="$tmp/home/data" JG_STATE_OVERRIDE="$tmp/home/state" JG_ROOT_OVERRIDE="$tmp/root" JG_SEND_SETTLE=0
  : > "$tmp/home/config/backlog-intake-loose"
  help=$("$jg" crew vendor-auth-probe --help)
  direct=$("$root/bin/jg-vendor-auth-probe.sh" --help)
  if ! jq -e '.ok' <<<"$help" >/dev/null || [ "$(jq -r .data.stdout <<<"$help")" != "$direct" ]; then
    echo 'vendor-auth-help failed' >&2
    exit 1
  fi
  rc=0; "$jg" crew vendor-auth-probe >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || { echo 'vendor-auth-no-args failed' >&2; exit 1; }
  printf 'PASS vendor-auth-help and vendor-auth-no-args\n'
  "$root/bin/jg-backlog.sh" add q-1 '[feature] Umer fixture' --priority 1 --kind ship --repo alpha --body Old >/dev/null
  body="$tmp/replacement body.txt"; printf 'Umer replacement first line\nUmer replacement second line\n' > "$body"
  updated=$(cd "$tmp" && "$jg" ticket backlog update q-1 --body-file "$body")
  jq -e '.ok' <<<"$updated" >/dev/null
  shown=$("$jg" ticket backlog show q-1 --full)
  card=$(jq -r .data.stdout <<<"$shown")
  [[ "$card" == *'Umer replacement first line'* && "$card" == *'Umer replacement second line'* ]] || { echo 'ticket-body-update failed' >&2; exit 1; }
  printf 'PASS ticket-body-update\n'
  printf 'Umer archived replacement first line\nUmer archived replacement second line\n' > "$body"
  archived=$(cd "$tmp" && "$jg" ticket backlog update q-1 --body-file "$body" --archive-body)
  jq -e '.ok and (.data.stdout | type == "string" and contains("updated q-1 (body, archive)"))' <<<"$archived" >/dev/null || { echo 'ticket-body-archive-update failed' >&2; exit 1; }
  archived_shown=$("$jg" ticket backlog show q-1 --full)
  archived_card=$(jq -r .data.stdout <<<"$archived_shown")
  [[ "$archived_card" == *'Umer archived replacement first line'* && "$archived_card" == *'Umer archived replacement second line'* ]] || { echo 'ticket-body-archive-show failed' >&2; exit 1; }
  printf 'PASS ticket-body-archive-update and ticket-body-archive-show\n'
  spawn_task=umer-fixture-task
  spawn_project="$tmp/nonexistent-fixture-project"
  direct_spawn_err="$tmp/spawn-direct.stderr"; public_spawn_json="$tmp/spawn-public.json"; public_spawn_err="$tmp/spawn-public.stderr"
  direct_spawn_rc=0
  "$root/bin/jg-spawn.sh" "$spawn_task" "$spawn_project" --ticket q-1 --mode local-only --yolo off --upstream-consent example.invalid/umer/repo > /dev/null 2> "$direct_spawn_err" || direct_spawn_rc=$?
  direct_spawn_error=$(cat "$direct_spawn_err")
  [[ "$direct_spawn_error" == *'error: --upstream-consent is meaningless on '* && "$direct_spawn_error" == *'which publishes nothing; drop it'* ]] || { echo 'spawn-direct-upstream-consent-refusal failed' >&2; exit 1; }
  public_spawn_rc=0
  "$jg" crew spawn "$spawn_task" "$spawn_project" --ticket q-1 --mode local-only --yolo off --upstream-consent example.invalid/umer/repo > "$public_spawn_json" 2> "$public_spawn_err" || public_spawn_rc=$?
  public_spawn_error=$(jq -er '.data.error | select(type == "string")' "$public_spawn_json") || { echo 'spawn-public-envelope failed' >&2; exit 1; }
  jq -e '.ok == false and (.data.error | type == "string")' "$public_spawn_json" >/dev/null || { echo 'spawn-public-refusal-envelope failed' >&2; exit 1; }
  [ "$public_spawn_error" = "$direct_spawn_error" ] || { echo 'spawn-public-error-mismatch failed' >&2; exit 1; }
  [ "$direct_spawn_rc" -ne 0 ] && [ "$public_spawn_rc" -ne 0 ] && [ "$direct_spawn_rc" = "$public_spawn_rc" ] || { echo 'spawn-refusal-exit-code-mismatch failed' >&2; exit 1; }
  printf 'PASS spawn-upstream-consent-refusal\n'
  printf 'window=sess:jg-t1\nkind=ship\nharness=claude\n' > "$tmp/home/state/t1.meta"
  printf 'blocked [at=%s] [key=fixture-key]: Umer fixture blocker\n' "$(date +%s)" > "$tmp/home/state/t1.status"
  sent=$("$jg" radio send t1 --resolve-key fixture-key 'Umer fixture answer')
  jq -e '.ok' <<<"$sent" >/dev/null
  grep -Fq 'Umer fixture answer' "$tmp/home/state/t1.inbox/001.msg"
  grep -Eq '^resolved \[key=fixture-key\] \[at=[0-9]+\]: answered: Umer fixture answer$' "$tmp/home/state/t1.status"
  printf 'PASS radio-keyed-answer\n'
  jq -n '{request_id:"req-1",platform:"discord",context_binding:{version:"ctx1",value:"ctx1_one"},public_safe_summary:"Umer asked for the fix",received_at:"2026-07-30T10:00:00Z",followup_expires_at:"2026-08-06T10:00:00Z",reservation_expires_at:"2026-08-06T10:00:00Z"}' > "$tmp/request.json"
  jq -n '{type:"pr-merged",project:"juggernaut",required_deliverables:["pr_url"],completion_policy:"all-required"}' > "$tmp/expected.json"
  follow=$("$jg" ticket backlog public-followup add pf-one --request-context-file "$tmp/request.json" --purpose promised-final --expected-final-file "$tmp/expected.json" --expires-at 2026-10-01T00:00:00Z --json)
  jq -e '.ok and .data.action == "public-followup.add" and .data.task.id == "pf-one" and .data.task.public_followup.delivery.state == "intent"' <<<"$follow" >/dev/null || { echo 'public-followup-add failed' >&2; exit 1; }
  printf 'PASS public-followup-add\n'
  relation="$tmp/relation file.json"
  jq -n '{relation_id:"rel-one",work_ref:{home_id:"main",task_id:"jg-work"},role:"fulfills",required:true,generation:1}' > "$relation"
  bind=$("$jg" ticket backlog public-followup bind-work pf-one --relation-file "$relation" --json)
  jq -e '.ok and .data.action == "public-followup.bind-work" and any(.data.task.public_followup.work_relations[]?; .relation_id == "rel-one" and .work_ref.home_id == "main" and .work_ref.task_id == "jg-work")' <<<"$bind" >/dev/null || { echo 'public-followup-bind-work failed' >&2; exit 1; }
  printf 'PASS public-followup-bind-work\n'
  "$root/bin/jg-backlog.sh" add bearing-hold-one '[feature] Umer bearings hold one' --priority 1 --kind ship --repo alpha --body Fixture >/dev/null
  "$root/bin/jg-backlog.sh" add bearing-hold-two '[feature] Umer bearings hold two' --priority 1 --kind ship --repo alpha --body Fixture >/dev/null
  "$root/bin/jg-captain-hold.sh" hold bearing-hold-one --reason 'Umer fixture captain hold' >/dev/null
  "$root/bin/jg-captain-hold.sh" hold bearing-hold-two --reason 'Umer fixture captain hold' >/dev/null
  export JG_BEARINGS_NOW=2026-11-22T11:00:00Z
  bearings_include=$("$jg" report bearings-snapshot --json --include-prs)
  bearings_include_direct=$("$root/bin/jg-bearings-snapshot.sh" --json --include-prs)
  jq -e '.ok and .data == $direct and (.data.candidate_prs | type == "array")' --argjson direct "$bearings_include_direct" <<<"$bearings_include" >/dev/null || { echo 'bearings-include-prs failed' >&2; exit 1; }
  export JG_BEARINGS_DECISIONS=1
  bearings_decisions=$("$jg" report bearings-snapshot --json --all-decisions)
  bearings_decisions_direct=$("$root/bin/jg-bearings-snapshot.sh" --json --all-decisions)
  jq -e '.ok and .data == $direct and (.data.decisions_open | map(.id) | sort) == ["bearing-hold-one","bearing-hold-two"]' --argjson direct "$bearings_decisions_direct" <<<"$bearings_decisions" >/dev/null || { echo 'bearings-all-decisions failed' >&2; exit 1; }
  printf 'PASS bearings-snapshot include-prs and all-decisions\n'
  bearings_combined=$("$jg" report bearings-snapshot --json --include-prs --all-decisions)
  bearings_combined_direct=$("$root/bin/jg-bearings-snapshot.sh" --json --include-prs --all-decisions)
  jq -e '.ok and .data == $direct and (.data.candidate_prs | type == "array")
    and (.data.decisions_open | map(.id) | sort) == ["bearing-hold-one","bearing-hold-two"]' \
    --argjson direct "$bearings_combined_direct" <<<"$bearings_combined" >/dev/null || { echo 'bearings-combined failed' >&2; exit 1; }
  printf 'PASS bearings-snapshot combined include-prs and all-decisions\n'
  backlog_help=$("$jg" ticket backlog help)
  backlog_help_direct=$("$root/bin/jg-backlog.sh" --help)
  afk_help=$("$jg" radio afk-contract --help)
  afk_help_direct=$("$root/bin/jg-afk-contract.sh" --help)
  if [ -z "$backlog_help_direct" ] || [ -z "$afk_help_direct" ] \
    || [ "$(jq -r .data.stdout <<<"$backlog_help")" != "$backlog_help_direct" ] \
    || [ "$(jq -r .data.stdout <<<"$afk_help")" != "$afk_help_direct" ]; then
    echo 'backlog-or-afk-help failed' >&2
    exit 1
  fi
  jq -e '.ok' <<<"$backlog_help" >/dev/null
  jq -e '.ok' <<<"$afk_help" >/dev/null
  printf 'PASS backlog-help and afk-contract-help\n'
  rc=0; bash "$root/bin/jg-arm-pretool-check.sh" --command 'jg radio watch-arm &' > "$tmp/arm.out" 2>&1 || rc=$?
  if [ "$rc" != 2 ] || ! grep -q 'watcher-background' "$tmp/arm.out"; then
    echo 'watch-arm-policy failed' >&2
    exit 1
  fi
  rc=0; bash "$root/bin/jg-arm-pretool-check.sh" --command 'jg radio watch-arm' > "$tmp/arm-foreground.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo 'watch-arm-foreground-control failed' >&2; exit 1; }
  printf 'PASS watch-arm-policy and foreground control\n'
  for named_test in tests/jg-pi-primary-live-e2e.test.sh tests/jg-opencode-primary-live-e2e.test.sh; do
    test_label=${named_test##*/}
    runjson="$tmp/${test_label}.json"; runerr="$tmp/${test_label}.stderr"; rc=0
    (cd "$root" && env -u JG_LIVE -u JG_PI_LIVE_E2E -u JG_OPENCODE_LIVE_E2E JG_TEST_SKIP_EXIT=77 JG_TEST_HOST_SLOTS="$tmp" "$jg" proof test-run single "$named_test") > "$runjson" 2> "$runerr" || rc=$?
    if [ "$rc" != 0 ] || ! jq -e '.ok and (.data.stdout
        | contains("gate_skip=true")
          and contains("total=1 failed=0 skipped_gate=1")
          and contains("skip: live: opt-in; set "))' "$runjson" >/dev/null; then
      cat "$runjson" "$runerr" >&2
      printf '%s opt-in gate failed\n' "$test_label" >&2
      exit 1
    fi
    printf 'Verified %s runner JSON and stderr:\n' "$test_label"
    cat "$runjson" "$runerr"
  done
  printf 'Verified watcher denial reason:\n'
  cat "$tmp/arm.out"
  printf 'PASS named live-test opt-in gates\n'
  version=$(git -C "$root" rev-parse HEAD)
  python3 - "$DONE_DONE_EVIDENCE_ROOT/steps.json" "$version" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as f:
 json.dump({'target':{'version':sys.argv[2]},'start':'Repository HEAD; isolated temporary home and fixture root.','steps':['Checked public vendor-auth help against direct usage and verified missing-argument exit 2.','Updated a fixture ticket body from a spaced file and read both replacement lines through the public CLI.','Updated the fixture ticket body again with --archive-body and checked the success text and both replacement lines in the full public ticket view.','Ran direct and public spawn commands with --upstream-consent on local-only delivery; verified the intake refusal, matching error text and nonzero exit codes.','Sent a keyed radio answer and verified its inbox record and resolved status line.','Added a local public-followup intent record and checked its returned fields.','Bound pf-one to the spaced-file work relation and checked its returned relation.','Compared the PR and decision flags, separately and combined, with the direct bearings script on held fixture tickets and a stub forge command.','Read a moved worker in read-only mode, then repaired its recorded endpoint through the bare crew state command.','Compared public backlog and AFK contract help with nonempty direct help.','Checked watcher-background denial and foreground allowance using command text only.','Ran the Pi and OpenCode named tests with live opt-ins unset and verified their gate skip markers.'],'result':'All existing and added public CLI assertions passed; both named live tests were skipped by their opt-in gates.'},f,indent=2)
 f.write('\n')
PY
) > "$DONE_DONE_EVIDENCE_ROOT/round-two.log" 2>&1
run_suite() {
  local suite=$1
  local log="$DONE_DONE_EVIDENCE_ROOT/$suite.log"
  local test_file="core/agent-cli/tests/$suite.test.sh"
  {
    printf 'Running %s\n' "$test_file"
    bash "$test_file" && printf 'PASS %s\n' "$test_file"
  } > "$log" 2>&1
}

# Every base suite owns its fixture homes and log. Join all of them so a
# failure cannot leave a sibling running without its result.
pids=()
for suite in "${suites[@]:0:parallel_count}"; do
  run_suite "$suite" < /dev/null &
  pids+=("$!")
done
failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[i]}"; then
    tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/${suites[i]}.log" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1

# Additional suites selected by a changed ref retain their original order.
for suite in "${suites[@]:parallel_count}"; do
  run_suite "$suite" || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/$suite.log" >&2; exit 1; }
done
bash tests/jg-endpoint-follow.test.sh > "$DONE_DONE_EVIDENCE_ROOT/endpoint-follow.log" 2>&1 \
  || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/endpoint-follow.log" >&2; exit 1; }
# Check that harness instructions use registered commands, except named script internals.
python3 - > "$DONE_DONE_EVIDENCE_ROOT/harness-instruction-contract.log" 2>&1 <<'PYTEST'
import glob
import json
import pathlib
import re

paths = [pathlib.Path('.agents/skills/harness-adapters/SKILL.md')]
paths += [pathlib.Path('.agents/skills/harness-adapters/references/common') / (name + '.md')
          for name in ('control-and-recovery', 'dispatch', 'model-and-effort', 'primary-hooks')]
entries = [entry for name in glob.glob('core/agent-cli/contract/*.json')
           for entry in json.loads(pathlib.Path(name).read_text())['entries']]
scripts = {pathlib.Path(entry['script']).name for entry in entries}
commands = {tuple(entry['path']) for entry in entries}
found = 0
for path in paths:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if 'script:' not in line:
            for script in scripts:
                if re.search(r'(?<![\w-])' + re.escape(script) + r'(?![\w.-])', line):
                    raise SystemExit(f'{path}:{number}: contract script lacks script: prefix: {script}')
        for command in re.findall(r'`(jg [^`]*)`', line):
            words = command.split()[1:]
            if not any(tuple(words[:len(candidate)]) == candidate for candidate in commands):
                raise SystemExit(f'{path}:{number}: unregistered command: {command}')
            found += 1
if not found:
    raise SystemExit('no harness instruction commands found')
print(f'PASS harness-instruction-contract: {found} registered command references; no unmarked contract scripts')
PYTEST
if [ "$#" -gt 0 ]; then
  bash bin/jg-test-run.sh --changed --base "$1" --json "$DONE_DONE_EVIDENCE_ROOT/changed-tests.json" \
    > "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" 2>&1 \
    || { tail -n 25 "$DONE_DONE_EVIDENCE_ROOT/changed-tests.log" >&2; exit 1; }
fi
