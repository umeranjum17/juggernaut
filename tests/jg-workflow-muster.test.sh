#!/usr/bin/env bash
# Exercise the real workflow, board, pack verifier and Blitz with scripted fixture workers.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

test_root=$(jg_test_tmproot jg-workflow-muster)
FIXTURE=$ROOT/tests/fixtures/muster-acceptance
WF=$ROOT/bin/jg-workflow.sh
HO=$ROOT/bin/jg-recon-handoff.sh
BOARD=$ROOT/bin/jg-board-answers.sh
BACKLOG=$ROOT/bin/jg-backlog.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")
export ROOT JG_WAR_ROOM_NEXT=1 JG_SWARM_ARM_KICK=0 SIGN_OFF_FILER=muster-test
unset JG_ROOT_OVERRIDE JG_TASK_ID JG_TICKET JG_TASK_INBOX

cat > "$test_root/spawn" <<'SH'
#!/usr/bin/env bash
printf 'kind=scout\n' > "$JG_STATE_OVERRIDE/$1.meta"
SH
cat > "$test_root/gate" <<'SH'
#!/usr/bin/env bash
phase=$("$ROOT/bin/jg-recon-handoff.sh" phase "$1")
[ "$phase" = accepted ] || {
  [ "$phase" = drafted ] &&
    grep -qx 'Recon depth: standard' "$JG_DATA_OVERRIDE/$1/brief.md" &&
    grep -q '^done ' "$JG_STATE_OVERRIDE/$1.status"
}
SH
cat > "$test_root/alert" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JG_HOME/failures"
SH
chmod +x "$test_root/"{spawn,gate,alert}
export JG_WAR_ROOM_SPAWN=$test_root/spawn JG_WAR_ROOM_GATE=$test_root/gate JG_WORKFLOW_ALERT=$test_root/alert

setup() {
  local dir=$test_root/$1
  export JG_HOME=$dir/home JG_DATA_OVERRIDE=$dir/home/data JG_STATE_OVERRIDE=$dir/home/state
  export JG_PROJECTS_OVERRIDE=$dir/home/projects JG_CONFIG_OVERRIDE=$dir/home/config
  export HOME=$dir/user TMPDIR=$dir/temp SIGN_OFF_HOME=$dir/board JG_CAPTAIN_CHANNEL=$dir/channel-off
  export XDG_DATA_HOME=$HOME/.local/share XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.local/state
  mkdir -p "$HOME" "$TMPDIR" "$SIGN_OFF_HOME/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$SIGN_OFF_HOME/.sign-off/decisions.json"
  printf 'leash: matters\n' > "$SIGN_OFF_HOME/.sign-off/config.yaml"
  printf 'set mode off\n' > "$JG_CAPTAIN_CHANNEL"
  jg_test_spawn_home "$JG_HOME"
  jg_git_identity
  printf '%s\n' '- helpdesk [local-trunk +yolo] - the fixture project (added 2026-11-22)' > "$JG_DATA_OVERRIDE/projects.md"
  project=$JG_PROJECTS_OVERRIDE/helpdesk
  mkdir -p "$project"
  cp -R "$ROOT/tests/fixtures/muster/example/helpdesk/." "$project/"
  git -C "$project" init -qb main
  git -C "$project" add -A
  git -C "$project" commit -qm 'Seed help desk'
  jg_test_add "$JG_HOME" jg-wf1 '[feature] Rate a resolved conversation' --repo helpdesk
  printf 'angles: reliability\n' > "$JG_CONFIG_OVERRIDE/workflows"
  "$WF" set jg-wf1 "$2" --order Main1 --subject 'Conversation rating'
}

