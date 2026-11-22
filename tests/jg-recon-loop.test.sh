#!/usr/bin/env bash
# A deep Recon's writer/critic loop advances by itself (jg-sws): replay of the jg-6si loop, two critics, three rounds with gaps, then the closure,
# with no Main action between its steps and one final outcome. Everything is real except the terminal, the worktree tool and the workers' minds:
# the real delivery tick (bin/jg-delivery-tick.sh) runs core/recon-loop; the loop drives the real bin/jg-recon-handoff.sh, bin/jg-recon-gate.sh,
# bin/jg-recon-critic.sh (a real ticket, brief and spawn for each critic, bin/jg-backlog.sh, bin/jg-brief.sh, bin/jg-spawn.sh), core/next-step and
# core/recon-ready over a fixture project and a Beads store. Stand-ins: the critic's spawn command (it records the profile it was asked for, then
# starts the lane on a harness the fake terminal can launch), the send and relaunch commands (they write the lane's real steering inbox), and the
# researcher and the critic, which are shell functions that read their inbox, change the files a worker changes and append their done line.
#
# T1 replay      researcher done -> critic started and named -> round sent -> critic round (written by hand: the loop records it) with gaps -> gaps sent
#                to the researcher -> revision (recorded by the researcher, then by the loop) -> the same critic, relaunched because its agent is gone ->
#                gaps -> the critic's lane is gone, a second critic starts -> gaps -> closure -> gate PASS -> the one announcement. The test makes no move of its
#                own: it ticks, plays the workers and reads. No wake for Main before the end, no relay move, nothing announced before the gate passes.
# T2 profile     the critic is started on agy / gemini-4-neon-high by default; config/tool-models.json (tool `recon-critic`) changes it; a task's own
#                profile (data/<recon>/critic-profile) wins over both.
# T3 cap         a fourth round with gaps is a stop: one wake for Main naming the cap, the researcher is not told, a second pass adds no second wake.
# T4 refusal     a gate refusal at closure, a critic that will not start, a researcher that reports done over an unchanged draft: each one wake for Main; the
#                loop goes on by itself when the cause is gone.
# T5 war room    a lane of a war room gets no critic from the loop (the war room starts it).
# T6 stall       a draft that is ready and untouched for 10 minutes raises the done-unhandled P1 (core/next-step); acknowledging it closes nothing, the loop's move does.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-recon-loop)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$HOME_DIR/projects/proj"; STATE="$HOME_DIR/state"; DATA="$HOME_DIR/data"
mkdir -p "$W" "$HOME_DIR/projects" "$W/agents"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
FAKEBIN=$(make_spawn_fakebin "$W/fake")
jg_test_fake_sleep_noop "$FAKEBIN"
jg_test_spawn_home "$HOME_DIR"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
mkdir -p "$HOME_DIR/user-home"

# The critic's spawn command: it notes the profile it was asked for, then starts the lane through the real spawn on codex (the fake terminal knows
# that launch; the agy launch itself is verified live, docs/verification/agy.md). SPAWN_FAIL=<file> makes it fail instead.
SPAWN_WRAP="$W/spawn-wrap.sh"
cat > "$SPAWN_WRAP" <<WRAP
#!/usr/bin/env bash
task=\$1; proj=\$2; shift 2
printf '%s\n' "\$*" >> "$W/spawn-calls.\$task"
[ ! -e "$W/spawn-fail" ] || { echo "spawn refused: no agy on this host" >&2; exit 1; }
args=()
while [ "\$#" -gt 0 ]; do
  case "\$1" in --harness|--model|--effort) shift 2 ;; *) args+=("\$1"); shift ;; esac
