#!/usr/bin/env bash
# The owner's calls in the item store (slice 2): drives jg-item and the owner, policy, bypass and turn-end adapters as processes in
# temporary homes (a main home, and a lead home bound to it by .jg-squad-lead-parent), against core/item-store of this checkout.
# a: policy import, check and row on the fixture registry. b: the store's refusals (a lead's close, Main's close of a tell, a pick he
# was not offered, one pick only). c: a tight project's merge question (a design pick, no and yes). d: after the cut-over (registry
# row refused, a new project's lane to intake, propose then yes, a message's own version). e: a standard project's release word
# (asked once, his yes, a push after it asks again), the trunk word and the standing release word. f: the reply proof. g: a bypass as a
# rule item. h: the stamp check (forged owner move, reused message id, registry row outside the cut-over, chat close with no sent
# record) and one message that opens a tell and answers a question. i: a hold opens its question, his board answer closes it, a refused
# hold call leaves one intake item, import-holds, and compare against today's records (real Beads homes).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
FIX=$HERE/fixtures/item-store-owner-calls
ITEM=$ROOT/core/item-store
JI=$ITEM/jg-item
AD=$ITEM/adapters
d=$(mktemp -d) || exit 1
trap 'rm -rf -- "$d"' EXIT
export JG_ITEM_TICK_LEASE_S=0
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
fail=0
ok()  { echo "ok $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }
want() {   # <label> <expected> <got>
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted [$2], got [$3]"; fi
}

mkhome() {   # <dir>: a main home with the store switched on
  mkdir -p "$1/state" "$1/config" "$1/data"; : > "$1/config/item-store"
}
mklead() {   # <dir> <main> <id>
  mkhome "$1"; printf '%s\n' "$3" > "$1/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.jg-squad-lead-parent"
}
ji()  { env JG_HOME="$H" "$JI" "$@"; }             # Main's writer
jl()  { env JG_HOME="$L" "$JI" "$@"; }             # the lead's writer
own() { env JG_HOME="${HH:-$H}" python3 -I "$AD/owner.py" "$@"; }
pol() { env JG_HOME="${HH:-$H}" python3 -I "$AD/policy.py" "$@"; }
sql() {    # <home> <query>
  python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1] + "/state/item-store/fleet.db")
for r in c.execute(sys.argv[2]): print("|".join("" if x is None else str(x) for x in r))' "$1" "$2"
}
py() {     # <home> <script>: the store as an adapter's own process opens it
  JG_HOME="$1" ITEM="$ITEM" python3 -I -c "$2"
}
open_key() { sql "${2:-$H}" "SELECT count(*) FROM item WHERE state='open' AND key='$1'"; }

# ------------------------------------------------------------------ a: the policy import on the fixture registry
H=$d/main; L=$d/lead
mkhome "$H"; mklead "$L" "$H" muxr
cp "$FIX/data/projects.md" "$H/data/projects.md"
pol --import --table "$FIX/rules-main.tsv" > "$d/import.out"; rc=$?
want "a1 import exits 0" 0 "$rc"
if diff "$d/import.out" "$FIX/expected-policy.out" >/dev/null; then ok "a2 policy --import gives exactly expected-policy.out"; else bad "a2 import output" "$(diff "$d/import.out" "$FIX/expected-policy.out" | head -4)"; fi
out=$(pol --check "$H" --table "$FIX/rules-main.tsv"); rc=$?
want "a3 --check prints ok for all 12 fixture projects" "12 0" "$(printf '%s\n' "$out" | grep -c ' ok$') $rc"
want "a4 --row prints the project's line" "mode=local-trunk level=standard merge=owner land=machine release=owner lanes=16 trunk=main" "$(pol --row b-lt)"
pol --row nope-nothing >/dev/null; want "a5 --row of an unknown project exits 1" 1 "$?"
want "a6 the cut-over table is saved for its log reader" 12 "$(grep -c . "$H/state/item-store/cut-over-policy.tsv" | awk '{print $1 - 1}')"
pol --import >/dev/null 2>&1; want "a7 the cut-over import runs once" 1 "$?"

