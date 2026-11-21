#!/usr/bin/env bash
# /muster council gathers questions first, with no pack: bin/jg-war-room.sh lenses starts one lens lane for each lens through
# War Room's own lane machinery, `next` stops once every lens has drafted, and bin/jg-muster-council.sh merge writes the merged
# questions in the round format. Real bin/jg-war-room.sh, bin/jg-muster-council.sh, bin/jg-recon-handoff.sh, bin/jg-brief.sh and
# bin/jg-backlog.sh over a brand-new project fixture (no pack, no docs) and a Beads store; the spawn is the stand-in
# tests/jg-war-room-next.test.sh uses (JG_WAR_ROOM_SPAWN: writes the lane's task record and notes each start).
#
# T1 lenses: one child ticket, one brief (`Lens: <lens>`) and one start for each of five lenses; the record says kind=lenses; a
#    second run files and starts nothing.
# T2 next: files no critic, no synthesis, no dry run and no plan question; it names the lens it waits for, then says to merge.
# T3 merge refused: a lens that has not drafted refuses the merge and writes no round.
# T4 merge: the round record follows formats.md section 2; agreed answers are taken=agent, a contested question and a
#    captain-only question stay open; the domain lens's objects, states and events reach the drafter; a second merge changes nothing.
# T5 no pack: the project and the ticket's muster folder hold no pack file, manifest or approval record; War Room approve refuses.
# T6 skills and contract: war-room names no /council, council loads /muster council, and the fragment has the frozen shape.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-muster-council)
W="$TMP_ROOT/world"; HOME_DIR="$W/home"; PROJ="$HOME_DIR/projects/newbot"
mkdir -p "$W" "$HOME_DIR/projects"
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
chmod +x "$W/spawn.sh"

export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config"
export JG_PROJECTS_OVERRIDE="$HOME_DIR/projects" JG_WAR_ROOM_SPAWN="$W/spawn.sh" JG_WAR_ROOM_WAIT=30 JG_WAR_ROOM_NEXT=0

war_room() { "$ROOT/bin/jg-war-room.sh" "$@" 2>&1; }
council_cmd() { "$ROOT/bin/jg-muster-council.sh" "$@" 2>&1; }
handoff() { "$ROOT/bin/jg-recon-handoff.sh" "$@" 2>&1; }
children() {
  python3 -I "$ROOT/core/item-store/adapters/bd_compat.py" list --parent "$1" --all --limit 0 --json 2>/dev/null | jq -r '.[]?.id' | sort
}
title_of() { jg_test_backlog "$HOME_DIR" show "$1" 2>&1 | sed -n 's/^  title: *//p' | head -1 | tr -d '"'; }
child_titled() {
  local id
  for id in $(children "$1"); do [ "$(title_of "$id")" = "$2" ] && { printf '%s\n' "$id"; return 0; }; done
  return 1
}
task_of() { printf '%s\n' "${1//./-}"; }
starts_of() { grep -c . "$STARTS/$1" 2>/dev/null || echo 0; }
questions_of() { jg_test_backlog "$HOME_DIR" questions --ticket "$1" --json 2>/dev/null | jq 'length' 2>/dev/null; }
sha12() { printf '%s' "$1" | sha256sum | cut -c1-12; }

LENSES=user,domain,architecture,skeptic,quality
council=jg-mc1
jg_test_add "$HOME_DIR" "$council" "[feature] Muster council for a new bot"

# T1: five lens lanes, started together, with no pack.
out=$(war_room lenses "$council" --project newbot --lenses "$LENSES" --harness codex --model gpt-5.5 --effort high) \
  || fail "T1 lenses should make five lanes live: $out"
[ "$(children "$council" | grep -c .)" = 5 ] || fail "T1 the council should have five child tickets: $(children "$council")"
for lens in user domain architecture skeptic quality; do
  row=$(child_titled "$council" "$lens lens") || fail "T1 no child titled '$lens lens'"
  task=$(task_of "$row")
  [ "$(starts_of "$task")" = 1 ] || fail "T1 the $lens lane should be started once, was $(starts_of "$task")"
  grep -qx "Lens: $lens" "$HOME_DIR/data/$task/brief.md" || fail "T1 the brief of $lens does not name its lens"
  grep -q 'jg-recon-handoff.sh draft' "$HOME_DIR/data/$task/brief.md" || fail "T1 the brief of $lens lacks the draft command"
  grep -qE '\{TASK\}|\{JUGGERNAUT_SPEC\}' "$HOME_DIR/data/$task/brief.md" && fail "T1 the brief of $lens holds a placeholder"
  case $lens in
    user) T_user=$task ;; domain) T_domain=$task ;; architecture) T_architecture=$task ;; skeptic) T_skeptic=$task ;; quality) T_quality=$task ;;
  esac