done
wt="$W/wt-\$task"
until mkdir "$W/wt.lock" 2>/dev/null; do /bin/sleep 0.1; done
git -C "$PROJ" worktree add -q --detach "\$wt" origin/main >/dev/null 2>&1
rmdir "$W/wt.lock"
JG_ROOT_OVERRIDE='' JG_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
  XDG_DATA_HOME="$HOME_DIR/user-home/.local/share" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$DATA" \
  JG_PROJECTS_OVERRIDE="$HOME_DIR/projects" JG_CONFIG_OVERRIDE="$HOME_DIR/config" JG_SPAWN_NO_GUARD=1 \
  JG_FAKE_PANE_PATH="\$wt" TMUX=fake,1,0 PATH="$FAKEBIN:\$PATH" \
  exec "$ROOT/bin/jg-spawn.sh" "\$task" "\$proj" "\${args[@]}" --harness codex --model gpt-5.5 --effort high
WRAP
cat > "$W/send.sh" <<SEND
#!/usr/bin/env bash
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$ROOT/bin/jg-task-inbox-lib.sh"
jg_task_inbox_write "$STATE" "\$1" "\$2" > /dev/null && printf '%s\n' "\$1" >> "$W/sends.log"
SEND
cat > "$W/control.sh" <<CONTROL
#!/usr/bin/env bash
# relaunch <note>: the agent is back, and its first message is the note
. "$ROOT/bin/jg-task-inbox-lib.sh"
[ "\$2" = relaunch ] && [ "\$3" = --note-file ] || exit 2
jg_task_inbox_write "$STATE" "\$1" "\$(cat "\$4")" > /dev/null && printf '%s\n' "\$1" >> "$W/relaunches.log" && echo alive > "$W/agents/\$1"
CONTROL
cat > "$W/agent.sh" <<AGENT
#!/usr/bin/env bash
cat "$W/agents/\$1" 2>/dev/null || echo alive
AGENT
chmod +x "$SPAWN_WRAP" "$W/send.sh" "$W/control.sh" "$W/agent.sh"

export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$DATA" JG_CONFIG_OVERRIDE="$HOME_DIR/config" JG_PROJECTS_OVERRIDE="$HOME_DIR/projects"
export JG_RECON_CRITIC_SPAWN="$SPAWN_WRAP" JG_RECON_LOOP_SEND="$W/send.sh" JG_RECON_LOOP_CONTROL="$W/control.sh" JG_RECON_LOOP_AGENT="$W/agent.sh"
export JG_WAR_ROOM_NEXT=0 JG_STATUS_KICK=0