# ------------------------------------------------------------------ b: refusals
ji open question:main/B1 --kind question --home main --subject B1 --owes "pick one" --options 'a|b' --source b1 >/dev/null
out=$(jl close question:main/B1 "done" "owner:board:1 pick=a" --source b2); rc=$?
case $out in refused*) want "b1 a lead's done close of a question is refused" "1 open" "$rc $(open_key question:main/B1 | sed 's/^1$/open/')" ;; *) bad "b1 lead close" "[$out]" ;; esac
own tell --channel chat --message-id m-b3 --subject - --text "tell me" >/dev/null
out=$(ji close tell:main/m-b3 "done" "sent:turn:x@1" --source b3); rc=$?
case $out in refused*) ok "b2 Main's close of a tell is refused" ;; *) bad "b2 main close of a tell" "[$out] rc=$rc" ;; esac
out=$(own answer --channel board --message-id b4 --key question:main/B1 --pick c)
want "b3 a pick he was not offered is refused and listed as one intake item" "intake 1 1" "$out $(open_key question:main/B1) $(sql "$H" "SELECT count(*) FROM item WHERE kind='intake' AND state='open'")"
out=$(ji open question:main/B2 --kind question --home main --subject B2 --owes "one pick" --options 'a' --source b5); rc=$?
case $out in refused*) ok "b4 a question with fewer than two picks is refused" ;; *) bad "b4 one pick" "[$out] rc=$rc" ;; esac

# ------------------------------------------------------------------ c: a tight project's merge question
q() { ji open "$1" --kind question --home main --subject "$2" --owes "$3" --options "${4:-yes|no}" --source "c-$1" ${5:+--project "$5"} >/dev/null; }
q question:main/C1 C1 "which colour" 'red|blue'
own answer --channel chat --message-id c1 --key question:main/C1 --pick red >/dev/null
want "c1 his design pick does not open the merge" 0 "$(sql "$H" "SELECT count(*) FROM item WHERE kind='merge'")"
q question:merge:main/C2@7 C2 "merge pull request 7 (https://x/pull/7) at abc? ready" yes\|no e-pr
own answer --channel chat --message-id c2 --key question:merge:main/C2@7 --pick no >/dev/null
want "c2 his pick=no on the merge question does not open the merge" 0 "$(sql "$H" "SELECT count(*) FROM item WHERE kind='merge'")"
q question:merge:main/C3@8 C3 "merge pull request 8 (https://x/pull/8) at def? ready" yes\|no e-pr
want "c3 his pick=yes opens the merge, and not the landing or a second pull request" "open|C3|e-pr 0 0" \
  "$(own answer --channel chat --message-id c3 --key question:merge:main/C3@8 --pick yes >/dev/null; sql "$H" "SELECT state, subject, project FROM item WHERE key='merge:main/C3@8'" | sed 's/^open|C3|e-pr$/open|C3|e-pr/') $(sql "$H" "SELECT count(*) FROM item WHERE kind='land'") $(sql "$H" "SELECT count(*) FROM item WHERE key LIKE 'merge:main/C3@%' AND key<>'merge:main/C3@8'")"
want "c4 the merge's open carries his answer's pair for the stamp check" "chat:c3" "$(sql "$H" "SELECT source FROM move WHERE key='question:merge:main/C3@8' AND verb='close'")"
out=$(jl open question:merge:muxr/C4@9 --kind question --home muxr --subject C4 --owes "merge pull request 9 (u) at h? r" --options 'yes|no' --source c5)
case $out in refused*) ok "c5 a lead's step question is refused" ;; *) bad "c5 lead step question" "[$out]" ;; esac
out=$(ji open question:merge:main/C5@9 --kind question --home main --subject C5 --owes "merge it" --options 'yes|no' --source c6)
case $out in refused*) ok "c6 Main's step question whose text does not name the pull request is refused" ;; *) bad "c6 text without the pull request" "[$out]" ;; esac

