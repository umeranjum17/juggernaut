#!/usr/bin/env bash
# jg-goal.sh - declare, show and cancel a Goal: an end state the system works toward until it is live.
#
# Usage: jg-goal.sh declare --ask <text> --repo <repo> [--released <how>] [--where <home or service>]
#                           [--attempts <n>] [--fix-steps <n>] [--priority <0-4>] [--auto-ship] -- <proof argv...>
#        jg-goal.sh show [<goal-id>]
#        jg-goal.sh cancel <goal-id> --reason <text>
#        jg-goal.sh rows
#        jg-goal.sh stop <goal-id> --kind <kind> --reason <text>
#        jg-goal.sh resume <stop-row>
#        jg-goal.sh notice <goal-id> <stop-row>
#        jg-goal.sh released <goal-id> <ref>
#        jg-goal.sh finish <goal-id>
#        jg-goal.sh proof-start <goal-id>
#        jg-goal.sh prove <goal-id>
#        jg-goal.sh proof-failed <goal-id> <exit code or lost>
#        jg-goal.sh start-step <goal-id> <step-row>
#        jg-goal.sh settle-step <goal-id> <step-row>
#
# A Goal is an epic labelled `goal` in this home's tickets tables, reached through
# core/item-store/adapters/bd_compat.py (JG_GOAL_BEADS_BIN names another program for tests), and a row closes through
# `jg-backlog.sh done`, whose note keeps the reason. When the tables refuse,
# their refusal is printed.
#
# declare makes the epic and its five steps, ship, merged, released, running and proven, each blocked by
# the one before. The epic's metadata.goal holds the ask, the finish line (finish.repo, finish.released,
# finish.where and finish.proof, the argv of a read-only command), limits.attempts (default 3) and
# limits.fix_steps (default 5), and a hash of the finish line. The finish line cannot shrink: a changed
# hash is a stop, never a pass. The finish line is also written to data/goals/<id>/finish.json, with the
# proof script copied beside it when the proof names a file.
# declare runs the proof once and refuses a Goal whose proof is missing, already exits 0 (it proves
# nothing), cannot run (exit 126 or 127), or does not end within 30 seconds.
# show prints one Goal's ask, state, steps and open stops, or one line per open Goal.
# rows prints every Goal-labelled row as one JSON list, for core/goal-loop's check (one read, no write).
# stop makes one on_hold row under the Goal, with metadata.hold_kind (owner-must, credential, quota, external
# or limit) and a reason the store insists on. resume closes that row, and that is the whole resume.
# notice and finish are the Goal's only messages, one for each stop row and one for the finish. Each is
# keyed in the epic's metadata (goal:<id>:stop:<row> and goal:<id>:finish) before it is printed, so a restart
# or a second pass prints nothing twice. finish closes the epic. Its claim goes through bin/jg-live-claim.sh.
# released records the version the released step shipped (a tag or a commit), on the epic. finish then claims
# `live: <ref> @ <where>`, so bin/jg-live-claim.sh keeps it only when the home's release record names the ref and its
# services run; with no ref, or a ref it does not know, the message says Landed, not in use.
# proof-start, prove and proof-failed are the check's three steps for the `proven` row. proof-start refuses to
# run when the finish line no longer hashes to finish_hash, in the epic or in data/goals/<id>/finish.json: that
# is an owner-must stop, never a pass (exit 3). prove closes the proven row and keeps the proof log's path; it is
# the only way a Goal reaches its finish. proof-failed keeps the log, reopens the row and adds a `fix` step. The
# same failure (its exit code and the end of its log, digits aside) limits.attempts times running, or
# limits.fix_steps fixes, makes a `limit` stop instead, and no fix step.
# --auto-ship is the owner's word, given at declare, that the Goal's own ship and fix steps may start without a lead:
# it sets metadata.goal.auto_ship, outside the finish line and its hash (it grants a start, it does not shrink the line).
# start-step files the ticket for an open ship or fix row through bin/jg-worker-start.sh (the project is finish.repo;
# the ticket carries the ask, the finish line and, for a fix, the last failed proof's log), takes the row (in_progress,
# metadata.ticket) and prints the ticket. The dispatch check then starts the worker. It refuses a Goal declared without
# --auto-ship, a row that is not an open ship or fix step, and a repeat after a cut run files nothing twice.
# settle-step closes an in-progress ship or fix row whose ticket the trunk lander has landed (data/trunk-landings.tsv,
# the lander's own record); with no landing it changes nothing and exits 4. A merge on a forge is not read here.
# cancel closes the Goal's open rows and the epic on the owner's word. It tears nothing down and sends
# no message, so unlanded work stays under the normal cleanup rules.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
if [ -n "${JG_GOAL_BEADS_BIN:-}" ]; then BEADS=("$JG_GOAL_BEADS_BIN"); else BEADS=(python3 -I "$SCRIPT_DIR/../core/item-store/adapters/bd_compat.py"); fi
STEPS='ship merged released running proven'

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'jg-goal: %s\n' "$*" >&2; exit 2; }

