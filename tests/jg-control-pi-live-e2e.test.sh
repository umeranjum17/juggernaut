#!/usr/bin/env bash
# Real managed Pi-to-Codex switch, with multiline input and preserved work.
# Opt-in: the replacement receives one short prompt through the real spawn.
# JG_CONTROL_PI_PACKAGES_JSON optionally names a JSON array of installed Pi
# package paths; their state stays under the lab's PI_CODING_AGENT_DIR.
# JG_CONTROL_PI_BIN can preserve the measured executable across PATH changes.
# JG_CONTROL_PI_EVIDENCE selects retained captures (screen: none).
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_live_gate opt-in JG_CONTROL_PI_LIVE pi codex herdr jq
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
. "$ROOT/bin/jg-composer-lib.sh"
# Keep the installed CLI precedence. A mise shim for python3 cannot run the
# lab viewer under an isolated HOME unless the user's config is trusted there.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | awk '$0 !~ /\/mise\/shims$/ { printf "%s%s", sep, $0; sep=":" }')
export PATH SHELL=/bin/bash
PI_BIN=${JG_CONTROL_PI_BIN:-$(command -v pi)}
case "$PI_BIN" in /*) ;; *) echo 'Pi executable must be an absolute path' >&2; exit 1 ;; esac
"$PI_BIN" --version
codex --version
herdr --version
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE HERDR_PANE_ID HERDR_SOCKET_PATH
REAL_HOME=$HOME
LAB=$(mktemp -d "${TMPDIR:-/tmp}/jg-control-pi.XXXXXX")
E=${JG_CONTROL_PI_EVIDENCE:-$LAB/evidence}
mkdir -p "$E"
{ readlink -f "$PI_BIN"; sha256sum "$PI_BIN"; "$PI_BIN" --version; } > "$E/pi-executable.txt"
H="$ROOT/bin/jg-herdr-lab.sh"
S=$("$H" name control-pi)
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" != 0 ] && [ -n "${P:-}" ]; then
    "$H" run "$S" pane read "$P" --source visible --format ansi > "$E/failure.ansi" || true
    "$H" run "$S" pane process-info --pane "$P" > "$E/failure-process.json" || true
  fi
  "$H" teardown "$S" || rc=1
  # The launch owner deliberately protects generated hooks from replacement.
  if [ -d "$LAB/parent/state/probe.git-hooks" ]; then chmod u+w "$LAB/parent/state/probe.git-hooks"; fi
  rm -rf -- "$LAB"
  exit "$rc"
}
trap cleanup EXIT
"$H" provision "$S"
"$H" viewer start "$S"
PARENT=$LAB/parent
LEAD=$LAB/lead
mkdir -p "$PARENT"/{data,state,config,projects} "$LEAD"/{data,state,config,projects,bin} "$LAB/pi-agent"
printf 'probe\n' > "$LEAD/.jg-squad-lead-home"
printf 'Isolated lifecycle test. Follow only the test charter.\n' > "$LEAD/AGENTS.md"
printf 'This is a lifecycle test. Reply exactly SWITCH_OK. Do not use tools or change files.\n' > "$LEAD/data/charter.md"
printf 'data/\nstate/\nconfig/\nprojects/\n' > "$LEAD/.gitignore"
printf 'committed\n' > "$LEAD/work.txt"
git -C "$LEAD" init -q
git -C "$LEAD" -c user.name=Test -c user.email=test@example.invalid add .
git -C "$LEAD" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
HEAD_BEFORE=$(git -C "$LEAD" rev-parse HEAD)
printf 'Umer uncommitted change\n' > "$LEAD/work.txt"
printf 'Umer untracked work\n' > "$LEAD/untracked.txt"
printf 'child worker state\n' > "$LEAD/state/child.meta"
mkdir -p "$PARENT/state/probe.inbox"
printf 'queued instruction for Umer\n' > "$PARENT/state/probe.inbox/001.msg"
cp "$LEAD/state/child.meta" "$E/child-before.txt"
cp "$PARENT/state/probe.inbox/001.msg" "$E/queued-before.txt"
if [ -n "${JG_CONTROL_PI_PACKAGES_JSON:-}" ]; then
  jq '{packages: .}' "$JG_CONTROL_PI_PACKAGES_JSON" > "$LAB/pi-agent/settings.json"
  PI_FLAGS=
else
  PI_FLAGS=--no-extensions
fi
"$H" run "$S" workspace create --cwd "$LEAD" --label control-pi --no-focus > "$E/workspace.json"
P=$(jq -r '.result.root_pane.pane_id' "$E/workspace.json")
W=$(jq -r '.result.workspace.workspace_id' "$E/workspace.json")
T=$(jq -r '.result.tab.tab_id' "$E/workspace.json")
for ((i=0; i<50; i++)); do
  "$H" run "$S" pane read "$P" --source visible > "$E/shell.txt"
  if grep -q '[$][[:space:]]*$' "$E/shell.txt"; then break; fi
  sleep 0.2
done
grep -q '[$][[:space:]]*$' "$E/shell.txt"
# The shell starts with disposable settings; installed CLIs then use their
# normal HOME without copying credentials or reloading the user's shell rc.
"$H" run "$S" pane run "$P" "export HOME='$REAL_HOME' CODEX_HOME='$REAL_HOME/.codex'; env PI_CODING_AGENT_DIR='$LAB/pi-agent' '$PI_BIN' $PI_FLAGS --no-context-files --no-skills --no-session --approve --offline --tui-mode regular" >/dev/null
for ((i=0; i<60; i++)); do
  "$H" run "$S" agent get "$P" > "$E/pi-agent.json" 2>/dev/null || true
  if jq -e '.result.agent.agent == "pi"' "$E/pi-agent.json" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
jq -e '.result.agent.agent == "pi"' "$E/pi-agent.json" >/dev/null
for ((i=0; i<150; i++)); do
  "$H" run "$S" pane read "$P" --source visible --format ansi > "$E/startup.ansi"
  "$H" run "$S" agent get "$P" > "$E/pi-agent.json"
  identity=$(jq -r '[.result.agent.agent, .result.agent.agent_status] | @tsv' "$E/pi-agent.json")
  verdict=$(jg_composer_classify_screen $'styled=1\ncursor=0\nidentity=1' "$(cat "$E/startup.ansi")" '' "$identity")
  [ "$verdict" != empty ] || break
  sleep 0.2
done
[ "$verdict" = empty ]
cat > "$PARENT/state/probe.meta" <<EOF
endpoint_task_id=probe
project=$LEAD
worktree=$LEAD
home=$LEAD
kind=squad_lead
mode=squad_lead
yolo=off
harness=pi
model=default
effort=default
backend=herdr
window=$S:$P
herdr_session=$S
herdr_workspace_id=$W
herdr_tab_id=$T
herdr_pane_id=$P
spawn_gen=lab-probe
EOF
control() (
  # shellcheck source=/dev/null
  . "$H"
  jg_herdr_lab_runtime_env "$S"
  export HOME="$REAL_HOME" CODEX_HOME="$REAL_HOME/.codex" JG_HOME="$PARENT" JG_ROOT_OVERRIDE="$ROOT"
  bash "$ROOT/bin/jg-control.sh" probe "$@"
)
capture() {
  "$H" run "$S" pane read "$P" --source visible --format ansi > "$E/$1.ansi"
  "$H" run "$S" pane process-info --pane "$P" > "$E/$1-process.json"
}
sleep 2
DRAFT=$'Umer first line\nsecond line\nthird line\nfourth line\nfifth line\nsixth line\nseventh line\nlast line'
"$H" run "$S" pane send-text "$P" "$DRAFT" >/dev/null
sleep 0.5
capture pending
PI_PID=$(jq -r '.result.process_info.foreground_processes[] | select(.name == "pi") | .pid' "$E/pending-process.json")
ps -p "$PI_PID" -o pid=,ppid=,stat=,lstart=,args= > "$E/pi-before.txt"
if control exit > "$E/refusal.txt" 2>&1; then echo 'not ok - ordinary exit discarded a draft'; exit 1; fi
grep -q 'visibly holds pending text' "$E/refusal.txt"
capture refused
before=$(jg_composer_extract_selected_content styled=1 "$(cat "$E/pending.ansi")")
after=$(jg_composer_extract_selected_content styled=1 "$(cat "$E/refused.ansi")")
[ "$before" = "$after" ] && [ "$before" = "${DRAFT//$'\n'/ }" ]
cp "$PARENT/state/probe.meta" "$E/original.meta"
sed 's/^endpoint_task_id=probe$/endpoint_task_id=unowned/' "$E/original.meta" > "$PARENT/state/probe.meta"
if control exit --clear-composer > "$E/identity-refusal.txt" 2>&1; then echo 'not ok - clear accepted an unowned target'; exit 1; fi
grep -q 'belongs to task unowned' "$E/identity-refusal.txt"
cp "$E/original.meta" "$PARENT/state/probe.meta"
capture identity-refused
[ "$before" = "$(jg_composer_extract_selected_content styled=1 "$(cat "$E/identity-refused.ansi")")" ]
# Replay the old adapter expectation through the supported home override.
# Keep the failed control result and actual remaining input beside the fix.
mkdir -p "$PARENT/config/harness-quirks"
jq '.rules[0].use.composer_clear_key = "C-u"' "$ROOT/bin/harness-quirks/pi.json" > "$PARENT/config/harness-quirks/pi.json"
if control relaunch --clear-composer --harness codex --model "${JG_CONTROL_CODEX_MODEL:-gpt-6-luna}" --effort high > "$E/old-clear-refusal.txt" 2>&1; then
  echo 'not ok - old line-clear sequence unexpectedly completed'; exit 1
fi
grep -q "C-u clear left it 'pending'" "$E/old-clear-refusal.txt"
capture old-clear
jq -e --argjson pid "$PI_PID" '.result.process_info.foreground_processes | any(.pid == $pid and .name == "pi")' "$E/old-clear-process.json" >/dev/null
jg_composer_extract_selected_content styled=1 "$(cat "$E/old-clear.ansi")" > "$E/old-clear-content.txt"
grep -q 'Umer first line' "$E/old-clear-content.txt"
mv "$PARENT/config/harness-quirks/pi.json" "$E/old-clear-override.json"
control relaunch --clear-composer --harness codex --model "${JG_CONTROL_CODEX_MODEL:-gpt-6-luna}" --effort high --note 'Continue the isolated lifecycle test.' > "$E/switch.txt" 2>&1
grep -q 'relaunched probe harness=codex' "$E/switch.txt"
capture codex
jq -e '.result.process_info.foreground_processes | any(.name == "codex" or ((.cmdline // "") | contains("codex")))' "$E/codex-process.json" >/dev/null
# A newly created lab repository has never been trusted. Use the documented
# native trust choice only for this exact synthetic directory and live pane.
trust_handled=0
for ((i=0; i<100; i++)); do
  capture codex-ready
  screen=$(jg_composer_strip_ansi < "$E/codex-ready.ansi")
if [ "$trust_handled" = 0 ] && printf '%s\n' "$screen" | grep -q 'Folder access'; then
  printf '%s\n' "$screen" | grep -Fq "$LEAD"
  printf '%s\n' "$screen" | grep -q '› 1. Trust and continue'
  "$H" run "$S" pane process-info --pane "$P" > "$E/trust-process.json"
  jq -e --arg p "$P" --arg l "$LEAD" '.result.process_info | .pane_id == $p and any(.foreground_processes[]; .name == "codex" and .cwd == $l)' "$E/trust-process.json" >/dev/null
  "$H" run "$S" pane send-keys "$P" enter > "$E/trust-choice.json"
  trust_handled=1
fi
  if jg_composer_strip_ansi < "$E/codex-ready.ansi" | grep -q '^[[:space:]•]*SWITCH_OK[[:space:]]*$'; then break; fi
  sleep 0.3
done
jg_composer_strip_ansi < "$E/codex-ready.ansi" | grep -q '^[[:space:]•]*SWITCH_OK[[:space:]]*$'
if ps -p "$PI_PID" -o pid=,ppid=,stat=,lstart=,args= > "$E/pi-after.txt"; then echo 'not ok - old Pi PID still exists'; exit 1; fi
[ "$(git -C "$LEAD" rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(cat "$LEAD/work.txt")" = 'Umer uncommitted change' ]
[ "$(cat "$LEAD/untracked.txt")" = 'Umer untracked work' ]
cmp "$LEAD/state/child.meta" "$E/child-before.txt"
cmp "$PARENT/state/probe.inbox/001.msg" "$E/queued-before.txt"
cp "$PARENT/state/probe.meta" "$E/replacement.meta"
cp "$PARENT/state/probe.control-relaunch" "$E/transaction.txt"
control exit > "$E/codex-exit.txt" 2>&1
grep -q '^stopped probe harness=codex' "$E/codex-exit.txt"
jq -n --arg head "$(git -C "$ROOT" rev-parse HEAD)" \
  --arg harnesses "Pi $("$PI_BIN" --version), $(codex --version), $(herdr --version)" \
  '{target: {version: $head, product: "Juggernaut managed lifecycle", harnesses: $harnesses},
    start: "Managed Pi holds an eight-line draft beside dirty work, child state and a queued instruction",
    steps: ["Ordinary exit refuses and retains the draft", "A mismatched target binding refuses explicit clear",
      "The old line-clear adapter expectation leaves input pending and refuses the real relaunch",
      "Explicit clear and real relaunch replace Pi with native Codex", "The replacement answers SWITCH_OK",
      "HEAD, dirty and untracked work, child state and queued instruction remain unchanged", "Native Codex exits through control"],
    result: "The automated managed switch completes with preserved work and verified process transitions"}' > "$E/steps.json"
echo 'ok - real Pi multiline clear and managed Codex switch preserve work, child state and queued input'