# ------------------------------------------------------------------ d: after the cut-over
out=$(py "$H" 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb, store as S
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry"); at = itemdb.stamp(st)
try: st.set_policy(at, "newp", "tight", "owner:registry", "import:projects.md:newp"); print("written")
except S.Refused as e: print("refused")')
want "d1 after the cut-over a registry row is refused" refused "$out"
out=$(env JG_ITEM_OR_INTAKE=1 JG_HOME="$H" "$JI" open work:main/W1 --kind work --home main --subject W1 --owes "do it" --project newp --source d2)
want "d2 a new project's lane goes to intake" "intake" "$out"
out=$(pol --propose --project newp --level tight --mode direct-PR)
want "d3 --propose opens the policy question" open "$out"
want "d4 the question is keyed and carries the full text" "question:policy/newp#v1|open" "$(sql "$H" "SELECT key, state FROM item WHERE key LIKE 'question:policy/%'")"
pol --row newp >/dev/null; want "d5 no version before his answer" 1 "$?"
own answer --channel board --message-id d6 --key 'question:policy/newp#v1' --pick yes >/dev/null
want "d6 his yes writes version 1" "mode=direct-PR level=tight merge=owner land=owner release=machine lanes=16 trunk=main" "$(pol --row newp)"
out=$(env JG_ITEM_OR_INTAKE=1 JG_HOME="$H" "$JI" open work:main/W2 --kind work --home main --subject W2 --owes "do it" --project newp --source d7)
want "d7 its lane then opens" open "$out"
q0=$(sql "$H" "SELECT count(*) FROM item WHERE key LIKE 'question:policy/%'")
out=$(pol --from-message --channel chat --message-id d8 --project newp --level loose)
want "d8 --from-message writes version 2 with no question" "version 2 $q0 mode=direct-PR level=loose merge=machine land=machine release=machine lanes=16 trunk=main" \
  "$out $(sql "$H" "SELECT count(*) FROM item WHERE key LIKE 'question:policy/%'") $(pol --row newp)"
want "d9 the same message again writes nothing" again "$(pol --from-message --channel chat --message-id d8 --project newp --level loose)"

# ------------------------------------------------------------------ e: the release word on a standard project
push() { env JG_HOME="$H" ITEM="$ITEM" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "adapter:trunk"); at = itemdb.stamp(st)
print(st.release_push(at, sys.argv[1], sys.argv[2], sys.argv[3], source="push:" + sys.argv[3]))' "$@"; }
push b-lt 5 h1 >/dev/null; push b-lt 5 h2 >/dev/null
want "e1 two landings pushed into one release pull request ask him once" "1 0" "$(open_key question:release:b-lt@5) $(open_key release:b-lt@5)"
want "e2 his trunk-word yes closes it stamped owner:trunk-word and opens the release" "done owner:trunk-word 1" \
  "$(own answer --channel trunk-word --message-id 100@h2 --key question:release:b-lt@5 --pick yes | tr -d '\n') $(sql "$H" "SELECT closed_by FROM item WHERE key='question:release:b-lt@5'") $(open_key release:b-lt@5)"
want "e3 the head his first yes saw" h2 "$(ji covered-head b-lt 5)"
sleep 2   # the store orders a yes and a push by the second
push b-lt 5 h3 >/dev/null
want "e4 a push after his yes asks again, and the release waits" "1 h2" "$(open_key question:release:b-lt@5) $(ji covered-head b-lt 5)"
out=$(py "$H" 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb, store as S
st = itemdb.open_db(os.environ["JG_HOME"], "adapter:trunk"); at = itemdb.stamp(st)
try: st.release_out(at, "b-lt", "5", "h3", source="out:h3"); print("released")
except S.Refused as e: print("refused")')
want "e5 the release cannot close past the head his yes covered" refused "$out"
push b-lt 6 k1 >/dev/null
want "e6 his standing release word (rules) closes it stamped owner:rules and opens the release" "done owner:rules 1" \
  "$(own answer --channel rules --message-id r1@k1 --key question:release:b-lt@6 --pick yes | tr -d '\n') $(sql "$H" "SELECT closed_by FROM item WHERE key='question:release:b-lt@6'") $(open_key release:b-lt@6)"
out=$(own answer --channel sms --message-id s1 --key question:release:b-lt@5 --pick yes 2>&1); rc=$?
want "e7 an unknown channel exits 2 and writes nothing" "2 1" "$rc $(open_key question:release:b-lt@5)"

# ------------------------------------------------------------------ f: the reply proof
printf 'sess1\n' > "$H/state/.lock-session"
own tell --channel chat --message-id sess1:4 --subject - --text "please deploy the thing" >/dev/null
turn() { printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | env JG_HOME="$H" python3 -I "$AD/turn_end.py"; }
tell=tell:main/sess1:4
turn other "$FIX/transcript-answered.jsonl"
want "f1 a non-primary session writes nothing" "1 0" "$(open_key $tell) $(test -s "$H/state/item-store/turn-sent.log" && echo 1 || echo 0)"
turn sess1 "$FIX/transcript-not-held.jsonl"
want "f2 a turn that does not hold the note leaves the tell open" 1 "$(open_key $tell)"
turn sess1 "$FIX/transcript-empty-final.jsonl"
want "f3 a turn with no final message leaves it open" 1 "$(open_key $tell)"
printf '{"session_id":"sess1"}' | env JG_HOME="$H" python3 -I "$AD/turn_end.py"
want "f4 a payload with no transcript writes nothing" 1 "$(open_key $tell)"
turn sess1 "$FIX/transcript-answered.jsonl"
want "f5 the turn that held the note closes the tell with its proof" "done|adapter:chat|sent:turn:sess1@2026-11-19T10:10:30Z" "$(sql "$H" "SELECT state, closed_by, outcome FROM item WHERE key='$tell'")"
want "f6 the sent record is in the log the stamp check reads" "turn:sess1@2026-11-19T10:10:30Z	$tell" "$(cat "$H/state/item-store/turn-sent.log")"
turn sess1 "$FIX/transcript-answered.jsonl"; want "f7 the same turn again writes nothing more" 1 "$(wc -l < "$H/state/item-store/turn-sent.log" | tr -d ' ')"


# ------------------------------------------------------------------ g: a bypass is a rule item
B=$d/byp; mkhome "$B"
pb() { env JG_HOME="$B" "$ROOT/bin/jg-proof-bypass.sh" "$@"; }
pb grant --project p --word owner-rule-x --hours 2 >/dev/null
due=$(sql "$B" "SELECT due_at - opened_at FROM item WHERE key='rule:project/p' AND state='open'")
case $due in 71[0-9][0-9]|7200) ok "g1 a grant opens rule:project/p, due at its end (2 hours)" ;; *) bad "g1 rule item" "due in [$due]" ;; esac
want "g2 the rule is stamped owner:rules and its source is the word" "owner:rules|owner-rule-x" "$(sql "$B" "SELECT opened_by, source FROM item JOIN move ON move.key=item.key AND move.verb='open' WHERE item.key='rule:project/p'")"
pb grant --project q --word owner-rule-y --hours 960 >/dev/null
want "g3 a grant of 40 days gets a 30-day deadline" 2592000 "$(sql "$B" "SELECT due_at - opened_at FROM item WHERE key='rule:project/q'")"
idp=$(awk -F'\t' '$3 == "p" { print $1 }' "$B/config/proof-bypass"); idq=$(awk -F'\t' '$3 == "q" { print $1 }' "$B/config/proof-bypass")
awk -F'\t' -v OFS='\t' -v i="$idp" -v t="$(( $(date +%s) - 5 ))" '$1 == i { $6 = t } { print }' "$B/config/proof-bypass" > "$B/config/pb.tmp" && mv "$B/config/pb.tmp" "$B/config/proof-bypass"
pb expire >/dev/null
case $(sql "$B" "SELECT state, outcome, closed_by FROM item WHERE key='rule:project/p'") in
  dropped\|expired\ at\ 20*\|owner:rules) ok "g4 expire past its end drops it with the reason (expired at <end>)" ;; *) bad "g4 expire" "$(sql "$B" "SELECT state, outcome, closed_by FROM item WHERE key='rule:project/p'")" ;; esac