goalstore() { JG_HOME="$JG_HOME" "${BEADS[@]}" "$@"; }
# A row closes through the backlog's done verb, the tables' one close; the reason stays in the row's body as a note.
close_row() { JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-backlog.sh" 'done' "$1" --note "$2" >/dev/null 2>&1; }

# The tables' own refusal is the message: the store has no other way in.
need_store() {
  local out
  out=$(JG_HOME="$JG_HOME" python3 -I "$SCRIPT_DIR/../core/item-store/adapters/tickets.py" check 2>&1) || { printf '%s\n' "$out" >&2; die "the Goal store is not ready"; }
}

sha_of() { { sha256sum || shasum -a 256; } | cut -d' ' -f1; }

# The proof must fail now, run, and end.
proof_check() {  # <argv...>
  local code
  [ "$#" -gt 0 ] || die "declare needs a proof command after --"
  (cd "$JG_HOME" && timeout 30 "$@" >/dev/null 2>&1 < /dev/null)
  code=$?
  case "$code" in
    0) die "the proof already exits 0, so it proves nothing: write a proof that fails until the Goal is live" ;;
    126|127) die "the proof cannot run (exit $code): $1" ;;
    124) die "the proof did not end within 30 seconds: $1" ;;
  esac
}

declare_goal() {
  local ask='' repo='' released=tag where='this home' attempts=3 fix_steps=5 priority=2 auto=false proof=() id step prev n meta finish hash dir made
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ask) ask=${2-}; shift 2 || die "--ask needs a value" ;;
      --repo) repo=${2-}; shift 2 || die "--repo needs a value" ;;
      --released) released=${2-}; shift 2 || die "--released needs a value" ;;
      --where) where=${2-}; shift 2 || die "--where needs a value" ;;
      --attempts) attempts=${2-}; shift 2 || die "--attempts needs a value" ;;
      --fix-steps) fix_steps=${2-}; shift 2 || die "--fix-steps needs a value" ;;
      --priority) priority=${2-}; shift 2 || die "--priority needs a value" ;;
      --auto-ship) auto=true; shift ;;
      --) shift; proof=("$@"); break ;;
      *) die "declare: unknown argument $1" ;;
    esac
  done
  [ -n "$ask" ] || die "declare needs --ask"
  [ -n "$repo" ] || die "declare needs --repo"
  for n in "$attempts" "$fix_steps"; do case "$n" in ''|*[!0-9]*|0) die "limits must be whole numbers above 0" ;; esac; done
  case "$priority" in [0-4]) ;; *) die "--priority is 0 to 4" ;; esac
  proof_check "${proof[@]+"${proof[@]}"}"
  need_store
  finish=$(printf '%s\0' "${proof[@]}" | jq -Rs --arg repo "$repo" --arg released "$released" --arg where "$where" -Sc \
    '{repo:$repo, released:$released, where:$where, proof:(split("\u0000")[:-1])}')
  hash=$(printf '%s' "$finish" | sha_of)
  meta=$(jq -nc --arg ask "$ask" --argjson finish "$finish" --arg hash "$hash" --argjson a "$attempts" --argjson f "$fix_steps" --argjson auto "$auto" \
    '{goal:{ask:$ask, finish:$finish, finish_hash:$hash, auto_ship:$auto, limits:{attempts:$a, fix_steps:$f}}}')
  id=$(goalstore create "Goal: $ask" -t epic --labels goal --priority "$priority" --metadata "$meta" --silent 2>/dev/null) \
    || die "the Goal store did not take the Goal"
  prev='' made=()
  for step in $STEPS; do
    n=$(goalstore create "$step" -t task --parent "$id" --priority "$priority" --metadata "{\"kind\":\"$step\"}" --silent 2>/dev/null) || n=
    [ -z "$n" ] || made+=("$n")
    if [ -n "$n" ] && { [ -z "$prev" ] || goalstore dep add "$n" "$prev" >/dev/null 2>&1; }; then prev=$n
    else  # the steps it made close first: an epic with an open step is never closed
      for n in ${made[@]+"${made[@]}"}; do close_row "$n" "declare failed"; done
      close_row "$id" "declare failed"; die "the Goal store did not take the step $step"; fi
  done
  dir=$DATA/goals/$id
  mkdir -p "$dir" || die "cannot write $dir"
  printf '%s\n' "$finish" > "$dir/finish.json" || die "cannot write $dir"
  [ ! -f "${proof[0]}" ] || cp -- "${proof[0]}" "$dir/proof-script" 2>/dev/null
  printf '%s\n' "$id"
}