children() { "${BD[@]}" list --parent "$1" --all --limit 0 --json; }
row() {
  children jg-wf1 | jq -r --arg kind "$1" --arg stage "$2" \
    '.[] | select(.metadata.wf_kind == $kind and .metadata.wf_stage == $stage) | .id'
}
done_lane() { printf 'done [at=%s]: Fixture worker finished.\n' "$(date +%s)" > "$JG_STATE_OVERRIDE/$1.status"; }
worker_finished() {
  local row_id=$1 task=${1//./-}
  printf 'kind=scout\n' > "$JG_STATE_OVERRIDE/$task.meta"
  printf '## 1. Answer (five lines)\n\nThe rating needs a deliberate storage choice.\n' > "$JG_DATA_OVERRIDE/$task/report.md"
  done_lane "$task"
  "$BACKLOG" 'done' "$row_id" --note 'Fixture worker finished' >/dev/null
}
advance() {
  "$WF" advance "$JG_HOME" >> "$JG_HOME/advance.log"
  if [ -s "$JG_HOME/failures" ]; then
    cat "$JG_HOME/failures" "$JG_DATA_OVERRIDE/workflows/"*.log >&2
    fail 'The workflow raised a failure'
  fi
}
wait_file() {
  local i
  for ((i=0; i<180; i++)); do
    [ ! -s "$1" ] || return 0
    advance
    sleep 0.15
  done
  cat "$JG_HOME/advance.log" "$JG_DATA_OVERRIDE/workflows/"*.log >&2
  fail "Workflow did not publish ${1##*/}"
}
draft_worker() {
  local marker=$muster_dir/worker-$1
  wait_file "$marker"
  worker=$(cat "$marker")
  wait_file "$JG_STATE_OVERRIDE/dispatch-approved/$worker"
}

drive_muster() {
  local source=$1 depth=$2 sent_back=${3:-} pack slug=rate-a-conversation question card gate
  draft_worker 1
  if [ -n "$source" ]; then
    assert_contains "$(cat "$JG_DATA_OVERRIDE/${worker//./-}/brief.md")" "$source" 'Muster receives earlier findings'
  fi
  question=$(jq -c '.[3:4]' "$FIXTURE/questions.json")
  jq -n --argjson questions "$question" '{questions:$questions}' > "$muster_dir/reply-1.json"
  worker_finished "$worker"
  wait_file "$muster_dir/round-1-posted"
  card=$(cut -f5 "$JG_DATA_OVERRIDE/$muster/muster/rounds.tsv" | head -1)
  assert_contains "$(cat "$SIGN_OFF_HOME/.sign-off/decisions.json")" "$card" 'the workflow posts the round on the board'
  "$BOARD" route-answer "$card" '2026-11-22T16:00:00Z' a
  # route-answer exercises delivery; close the fixture card as the board UI would.
  sign-off-axi dismiss "$card" --reason done-elsewhere >/dev/null
  draft_worker 2
  pack=$muster_dir/draft
  python3 -I "$FIXTURE/draft.py" "$ROOT" "$pack" "$muster_dir/decisions.md" rated
  if [ "$depth" = light ]; then
    sed '/^## Charter$/,/^## Changelog$/{ /^## Changelog$/!d; }; s/^depth: full$/depth: light/' \
      "$pack/docs/changes/$slug.md" > "$pack/change.tmp"
    mv "$pack/change.tmp" "$pack/docs/changes/$slug.md"
    rm -- "$pack/docs/design/$slug.md"
    mkdir -p "$muster_dir/orders"
    printf '# Store a conversation rating\n\n## Goal\n\nStore one rating on the resolved conversation.\n\n## Acceptance\n\nRun the rating journeys.\n' > "$muster_dir/orders/rating.md"
    awk '/^## Objectives$/{active=1; next} /^## /{active=0} active && /^- .* \(new\)/{print $2}' "$pack/docs/changes/$slug.md" |
      jq -Rs --arg report "$pack/docs/changes/$slug.md" 'split("\n") | map(select(length > 0)) as $journeys |
        {title:"Store a conversation rating", report:$report, intent:"Store a rating.",
         prior_art:"Prior art: none needed - fixture.",
         slices:[{id:"rating",title:"Store a rating",owner_home:"main",project:"helpdesk",size:"S",risk:"Low",
                  files:["src/domain/conversation.ts"],depends_on:[],order:"rating.md",journeys:$journeys}]}' > "$muster_dir/orders/plan.json"
  fi
  "$ROOT/bin/jg-muster-objectives.sh" objectives "$project" --base "$(git -C "$project" rev-parse HEAD)" \
    --draft "$pack" --change "$slug" > "$muster_dir/objectives-2.log"
  jq -n --arg change "$slug" '{ready:true,change:$change}' > "$muster_dir/reply-2.json"
  if [ -n "$sent_back" ]; then
    "$ROOT/bin/jg-muster-drafts.sh" revise helpdesk ways-of-working --note "$sent_back" > /dev/null
    worker_finished "$worker"
    draft_worker 3
    assert_contains "$(cat "$JG_DATA_OVERRIDE/${worker//./-}/brief.md")" "$sent_back" 'a document sent back reaches the next draft round'
    [ ! -f "$JG_DATA_OVERRIDE/$muster/muster/approvals.tsv" ] || fail 'the captain was asked to approve before the revision'
    printf '\nThe lead runs the weekly check.\n' >> "$pack/docs/ways-of-working.md"
    "$ROOT/bin/jg-muster-objectives.sh" objectives "$project" --base "$(git -C "$project" rev-parse HEAD)" \
      --draft "$pack" --change "$slug" > "$muster_dir/objectives-3.log"
    jq -n --arg change "$slug" '{ready:true,change:$change}' > "$muster_dir/reply-3.json"
  fi
  worker_finished "$worker"
  wait_file "$JG_DATA_OVERRIDE/$muster/muster/approvals.tsv"
  gate=$(awk -F '\t' '$2 == "approve" {print $4}' "$JG_DATA_OVERRIDE/$muster/muster/approvals.tsv")
  "$FIXTURE/owner-reply.sh" "$gate" yes
  wait_file "$JG_DATA_OVERRIDE/workflows/$muster.pack"
  sha=$(jq -er .sha "$JG_DATA_OVERRIDE/workflows/$muster.pack")
}

# The ways of working were sent back while the pack was ready: the pack was revised before the captain was asked, and the
# approved document is its second version. Landing copies the approved documents into the project, as Blitz does.
drafts_after_approval() {
  local out
  cp -R "$JG_DATA_OVERRIDE/$muster/muster/pack-$sha/docs/." "$project/docs/"
  out=$("$ROOT/bin/jg-muster-drafts.sh" drafts "$muster")
  assert_contains "$out" 'docs/ways-of-working.md | approved | v2 | +2 -0 since v1' 'the approved document is its second version'
  assert_contains "$("$ROOT/bin/jg-muster-drafts.sh" revise "$muster" ways-of-working --note 'Reopen: the owner changed.')" \
    'docs/ways-of-working.md: approved -> discussion' 'an approved document is reopened with a reason'
}

model_room() {
  local council=$1 child task title assignment target path hash
  [ -s "$JG_DATA_OVERRIDE/war-room/$council/record" ] || return 0
  while IFS=$'\t' read -r child title; do
    task=${child//./-}
    path=$JG_DATA_OVERRIDE/$task
    [ -f "$JG_STATE_OVERRIDE/$task.meta" ] && [ ! -f "$JG_STATE_OVERRIDE/$task.status" ] || continue
    case $title in
      *' critic')
        assignment=$path/assignment.tsv
        [ -s "$assignment" ] || continue
        IFS=$'\t' read -r target _ hash < "$assignment"
        "$HO" verdict "$target" --critic "$task" --hash "$hash" --gaps 0 ;;
      'Muster discovery Recon')
        {
          printf '## Open decisions\n\n### First round\n\n%s\n' '```json'
          jq '.[3:4]' "$FIXTURE/questions.json"
          printf '%s\n' '```'
        } > "$path/report.md"
        "$HO" draft "$task" ;;
      'synthesis Recon')
        assert_contains "$(cat "$path/brief.md")" "Muster manifest SHA: $sha" 'War Room reads the signed pack'
        printf 'The rating should live on its conversation.\n' > "$path/report.md"
        printf '[]\n' > "$path/muster-proposals.json"
        python3 -I "$FIXTURE/build.py" plan "$muster" "$JG_DATA_OVERRIDE/$muster/muster/manifest-$sha.tsv" \
          "$muster_dir/draft/docs/changes/rate-a-conversation.md" "$path/orders/plan.json"
        "$HO" draft "$task" ;;
      *' lens'|*' variant Recon')
        printf 'Reopening must clear the score.\n' > "$path/report.md"
        "$HO" draft "$task" ;;
      'dry run of order 1') printf 'The first slice can start.\n' > "$path/report.md" ;;
      *) fail "Unexpected council child $title" ;;
    esac
    done_lane "$task"
    "$BACKLOG" 'done' "$child" --note 'Fixture worker finished' >/dev/null
  done < <(children "$council" | jq -r '.[] | [.id,.title] | @tsv')
}