pb end "$idq" >/dev/null
want "g5 end (his word) closes it done with proof owner:rules:<word>" "done|owner:rules:owner-rule-y" "$(sql "$B" "SELECT state, outcome FROM item WHERE key='rule:project/q'")"
out=$(env JG_HOME="$B" "$JI" stamp-check); rc=$?
want "g6 the stamp check is clean for all three" "0 []" "$rc [$out]"
before=$(sql "$B" "SELECT count(*) FROM move")
out=$(env JG_TASK_ID=jg-w1 JG_HOME="$B" "$ROOT/bin/jg-proof-bypass.sh" grant --project z --word owner-rule-z 2>&1); rc=$?
want "g7 a worker's grant is refused and writes nothing" "1 $before 2" "$rc $(sql "$B" "SELECT count(*) FROM move") $(grep -c . "$B/config/proof-bypass")"

# ------------------------------------------------------------------ h: the stamp check, and one message that does two things
S=$d/stamp; mkhome "$S"
js() { env JG_HOME="$S" "$JI" "$@"; }
HH=$S
js open question:main/F9 --kind question --home main --subject F9 --owes "pick" --options 'yes|no' --source h0 >/dev/null
own tell --channel chat --message-id c9 --subject F9 --text "one message" >/dev/null
own answer --channel chat --message-id c9 --key question:main/F9 --pick yes >/dev/null
want "h1 one chat message that opens a tell and answers a question writes both" "2 1 1" "$(sql "$S" "SELECT count(*) FROM move WHERE source='chat:c9'") $(open_key tell:main/c9 "$S") $(sql "$S" "SELECT count(*) FROM item WHERE key='question:main/F9' AND state='done'")"
own tell --channel chat --message-id c9 --subject F9 --text "one message" >/dev/null; own answer --channel chat --message-id c9 --key question:main/F9 --pick yes >/dev/null
want "h2 the same message again writes nothing" 2 "$(sql "$S" "SELECT count(*) FROM move WHERE source='chat:c9'")"
js tick >/dev/null
want "h3 his own moves are in his log: no finding" 0 "$(sql "$S" "SELECT count(*) FROM item WHERE kind='security'")"
js open question:main/F1 --kind question --home main --subject F1 --owes "pick" --options 'yes|no' --source h4 >/dev/null
js open question:main/F3 --kind question --home main --subject F3 --owes "pick" --options 'yes|no' --source h5 >/dev/null
own tell --channel chat --message-id c8 --subject F8 --text "a note" >/dev/null
py "$S" 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
home = os.environ["JG_HOME"]
o = itemdb.open_db(home, "owner:chat"); at = itemdb.stamp(o)
o.close(at, "question:main/F1", "done", "owner:chat:evil pick=yes", o.me, source="chat:evil")      # a forged owner move: no message of his
o.close(at, "question:main/F3", "done", "owner:chat:c9 pick=yes", o.me, source="chat:c9")           # a reused message id: c9 never answered F3
r = itemdb.open_db(home, "owner:registry"); at = itemdb.stamp(r)
r.set_policy(at, "zz", "tight", "owner:registry", "import:projects.md:zz")                          # a registry row outside the cut-over run
c = itemdb.open_db(home, "adapter:chat"); at = itemdb.stamp(c)
c.close(at, "tell:main/c8", "done", "sent:turn:s@9", c.me, source="turn:s@9")                        # a chat-adapter close with no sent record'
js tick >/dev/null
want "h4 each forged record opens one security item at the next tick" "4" "$(sql "$S" "SELECT count(*) FROM item WHERE kind='security' AND state='open'")"
want "h5 the tick's log names the four findings" 4 "$(grep -c ' stamp ' "$S/state/item-store/tick.log")"
js stamp-check >/dev/null; want "h6 the stamp check exits 1 while the registry row stands" 1 "$?"