show_goal() {
  local id=${1-} json
  need_store
  if [ -z "$id" ]; then
    goalstore list --label goal --type epic --json 2>/dev/null \
      | jq -r '.[] | "\(.id)\t\(.status)\t\(.metadata.goal.ask // .title)"'
    return 0
  fi
  json=$(goalstore show "$id" --json 2>/dev/null | jq -c '.[0] // empty') && [ -n "$json" ] || die "no Goal $id"
  jq -r '.metadata.goal as $g | "goal: \(.id)\nask: \($g.ask)\nstate: \(.status)\nfinish: repo \($g.finish.repo), released \($g.finish.released), where \($g.finish.where)\nproof: \($g.finish.proof | join(" "))"' <<< "$json"
  goalstore list --parent "$id" --all --json 2>/dev/null \
    | jq -r 'sort_by(.id | split(".") | last | tonumber? // 0) | .[] |
        if .status == "on_hold" or .status == "blocked"
        then "stop: \(.id) \(.status) \(.metadata.hold_kind // "") - \(.metadata.hold_reason // "")"
        else "step: \(.id) \(.title) \(.status)" end'
}

rows_goal() { need_store; goalstore list --label goal --all -n 0 --json 2>/dev/null; }

KINDS='owner-must credential quota external limit'

is_goal() { goalstore show "$1" --json 2>/dev/null | jq -e '.[0].labels | index("goal")' >/dev/null; }

stop_goal() {
  local id=${1-} kind='' reason='' row
  [ -n "$id" ] || die "stop needs a Goal id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind) kind=${2-}; shift 2 || die "--kind needs a value" ;;
      --reason) reason=${2-}; shift 2 || die "--reason needs a value" ;;
      *) die "stop: unknown argument $1" ;;
    esac
  done
  case " $KINDS " in *" $kind "*) ;; *) die "stop needs --kind, one of: $KINDS" ;; esac
  [ -n "${reason//[[:space:]]/}" ] || die "stop needs --reason"
  need_store
  is_goal "$id" || die "no Goal $id"
  row=$(goalstore create "stop: $kind" -t task --parent "$id" --silent \
    --metadata "$(jq -nc --arg k "$kind" --arg r "$reason" '{hold_kind:$k, hold_reason:$r}')" 2>/dev/null) || die "the Goal store did not take the stop"
  goalstore update "$row" --status on_hold >/dev/null 2>&1 || { close_row "$row" "stop failed"; die "could not hold $row"; }
  printf '%s\n' "$row"
}

