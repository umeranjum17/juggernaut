#!/usr/bin/env bash
# jg-ask-record.sh - the measurement record of one ask: what it cost and where it went, joined from the records this home keeps.
#
# Usage: jg-ask-record.sh show <ticket>     print the ask's record as one JSON object
#        jg-ask-record.sh turns <task>      count a finished worker's model turns and keep them (data/ask-turns.tsv)
#        jg-ask-record.sh observe <ticket> <home> <version> <pass|fail> <what was seen>
#                                           keep one behaviour observation of the ask's change running in a home (data/ask-observations.tsv)
# `show` only reads. Nothing is joined by hand: the ticket's moments, its landing, proof and verify runs, each home's install rows and
# the release are found by the ticket, its task and the commit it landed, through git ancestry for every run or row that covers it.
#
# Record fields (a field no record shows is null or empty, named in `missing`, and never guessed):
#   ticket, task, project, commit (12), requested_at, started_at, ready_at, landed_at, in_use_at, released_at (epoch seconds)
#   ask_to_in_use_min, ready_to_in_use_min     from those moments; in_use_at is the ticket's live moment (never one a later pin-back
#                       undid), else the first `live` install row that covers the commit
#   model_turns         the worker's model calls, the latest `turns` row of the task; `unrecorded` lists the turns nobody counts
#   machine_minutes     {sealed, verify, landing, total}: sealed done-done runs of the task, the verify runs of the candidate's own proof
#                       (the earliest verify that covers the commit, and every rerun at that same tip), and the lander's own gate and landing seconds (queue waiting is not machine time)
#   run_ids             {sealed: [...], receipt, landing, verify: [...], install: ["<home>@<commit12>@<epoch>"], release: <pull request>}
#   homes               one row per install row that covers the commit: home, commit, at, status, waiver, verdict, behavior, previous
#                       (behavior is the latest observation of that home at that version, else the `behavior=` word of the row, else
#                       `unobserved`; `seen` is what the observer wrote)
#   proofs_per_candidate  the verify runs of the candidate's own proof, as counted above; more than 1 is a rerun
# Sources: `jg-backlog.sh times --json` (the ticket), data/trunk-landings.tsv, trunk-landing-proofs.tsv, trunk-verify.tsv, trunk-in-use.tsv,
# trunk-releases.tsv, data/<task>/.done-done/runs/*.json, data/ask-turns.tsv, data/ask-observations.tsv, and the project clone for ancestry.
# Env: JG_HOME, JG_DATA_OVERRIDE, JG_STATE_OVERRIDE, JG_ASK_BACKLOG (the backlog command, default bin/jg-backlog.sh beside this script).
# `turns` reads the Claude transcripts of the task's worker (state/<task>.meta: account, worktree, harness) written since its spawn, and
# counts distinct model responses; another harness writes nothing and says so. The delivery tick calls it when a lane reports done.
# Needs git and jq. Exit: 0 printed, 1 no such ask or nothing to count, 64 usage.
set -u
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
BACKLOG=${JG_ASK_BACKLOG:-$SCRIPT_DIR/jg-backlog.sh}
TURNS=$DATA/ask-turns.tsv OBS=$DATA/ask-observations.tsv

