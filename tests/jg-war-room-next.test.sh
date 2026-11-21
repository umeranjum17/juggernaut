#!/usr/bin/env bash
# A /war-room moves itself from its variants to the owner's plan approval, and the owner's one yes starts /blitz.
# Real bin/jg-war-room.sh, bin/jg-recon-handoff.sh, bin/jg-brief.sh, bin/jg-backlog.sh, bin/jg-captain-hold.sh and
# bin/jg-swarm-plan-check.sh over a fixture project and a Beads store. Stand-ins: the spawn (JG_WAR_ROOM_SPAWN: writes the lane's
# task record and notes each start), the Recon gate (JG_WAR_ROOM_GATE: passes a task whose name is a file in $W/gate-pass) and the
# swarm (JG_WAR_ROOM_SWARM: notes its arguments).
#
# T1 critic: a variant's draft (jg-recon-handoff.sh draft) starts `jg-war-room.sh next` by itself: within 5 s one critic child
#    exists, it was spawned once and the handoff's assignee names it. A second `next` adds nothing.
# T2 synthesis: with every variant past its gate, `next` files and starts one synthesis lane, once.
# T3 approval ask: with the synthesis past its gate, `next` files the dry run; once the dry run is done and the plan is good,
#    `next` holds the council with the must `plan-approval` once, and a second `next` holds nothing new.
# T4 approve: `approve` runs the swarm once with the plan path and the profile of the record; a second `approve` says already started.
# T5 off: JG_WAR_ROOM_NEXT=0 and a draft: no `next` runs.
# T6 fast: `start --depth standard --synthesis-depth deep --no-variant-critics`: a variant's draft files no critic; the variants
#    keep depth standard, the synthesis is briefed deep and still gets its own separate critic. A war room started with no flag keeps
#    the one depth for the synthesis (T2 checks it).
# T7 refusal: --no-variant-critics with --depth deep, or a synthesis depth that is not standard or deep, exits 2 and writes nothing.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-war-room-next)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$HOME_DIR/projects/proj"
mkdir -p "$W" "$HOME_DIR/projects" "$W/gate-pass"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true
jg_test_spawn_home "$HOME_DIR"

STARTS="$W/starts"; mkdir -p "$STARTS"
cat > "$W/spawn.sh" <<SPAWN
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STARTS/\$1"
printf 'task=%s\n' "\$1" > "$HOME_DIR/state/\$1.meta"
SPAWN
cat > "$W/gate.sh" <<GATE
#!/usr/bin/env bash
[ -e "$W/gate-pass/\$1" ]
GATE
cat > "$W/swarm.sh" <<SWARM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/swarm-calls"
SWARM
chmod +x "$W/spawn.sh" "$W/gate.sh" "$W/swarm.sh"

export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config"
export JG_PROJECTS_OVERRIDE="$HOME_DIR/projects" JG_WAR_ROOM_SPAWN="$W/spawn.sh" JG_WAR_ROOM_GATE="$W/gate.sh" JG_WAR_ROOM_SWARM="$W/swarm.sh"
export JG_WAR_ROOM_WAIT=30

war_room() { "$ROOT/bin/jg-war-room.sh" "$@" 2>&1; }
handoff() { "$ROOT/bin/jg-recon-handoff.sh" "$@" 2>&1; }
children() {  # <council> -> the ids of its children
  python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" list --parent "$1" --all --limit 0 --json 2>/dev/null | jq -r '.[]?.id' | sort
}
title_of() { jg_test_backlog "$HOME_DIR" show "$1" 2>&1 | sed -n 's/^  title: *//p' | head -1 | tr -d '"'; }
child_titled() {  # <council> <title> -> the child's id
  local id
  for id in $(children "$1"); do [ "$(title_of "$id")" = "$2" ] && { printf '%s\n' "$id"; return 0; }; done
  return 1
}
task_of() { printf '%s\n' "${1//./-}"; }
starts_of() { grep -c . "$STARTS/$1" 2>/dev/null || echo 0; }
questions_of() { jg_test_backlog "$HOME_DIR" questions --ticket "$1" --json 2>/dev/null | jq 'length' 2>/dev/null; }

