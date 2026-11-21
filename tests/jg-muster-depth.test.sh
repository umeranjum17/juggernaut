#!/usr/bin/env bash
# bin/jg-muster-depth.sh: the decision table, the labelled replay, the must-catch and negative sets, and `record`.
# Builds throwaway projects for each state and a throwaway home: (1) every table row must give its expected line,
# (2) the labelled replay must show no wrong refusal (a skip or light ticket picked full or complete) and at most
# 3 missed big asks, (3) `record` writes, replaces and raises the ticket's one Muster line, (4) the fragment holds its shape.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
pick=$here/bin/jg-muster-depth.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
mk() {  # <name> <commits> <pack yes|no>
  mkdir -p "$d/$1" && git -C "$d/$1" init -q && git -C "$d/$1" config user.email t@t && git -C "$d/$1" config user.name t
  local i=0; while [ "$i" -lt "$2" ]; do git -C "$d/$1" commit -q --allow-empty -m "c$i"; i=$((i + 1)); done
  if [ "$3" = yes ]; then mkdir -p "$d/$1/docs"; : > "$d/$1/VISION.md"; : > "$d/$1/GLOSSARY.md"; : > "$d/$1/docs/ways-of-working.md"; fi
}
mk new 0 no; mk young 5 no; mk mature 25 no; mk documented 25 yes
fail=0
row() {  # <case> <expected line> <project or -> <ask>
  local got; if [ "$3" = - ]; then got=$("$pick" --projects-dir "$d" "$4"); else got=$("$pick" --projects-dir "$d" --project "$3" "$4"); fi
  if [ "$got" = "$2" ]; then echo "ok   $1: $got"; else echo "FAIL $1: want '$2' got '$got'"; fail=1; fi
}
row 'status request, no project' skip - 'what is running right now?'
row 'typo, project without documents' skip mature 'fix the typo in the settings heading'
row 'small feature, project without documents' light mature 'add a dark mode toggle to settings'
row 'small feature, project with documents' light documented 'add a dark mode toggle to settings'
row 'unregistered mature repo, small feature' light elsewhere 'add an export button to the report page'
row 'large change in that repo' 'full survey-first' mature 'redesign the sync architecture for many machines'
row 'large change, documents present' full documented 'redesign the sync architecture for many machines'
row 'true new project' complete new 'start a new chat bot project'
row 'new-project words, no project named' complete - 'New React Native app: addictive book reader'
row 'explicit word wins over the rule' 'full survey-first' mature 'fix the login bug, muster: full'
row 'explicit skip wins over complex words' skip mature 'redesign onboarding, no grilling'
row 'older ticket with no depth line' 'full survey-first' mature 'Main wakes by priority and time, not every few minutes'
row 'slice of an approved plan' skip mature 'Studio restore W3: iterate and handoff on lanes'
row 'build in a young project, no documents' light young 'add a share button'
row 'request for action phrased as a question' complete - 'Can you start a brand-new project?'
row 'new-project intent beats an incidental noun' complete - 'Start a new project for account payments'
row 'complex verb beats a small one' 'full survey-first' mature 'Remove the old storage system and migrate the payment schema across all machines'
row 'request for information about a complex area' skip - 'What is the status of the payment sync?'
row 'strong small word beats a complex noun' skip mature 'Fix the typo in the migration guide'
row 'a not-build word inside the object of a build' complete - 'Build a new app to approve expense reports'
row 'an information verb about a new project' skip - 'Can you explain the new project?'
row 'a fix beats a complex noun in its object' skip mature 'Fix a bug in the login sync'
row 'a blocker tag is a fix' skip mature '[blocker] Fix security header regression'
row 'a fix with a complex verb is complex' 'full survey-first' mature 'Fix the sync by migrating the schema to the new store'
row 'an ask with no readable action is read by Main' 'skip review' mature 'Alignment phase before War Room and Blitz'
row 'a build behind a help-me wrapper (closure review)' complete - 'Could you help me build a new app to approve expense reports?'
row 'a show-me request about a new project (closure review)' skip - 'Could you show me the new project?'
row 'a request whose action stays unread: depth from its nouns, Main confirms' 'full survey-first review' mature 'Could you sort out the onboarding?'
# replay: each labelled ticket runs against the throwaway project of its recorded state
wrong=0 exact=0 missed=0 n=0 review=0
while IFS=$'\t' read -r label state pack title; do
  case $label in '#'*|'') continue ;; esac
  proj=-; case "$state:$pack" in mature:yes) proj=documented ;; none:*) proj=- ;; *) proj=$state ;; esac
  if [ "$proj" = - ]; then got=$("$pick" --projects-dir "$d" "$title"); else got=$("$pick" --projects-dir "$d" --project "$proj" "$title"); fi
  case $got in *review*) review=$((review + 1)) ;; esac
  got=${got%% *}; n=$((n + 1))
  [ "$got" = "$label" ] && exact=$((exact + 1))
  case "$label:$got" in skip:full|skip:complete|light:full|light:complete) wrong=$((wrong + 1)); echo "wrong refusal: $label -> $got: $title" ;; esac
  case "$label:$got" in full:skip|full:light|complete:skip|complete:light) missed=$((missed + 1)); echo "missed big ask: $label -> $got: $title" ;; esac