RH="$ROOT/bin/jg-recon-handoff.sh"; GATE="$ROOT/bin/jg-recon-gate.sh"
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$HOME_DIR" > "$W/tick.out" 2> "$W/tick.err" || fail "the delivery tick failed: $(tail -3 "$W/tick.err")"; }
ready() { JG_RECON_READY_GATE="$GATE" bash "$ROOT/core/recon-ready/ready.sh" check "$HOME_DIR"; }
phase() { bash "$RH" phase "$1"; }
sha() { sha256sum "$DATA/$1/report.md" | cut -d' ' -f1; }
say() { printf '%s [at=%s]: %s\n' "$2" "$(date +%s)" "$3" >> "$STATE/$1.status"; }
sec() { /bin/sleep 1; }   # the loop compares whole seconds: a worker's line is always a second after the move it answers
wakes() { grep -c "recon-loop-$1" "$STATE/.wake-queue" 2>/dev/null || true; }
wait_for() {  # <what> <file>: a detached spawn is done when its task record exists
  local n=0
  until [ -f "$2" ]; do /bin/sleep 0.5; n=$((n + 1)); [ "$n" -lt 240 ] || fail "waited 120 s for $1"; done
}
inbox_next() {  # <lane>: the oldest unread steer, acknowledged (the worker's mv into handled/); fails when there is none
  local f; f=$(find "$STATE/$1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | sort | head -n 1)
  [ -n "$f" ] || return 1
  cat "$f"; mv "$f" "$STATE/$1.inbox/handled/"
}
critic_of() { sed -n 's/^Critic:[[:space:]]*//p' "$DATA/$1/critic.md" | head -n 1; }

# A real deep Recon lane: a ticket, the real deep scaffold, the real spawn, the files the method writes, and the researcher's done line.
make_recon() {  # <task id> <title>
  local id=$1 d=$DATA/$1 n title kinds=(code docs upstream oss community run)
  jg_test_add "$HOME_DIR" "$id" "$2"
  bash "$ROOT/bin/jg-brief.sh" "$id" proj --scout --depth deep --ticket "$id" > /dev/null 2>&1 || fail "jg-brief.sh could not scaffold $id"
  sed -i 's/^{TASK}$/Replay the loop./; s/^{JUGGERNAUT_SPEC}$/Write the report./' "$d/brief.md"
  "$SPAWN_WRAP" "$id" "$PROJ" --ticket "$id" --scout --harness codex --model gpt-5.5 --effort high > "$W/spawn-$id.log" 2>&1 || fail "could not spawn $id: $(tail -3 "$W/spawn-$id.log")"
  : > "$d/sources.jsonl"
  for n in $(seq 1 20); do printf '{"id":"S-%d","kind":"%s","title":"source %d","link":"x/%d","read":"2026-11-05"}\n' "$n" "${kinds[$((n % 5))]}" "$n" "$n" >> "$d/sources.jsonl"; done
  printf '%s\n' '{"id":"C-1","text":"first claim","kind":"fact","sources":["S-1","S-2"],"load_bearing":true}' > "$d/claims.jsonl"
  printf '%s\n' '{"claim":"C-1","status":"verified","method":"run","note":"re-measured"}' > "$d/checks.jsonl"
  {
    printf '# Report for %s\n\nAnswer first.\n\n' "$id"; n=1
    for title in "Answer" "What was asked" "Method and depth record" "Prior art and options" "Findings" "Design" "Not checked" \
      "Implementation plan" "Risks and mitigations" "Open decisions" "Acceptance test" "Sources and evidence" "Revision log"; do
      printf '## %d. %s\n' "$n" "$title"
      if [ "$title" = "Not checked" ]; then printf 'Nothing load-bearing is left unchecked.\n\n'; else printf 'Body of %s, citing [C-1].\n\n' "$title"; fi
      n=$((n + 1))
    done
  } > "$d/report.md"
  say "$id" "done" "draft ready for the separate critic"
}
researcher_turn() {  # <recon> <records the revision itself: yes|no>: read the steer, fix the gaps, say done
  local msg; msg=$(inbox_next "$1") || fail "$1 has no steer to read"
  assert_contains "$msg" "found new gaps" "the researcher is told the critic's gaps"
  assert_contains "$msg" "- gap " "the researcher is given the open gaps themselves"
  printf '\nRevision %s: closed the gaps.\n' "$(date +%s%N)" >> "$DATA/$1/report.md"
  [ "$2" != yes ] || bash "$RH" revise "$1" > /dev/null || fail "the researcher could not record its revision"
  say "$1" "done" "draft ready for the separate critic"
}
critic_turn() {  # <critic> <recon> <gaps> <how: round|closure>: read the steer, write the round by hand (never the verdict command), say done
  local msg h k n; msg=$(inbox_next "$1") || fail "$1 has no steer to read"
  h=$(sha "$2")
  assert_contains "$msg" "$h" "the critic is told the exact draft to read"
  assert_contains "$msg" "closure" "the critic is told the closure rule"
  if [ "$4" = closure ]; then
    printf 'Closure check: %s closed by %s report %s\n' "$LAST_GAPS" "$1" "$h" >> "$DATA/$1/critic.md"
  else
    k=$(( $(grep -c '^Round' "$DATA/$1/critic.md") + 1 ))
    { printf 'Round %s: new gaps %s report %s\n' "$k" "$3" "$h"
      for n in $(seq 1 "$3"); do printf -- '- gap %s of the draft %s\n' "$n" "${h:0:8}"; done; } >> "$DATA/$1/critic.md"
    LAST_GAPS=$3
  fi
  say "$1" "done" "round recorded"
}

# --- T1: the replay --------------------------------------------------------------------------------------------------------
R=jg-lp1
make_recon "$R" "Loop replay Recon"
assert_equals none "$(phase "$R")" "T1 a fresh Recon has no handoff record"
assert_contains "$(bash "$GATE" "$R" --step 2>&1)" "STEP critic" "T1 the replay is not vacuous: only the critic is open"
sec
tick
assert_equals assigned "$(phase "$R")" "T1 the researcher's done line started the loop: the draft is recorded and a critic holds it"
C1=$(bash "$RH" assignee "$R" | cut -f1)
[ -n "$C1" ] && [ "$C1" != none ] || fail "T1 no critic was named"
[ "$(jq -r '.[]?.id' < <(JG_HOME="$HOME_DIR" python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" list --parent "$R" --all --limit 0 --json 2>/dev/null) | wc -l | tr -d ' ')" = 1 ] \
  || fail "T1 the Recon's ticket should have exactly one critic child"