resume_goal() {
  local row=${1-} json
  [ -n "$row" ] || die "resume needs a stop row"
  need_store
  json=$(goalstore show "$row" --json 2>/dev/null | jq -c '.[0] // empty') && [ -n "$json" ] || die "no row $row"
  jq -e '(.status == "on_hold" or .status == "blocked") and (.metadata.hold_reason // "") != ""' <<< "$json" >/dev/null || die "$row is not an open stop"
  close_row "$row" "resumed" || die "could not close $row"
  printf 'resumed %s\n' "$row"
}

# Record a message key on the epic: exit 0 when it is new, 1 when that message already went out.
mark_sent() {  # <goal-id> <key>
  local k="sent_${2//[!A-Za-z0-9]/_}"
  goalstore show "$1" --json 2>/dev/null | jq -e --arg k "$k" '.[0].metadata | has($k)' >/dev/null && return 1
  goalstore update "$1" --set-metadata "$k=$(date +%s)" >/dev/null 2>&1 || die "could not record the message $2"
}

notice_goal() {
  local id=${1-} row=${2-} json action
  [ -n "$id" ] && [ -n "$row" ] || die "notice needs a Goal id and a stop row"
  need_store
  json=$(goalstore show "$row" --json 2>/dev/null | jq -c '.[0] // empty') && [ -n "$json" ] || die "no row $row"
  mark_sent "$id" "goal:$id:stop:$row" || return 0
  case "$(jq -r '.metadata.hold_kind // ""' <<< "$json")" in
    owner-must) action='the owner must decide' ;;
    credential) action='the owner must sign in or act on the account' ;;
    quota) action='no worker has quota; it can resume when one does' ;;
    external) action='it waits on an outside party' ;;
    limit) action='the same failure kept repeating; the owner must change the plan or cancel it' ;;
    *) action='it needs a decision' ;;
  esac
  jq -r --arg id "$id" --arg a "$action" '"\($id) is stopped (\(.metadata.hold_kind // "no kind")): \(.metadata.hold_reason) - \($a); bin/jg-goal.sh resume \(.id) when it is settled"' <<< "$json"
}

finish_goal() {
  local id=${1-} json new=1 ask claim ref
  [ -n "$id" ] || die "finish needs a Goal id"
  need_store
  json=$(goalstore show "$id" --json 2>/dev/null | jq -c '.[0] // empty') && [ -n "$json" ] || die "no Goal $id"
  mark_sent "$id" "goal:$id:finish" || new=0
  close_row "$id" "goal finished" || die "could not close $id"
  [ "$new" = 1 ] || return 0
  ask=$(jq -r '.metadata.goal.ask // .title' <<< "$json")
  ref=$(jq -r '.metadata.released_ref // ""' <<< "$json")
  claim=$(JG_HOME=$JG_HOME "$SCRIPT_DIR/jg-live-claim.sh" "done" "the Goal is done: $ask${ref:+ - Released, $ref; live: $ref @ $(jq -r '.metadata.goal.finish.where // "this home"' <<< "$json")}" 2>/dev/null)
  printf '%s finished - %s (where: %s; proof log: %s)\n' "$id" "${claim:-the Goal is done: $ask}" \
    "$(jq -r '.metadata.goal.finish.where // "this home"' <<< "$json")" "$(jq -r '.metadata.proof_log // "none"' <<< "$json")"
}