# ------------------------------------------------------------------ r: the standing release word is read from the release record
R=$d/rel; mkhome "$R"; cp "$FIX/data/projects.md" "$R/data/projects.md"
HH=$R pol --import >/dev/null
printf 'kind=release\nproject=/x/projects/b-lt\npr=https://github.com/o/r/pull/6\npr_head=k1\nmerge_rule=r1\n' > "$R/state/release-b-lt-x.meta"
rp() { env JG_HOME="$R" ITEM="$ITEM" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "adapter:trunk"); at = itemdb.stamp(st)
st.release_push(at, "b-lt", sys.argv[1], sys.argv[2], source="push:" + sys.argv[2])' "$@"; }
rp 6 k1; rp 7 k2
HH=$R own answer --channel rules --message-id r1@k1 --key question:release:b-lt@6 --pick yes >/dev/null
out=$(env JG_HOME="$R" "$JI" stamp-check); rc=$?
want "r1 with a release record carrying merge_rule=r1 and pr_head the stamp check is clean for it" "0 []" "$rc [$out]"
HH=$R own answer --channel rules --message-id r2@k2 --key question:release:b-lt@7 --pick yes >/dev/null
out=$(env JG_HOME="$R" "$JI" stamp-check); rc=$?
want "r2 a rules close with no such record is found (the close and the step it opened)" "1 2" "$rc $(printf '%s\n' "$out" | grep -c '^stamp ')"
unset HH