drive_room() {
  local council=$1 file=$2 i
  for ((i=0; i<180; i++)); do
    [ ! -s "$file" ] || return 0
    advance
    model_room "$council"
    sleep 0.15
  done
  cat "$JG_HOME/advance.log" "$JG_DATA_OVERRIDE/workflows/$council.next.log" >&2
  fail "War Room did not publish ${file##*/}"
}

drive_blitz() {
  local owner_row=$1 fanout_row=$2 marker values plan_id derived slice
  wait_file "$JG_DATA_OVERRIDE/workflows/$owner_row.start.rc"
  assert_contains "$(cat "$JG_DATA_OVERRIDE/workflows/$owner_row.start.rc")" '0 waits' 'Plan awaits owner approval'
  marker=$(find "$JG_STATE_OVERRIDE/workflow-cards" -type f -print -quit)
  values=$(cut -f6 "$marker")
  if compgen -G "$JG_DATA_OVERRIDE/swarm/*/swarm.json" >/dev/null; then fail 'Blitz ran before plan approval'; fi
  "$BOARD" route-answer "${marker##*/}" '2026-11-22T16:01:00Z' "${values%%,*}" 'Approve'
  wait_file "$JG_DATA_OVERRIDE/workflows/$fanout_row.start.rc"
  assert_contains "$(cat "$JG_DATA_OVERRIDE/workflows/$fanout_row.start.rc")" '0 waits' 'Blitz start completed'
  plan_id=$(find "$JG_DATA_OVERRIDE/swarm" -name swarm.json -print -quit)
  assert_equals running "$(jq -er .state "$plan_id")" 'Blitz reached running'
  derived=${plan_id%/*}/plan.json
  assert_equals "$sha" "$(jq -er .muster.manifest_sha "$derived")" 'Blitz used the signed pack'
  assert_equals "$muster" "$(jq -er .muster.ticket "$derived")" 'Blitz used the right Muster round'
  while IFS= read -r slice; do
    [ -s "$JG_STATE_OVERRIDE/dispatch-approved/$slice" ] || fail "Blitz did not approve $slice"
  done < <(jq -er '.slices[] | select(.depends_on == []) | .row' "$derived")
}

setup discovery-first discovery-first
discovery=$(row war-room 1)
muster=$(row muster 2)
muster_dir=$JG_DATA_OVERRIDE/workflows/$muster.muster
findings=$JG_DATA_OVERRIDE/$discovery/muster/discovery/findings.md
drive_room "$discovery" "$findings"
drive_muster "$findings" full
review=$(row war-room 3)
drive_room "$review" "$JG_DATA_OVERRIDE/war-room/$review/plan-ready"
drive_blitz "$(row owner 4)" "$(row fanout 5)"
pass 'Discovery, full Muster and full War Room start Blitz'

setup muster-only muster-only
muster=$(row muster 1)
muster_dir=$JG_DATA_OVERRIDE/workflows/$muster.muster
drive_muster '' light 'Name who runs the weekly check.'
drafts_after_approval
drive_blitz "$(row owner 2)" "$(row fanout 3)"
pass 'Light Muster starts Blitz by itself'

setup recon-first 'recon(deep) > muster > war-room > blitz'
recon=$(row recon 1)
wait_file "$JG_STATE_OVERRIDE/dispatch-approved/$recon"
worker_finished "$recon"
mkdir -p "$JG_STATE_OVERRIDE/recon-ready"
printf 'Fixture accepted its Recon report.\n' > "$JG_STATE_OVERRIDE/recon-ready/${recon//./-}"
muster=$(row muster 2)
muster_dir=$JG_DATA_OVERRIDE/workflows/$muster.muster
drive_muster "$JG_DATA_OVERRIDE/${recon//./-}/report.md" full
review=$(row war-room 3)
drive_room "$review" "$JG_DATA_OVERRIDE/war-room/$review/plan-ready"
drive_blitz "$(row owner 4)" "$(row fanout 5)"
pass 'Deep Recon, full Muster and fast War Room start Blitz'

setup parallel-muster 'muster(light)*2 > blitz'
mapfile -t parallel_rows < <(row muster 1 | sort)
assert_equals 2 "${#parallel_rows[@]}" 'two configured Muster invocations'
for muster in "${parallel_rows[@]}"; do
  muster_dir=$JG_DATA_OVERRIDE/workflows/$muster.muster
  drive_muster '' light
done
drive_blitz "$(row owner 2)" "$(row fanout 3)"
pass 'Parallel Muster steps start Blitz with the last configured pack'