released_goal() {
  local id=${1-} ref=${2-}
  [ -n "$id" ] && [ -n "$ref" ] || die "released needs a Goal id and the released ref"
  need_store
  is_goal "$id" || die "no Goal $id"
  goalstore update "$id" --set-metadata "released_ref=$ref" >/dev/null 2>&1 || die "could not record the released ref"
  printf 'released %s: %s\n' "$id" "$ref"
}

goal_json() { goalstore show "$1" --json 2>/dev/null | jq -c '.[0] // empty'; }

step_row() {  # <goal-id> <kind>: the row id of the first step of that kind
  goalstore list --parent "$1" --all --json 2>/dev/null | jq -r --arg k "$2" '[.[] | select(.metadata.kind == $k)] | first | .id // empty'
}

# The finish line as declared: the epic's copy and the copy on disk must both hash to finish_hash.
finish_unchanged() {  # <goal-id> <goal json>
  local want have disk
  want=$(jq -r '.metadata.goal.finish_hash' <<< "$2")
  have=$(jq -Sc '.metadata.goal.finish' <<< "$2" | tr -d '\n' | sha_of)
  disk=$(jq -Sc . "$DATA/goals/$1/finish.json" 2>/dev/null | tr -d '\n' | sha_of)
  [ "$have" = "$want" ] && [ "$disk" = "$want" ]
}

proof_guard() {  # <goal-id> <goal json>: exit 3 after a stop when the finish line changed
  finish_unchanged "$@" && return 0
  stop_goal "$1" --kind owner-must --reason "the finish line changed after it was declared, so the proof is not trusted" > /dev/null
  exit 3
}

proof_start() {
  local id=${1-} json
  [ -n "$id" ] || die "proof-start needs a Goal id"
  need_store
  json=$(goal_json "$id") && [ -n "$json" ] || die "no Goal $id"
  proof_guard "$id" "$json"
  goalstore update "$(step_row "$id" proven)" --status in_progress > /dev/null 2>&1 || die "could not take the proven step"
}

prove_goal() {
  local id=${1-} json log
  [ -n "$id" ] || die "prove needs a Goal id"
  need_store
  json=$(goal_json "$id") && [ -n "$json" ] || die "no Goal $id"
  proof_guard "$id" "$json"
  log=$DATA/goals/$id/proof-$(date +%s).log
  mv -f "$DATA/goals/$id/proof.log" "$log" 2> /dev/null; rm -f "$DATA/goals/$id/proof.exit" "$DATA/goals/$id/proof.pid"
  goalstore update "$id" --set-metadata "proof_log=$log" > /dev/null 2>&1 || die "could not record the proof log"
  close_row "$(step_row "$id" proven)" "the proof passed" || die "could not close the proven step"
}

proof_failed() {
  local id=${1-} code=${2-} json dir log sig runs fixes row
  [ -n "$id" ] && [ -n "$code" ] || die "proof-failed needs a Goal id and an exit code"
  need_store
  json=$(goal_json "$id") && [ -n "$json" ] || die "no Goal $id"
  dir=$DATA/goals/$id
  log=$dir/proof-$(date +%s).log
  mv -f "$dir/proof.log" "$log" 2> /dev/null; rm -f "$dir/proof.exit" "$dir/proof.pid"
  sig="$code-$(tail -n 20 "$log" 2> /dev/null | tr -d '0-9' | cksum | cut -d' ' -f1)"
  runs=1; [ "$(jq -r '.metadata.fail_sig // ""' <<< "$json")" != "$sig" ] || runs=$(($(jq -r '.metadata.fail_runs // 0' <<< "$json") + 1))
  fixes=$(($(jq -r '.metadata.fixes // 0' <<< "$json") + 1))
  goalstore update "$id" --set-metadata "fail_sig=$sig" --set-metadata "fail_runs=$runs" --set-metadata "fixes=$fixes" > /dev/null 2>&1 || die "could not record the failure"
  goalstore update "$(step_row "$id" proven)" --status open > /dev/null 2>&1 || die "could not reopen the proven step"
  if [ "$runs" -ge "$(jq -r '.metadata.goal.limits.attempts' <<< "$json")" ]; then
    stop_goal "$id" --kind limit --reason "the proof failed $runs times running with the same result (exit $code); see $dir" > /dev/null
  elif [ "$fixes" -gt "$(jq -r '.metadata.goal.limits.fix_steps' <<< "$json")" ]; then
    stop_goal "$id" --kind limit --reason "the fix steps limit was reached ($((fixes - 1))); the proof still fails (exit $code); see $dir" > /dev/null
  else
    row=$(goalstore create "fix $fixes" -t task --parent "$id" --metadata '{"kind":"fix"}' --silent 2> /dev/null) || die "could not add the fix step"
    goalstore dep add "$(step_row "$id" proven)" "$row" > /dev/null 2>&1
  fi
}