# ------------------------------------------------------------------ i: the hold scripts on real Beads homes, import-holds and compare
# A hold on a yolo-off task that names its pull request asks his merge word; any other hold asks the plain question; his board answer
# closes it with his pick and a yes on a merge opens the merge. A refused hold call leaves one intake item and the hold itself set.
if [ -z "${JG_BEADS_TEST_BD:-}" ] && command -v bd >/dev/null 2>&1; then JG_BEADS_TEST_BD=$(command -v bd); fi
if [ -z "${JG_BEADS_TEST_DOLT:-}" ] && command -v dolt >/dev/null 2>&1; then JG_BEADS_TEST_DOLT=$(command -v dolt); fi
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  echo "skip i: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset"
  exit "$fail"
fi
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
# shellcheck source=core/lib/beads-test-env.sh disable=SC1091
. "$ROOT/core/lib/beads-test-env.sh"
HB=$d/hb; LB=$d/lb
mkdir -p "$HB/state" "$LB/state"
core_beads_home "$ROOT" "$HB"; core_beads_home "$ROOT" "$LB"
: > "$HB/config/item-store"; : > "$LB/config/item-store"
cp "$FIX/data/projects.md" "$HB/data/projects.md"
printf 'muxr\n' > "$LB/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$HB" > "$LB/.jg-squad-lead-parent"
hold() {   # <home> <command args...>: the hold script of that home
  local h=$1; shift
  env JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/jg-captain-hold.sh" "$@"
}
meta() {   # <home> <task> <ticket> [pr number]
  printf 'ticket=%s\nproject=/x/projects/e-pr\n' "$3" > "$1/state/$2.meta"
  [ -z "${4:-}" ] || printf 'pr=https://github.com/o/r/pull/%s\npr_head=abc123\n' "$4" >> "$1/state/$2.meta"
}
HH=$HB
meta "$HB" jg-a0001 jg-a0001 7; meta "$HB" jg-a0002 jg-a0002
hold "$HB" hold jg-a0001 --title "[captain-ask] merge it" --reason "may it merge?" --repo e-pr >/dev/null
hold "$HB" hold jg-a0002 --title "[captain-ask] pick a colour" --reason "which colour?" --repo e-pr >/dev/null
want "i1 a hold on a yolo-off task that names its pull request opens the merge question naming it" "1 1" \
  "$(open_key question:merge:main/jg-a0001@7 "$HB") $(sql "$HB" "SELECT count(*) FROM item WHERE key='question:merge:main/jg-a0001@7' AND owes LIKE 'merge pull request 7 (https://github.com/o/r/pull/7) at abc123? may it merge?'")"