# A council whose three variants are live: start writes its record.
new_council() {  # <id> [start flags...] -> sets V1 V2 V3 (the variant tasks)
  local id=$1; shift
  jg_test_add "$HOME_DIR" "$id" "[feature] War room council"
  "$ROOT/bin/jg-muster-depth.sh" record --ticket "$id" --depth skip --reason "fixture startup" >/dev/null || fail "record skip"
  local out
  out=$(war_room start "$id" --project proj --angles alpha,bravo,gamma --depth standard --harness codex --model gpt-5.5 --effort high "$@") \
    || fail "$id: start should make three lanes live: $out"
  [ -s "$HOME_DIR/data/war-room/$id/record" ] || fail "$id: start should write data/war-room/$id/record"
  V1=$(task_of "$(child_titled "$id" 'alpha variant Recon')"); V2=$(task_of "$(child_titled "$id" 'bravo variant Recon')")
  V3=$(task_of "$(child_titled "$id" 'gamma variant Recon')")
}

# T1: a draft starts next; the critic is filed, started once and assigned.
council=jg-wna
new_council "$council"
printf '# Report of %s\n' "$V1" > "$HOME_DIR/data/$V1/report.md"
before=$(children "$council" | grep -c .)
out=$(handoff draft "$V1") || fail "T1 the draft should be recorded: $out"
critic=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  critic=$(child_titled "$council" 'alpha variant Recon critic' || true)
  [ -n "$critic" ] && [ "$(handoff assignee "$V1" | cut -f1)" = "$(task_of "${critic:-none}")" ] && break
  /bin/sleep 0.5
done
[ -n "$critic" ] || fail "T1 no critic child within 5 s of the draft"
ctask=$(task_of "$critic")
[ "$(children "$council" | grep -c .)" = $((before + 1)) ] || fail "T1 exactly one critic child should exist"
[ "$(handoff assignee "$V1" | cut -f1)" = "$ctask" ] || fail "T1 the assignee of $V1 should be $ctask: $(handoff assignee "$V1")"
[ "$(starts_of "$ctask")" = 1 ] || fail "T1 the critic should be spawned once, was $(starts_of "$ctask")"
grep -q "jg-recon-handoff.sh verdict $V1 --critic $ctask" "$HOME_DIR/data/$ctask/brief.md" || fail "T1 the critic's brief lacks its verdict command"
out=$(war_room next "$council") || fail "T1 a second next should exit 0: $out"
[ "$(children "$council" | grep -c .)" = $((before + 1)) ] || fail "T1 a second next filed a ticket"
[ "$(starts_of "$ctask")" = 1 ] || fail "T1 a second next spawned the critic again"
[ "$(handoff assignee "$V1" | cut -f1)" = "$ctask" ] || fail "T1 a second next changed the assignee"
pass "T1 a draft starts next: one critic filed, started once and assigned; a second next adds nothing"

# T2: every variant past its gate, the synthesis starts once.
for v in "$V1" "$V2" "$V3"; do : > "$W/gate-pass/$v"; done
out=$(war_room next "$council") || fail "T2 next should exit 0: $out"
synth=$(child_titled "$council" 'synthesis Recon') || fail "T2 no synthesis ticket after next: $out"
stask=$(task_of "$synth")
[ "$(starts_of "$stask")" = 1 ] || fail "T2 the synthesis should be spawned once, was $(starts_of "$stask")"
for v in "$V1" "$V2" "$V3"; do
  grep -q "$HOME_DIR/data/$v/report.md" "$HOME_DIR/data/$stask/brief.md" || fail "T2 the synthesis brief lacks the report path of $v"
done
grep -qx 'Recon depth: standard' "$HOME_DIR/data/$stask/brief.md" || fail "T2 a council with no depth flag should brief the synthesis at the variants' depth"
grep -q 'strike-recon' "$HOME_DIR/data/$stask/brief.md" || fail "T2 the synthesis brief lacks strike-recon"
grep -q "$stask/orders/plan.json" "$HOME_DIR/data/$stask/brief.md" || fail "T2 the synthesis brief lacks its plan path"
war_room next "$council" > /dev/null || fail "T2 a second next should exit 0"
[ "$(starts_of "$stask")" = 1 ] || fail "T2 a second next spawned the synthesis again"
n=0; for id in $(children "$council"); do [ "$(title_of "$id")" = 'synthesis Recon' ] && n=$((n + 1)); done
[ "$n" = 1 ] || fail "T2 one synthesis ticket expected, found $n"
pass "T2 every variant past its gate: one synthesis lane, filed and started once"

