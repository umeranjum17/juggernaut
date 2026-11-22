#!/usr/bin/env bash
# Drive the public CLI and the inventory's real script parsers in isolated homes.
# With a trunk ref, require the named test for every changed e6 fragment or test.
set -euo pipefail

suites=(contract inventory forms e6land2 e6homes e6steer e6radio3)
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
  rc=0; bash "$root/bin/jg-arm-pretool-check.sh" --command 'jg radio watch-arm &' > "$tmp/arm.out" 2>&1 || rc=$?
  if [ "$rc" != 2 ] || ! grep -q 'watcher-background' "$tmp/arm.out"; then
    echo 'watch-arm-policy failed' >&2
    exit 1
  fi
  rc=0; bash "$root/bin/jg-arm-pretool-check.sh" --command 'jg radio watch-arm' > "$tmp/arm-foreground.out" 2>&1 || rc=$?
  [ "$rc" = 0 ] || { echo 'watch-arm-foreground-control failed' >&2; exit 1; }
  printf 'PASS watch-arm-policy and foreground control\n'
  runjson="$tmp/pi-run.json"; runerr="$tmp/pi-run.stderr"; rc=0
  (cd "$root" && env -u JG_LIVE -u JG_PI_LIVE_E2E JG_TEST_SKIP_EXIT=77 JG_TEST_HOST_SLOTS="$tmp" "$jg" proof test-run single tests/jg-pi-primary-live-e2e.test.sh) > "$runjson" 2> "$runerr" || rc=$?
  if [ "$rc" != 0 ] || ! jq -e '.ok and (.data.stdout
      | contains("skip: live: opt-in; set JG_PI_LIVE_E2E=1 to run")
        and contains("gate_skip=true")
        and contains("total=1 failed=0 skipped_gate=1"))' "$runjson" >/dev/null; then
    cat "$runjson" "$runerr" >&2
    echo 'pi-live-opt-in-gate failed' >&2
    exit 1
  fi
  printf 'Verified Pi runner JSON and stderr:\n'
  cat "$runjson" "$runerr"
  printf 'Verified watcher denial reason:\n'
  cat "$tmp/arm.out"
  printf 'PASS pi-live-opt-in-gate\n'
  version=$(git -C "$root" rev-parse HEAD)
  python3 - "$DONE_DONE_EVIDENCE_ROOT/steps.json" "$version" <<'PY'
import json,sys
with open(sys.argv[1], 'w') as f:
 json.dump({'target':{'version':sys.argv[2]},'start':'Repository HEAD; isolated temporary home and fixture root.','steps':['Checked public vendor-auth help against direct usage and verified missing-argument exit 2.','Updated a fixture ticket body from a spaced file and read both replacement lines through the public CLI.','Sent a keyed radio answer and verified its inbox record and resolved status line.','Added a local public-followup intent record and checked its returned fields.','Checked watcher-background denial and foreground allowance using command text only.','Ran the Pi live test with opt-in unset and verified the gate skip markers.'],'result':'All six public CLI assertions passed; the Pi live test was skipped by its opt-in gate.'},f,indent=2)
 f.write('\n')
PY
) > "$DONE_DONE_EVIDENCE_ROOT/round-two.log" 2>&1
for suite in "${suites[@]}"; do
  log="$DONE_DONE_EVIDENCE_ROOT/$suite.log"
  test_file="core/agent-cli/tests/$suite.test.sh"
  {
    printf 'Running %s\n' "$test_file"
    bash "$test_file" && printf 'PASS %s\n' "$test_file"
  } > "$log" 2>&1 || { tail -n 25 "$log" >&2; exit 1; }
done
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
