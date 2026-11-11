#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are literal
# claude-model-guard in a throwaway HOME, XDG data dir and Claude config: wiring starts no ban on a host that never
# installed one, --install adds it without printing or dropping other settings, a rewire is unchanged, the hook refuses
# every Fable form unless allow-tasks lists the session's JG_TASK_ID, `allowed` answers from that same list, and unwiring
# removes only the guard's keys and executable while allow-tasks stays. No claude process is started.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
export HOME=$T/home XDG_DATA_HOME=$T/share
unset CLAUDE_CONFIG_DIR ANTHROPIC_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL JG_TASK_ID
mkdir -p "$HOME/.claude"
S=$HOME/.claude/settings.json
echo '{"theme":"dark","env":{"KEEP_ME":"1","FAKE_SECRET":"sk-do-not-print-0000","ANTHROPIC_DEFAULT_SONNET_MODEL":"claude-haiku-5-5"},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"other-hook"}]}]}}' >"$S"
G=$(bash "$here/wiring.sh" --where)
fail=0
ok() { echo "ok: $*"; }
no() { echo "FAIL: $*"; fail=1; }

before=$(sha256sum <"$S")
out=$(bash "$here/wiring.sh")
if [[ $out == "not installed: "* ]] && [ ! -e "$G" ] && [ "$before" = "$(sha256sum <"$S")" ]; then
  ok "a host with no guard is left alone"
else
  no "wiring started a ban nobody installed: $out"
fi
bash "$here/wiring.sh" --install --dry-run >"$T/dry.out"
if [ ! -e "$G" ] && [ "$before" = "$(sha256sum <"$S")" ]; then ok "dry run writes nothing"; else no "dry run wrote"; fi
bash "$here/wiring.sh" --install >"$T/install.out" && bash "$here/wiring.sh" >"$T/rewire.out"
if cat "$T/dry.out" "$T/install.out" "$T/rewire.out" | grep -q 'sk-do-not-print\|KEEP_ME\|theme'; then
  no "wiring printed other settings"
else
  ok "wiring prints only its own keys"
fi
if grep -q '^unchanged: ' "$T/rewire.out"; then ok "a rewire changes nothing"; else no "rewire not idempotent"; fi
if jq -e '.theme == "dark" and .env.KEEP_ME == "1" and .env.FAKE_SECRET == "sk-do-not-print-0000"
  and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == null and .env.ANTHROPIC_DEFAULT_FABLE_MODEL == "claude-haiku-5-5"
  and ([.hooks.UserPromptSubmit[].hooks[].command] | . == ["other-hook", $g])
  and .hooks.PreToolUse[0].matcher == "Agent|Task"' --arg g "$G" "$S" >/dev/null; then
  ok "fable key and hooks set, stale sonnet mapping cleared, other settings kept"
else
  no "settings content"
fi
if cmp -s "$here/refuse-model.sh" "$G"; then ok "hook installed"; else no "hook not installed"; fi

# hook <expected exit> <label> [env...]: run the installed hook on an Agent call's input.
hook() {
  local want=$1 label=$2 rc
  shift 2
  env "$@" "$G" <<<'{"tool_input":{"model":"claude-fable-5-1"}}' 2>/dev/null
  rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$label"; else no "$label (exit $rc, want $want)"; fi
}
hook 2 "Fable Agent call refused with no allow-tasks"
printf '# research\nfable-*\n\nautopilot-fable-plan' >"${G%/*}/allow-tasks"
hook 0 "a fable-* task runs Fable" JG_TASK_ID=fable-why-no-landing
hook 0 "an exact listed task runs Fable" JG_TASK_ID=autopilot-fable-plan
hook 2 "an unlisted task is refused" JG_TASK_ID=fric-pulse-fable-allow
hook 2 "ANTHROPIC_MODEL=claude-fable-5-1 refused for an unlisted task" JG_TASK_ID=other ANTHROPIC_MODEL=claude-fable-5-1
if env "$G" <<<'{"tool_input":{"model":"claude-sonnet-5-5"}}'; then ok "Sonnet Agent call allowed"; else no "Sonnet refused"; fi
if "$G" allowed fable-x; then ok "allowed: prefix entry"; else no "allowed: prefix entry"; fi
if "$G" allowed autopilot-fable-plan; then ok "allowed: last line with no newline"; else no "allowed: last line"; fi
if "$G" allowed fric-other; [ $? -eq 1 ]; then ok "allowed: unlisted is 1"; else no "allowed: unlisted"; fi
if "$G" allowed ''; [ $? -eq 1 ]; then ok "allowed: empty id is 1"; else no "allowed: empty id"; fi
if "$G" allowed 2>/dev/null; [ $? -eq 2 ]; then ok "allowed: missing id is a usage error"; else no "allowed: usage"; fi

bash "$here/unwiring.sh" >/dev/null
if jq -e '.env.ANTHROPIC_DEFAULT_FABLE_MODEL == null and .env.KEEP_ME == "1" and .theme == "dark"
  and ([.hooks.UserPromptSubmit[].hooks[].command] == ["other-hook"]) and ([.hooks.PreToolUse[]?.hooks[]?.command] | length == 0)' "$S" >/dev/null; then
  ok "unwiring removes only its keys"
else
  no "unwiring settings"
fi
if [ ! -e "$G" ] && [ -f "${G%/*}/allow-tasks" ]; then ok "unwiring removes the hook and keeps allow-tasks"; else no "unwiring files"; fi
before=$(sha256sum <"$S")
bash "$here/unwiring.sh" >/dev/null
if [ "$before" = "$(sha256sum <"$S")" ]; then ok "a second unwiring changes nothing"; else no "unwiring not idempotent"; fi

[ "$fail" -eq 0 ] || { echo FAIL; exit 1; }
echo PASS claude-model-guard