# T3: the synthesis past its gate, the dry run is started; done with a good plan, the council is held once.
: > "$W/gate-pass/$stask"
out=$(war_room next "$council") || fail "T3 next should exit 0: $out"
dry=$(child_titled "$council" 'dry run of order 1') || fail "T3 no dry-run ticket after next: $out"
dtask=$(task_of "$dry")
[ "$(starts_of "$dtask")" = 1 ] || fail "T3 the dry run should be spawned once, was $(starts_of "$dtask")"
[ "$(questions_of "$council")" = 0 ] || fail "T3 the council is held before the dry run is done"
out=$(war_room next "$council"); assert_contains "$out" "waits: $dtask" "T3 next should say it waits for the dry run: $out"
plan_dir="$HOME_DIR/data/$stask/orders"; mkdir -p "$plan_dir"
printf 'order\n' > "$plan_dir/a.md"; printf 'order\n' > "$plan_dir/b.md"
jq -n '{plan: "jg-wna-plan", title: "Run the probe plan", report: "/tmp/report.md", intent: "Run the probe.",
        prior_art: "Prior art: none needed - a plain check",
        slices: [{id: "a", title: "Make part a of it", owner_home: "main", project: "proj", size: "S", risk: "Low", depends_on: [],
                  files: ["bin/a.sh (new)"], machine: null, order: "a.md", owner_word: null, gate: null},
                 {id: "b", title: "Make part b of it", owner_home: "main", project: "proj", size: "S", risk: "Low", depends_on: ["a"],
                  files: ["bin/b.sh (new)"], machine: null, order: "b.md", owner_word: null, gate: null}]}' > "$plan_dir/plan.json"
printf 'done [at=1]: dry run finished\n' > "$HOME_DIR/state/$dtask.status"
out=$(war_room next "$council") || fail "T3 next should exit 0: $out"
assert_contains "$out" "owner approval asked" "T3 next should ask the owner: $out"
[ "$(questions_of "$council")" = 1 ] || fail "T3 the council should hold one question, holds $(questions_of "$council")"
jg_test_backlog "$HOME_DIR" questions --ticket "$council" --json | grep -q 'plan-approval' || fail "T3 the question lacks the must plan-approval"
jg_test_backlog "$HOME_DIR" questions --ticket "$council" --json | grep -q "$plan_dir/plan.json" || fail "T3 the question lacks the plan path"
out=$(war_room next "$council") || fail "T3 a second next should exit 0: $out"
case $out in *"owner approval asked"*) fail "T3 a second next asked again: $out" ;; esac
[ "$(questions_of "$council")" = 1 ] || fail "T3 a second next held again"
pass "T3 the dry run starts after the synthesis; a done dry run and a good plan hold the council once, with plan-approval"

# T4: approve starts the swarm once.
out=$(war_room approve "$council" --words "yes, go ahead") || fail "T4 approve should exit 0: $out"
[ "$(grep -c . "$W/swarm-calls")" = 1 ] || fail "T4 the swarm should run once: $(cat "$W/swarm-calls")"
assert_contains "$(cat "$W/swarm-calls")" "start $plan_dir/plan.json --harness codex --model gpt-5.5 --effort high" "T4 the swarm line"
grep -q 'yes, go ahead' "$HOME_DIR/data/war-room/$council/approved" || fail "T4 the approved record lacks the owner's words"
out=$(war_room approve "$council" --words "yes again") || fail "T4 a second approve should exit 0: $out"
assert_contains "$out" "already started" "T4 a second approve should say already started: $out"
[ "$(grep -c . "$W/swarm-calls")" = 1 ] || fail "T4 a second approve ran the swarm again"
pass "T4 approve records the owner's words and runs the swarm once"