done
grep -qx 'kind=lenses' "$HOME_DIR/data/war-room/$council/record" || fail "T1 the record does not say kind=lenses"
grep -q 'owner: ' "$HOME_DIR/data/$T_user/brief.md" || fail "T1 the brief does not show the question line format"
grep -q 'Core objects' "$HOME_DIR/data/$T_domain/brief.md" || fail "T1 the domain lens brief does not ask for core objects"
before=$(children "$council")
war_room lenses "$council" --project newbot --lenses "$LENSES" --harness codex --model gpt-5.5 --effort high > /dev/null \
  || fail "T1 a second run should exit 0"
[ "$(children "$council")" = "$before" ] || fail "T1 a second run filed a ticket"
for task in $T_user $T_domain $T_architecture $T_skeptic $T_quality; do
  [ "$(starts_of "$task")" = 1 ] || fail "T1 a second run started $task again"
done
pass "T1 lenses files five lens lanes, briefs and starts each once, records kind=lenses; a second run adds nothing"

# T2: next waits for the lens drafts and files nothing else.
write_draft() {  # <task> <body>
  printf '%s\n' "$2" > "$HOME_DIR/data/$1/report.md"
}
write_draft "$T_user" '## Questions
- Q: Who is the first user of the bot? | A: A solo shop owner | owner: no
- Q: Should the bot ever send a message by itself? | A: | owner: yes
- Q: Which chat service does it live in? | A: Telegram | owner: no'
out=$(handoff draft "$T_user") || fail "T2 the user draft should be recorded: $out"
out=$(war_room next "$council") || fail "T2 next should exit 0: $out"
assert_contains "$out" "waits: " "T2 next should name what it waits for: $out"
[ "$(children "$council" | grep -c .)" = 5 ] || fail "T2 next filed a ticket (a critic, synthesis or dry run): $(children "$council")"
[ "$(questions_of "$council")" = 0 ] || fail "T2 next held the council for a plan question"
[ ! -e "$HOME_DIR/data/war-room/$council/plan-asked" ] || fail "T2 next asked for a plan"

# T3: a merge before every lens has drafted is refused.
out=$(council_cmd merge "$council"); rc=$?
expect_code 1 "$rc" "T3 merge before every lens drafted should be refused: $out"
assert_contains "$out" "domain" "T3 the refusal should name a lens that has not drafted: $out"
[ ! -e "$HOME_DIR/data/$council/muster/rounds.tsv" ] || fail "T3 a refused merge wrote a round"

pass "T3 a merge before every lens has drafted is refused and writes no round"

write_draft "$T_domain" '## Questions
- Q: Who is the first user of the bot? | A: a solo shop owner | owner: no
- Q: Which chat service does it live in? | A: Telegram | owner: no
## Core objects
- Object: Conversation | states: open, waiting, resolved | events: ConversationOpened, MessageReceived, ConversationResolved
- Object: Message | states: none | events: MessageReceived, MessageSent'
write_draft "$T_architecture" '## Questions
- Q: Where is the data stored? | A: One JSON file per conversation | owner: no
- Q: Which chat service does it live in? | A: WhatsApp | owner: no'
write_draft "$T_skeptic" '## Questions
- Q: What happens when the chat service is down? | A: | owner: no'
write_draft "$T_quality" '## Questions
- Q: Where is the data stored? | A: one json file per conversation | owner: no'
for t in $T_domain $T_architecture $T_skeptic $T_quality; do handoff draft "$t" > /dev/null || fail "T2 draft of $t should be recorded"; done
out=$(war_room next "$council") || fail "T2 next should exit 0: $out"
assert_contains "$out" "jg-muster-council.sh merge $council" "T2 next should say to merge once every lens drafted: $out"
[ "$(children "$council" | grep -c .)" = 5 ] || fail "T2 next filed a ticket after the last draft"
[ "$(questions_of "$council")" = 0 ] || fail "T2 next held the council after the last draft"
pass "T2 next files no critic, synthesis, dry run or plan question; it waits, then says to merge"