wait_for "the critic $C1" "$STATE/$C1.meta"
# The critic's default profile: agy with gemini-4-neon-high (T2 covers the other sources).
assert_contains "$(cat "$W/spawn-calls.$C1")" "--harness agy --model gemini-4-neon-high" "T1 the critic is started on the default profile"
sec
tick
[ -n "$(find "$STATE/$C1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null)" ] || fail "T1 the critic was not sent its round"
assert_equals "" "$(ready)" "T1 nothing is announced while the critic is open"
pass "T1 the researcher's done line starts the critic by itself: draft recorded, critic started on agy/gemini-4-neon-high, named, and sent the round"

# Round 1 (critic C1, 3 gaps): the critic wrote its round by hand; the loop records it and sends the researcher the gaps.
sec; critic_turn "$C1" "$R" 3 round
tick
assert_equals critiqued "$(phase "$R")" "T1 the loop recorded the critic's hand-written round"
assert_contains "$(cat "$DATA/$R/critic.md")" "Round 1: new gaps 3 report $(sha "$R")" "T1 critic.md was installed in the Recon with the round"
assert_contains "$(cat "$DATA/$R/critic.md")" "- gap 3 of the draft" "T1 the critic's gaps were installed with it"
assert_equals "$(grep -c '^Round' "$DATA/$C1/critic.md")" 1 "T1 the round was counted once in the critic's own file"
[ -n "$(find "$STATE/$R.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null)" ] || fail "T1 the researcher was not sent the gaps"
assert_equals "" "$(ready)" "T1 nothing is announced after a round with gaps"
JG_STATE_OVERRIDE="$STATE" bash -c '. "$1/bin/jg-facts-lib.sh"; jg_fact_next_step "$2" "$3" "$4"' _ "$ROOT" "$STATE" "$DATA" "$R" | grep -q $'^step\trevise' || fail "T1 the revision should be owed while the steer is unread"
sec; researcher_turn "$R" yes
sec
echo dead > "$W/agents/$C1"      # the critic's agent ended with its done line
tick
assert_equals assigned "$(phase "$R")" "T1 the revision was recorded and the same critic holds the new draft"
assert_contains "$(cat "$W/relaunches.log")" "$C1" "T1 the same critic was relaunched with the round as its note"
pass "T1 round 1: the loop records a hand-written round, sends the gaps, and relaunches the same critic on the new draft"