done < "$here/tests/fixtures/muster-depth-labels.tsv"
echo "replay: $n tickets, exact $exact, wrong refusals $wrong, missed $missed (limit 3), sent to Main's review $review"
[ "$wrong" -eq 0 ] && [ "$missed" -le 3 ] || fail=1
# must-catch set (general phrasings): no big ask may be missed and no small ask refused
cw=0 cm=0 cn=0
while IFS=$'\t' read -r label state pack title; do
  case $label in '#'*|'') continue ;; esac
  proj=-; case "$state:$pack" in mature:yes) proj=documented ;; none:*) proj=- ;; *) proj=$state ;; esac
  if [ "$proj" = - ]; then got=$("$pick" --projects-dir "$d" "$title"); else got=$("$pick" --projects-dir "$d" --project "$proj" "$title"); fi
  got=${got%% *}; cn=$((cn + 1))
  case "$label:$got" in skip:full|skip:complete|light:full|light:complete) cw=$((cw + 1)); echo "must-catch wrong refusal: $label -> $got: $title" ;; esac
  # exact depth for a big ask: complete starts the council by default (D7), so full for complete is a miss too
  case "$label:$got" in full:skip|full:light|complete:skip|complete:light|complete:full) cm=$((cm + 1)); echo "must-catch miss: $label -> $got: $title" ;; esac
done < "$here/tests/fixtures/muster-depth-mustcatch.tsv"
echo "must-catch: $cn asks, missed $cm, wrong refusals $cw"
[ "$cm" -eq 0 ] && [ "$cw" -eq 0 ] || fail=1
# negative set: everyday fixes whose object holds a complex noun must stay skip (D5 a refuses from day one)
nw=0 nn=0
while IFS=$'\t' read -r label state pack title; do
  case $label in '#'*|'') continue ;; esac
  got=$("$pick" --projects-dir "$d" --project "$state" "$title"); got=${got%% *}; nn=$((nn + 1))
  [ "$got" = "$label" ] || { nw=$((nw + 1)); echo "negative set: $label -> $got: $title"; }
done < "$here/tests/fixtures/muster-depth-negative.tsv"
echo "negative set: $nn fixes, not skip $nw"
[ "$nw" -eq 0 ] || fail=1
# the order's acceptance asks, through the command itself
acc() {  # <expected> <ask>
  local got; got=$("$pick" "$2"); if [ "$got" = "$1" ]; then echo "ok   acceptance: $1: $2"; else echo "FAIL acceptance: want '$1' got '$got': $2"; fail=1; fi
}
acc complete 'Build a new app to approve expense reports'
acc complete 'Could you help me build a new app to approve expense reports?'
acc skip 'Can you explain the new project?'
acc skip 'Could you show me the new project?'

# record: the one Muster line of a ticket, on a throwaway home (no live home is read)
H=$d/home; mkdir -p "$H/config" "$H/state" "$H/data" "$d/user"
tk() {  # a jg-backlog.sh call on the throwaway home
  env HOME="$d/user" TMPDIR="$d" PATH="/usr/bin:/bin:$PATH" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$here/bin/jg-backlog.sh" "$@" 2>&1
}
rec() { env HOME="$d/user" TMPDIR="$d" PATH="/usr/bin:/bin:$PATH" JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
  JG_CONFIG_OVERRIDE="$H/config" JG_BOOTSTRAP_NETWORK=skip "$pick" record --projects-dir "$d" "$@" 2>&1; }
sections=$'## Captain\nwhat was said\n## Ask\nthe change\n## Why\nthe reason\n## Done when\nit works\n## Acceptance Criteria\nit is proved'
body_of() { tk show "$1" --full | sed -n 's/^  body: //p' | jq -r .; }
muster_lines() { body_of "$1" | grep -c '^Muster: '; }
check() {  # <name> <condition result 0|1> <detail>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1: $3"; fail=1; fi
}