# T4: the merge, in the round format.
out=$(council_cmd merge "$council") || fail "T4 merge should exit 0: $out"
rounds="$HOME_DIR/data/$council/muster/rounds.tsv"
[ -s "$rounds" ] || fail "T4 no round record at $rounds"
[ "$(awk -F'\t' 'NF != 12' "$rounds" | grep -c .)" = 0 ] || fail "T4 every row should have the twelve round columns"
[ "$(wc -l < "$rounds")" = 5 ] || fail "T4 five distinct questions expected, rows: $(wc -l < "$rounds")"
row_of() { awk -F'\t' -v q="$(sha12 "$1")" '$7 == q' "$rounds"; }
col() { printf '%s\n' "$1" | cut -f"$2"; }
r=$(row_of "Who is the first user of the bot?")
[ -n "$r" ] || fail "T4 no row for the first-user question"
[ "$(col "$r" 1)" = 1 ] && [ "$(col "$r" 2)" = 1 ] || fail "T4 the first merge writes round 1 revision 1: $r"
case $(col "$r" 3) in R1Q[0-9]*) ;; *) fail "T4 the qid should read R1Q<k>: $r" ;; esac
[ "$(col "$r" 9)" = agent ] && [ "$(col "$r" 10)" = agent ] || fail "T4 an agreed question is source=agent taken=agent: $r"
assert_contains "$(col "$r" 8)" "solo shop owner" "T4 the agreed answer is kept: $r"
r=$(row_of "Where is the data stored?")
[ "$(col "$r" 10)" = agent ] || fail "T4 two lenses agreeing (case aside) is taken=agent: $r"
r=$(row_of "Which chat service does it live in?")
[ -n "$r" ] && [ -z "$(col "$r" 8)" ] && [ -z "$(col "$r" 10)" ] || fail "T4 a contested question stays open: $r"
r=$(row_of "Should the bot ever send a message by itself?")
[ -n "$r" ] && [ -z "$(col "$r" 8)" ] && [ -z "$(col "$r" 10)" ] || fail "T4 a captain-only question stays open: $r"
r=$(row_of "What happens when the chat service is down?")
[ -n "$r" ] && [ -z "$(col "$r" 10)" ] || fail "T4 a question nobody could answer stays open: $r"
[ "$(awk -F'\t' '$10 == "" && $8 == ""' "$rounds" | grep -c .)" = 3 ] || fail "T4 exactly three questions should be open"
[ "$(awk -F'\t' '$10 == "agent"' "$rounds" | grep -c .)" = 2 ] || fail "T4 exactly two questions should be taken by the agent"
domain="$HOME_DIR/data/$council/muster/council-domain.md"
[ -s "$domain" ] || fail "T4 the domain lens's objects did not reach the drafter ($domain)"
grep -q 'Object: Conversation | states: open, waiting, resolved | events: ConversationOpened' "$domain" || fail "T4 the objects, states and events are not carried"
before=$(md5sum "$rounds")
out=$(council_cmd merge "$council") || fail "T4 a second merge should exit 0: $out"
assert_contains "$out" "already merged" "T4 a second merge should say so: $out"
[ "$(md5sum "$rounds")" = "$before" ] || fail "T4 a second merge changed the round record"
pass "T4 merge writes the round format: agreed answers taken=agent, contested and captain-only questions open, objects carried"

# T5: no pack anywhere, and no plan.
[ -z "$(git -C "$PROJ" status --porcelain)" ] || fail "T5 the project was changed"
for f in manifest approvals; do
  find "$HOME_DIR/data/$council/muster" -name "$f*" | grep -q . && fail "T5 the council wrote a $f record"
done
out=$(war_room approve "$council" --words "yes"); rc=$?
expect_code 2 "$rc" "T5 a lens council has no plan to approve: $out"
pass "T5 the council needs and writes no pack; a lens council has no plan to approve"

# T6: skills and the command contract.
[ "$(grep -c '/council' "$ROOT/.agents/skills/war-room/SKILL.md")" = 0 ] || fail "T6 war-room/SKILL.md still names /council"
grep -q '/muster council' "$ROOT/.agents/skills/council/SKILL.md" || fail "T6 council/SKILL.md does not load /muster council"
frag="$ROOT/core/agent-cli/contract/muster-council.json"
jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
  (.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
  (.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
  ((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))' "$frag" > /dev/null \
  || fail "T6 the fragment does not have the frozen shape"
[ "$(jq -r '.owner' "$frag")" = m7 ] || fail "T6 the fragment owner is m7"
[ "$(jq -r '[.entries[] | .path | join(" ")] | sort | join(",")' "$frag")" = "muster council,plan war-room lenses" ] \
  || fail "T6 the fragment holds the two paths 'muster council' and 'plan war-room lenses'"
[ "$(jq -r '[.entries[].method] | unique | join(",")' "$frag")" = POST ] || fail "T6 both entries should be POST"
pass "T6 war-room names no /council, council loads /muster council, the fragment holds both paths in the frozen shape"