# Round 2 (critic C1, 2 gaps): the researcher forgets to record its revision, and the loop does.
sec; critic_turn "$C1" "$R" 2 round
tick
assert_equals critiqued "$(phase "$R")" "T1 round 2 recorded"
sec; researcher_turn "$R" no
sec
rm -f "$STATE/$C1.meta"          # the first critic's lane is gone (cleaned up, or its host lost)
tick
assert_equals assigned "$(phase "$R")" "T1 the loop recorded the researcher's revision itself and named a critic again"
C2=$(bash "$RH" assignee "$R" | cut -f1)
[ "$C2" != "$C1" ] && [ -n "$C2" ] || fail "T1 a second critic should hold the draft, got $C2"
assert_contains "$(grep -c "$(printf '\trevise\t')" "$DATA/$R/handoff.tsv")" 2 "T1 two revisions are recorded"
wait_for "the second critic $C2" "$STATE/$C2.meta"
sec; tick
[ -n "$(find "$STATE/$C2.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null)" ] || fail "T1 the second critic was not sent its round"
pass "T1 round 2: the loop records the researcher's revision itself, and a second critic starts when the first one's lane is gone"

# Round 3 (critic C2, 1 gap), then the closure.
sec; critic_turn "$C2" "$R" 1 round
tick
assert_equals critiqued "$(phase "$R")" "T1 round 3 recorded"
sec; researcher_turn "$R" yes
sec; tick
assert_equals assigned "$(phase "$R")" "T1 the revision of round 3 is with the second critic"
assert_equals "" "$(ready)" "T1 nothing is announced before the closure"
sec; critic_turn "$C2" "$R" 0 closure
tick
assert_equals accepted "$(phase "$R")" "T1 the closure was recorded: the draft is accepted"
out=$(bash "$GATE" "$R" 2>&1) || fail "T1 the gate must pass at the closure: $out"
assert_contains "$out" PASS "T1 the gate passes"
tick
out=$(ready); assert_contains "$out" "recon-ready: $R report is ready" "T1 the final outcome is announced once the gate passes"
assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "T1 exactly one outcome"
assert_equals "" "$(ready)" "T1 the outcome is not announced twice"
assert_equals 0 "$(wakes "$R")" "T1 Main was never woken by the loop"
[ ! -s "$DATA/moves.log" ] || ! grep -q relayed "$DATA/moves.log" || fail "T1 the loop relayed the report"
assert_equals 3 "$(grep -c "$(printf '\tgaps\t')" "$DATA/$R/handoff.tsv")" "T1 three rounds found gaps"
assert_equals "" "$(ls "$STATE/.wake-queue" >/dev/null 2>&1 && grep -c 'recon-loop' "$STATE/.wake-queue" | grep -v '^0$')" "T1 no stop wake in the queue"
pass "T1 the replay: two critics, three rounds with gaps, then the closure; no Main action, the gate passed, and one final outcome"

# --- T2: the critic's profile ----------------------------------------------------------------------------------------------------
R2=jg-lp2
make_recon "$R2" "Profile replay Recon"
printf '{"rules":[{"tool":"recon-critic","when":"The critic of a deep Recon.","use":{"harness":"claude","model":"claude-opus-5-5","effort":"high"}}]}\n' > "$HOME_DIR/config/tool-models.json"
assert_equals "$(printf 'config\tclaude claude-opus-5-5 high')" "$("$ROOT/bin/jg-recon-critic.sh" profile "$R2")" "T2 config/tool-models.json sets the critic's profile"
"$ROOT/bin/jg-recon-critic.sh" profile "$R2" codex gpt-5.5 medium > /dev/null
assert_equals "$(printf 'task\tcodex gpt-5.5 medium')" "$("$ROOT/bin/jg-recon-critic.sh" profile "$R2")" "T2 the task's own profile wins over the config"
sec; tick
C=$(bash "$RH" assignee "$R2" | cut -f1)
assert_contains "$(cat "$W/spawn-calls.$C")" "--harness codex --model gpt-5.5 --effort medium" "T2 the critic starts on the task's own profile"
rm -f "$DATA/$R2/critic-profile"
assert_equals "$(printf 'config\tclaude claude-opus-5-5 high')" "$("$ROOT/bin/jg-recon-critic.sh" profile "$R2")" "T2 without the task's file the config answers again"
rm -f "$HOME_DIR/config/tool-models.json"
assert_equals "$(printf 'default\tagy gemini-4-neon-high')" "$("$ROOT/bin/jg-recon-critic.sh" profile "$R2")" "T2 with neither, the default is agy gemini-4-neon-high"
pass "T2 the critic defaults to agy gemini-4-neon-high, config/tool-models.json (recon-critic) changes it, and the task's own profile wins"