# A ship or fix row is the Goal's own work: the Goal's owner may let it start by itself (declare --auto-ship).
start_step() {
  local id=${1-} row=${2-} json rj kind title ticket project ask proof last body task spec dir out
  [ -n "$id" ] && [ -n "$row" ] || die "start-step needs a Goal id and a step row"
  need_store
  json=$(goal_json "$id") && [ -n "$json" ] || die "no Goal $id"
  [ "$(jq -r '.metadata.goal.auto_ship // false' <<< "$json")" = true ] || die "$id was not declared with --auto-ship, so no step starts without a lead"
  rj=$(goal_json "$row") && [ -n "$rj" ] || die "no row $row"
  kind=$(jq -r '.metadata.kind // ""' <<< "$rj")
  case "$kind" in ship|fix) ;; *) die "$row is not a ship or fix step" ;; esac
  [ "$(jq -r '.parent // ""' <<< "$rj")" = "$id" ] || die "$row is not a step of $id"
  case "$(jq -r '.status' <<< "$rj")" in open|in_progress) ;; *) die "$row is not open" ;; esac
  project=$(jq -r '.metadata.goal.finish.repo' <<< "$json")
  ask=$(jq -r '.metadata.goal.ask' <<< "$json")
  proof=$(jq -r '.metadata.goal.finish.proof | join(" ")' <<< "$json")
  ticket=$(printf '%s-%s' "$id" "$(jq -r '.title' <<< "$rj")" | tr '[:upper:] .' '[:lower:]--' | tr -c 'a-z0-9\n-' - | sed -E 's/-+/-/g; s/-+$//')
  title="Goal $kind: $(printf '%s' "$ask" | tr -c 'A-Za-z0-9 ' ' ' | awk '{ for (i = 1; i <= 4 && i <= NF; i++) printf "%s%s", (i > 1 ? " " : ""), $i }')"
  dir=$DATA/goals/$id
  last=$(printf '%s\n' "$dir"/proof-*.log | sort | tail -n 1); [ -f "$last" ] || last='' 
  body=$(mktemp "${TMPDIR:-/tmp}/jg-goal-body.XXXXXX") || die "cannot stage the ticket files"
  task=$(mktemp "${TMPDIR:-/tmp}/jg-goal-task.XXXXXX") || { rm -f -- "$body"; die "cannot stage the ticket files"; }
  spec=$(mktemp "${TMPDIR:-/tmp}/jg-goal-spec.XXXXXX") || { rm -f -- "$body" "$task"; die "cannot stage the ticket files"; }
  {
    printf 'Captain: %s\n\nAsk: %s\n\n' "$ask" "$ask"
    printf 'Why: Goal %s is declared with its ship and fix steps allowed to start without a lead; this is its %s step.\n\n' "$id" "$kind"
    printf 'Done when: the Goal proof passes: %s\n\n' "$proof"
    printf 'Acceptance Criteria: the %s step of %s is delivered and the proof above passes once the change runs where the Goal says.\n' "$kind" "$id"
  } > "$body"
  {
    printf '%s\n\nThis is the %s step of Goal %s.\n' "$ask" "$kind" "$id"
    printf 'The Goal is finished when this proof exits 0: %s\n' "$proof"
    [ "$kind" != fix ] || [ -z "$last" ] || printf 'The last proof run failed; its log is %s\n' "$last"
  } > "$task"
  {
    printf 'Build what the ask names, and nothing else, so the Goal proof passes. Stay inside the ask; note any follow-up in your report.\n'
    [ "$kind" != fix ] || printf 'Read the failed proof log named above and fix its cause.\n'
  } > "$spec"
  out=$(JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-worker-start.sh" "$ticket" "$title" "$project" --body-file "$body" --task-file "$task" --spec-file "$spec" 2>&1)
  local rc=$?
  rm -f -- "$body" "$task" "$spec"
  [ "$rc" = 0 ] || die "$(printf '%s' "$out" | tail -n 1)"
  goalstore update "$row" --status in_progress --set-metadata "ticket=$ticket" >/dev/null 2>&1 || die "could not take $row"
  printf 'started %s: ticket %s (%s)\n' "$row" "$ticket" "$out"
}