# T5: JG_WAR_ROOM_NEXT=0 leaves every step to Overwatch.
council=jg-wnb
new_council "$council"
printf '# Report of %s\n' "$V1" > "$HOME_DIR/data/$V1/report.md"
before=$(children "$council" | grep -c .)
out=$(JG_WAR_ROOM_NEXT=0 handoff draft "$V1") || fail "T5 the draft should be recorded: $out"
/bin/sleep 4
[ "$(children "$council" | grep -c .)" = "$before" ] || fail "T5 a draft with JG_WAR_ROOM_NEXT=0 filed a ticket"
[ "$(handoff assignee "$V1")" = none ] || fail "T5 a draft with JG_WAR_ROOM_NEXT=0 assigned a critic"
pass "T5 JG_WAR_ROOM_NEXT=0: no next runs"

# T6: the fast war room: standard variants with no critic lanes, then a deep synthesis with its own critic.
council=jg-wnc
new_council "$council" --synthesis-depth deep --no-variant-critics
grep -qx 'synthesis_depth=deep' "$HOME_DIR/data/war-room/$council/record" || fail "T6 the record lacks synthesis_depth=deep"
grep -qx 'variant_critics=0' "$HOME_DIR/data/war-room/$council/record" || fail "T6 the record lacks variant_critics=0"
for v in "$V1" "$V2" "$V3"; do
  grep -qx 'Recon depth: standard' "$HOME_DIR/data/$v/brief.md" || fail "T6 the brief of $v is not standard"
  printf '# Report of %s\n' "$v" > "$HOME_DIR/data/$v/report.md"
  out=$(handoff draft "$v") || fail "T6 the draft of $v should be recorded: $out"
done
/bin/sleep 4
before=$(children "$council" | grep -c .)
[ "$before" = 3 ] || fail "T6 a draft of a fast variant filed a critic: $(children "$council" | tr '\n' ' ')"
for v in "$V1" "$V2" "$V3"; do : > "$W/gate-pass/$v"; done
out=$(war_room next "$council") || fail "T6 next should exit 0: $out"
for angle in alpha bravo gamma; do
  child_titled "$council" "$angle variant Recon critic" > /dev/null && fail "T6 next filed a critic for $angle"
done
synth=$(child_titled "$council" 'synthesis Recon') || fail "T6 no synthesis ticket after next: $out"
stask=$(task_of "$synth")
[ "$(starts_of "$stask")" = 1 ] || fail "T6 the synthesis should be spawned once, was $(starts_of "$stask")"
grep -qx 'Recon depth: deep' "$HOME_DIR/data/$stask/brief.md" || fail "T6 the synthesis brief is not deep"
printf '# Report of %s\n' "$stask" > "$HOME_DIR/data/$stask/report.md"
out=$(handoff draft "$stask") || fail "T6 the synthesis draft should be recorded: $out"
scritic=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  scritic=$(child_titled "$council" 'synthesis Recon critic' || true)
  [ -n "$scritic" ] && break
  /bin/sleep 0.5
done
[ -n "$scritic" ] || fail "T6 the synthesis got no separate critic within 5 s of its draft"
[ "$(handoff assignee "$stask" | cut -f1)" = "$(task_of "$scritic")" ] || fail "T6 the synthesis critic is not assigned: $(handoff assignee "$stask")"
pass "T6 fast: no variant critic, a deep synthesis, its own critic assigned"

# T7: a refused combination writes nothing.
council=jg-wnd
jg_test_add "$HOME_DIR" "$council" "[feature] War room refusal"
"$ROOT/bin/jg-muster-depth.sh" record --ticket "$council" --depth skip --reason "fixture startup" >/dev/null || fail "record skip"
out=$(war_room start "$council" --project proj --angles alpha --depth deep --no-variant-critics --harness codex --model gpt-5.5 --effort high); rc=$?
[ "$rc" = 2 ] || fail "T7 --no-variant-critics with deep variants should exit 2, exited $rc: $out"
assert_contains "$out" "needs --depth standard" "T7 the refusal should name the cause: $out"
out=$(war_room start "$council" --project proj --angles alpha --depth standard --synthesis-depth quick --harness codex --model gpt-5.5 --effort high); rc=$?
[ "$rc" = 2 ] || fail "T7 a synthesis depth of quick should exit 2, exited $rc: $out"
[ ! -e "$HOME_DIR/data/war-room/$council" ] || fail "T7 a refused start wrote data/war-room/$council"
[ "$(children "$council" | grep -c .)" = 0 ] || fail "T7 a refused start filed a ticket"
pass "T7 a refused combination exits 2 and writes nothing"