want "i2 a hold on a task with no pull request opens the plain question" "1 jg-a0002" "$(open_key question:main/jg-a0002 "$HB") $(sql "$HB" "SELECT subject FROM item WHERE key='question:main/jg-a0002'")"
meta "$LB" jg-b0001 jg-b0001 9
hold "$LB" hold jg-b0001 --title "[captain-ask] lead call" --reason "lead asks" --repo e-pr >/dev/null
want "i3 in a lead home the hold opens the plain question" "1 0" "$(open_key question:muxr/jg-b0001 "$HB") $(sql "$HB" "SELECT count(*) FROM item WHERE key LIKE 'question:merge:muxr/%'")"
printf 'yes, merge it\n' > "$d/dec-1.txt"
hold "$HB" answer jg-a0001 --decision-file "$d/dec-1.txt" >/dev/null
want "i4 answer closes it with pick=yes and opens the merge step" "done|owner:board:dec-1.txt pick=yes 1" \
  "$(sql "$HB" "SELECT state, outcome FROM item WHERE key='question:merge:main/jg-a0001@7'") $(open_key merge:main/jg-a0001@7 "$HB")"
# a refused hold call: the ticket id holds a slash, so the store refuses the question; one intake item, and the hold is set
meta "$HB" jg-a0003 'bad/ticket'
hold "$HB" hold jg-a0003 --title "[captain-ask] odd ticket" --reason "odd" --repo e-pr >/dev/null
want "i5 a refused hold call leaves one intake item and the hold itself set" "1 0" \
  "$(sql "$HB" "SELECT count(*) FROM item WHERE kind='intake' AND state='open'") $(hold "$HB" open jg-a0003 >/dev/null; echo $?)"
# a standing owner rule is not owed by a date: the surface takes it and the store takes no item
n0=$(sql "$HB" "SELECT count(*) FROM move")
env JG_HOME="$HB" JG_DATA_OVERRIDE="$HB/data" JG_STATE_OVERRIDE="$HB/state" JG_CONFIG_OVERRIDE="$HB/config" "$ROOT/bin/jg-owner-rules.sh" init >/dev/null 2>&1
env JG_HOME="$HB" JG_DATA_OVERRIDE="$HB/data" JG_STATE_OVERRIDE="$HB/state" JG_CONFIG_OVERRIDE="$HB/config" "$ROOT/bin/jg-owner-rules.sh" add --kind owner --words "No forecast dates, ever." \
  --scope all --enforce "AGENTS.md section 9" --date 2026-11-19 --title "no forecast dates" >/dev/null 2>&1
want "i6 jg-owner-rules.sh add writes data/owner-rules.md and opens no item" "1 $n0" "$(grep -c 'No forecast dates' "$HB/data/owner-rules.md" 2>/dev/null) $(sql "$HB" "SELECT count(*) FROM move")"

# import-holds: two open legacy keys and one resolved key open two questions, quietly; run twice it writes nothing
cat > "$HB/state/muxr.status" <<'EOF'
needs-decision [key=k1] [at=1000]: captain hold jg-c0001: may the pipeline run on Friday?
blocked [key=k2] [at=1001]: captain hold jg-c0002: which account pays?
needs-decision [key=k3] [at=1002]: captain hold jg-c0003: ship it?
resolved [key=k3] [at=1003]: captain hold jg-c0003: answered yes
EOF
out=$(own import-holds "$LB")
want "i7 import-holds opens one question for each open legacy key, none for the resolved one (3 records: its 2 keys and the lead's own active hold)" "2 0 3" \
  "$(sql "$HB" "SELECT count(*) FROM item WHERE state='open' AND key IN ('question:muxr/jg-c0001','question:muxr/jg-c0002')") $(sql "$HB" "SELECT count(*) FROM item WHERE key='question:muxr/jg-c0003'") $(printf '%s\n' "$out" | sed -n 's/.*: \([0-9]*\) records.*/\1/p')"