settle_step() {
  local id=${1-} row=${2-} rj ticket commit
  [ -n "$id" ] && [ -n "$row" ] || die "settle-step needs a Goal id and a step row"
  need_store
  rj=$(goal_json "$row") && [ -n "$rj" ] || die "no row $row"
  [ "$(jq -r '.parent // ""' <<< "$rj")" = "$id" ] && [ "$(jq -r '.status' <<< "$rj")" = in_progress ] || die "$row is not an in-progress step of $id"
  ticket=$(jq -r '.metadata.ticket // ""' <<< "$rj")
  [ -n "$ticket" ] || return 4
  commit=$(awk -F'\t' -v t="$ticket" '$1 == t { c = $3 } END { print c }' "$DATA/trunk-landings.tsv" 2>/dev/null)
  [ -n "$commit" ] || return 4
  close_row "$row" "landed $commit" || die "could not close $row"
  printf 'landed %s: %s on the trunk as %s\n' "$row" "$ticket" "$commit"
}

cancel_goal() {
  local id=${1-} reason='' row
  [ -n "$id" ] || die "cancel needs a Goal id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason=${2-}; shift 2 || die "--reason needs a value" ;;
      *) die "cancel: unknown argument $1" ;;
    esac
  done
  [ -n "$reason" ] || die "cancel needs --reason"
  need_store
  goalstore show "$id" --json 2>/dev/null | jq -e '.[0].labels | index("goal")' >/dev/null || die "no Goal $id"
  while read -r row; do
    [ -z "$row" ] || close_row "$row" "goal cancelled: $reason" || die "could not close $row"
  done < <(goalstore list --parent "$id" --status open,in_progress,blocked,on_hold,deferred --json 2>/dev/null \
    | jq -r 'sort_by(.id | split(".") | last | tonumber? // 0) | .[].id')
  close_row "$id" "goal cancelled: $reason" || die "could not close $id"
  printf 'cancelled %s\n' "$id"
}

case "${1:-}" in
  ''|-h|--help) usage ;;
  declare) shift; declare_goal "$@" ;;
  show) shift; show_goal "$@" ;;
  cancel) shift; cancel_goal "$@" ;;
  rows) rows_goal ;;
  stop) shift; stop_goal "$@" ;;
  resume) shift; resume_goal "$@" ;;
  notice) shift; notice_goal "$@" ;;
  released) shift; released_goal "$@" ;;
  finish) shift; finish_goal "$@" ;;
  proof-start) shift; proof_start "$@" ;;
  prove) shift; prove_goal "$@" ;;
  proof-failed) shift; proof_failed "$@" ;;
  start-step) shift; start_step "$@" ;;
  settle-step) shift; settle_step "$@" ;;
  *) die "unknown verb $1 (declare, show, cancel, rows, stop, resume, notice, finish, proof-start, prove, proof-failed, start-step, settle-step)" ;;
esac