usage() { echo "usage: jg-ask-record.sh show <ticket> | turns <task> | observe <ticket> <home> <version> <pass|fail> <what was seen>" >&2; exit 64; }
die() { echo "jg-ask-record: $*" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then echo 'jg-ask-record: needs git and jq' >&2; exit 2; fi
ep() { [ -n "${1:-}" ] && date -u -d "$1" +%s 2>/dev/null || true; }   # a moment as epoch seconds, empty when absent or unreadable
meta_of() { sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | tail -n 1; }

turns() {  # <task>
  local task=$1 ticket harness account wt dir spawn n f
  [ -f "$STATE/$task.meta" ] || die "no task record for $task"
  ticket=$(meta_of "$task" ticket); harness=$(meta_of "$task" harness); wt=$(meta_of "$task" worktree)
  [ -n "$ticket" ] || die "$task has no ticket, so its turns belong to no ask"
  [ "$harness" = claude ] || die "unrecorded: no turn counter for the $harness harness"
  account=$(meta_of "$task" account); account=${account:-$HOME/.claude}
  dir=$account/projects/$(printf '%s' "$wt" | sed 's#[/.]#-#g')
  spawn=$(cut -f1 "$STATE/$task.models" 2>/dev/null | head -n 1)
  [ -d "$dir" ] || die "no transcript directory for $task"
  n=$(for f in "$dir"/*.jsonl; do [ -f "$f" ] && [ "$(stat -c %Y "$f")" -ge "${spawn:-0}" ] && cat "$f"; done 2>/dev/null \
    | jq -r 'select(.type == "assistant") | .message.id // empty' 2>/dev/null | sort -u | grep -c .)
  [ "${n:-0}" -gt 0 ] || die "no model turns found for $task"
  mkdir -p "$DATA" && printf '%s\t%s\t%s\t%s\t%s\ttranscript\n' "$(date +%s)" "$ticket" "$task" "$harness" "$n" >> "$TURNS"
}

observe() {  # <ticket> <home> <version> <pass|fail> <what was seen>
  case $4 in pass|fail) ;; *) usage ;; esac
  [ -n "$5" ] || usage
  mkdir -p "$DATA" && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "${3:0:12}" "$4" "$(printf '%s' "$5" | tr '\t\n' '  ')" >> "$OBS"
}

show() {  # <ticket>
  local ticket=$1 row task project commit landed_ep repo proofs landing_s gate_s
  row=$(JG_HOME=$JG_HOME JG_DATA_OVERRIDE=$DATA bash "$BACKLOG" times --json 2>/dev/null | jq -c --arg t "$ticket" 'map(select(.ticket == $t)) | first // empty') \
    || die "cannot read the ticket moments"
  [ -n "$row" ] || die "no recorded moments for ask $ticket"
  task=$(jq -r '.task' <<< "$row"); project=$(jq -r '.project' <<< "$row"); repo=$JG_HOME/projects/$project
  covers() { git -C "$repo" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }   # <landed> <later commit>

  # landing: the task's last row of trunk-landings.tsv, and the receipt its proofs row records
  commit=; landed_ep=
  if [ -r "$DATA/trunk-landings.tsv" ]; then
    IFS=$'\t' read -r commit landed_ep < <(awk -F'\t' -v t="$task" -v p="$project" '$1 == t && $2 == p && $5 !~ /^reverts-/ { c = $3; e = $4 } END { if (c != "") print c "\t" e }' "$DATA/trunk-landings.tsv")
  fi
  proofs=$(awk -F'\t' -v t="$task" -v c="${commit:-none}" '$1 == t && $3 == c { for (i = 5; i <= NF; i++) if ($i ~ /^receipt=/) r = $i } END { print r }' "$DATA/trunk-landing-proofs.tsv" 2>/dev/null)
  landing_s=0; gate_s=0
  if [ -n "$commit" ]; then
    IFS=$'\t' read -r landing_s gate_s < <(JG_HOME=$JG_HOME JG_DATA_OVERRIDE=$DATA bash "$BACKLOG" trace landing "$task" "$commit" 2>/dev/null \
      | cut -f3 | jq -r '[(.landing_s // 0), (.gate_s // 0)] | @tsv' 2>/dev/null) || :
  fi

  # sealed done-done runs of the task: one object each, minutes from the run's own start and end
  local sealed='[]' f
  for f in "$DATA/$task"/.done-done/runs/*.json; do
    [ -f "$f" ] || continue
    sealed=$(jq -c --slurpfile r "$f" '. + [$r[0] | {run: .run_id, commit: .commit[:12], exit: .exit, minutes: ((((.ended_at | sub("\\.[0-9]+"; "") | fromdateiso8601) - (.started_at | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 60) * 10 | round / 10)}]' <<< "$sealed")
  done

  # verify runs, in-use rows and the release that cover the landed commit
  local verify='[]' homes='[]' release=null c e rest run res secs home status prev
  if [ -n "$commit" ]; then
    while IFS=$'\t' read -r _ e run c res secs _; do
      covers "$commit" "$c" && verify=$(jq -c --arg run "$run" --arg c "$c" --arg res "$res" --argjson e "${e:-0}" --argjson s "${secs:-0}" '. + [{run: $run, commit: $c, result: $res, at: $e, seconds: $s}]' <<< "$verify")
    done < <(awk -F'\t' -v p="$project" '$1 == p' "$DATA/trunk-verify.tsv" 2>/dev/null)
    # the candidate's own proof: the earliest verify that covers the commit, and every run at that same tip (a rerun counts)
    verify=$(jq -c 'if length == 0 then . else (min_by(.at).commit) as $t | map(select(.commit == $t)) end' <<< "$verify")
    while IFS=$'\t' read -r home c e status prev; do
      covers "$commit" "$c" || continue
      home=${home#*:}; [ "$home" != "$project" ] || home=$project
      homes=$(jq -c --arg h "$home" --arg c "${c:0:12}" --argjson e "${e:-0}" --arg st "$status" --arg pv "${prev:0:12}" '
        . + [{home: $h, commit: $c, at: $e, status: ($st | split(",")[0]),
              waiver: (($st | split(",") | map(select(startswith("waiver=")) | .[7:]) | first) // null),
              verdict: (($st | split(",") | map(select(startswith("verdict=")) | .[8:]) | first) // null),
              behavior: (($st | split(",") | map(select(startswith("behavior=")) | .[9:]) | first) // "unobserved"),
              previous: (if $pv == "" then null else $pv end)}]' <<< "$homes")
    done < <(awk -F'\t' -v p="$project" '$1 == p || index($1, p ":") == 1' "$DATA/trunk-in-use.tsv" 2>/dev/null | sort -t$'\t' -k3,3n)
    while IFS=$'\t' read -r _ _ c _ _ rest; do
      [ -n "${rest:-}" ] || continue
      covers "$commit" "$c" && { release=$(jq -Rn --arg u "$rest" '$u'); break; }
    done < <(awk -F'\t' -v p="$project" 'NF >= 6 && $1 == p { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' "$DATA/trunk-releases.tsv" 2>/dev/null | sort -t$'\t' -k5,5n)
  fi

  # behaviour observations of this ask: the latest row of each home and version wins
  local obs
  obs=$(awk -F'\t' -v t="$ticket" '$2 == t' "$OBS" 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")) | map({home: .[2], commit: .[3], at: (.[0] | tonumber), result: .[4], seen: .[5]}) | sort_by(.at)')
  homes=$(jq -c --argjson obs "${obs:-[]}" 'map(. as $h | ($obs | map(select(.home == $h.home and .commit == $h.commit)) | last) as $o
    | if $o then . + {behavior: $o.result, seen: $o.seen, observed_at: $o.at} else . + {seen: null, observed_at: null} end)' <<< "$homes")
  local turns_n
  turns_n=$(awk -F'\t' -v t="$task" '$3 == t { n = $5 } END { print n }' "$TURNS" 2>/dev/null)

  jq -n --argjson row "$row" --arg commit "${commit:0:12}" --arg landed_ep "$landed_ep" --arg receipt "${proofs#receipt=}" \
    --argjson sealed "$sealed" --argjson verify "$verify" --argjson homes "$homes" --argjson release "$release" \
    --arg turns "${turns_n:-}" --argjson landing_s "${landing_s:-0}" --argjson gate_s "${gate_s:-0}" \
    --arg req "$(ep "$(jq -r '.requested_at // ""' <<< "$row")")" --arg st "$(ep "$(jq -r '.started' <<< "$row")")" \
    --arg rd "$(ep "$(jq -r '.ready_at' <<< "$row")")" --arg ld "$(ep "$(jq -r '.landed_at' <<< "$row")")" \
    --arg lv "$(ep "$(jq -r '.live_at' <<< "$row")")" --arg pb "$(ep "$(jq -r '.pinned_back_at' <<< "$row")")" \
    --arg rl "$(ep "$(jq -r '.released_at' <<< "$row")")" '
    def n: if . == "" then null else tonumber end;
    def mins: if . == null then null else (. * 10 | round) / 10 end;
    ($lv | n) as $live_raw | ($pb | n) as $pinned
    | ($homes | map(select(.status == "live") | .at) | min) as $first_live
    | (if $live_raw != null and ($pinned == null or $pinned < $live_raw) then $live_raw else $first_live end) as $live
    | ($req | n) as $requested | ($rd | n) as $ready
    | ($sealed | map(.minutes) | add // 0) as $m_sealed | ($verify | map(.seconds) | add // 0) as $v_s
    | {ticket: $row.ticket, task: $row.task, project: $row.project, commit: (if $commit == "" then null else $commit end),
       requested_at: $requested, started_at: ($st | n), ready_at: $ready, landed_at: ($ld | n), in_use_at: $live, released_at: ($rl | n),
       ask_to_in_use_min: (if $live != null and $requested != null then ($live - $requested) / 60 | mins else null end),
       ready_to_in_use_min: (if $live != null and $ready != null then ($live - $ready) / 60 | mins else null end),
       model_turns: ($turns | n), unrecorded: ["supervisor and lead model turns"],
       machine_minutes: {sealed: ($m_sealed | mins), verify: ($v_s / 60 | mins), landing: (($landing_s + $gate_s) / 60 | mins),
                         total: (($m_sealed + $v_s / 60 + ($landing_s + $gate_s) / 60) | mins)},
       proofs_per_candidate: ($verify | length),
       run_ids: {sealed: ($sealed | map(.run)), receipt: (if $receipt == "" then null else $receipt end),
                 landing: (if $commit == "" then null else ($row.task + "@" + $commit) end), verify: ($verify | map(.run)),
                 install: ($homes | map(.home + "@" + .commit + "@" + (.at | tostring))), release: $release},
       homes: $homes}
    | . + {missing: ([ (select(.requested_at == null) | "requested_at"), (select(.ready_at == null) | "ready_at"),
                       (select(.commit == null) | "landing"), (select(.model_turns == null) | "model_turns"),
                       (select(.run_ids.sealed == []) | "sealed_runs"), (select(.run_ids.verify == []) | "verify_runs"),
                       (select(.in_use_at == null) | "in_use_at"), (select(.homes == []) | "homes"),
                       (select(.run_ids.release == null) | "release"),
                       (.homes[] | select(.behavior == "unobserved") | "behavior:" + .home) ] | unique)}'
}

case ${1-} in
  observe) [ $# -ge 6 ] || usage; observe "$2" "$3" "$4" "$5" "${*:6}" ;;
  show) [ $# -eq 2 ] || usage; show "$2" ;;
  turns) [ $# -eq 2 ] || usage; turns "$2" ;;
  *) usage ;;
esac