# --- T3: the cap ------------------------------------------------------------------------------------------------------------------
R3=jg-lp3
make_recon "$R3" "Cap replay Recon"
mkdir -p "$DATA/cap-critic"
bash "$RH" draft "$R3" > /dev/null; bash "$RH" assign "$R3" --critic cap-critic > /dev/null
for round in 1 2 3 4; do
  bash "$RH" verdict "$R3" --critic cap-critic --hash "$(sha "$R3")" --gaps 1 > /dev/null || fail "T3 round $round"
  [ "$round" = 4 ] || { printf '\nfix %s\n' "$round" >> "$DATA/$R3/report.md"; bash "$RH" revise "$R3" > /dev/null; bash "$RH" assign "$R3" --critic cap-critic > /dev/null; }
done
out=$(bash "$GATE" "$R3" --step 2>&1); rc=$?
assert_equals 1 "$rc" "T3 a deep Recon past its 3 rounds is not in the step critic"
assert_contains "$out" "allows 3" "T3 the gate names the cap"
sec; tick
assert_equals 1 "$(wakes "$R3")" "T3 the cap is one wake for Main"
assert_contains "$(grep "recon-loop-$R3" "$STATE/.wake-queue")" "allows 3" "T3 the wake names the cap"
[ -z "$(find "$STATE/$R3.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null)" ] || fail "T3 the researcher was sent a fifth round"
tick; tick
assert_equals 1 "$(wakes "$R3")" "T3 a second pass adds no second wake"
pass "T3 the cap: a fourth round with gaps is one wake for Main, the researcher is not told, and the loop does not repeat the wake"

# --- T4: refusals -----------------------------------------------------------------------------------------------------------------
R4=jg-lp4
make_recon "$R4" "Refusal replay Recon"
mkdir -p "$DATA/ref-critic"
bash "$RH" draft "$R4" > /dev/null; bash "$RH" assign "$R4" --critic ref-critic > /dev/null; bash "$RH" verdict "$R4" --critic ref-critic --hash "$(sha "$R4")" --gaps 0 > /dev/null
cp "$DATA/$R4/report.md" "$W/report.keep"; grep -v '^## 6\. Design$' "$W/report.keep" > "$DATA/$R4/report.md"
sec; tick
assert_equals 1 "$(wakes "$R4")" "T4 a gate refusal at the closure is one wake for Main"
assert_contains "$(grep "recon-loop-$R4" "$STATE/.wake-queue")" "refuses" "T4 the wake says the gate refuses"
cp "$W/report.keep" "$DATA/$R4/report.md"; sec; tick
[ ! -e "$DATA/$R4/recon-loop/stopped" ] || fail "T4 the stop was not cleared when the gate passed again"
pass "T4 a gate refusal at the closure is one wake for Main, and the loop clears the stop by itself once the gate passes"

R5=jg-lp5
make_recon "$R5" "Spawn failure Recon"
: > "$W/spawn-fail"
sec; tick
n=0; until [ -f "$DATA/$R5/critic-1/spawn.rc" ]; do /bin/sleep 0.5; n=$((n + 1)); [ "$n" -lt 40 ] || fail "T4 first spawn did not finish"; done
sec; tick
assert_equals 1 "$(wakes "$R5")" "T4 the first failed critic start alerts Main"
for i in 2 3 4 5 6; do
  n=0; until [ -f "$DATA/$R5/critic-1/spawn.rc" ] || [ "$i" = 6 ]; do /bin/sleep 0.5; n=$((n + 1)); [ "$n" -lt 40 ] || break; done
  sec; tick