want "i8 they are written quietly (no page)" 0 "$(sql "$HB" "SELECT count(*) FROM move WHERE key IN ('question:muxr/jg-c0001','question:muxr/jg-c0002') AND page IS NOT NULL")"
n1=$(sql "$HB" "SELECT count(*) FROM move"); own import-holds "$LB" >/dev/null
want "i9 run twice it writes nothing" "$n1" "$(sql "$HB" "SELECT count(*) FROM move")"

# compare: today's records against the store
rm -f "$HB/config/item-store"; meta "$HB" jg-a0004 jg-a0004
hold "$HB" hold jg-a0004 --title "[captain-ask] store off" --reason "set with the store off" --repo e-pr >/dev/null; : > "$HB/config/item-store"
out=$(own compare "$HB"); rc=$?
want "i10 compare lists a hold set only in today's record, once" "1 1 jg-a0004 question today=held store=none" "$rc $(printf '%s\n' "$out" | grep -c 'jg-a0004') $(printf '%s\n' "$out" | grep 'jg-a0004')"
own import-holds "$HB" >/dev/null
out=$(own compare "$HB" | grep 'jg-a0004')
want "i11 after import-holds that hold has its question" "" "$out"
mkdir -p "$HB/state/inbox"; printf 'id=1-abc\nsource=text\n--\nhello\n' > "$HB/state/inbox/1-abc.note"
out=$(own compare "$HB"); want "i12 an inbox note that is not handled needs an open tell" "1-abc tell today=waiting store=none" "$(printf '%s\n' "$out" | grep '1-abc')"
own tell --channel chat --message-id 1-abc --subject - --text hello >/dev/null
out=$(own compare "$HB"); want "i13 the tell closes the difference" 0 "$(printf '%s\n' "$out" | grep -c '1-abc')"
printf 'bp-1-aaaaaa\tproject\tpx\towner-rule-px\t1\t%s\tstanding\t0\t-\t-\n' "$(( $(date +%s) + 3600 ))" >> "$HB/config/proof-bypass"
out=$(own compare "$HB"); want "i14 a standing bypass without its rule is listed" "bp-1-aaaaaa rule today=standing store=none" "$(printf '%s\n' "$out" | grep 'bp-1-aaaaaa')"
env JG_HOME="$HB" python3 -I "$AD/bypass.py" grant --id bp-1-aaaaaa --scope project --target px --word owner-rule-px --until "$(( $(date +%s) + 3600 ))" >/dev/null
out=$(own compare "$HB"); want "i15 the rule item closes it" 0 "$(printf '%s\n' "$out" | grep -c 'bp-1-aaaaaa')"
# import-holds also opens the rule of each standing bypass granted before the store was on, so compare no longer shows it
printf 'bp-2-bbbbbb\tproject\tpy\towner-rule-py\t1\t%s\tstanding\t0\t-\t-\n' "$(( $(date +%s) + 3600 ))" >> "$HB/config/proof-bypass"
out=$(own compare "$HB"); want "i16 a bypass granted before the store was on is listed" "bp-2-bbbbbb rule today=standing store=none" "$(printf '%s\n' "$out" | grep 'bp-2-bbbbbb')"
out=$(own import-holds "$HB")
want "i17 import-holds opens its rule item, once" "1 1" "$(open_key rule:project/py "$HB") $(printf '%s\n' "$out" | grep -c '1 rules opened')"
want "i18 compare no longer lists it" 0 "$(own compare "$HB" | grep -c 'bp-2-bbbbbb')"
n1=$(sql "$HB" "SELECT count(*) FROM move"); own import-holds "$HB" >/dev/null
want "i19 import-holds run twice writes nothing" "$n1" "$(sql "$HB" "SELECT count(*) FROM move")"
# a home with no hold file (no backlog store) holds nothing: compare reads none, never unreadable
HN=$d/hn; mkhome "$HN"; HH=$HN
out=$(own compare "$HN"); rc=$?
want "i20 a home with no hold file compares clean" "0 0" "$rc $(printf '%s\n' "$out" | grep -c unreadable)"
unset HH

exit "$fail"
