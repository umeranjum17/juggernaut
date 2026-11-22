#!/usr/bin/env bash
# Drive discovery into round one on the helpdesk skeleton, with simulated worker output.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

t=$(jg_test_tmproot jg-muster-discover)
export JG_HOME=$t/home JG_DATA_OVERRIDE=$t/home/data JG_STATE_OVERRIDE=$t/home/state
export JG_PROJECTS_OVERRIDE=$t/home/projects JG_CONFIG_OVERRIDE=$t/home/config
export HOME=$t/user TMPDIR=$t/tmp SIGN_OFF_HOME=$t/board SIGN_OFF_FILER=muster-test
export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config
export JG_WAR_ROOM_SPAWN=$t/spawn JG_WAR_ROOM_NEXT=0 JG_CAPTAIN_CHANNEL=$t/channel-off
unset JG_ROOT_OVERRIDE JG_TASK_ID
project=$JG_PROJECTS_OVERRIDE/helpdesk
mkdir -p "$project" "$HOME" "$TMPDIR" "$SIGN_OFF_HOME/.sign-off"
printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"
jg_test_spawn_home "$JG_HOME"
jg_git_identity
cp -R "$ROOT/tests/fixtures/muster/example/skeleton/." "$project/"
git -C "$project" init -qb main
git -C "$project" add -A
git -C "$project" commit -qm skeleton
cat > "$JG_WAR_ROOM_SPAWN" <<'SPAWN'
#!/usr/bin/env bash
printf 'task=%s\n' "$1" > "$JG_STATE_OVERRIDE/$1.meta"
SPAWN
chmod +x "$JG_WAR_ROOM_SPAWN"

jg() { "$ROOT/bin/jg" "$@"; }
plain() {
  local out rc=0
  out=$(jg "$@") || rc=$?
  jq -r '.data.stdout // "", .data.error // empty' <<<"$out"
  return "$rc"
}
next() { plain plan war-room next "$discovery_ticket"; }
handoff() { "$ROOT/bin/jg-recon-handoff.sh" "$@"; }

discovery_ticket=$(jg ticket add 'Start a help desk bot' --why 'Keep support available after a restart.' --repo helpdesk --kind ship | jq -er .data.task)
muster=$JG_DATA_OVERRIDE/$discovery_ticket/muster
profile=(--project helpdesk --harness codex --model gpt-5.5 --effort high)
plain muster discover "$discovery_ticket" "${profile[@]}"
assert_contains "$(plain muster status "$discovery_ticket")" 'discover' 'Muster reports discovery before the first round'
refusal=$(plain muster round "$discovery_ticket" 2>&1) && fail 'an unreviewed round opened'
assert_contains "$refusal" 'discovery is still in progress' 'round waits for discovery'
while IFS=$'\t' read -r lens task; do
  case $lens in
    prior-art) finding='A public help site can supply articles.' ;;
    risks) finding='A restart can lose an open conversation.' ;;
    domain) finding='Conversation is the object an agent hands off.' ;;
    *) fail "unexpected discovery lens $lens" ;;
  esac
  printf '# %s\n\n%s\n' "$lens" "$finding" > "$JG_DATA_OVERRIDE/$task/report.md"
  handoff draft "$task"
done < "$JG_DATA_OVERRIDE/war-room/$discovery_ticket/lanes"
out=$(next)
task=$(sed -n 's/^discovery: \([^ ]*\) started$/\1/p' <<<"$out")
[ -n "$task" ] || fail "no discovery synthesis started: $out"
dir=$JG_DATA_OVERRIDE/$task
for n in {1..4}; do
  for kind in code docs upstream oss run; do
    printf '{"id":"S-%s-%s","kind":"%s"}\n' "$kind" "$n" "$kind"
  done
done > "$dir/sources.jsonl"
printf '%s\n' '{"id":"C-1","text":"Restart can lose an open conversation","sources":["S-code-1","S-run-1"],"load_bearing":true}' > "$dir/claims.jsonl"
printf '%s\n' '{"claim":"C-1","status":"verified","method":"run"}' > "$dir/checks.jsonl"
{
  printf '# Discovery for %s\n' "$task"
  n=0
  for section in Answer 'What was asked' 'Method and depth record' 'Prior art and options' Findings Design 'Not checked' 'Implementation plan' 'Risks and mitigations' 'Open decisions' 'Acceptance test' 'Sources and evidence' 'Revision log'; do
    n=$((n + 1))
    printf '\n## %s. %s\n\nAn open conversation disappears on restart [C-1].\n' "$n" "$section"
    if [ "$n" = 10 ]; then
      printf '\n### First round\n\n%s\n' '```json'
      jq '.[1:2] | .[0].why = "Discovery found the bot can answer from bundled pages after a restart."' "$ROOT/tests/fixtures/muster-acceptance/questions.json"
      printf '%s\n' '```'
    fi
  done
} > "$dir/report.md"
handoff draft "$task"
out=$(next)
critic=$(handoff assignee "$task" | cut -f1)
[ -n "$critic" ] && [ "$critic" != none ] && [ "$critic" != "$task" ] || fail "no separate critic assigned: $out"
assert_absent "$muster/discovery/findings.md" 'an assigned draft is not pack input'
handoff verdict "$task" --critic "$critic" --hash "$(sha256sum "$dir/report.md" | cut -d' ' -f1)" --gaps 0
assert_contains "$(next)" 'discovery ready' 'reviewed findings are published'
cmp "$dir/report.md" "$muster/discovery/findings.md"
assert_contains "$(plain muster round "$discovery_ticket")" 'round 1 shown: 1 questions' 'discovery seeds round 1'
assert_contains "$("$ROOT/bin/jg-backlog.sh" questions --ticket "$discovery_ticket" --all --json)" 'Where should the help pages live?' 'owner gate uses the discovery question'
assert_contains "$(cat "$SIGN_OFF_HOME/.sign-off/decisions.json")" 'Discovery found the bot can answer from bundled pages after a restart.' 'card explains the finding'
assert_contains "$(next)" 'discovery ready' 'advance is repeatable'
assert_contains "$(plain muster round "$discovery_ticket")" 'already shown' 'the round is presented once'
pass 'reviewed discovery from the helpdesk fixture feeds the first Muster round'