done
assert_equals 1 "$(wakes "$R5")" "T4 a critic that would not start in five tries is one wake for Main"
assert_contains "$(grep "recon-loop-$R5" "$STATE/.wake-queue")" "did not start" "T4 the wake says the critic did not start"
assert_contains "$(grep "recon-loop-$R5" "$STATE/.wake-queue")" "no agy on this host" "T4 and why"
rm -f "$W/spawn-fail"
pass "T4 a critic that will not start is one wake for Main with the spawn's own reason"

R6=jg-lp6
make_recon "$R6" "Unchanged draft Recon"
mkdir -p "$DATA/unch-critic"
bash "$RH" draft "$R6" > /dev/null; bash "$RH" assign "$R6" --critic unch-critic > /dev/null; bash "$RH" verdict "$R6" --critic unch-critic --hash "$(sha "$R6")" --gaps 1 > /dev/null
sec; tick                         # the gaps are sent
say "$R6" "done" "draft ready for the separate critic"   # the researcher says done and changed nothing
sec; tick
assert_equals 1 "$(wakes "$R6")" "T4 a researcher done over the unchanged draft is one wake for Main"
assert_contains "$(grep "recon-loop-$R6" "$STATE/.wake-queue")" "without changing report.md" "T4 the wake says what happened"
pass "T4 a done line over an unchanged critiqued draft is one wake for Main"

# --- T5: a war room's lane ------------------------------------------------------------------------------------------------------
mkdir -p "$DATA/war-room/jg-wr"; printf 'council=jg-wr\n' > "$DATA/war-room/jg-wr/record"
make_recon jg-wr-1 "War room lane Recon"
sec; tick
assert_equals drafted "$(phase jg-wr-1)" "T5 the loop recorded the war room lane's draft"
[ ! -d "$DATA/jg-wr-1/critic-1" ] || fail "T5 the loop started a critic for a war room's lane"
pass "T5 a war room's lane gets its draft recorded and no critic from the loop"

# --- T6: a stall is a P1 that only progress clears ---------------------------------------------------------------------------
R7=jg-lp7
make_recon "$R7" "Stalled loop Recon"
: > "$STATE/$R7.status"; say "$R7" working "researching"
printf 'done [at=%s]: draft ready for the separate critic\n' "$(( $(date +%s) - 700 ))" >> "$STATE/$R7.status"
bash "$ROOT/core/next-step/next-step.sh" tick "$HOME_DIR" || fail "T6 the next-step tick failed"
ALERT() { bash "$ROOT/bin/jg-alert.sh" "$@"; }
[ "$(ALERT word "done-unhandled--$R7")" = open ] || fail "T6 a ready draft untouched for 700 s raised no P1"
assert_contains "$(ALERT show "done-unhandled--$R7")" "assign owed by the Recon loop" "T6 the P1 names the loop's step"
ALERT ack "done-unhandled--$R7" > /dev/null
bash "$ROOT/core/next-step/next-step.sh" tick "$HOME_DIR"
[ "$(ALERT word "done-unhandled--$R7")" != resolved ] || fail "T6 an acknowledgement closed the P1"
sec; tick                          # the loop takes its move
bash "$ROOT/core/next-step/next-step.sh" tick "$HOME_DIR"
[ "$(ALERT word "done-unhandled--$R7")" = resolved ] || fail "T6 the loop's move did not close the P1"
pass "T6 a draft that is ready and untouched for 10 minutes raises the done-unhandled P1; an acknowledgement closes nothing and the loop's move does"

echo "# jg-recon-loop.test.sh: all assertions passed"