tk add jg-r1 "Add a dark mode toggle" --priority 2 --body "$sections" >/dev/null
tk add jg-r2 "Alignment phase before War Room and Blitz" --priority 2 --body "$sections" >/dev/null
tk add jg-r3 "[blocker] Fix security header regression" --priority 2 --body "$sections" >/dev/null
out=$(rec --ticket jg-r1 --project mature)
if [ "$(body_of jg-r1 | grep '^Muster: ')" = 'Muster: light - a build' ]; then check 'record writes one Muster line' 0 ''; else check 'record writes one Muster line' 1 "$out / $(body_of jg-r1 | tail -2)"; fi
before=$(body_of jg-r1); out=$(rec --ticket jg-r1 --project mature)
check 'a second record changes nothing' "$([ "$(body_of jg-r1)" = "$before" ] && [ "$(muster_lines jg-r1)" = 1 ] && echo 0 || echo 1)" "$out"
out=$(rec --ticket jg-r3 --project mature)
if [ "$(body_of jg-r3 | grep '^Muster: ')" = 'Muster: skip - a small change: a fix, typo or rename' ]; then check 'a [blocker] label is read as the tag, so a complex noun stays skip' 0 ''; else check 'a [blocker] label is read as the tag, so a complex noun stays skip' 1 "$out / $(body_of jg-r3 | tail -1)"; fi
out=$(rec --ticket jg-r2 --backfill --project mature)
if [ "$(body_of jg-r2 | grep '^Muster: ')" = 'Muster: skip backfilled review - no rule read the action' ]; then check 'a backfilled ask the rule cannot read carries backfilled and review' 0 ''; else check 'a backfilled ask the rule cannot read carries backfilled and review' 1 "$out / $(body_of jg-r2 | tail -1)"; fi
out=$(rec --ticket jg-r2 --depth light); rc=$?
check 'record --depth without --reason is refused' "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc $out"
out=$(rec --ticket jg-r2 --reason because); rc=$?
check 'record --reason without --depth is refused' "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc $out"
out=$(rec --ticket jg-r2 --depth huge --reason because); rc=$?
check 'record with an unknown depth is refused' "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc $out"
out=$(rec --ticket jg-none); rc=$?
check 'record on a missing ticket is refused with the cause' "$([ "$rc" -eq 2 ] && echo "$out" | grep -q 'cannot read ticket jg-none' && echo 0 || echo 1)" "rc=$rc $out"
out=$(rec --ticket jg-r2 --depth light --reason 'Main read it: a small feature')
if [ "$(body_of jg-r2 | grep '^Muster: ')" = 'Muster: light - Main read it: a small feature' ] && [ "$(muster_lines jg-r2)" = 1 ]; then check 'Main replaces a review line with a reading and a reason' 0 ''; else check 'Main replaces a review line with a reading and a reason' 1 "$out / $(body_of jg-r2 | tail -1)"; fi
out=$(rec --ticket jg-r1 --depth full --reason 'it changes a state machine')
if [ "$(body_of jg-r1 | grep '^Muster: ')" = 'Muster: full - it changes a state machine' ] && [ "$(muster_lines jg-r1)" = 1 ]; then check 'Main raises light to full with a reason' 0 ''; else check 'Main raises light to full with a reason' 1 "$out / $(body_of jg-r1 | tail -1)"; fi
before=$(body_of jg-r1); out=$(rec --ticket jg-r1 --depth full --reason 'it changes a state machine')
check 'a repeat of the same raise changes nothing' "$([ "$(body_of jg-r1)" = "$before" ] && echo 0 || echo 1)" "$out"
out=$(rec --ticket jg-r1)
if [ "$(body_of jg-r1 | grep '^Muster: ')" = 'Muster: full - it changes a state machine' ]; then check 'a plain record never undoes a raise' 0 ''; else check 'a plain record never undoes a raise' 1 "$out"; fi
if [ "$(body_of jg-r1 | sed -n 1p)" = '## Captain' ] && body_of jg-r1 | grep -q '^## Acceptance Criteria$'; then check 'the rest of the ticket body is kept' 0 ''
else check 'the rest of the ticket body is kept' 1 "$(body_of jg-r1)"; fi

# the contract fragment keeps the shape of the muster formats (section 6), and one path never both reads and changes
frag=$here/core/agent-cli/contract/muster-depth.json
if jq -e '(.area|type=="string") and (.owner|type=="string") and (.entries|length>0) and all(.entries[];
  (.path|type=="array" and length>0) and (.meaning|type=="string" and length>0) and (.roles|type=="array") and
  (.changes|type=="boolean") and (.method == (if .changes then "POST" else "GET" end)) and
  ((.changes|not) or (.repeat_key|type=="string")) and (.script|startswith("bin/")) and (.operation|type=="string"))' "$frag" >/dev/null; then check 'the fragment passes the shape check' 0 ''
else check 'the fragment passes the shape check' 1 "jq refused $frag"; fi
if jq -e '.owner == "m3" and ([.entries[] | select(.path == ["muster","depth"])] | length == 1 and .[0].changes == false and .[0].method == "GET")
  and ([.entries[] | select(.path == ["muster","depth","record"])] | length == 1 and .[0].changes == true and .[0].method == "POST" and .[0].repeat_key == "ticket")
  and ([.entries[] | .script] | all(. == "bin/jg-muster-depth.sh")) and ([.entries[] | [.script, .operation]] | unique | length == 2)' "$frag" >/dev/null; then check 'the read path and the record path are two entries of this script' 0 ''
else check 'the read path and the record path are two entries of this script' 1 "$(jq -c '.entries[] | [.path, .method, .operation]' "$frag")"; fi
form_ok=0; while IFS=$'\t' read -r op form; do
  [ "$op" = - ] && continue
  case $form in "bin/jg-muster-depth.sh $op "*) ;; *) form_ok=1 ;; esac
done < <(jq -r '.entries[] | [.operation, .form] | @tsv' "$frag")
check 'the record form names its operation word' "$form_ok" "$(jq -c '.entries[] | .form' "$frag")"
[ "$fail" -eq 0 ] && echo "muster depth: ok" || echo "muster depth: FAIL"
exit "$fail"
