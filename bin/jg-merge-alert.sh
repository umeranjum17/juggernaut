#!/usr/bin/env bash
# jg-merge-alert.sh - one board alert for every proven merge, queued durably while the board is down.
#
# Usage: jg-merge-alert.sh post <task-id> --pr <url> [--authority <a>]
#        jg-merge-alert.sh drain
#
# post    Called after a proven PR merge by bin/jg-merge-outcome-lib.sh. No model chooses
#         anything. It files one text-only Evidence card (status Fixed) on the board
#         `jg_board_file` names, with the same sign-off-axi client merge-card files its
#         proof card with:
#           title  Merged: <the PR title>
#           about  project, the PR's full URL, who merged it, who built it with which
#                  model, and the proof card's key (or that the board has none)
#           link   the proof card's deep link, without the board token
#         The key is mergealert-<the merge-card key without merge->, so a repeat is a no-op
#         and the card shares neither merge-card's key nor a PR link its one-card-per-pr
#         sweep reads. The board's notify block pushes a new Evidence card to the phone.
#         Who merged: a Squad Lead's id in a lead home, Main otherwise, "outside Juggernaut"
#         for --authority external; the model is JG_MERGER_MODEL, else the lead's recorded
#         one, else the card says it is not recorded.
#         The alert is written to state/merge-alerts/pending/ before delivery (sent/ after),
#         so a board that is down never blocks the merge. post exits 0 for a valid request.
# drain   Retries every queued alert, at most 20 a run. bin/jg-watch.sh runs it each
#         supervision cycle while state/merge-alerts/pending holds anything.
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export JG_HOME
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
QUEUE="$STATE/merge-alerts"
PENDING="$QUEUE/pending"
SENT="$QUEUE/sent"
FILER=juggernaut-merge-alert
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-timeout-lib.sh
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-parent-channel-lib.sh
. "$SCRIPT_DIR/jg-parent-channel-lib.sh"

die() { printf 'jg-merge-alert: %s\n' "$1" >&2; exit "${2:-1}"; }
say() { printf 'merge alert: %s\n' "${1:0:300}"; }
meta_of() { sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null | tail -n 1; }
now() { date +%s; }

# envelope_set <file> <jq args...>: rewrite a queue file atomically.
envelope_set() {
  local file=$1 tmp
  shift
  tmp=$(umask 077; mktemp "$QUEUE/.tmp.XXXXXX") || return 1
  if jq "$@" "$file" > "$tmp"; then mv -f -- "$tmp" "$file"; else rm -f -- "$tmp"; return 1; fi
}

# merger_of <authority>: "<who>\t<model>" for the agent whose home ran the merge.
merger_of() {
  local authority=$1 lead parent_meta model=${JG_MERGER_MODEL:-}
  if [ "$authority" = external ]; then printf 'outside Juggernaut\t\n'; return 0; fi
  if lead=$(jg_parent_channel_home_id "$JG_HOME"); then
    if [ -z "$model" ] && jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$JG_HOME")" \
      && [ -n "$JG_SQUAD_LEAD_PARENT_HOME" ]; then
      parent_meta="$JG_SQUAD_LEAD_PARENT_HOME/state/$lead.meta"
      model=$(sed -n 's/^model=//p' "$parent_meta" 2>/dev/null | tail -n 1)
    fi
    printf 'Squad Lead %s\t%s\n' "$lead" "$model"
  else
    printf 'Main\t%s\n' "$model"
  fi
}

cmd_post() {
  local id=${1-} pr='' authority='' title='' project proj_path worker_h worker_m key proof_key
  local merger who model outcome repo
  [ -n "$id" ] || die "post needs a task id" 2
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "$1 needs a value" 2
    case "$1" in
      --pr) pr=$2 ;;
      --authority) authority=$2 ;;
      *) die "unknown option $1" 2 ;;
    esac
    shift 2
  done
  jg_pr_task_id_valid "$id" || die "invalid task id" 2
  [ -n "$pr" ] || die "post needs --pr" 2
  command -v jq >/dev/null 2>&1 || { say "skipped for $id: jq is not installed"; return 0; }
  jg_board_file "$JG_HOME" >/dev/null || return 0

  proj_path=$(meta_of "$id" project)
  project=${proj_path##*/}
  jg_pr_url_parse "$pr" || die "invalid PR URL" 2
  pr=$JG_PR_URL
  proof_key=$(jg_board_merge_key "$pr")
  key=mergealert-${proof_key#merge-}
  [ -n "$project" ] || { repo=${JG_PR_PATH%/pull/*}; project=${repo##*/}; }
  title=$(jg_run_timed 15 gh pr view "$pr" --json title --jq .title 2>/dev/null | head -n 1) || title=''
  outcome=${title:-$(printf '%s' "$id" | tr -- '-_' '  ')}
  key=${key:0:128}
  [ ! -e "$SENT/$key.json" ] && [ ! -e "$PENDING/$key.json" ] || { say "$key is already recorded"; return 0; }

  merger=$(merger_of "$authority") || merger=$'Main\t'
  who=${merger%%$'\t'*}
  model=${merger#*$'\t'}
  worker_h=$(meta_of "$id" harness)
  worker_m=$(meta_of "$id" model)
  mkdir -p "$PENDING" "$SENT" || { say "cannot create $QUEUE"; return 0; }
  local env_file
  env_file=$(umask 077; mktemp "$QUEUE/.tmp.XXXXXX") || { say "cannot write $QUEUE"; return 0; }
  jq -n --arg key "$key" --arg task "$id" --arg project "$project" --arg pr "$pr" \
    --arg outcome "$outcome" --arg who "$who" --arg model "$model" --arg wh "$worker_h" --arg wm "$worker_m" \
    --arg proof "$proof_key" --arg authority "$authority" --argjson at "$(now)" '
    {key: $key, task: $task, project: $project, pr: $pr, outcome: $outcome,
     merger: {who: $who, model: $model}, worker: {harness: $wh, model: $wm},
     proof_key: $proof, authority: $authority, queued_at: $at, attempts: 0, last_error: "", reported: false}' > "$env_file"
  mv -f -- "$env_file" "$PENDING/$key.json" 2>/dev/null || { rm -f -- "$env_file"; say "cannot record $key"; return 0; }
  deliver "$PENDING/$key.json" || true
  return 0
}

deliver_fail() {  # <pending-file> <key> <reason>
  # shellcheck disable=SC2016 # jq variables, not shell ones
  envelope_set "$1" --arg e "${3:0:300}" '.attempts += 1 | .last_error = $e' || true
  say "$2 queued, the board is not ready: ${3:0:200}"
}

# deliver <pending-file>: 0 once the alert is on the board and in sent/, else 1 with the reason kept.
deliver() {
  local file=$1 key board cards proof link out card rc=0
  key=$(jq -r .key "$file") || return 1
  board=$(jg_board_file "$JG_HOME") || { deliver_fail "$file" "$key" "no board is configured"; return 1; }
  command -v sign-off-axi >/dev/null 2>&1 || { deliver_fail "$file" "$key" "sign-off-axi is not installed"; return 1; }
  [ -f "$board" ] || { deliver_fail "$file" "$key" "the board file $board does not exist"; return 1; }
  cards=$(jg_run_timed 20 sign-off-axi list "$board" --json --full 2>&1) || { deliver_fail "$file" "$key" "sign-off-axi could not list the board: ${cards//$'\n'/ }"; return 1; }
  if jq -e --arg k "$key" 'any(.decisions[]?; .key == $k)' <<<"$cards" >/dev/null 2>&1; then
    sent_mark "$file"
    say "$key is already on the board"
    return 0
  fi
  # The live proof card: merge-card's key, or that key plus the 13-character suffix of a replaced card.
  proof=$(jq -r --arg k "$(jq -r .proof_key "$file")" '
    [.decisions[]? | select(.dismissed != true)
     | select(.key == $k or (.key | startswith($k + "-") and length == ($k | length) + 13)) | .key][0] // empty' <<<"$cards" 2>/dev/null)
  link=''
  [ -z "$proof" ] || link=$(jg_board_link evidence "$proof" 2>/dev/null | sed 's/?token=[^#]*#/#/')
  card=$(umask 077; mktemp "$QUEUE/.card.XXXXXX") || { deliver_fail "$file" "$key" "cannot stage the card"; return 1; }
  jq --arg proof "$proof" --arg link "$link" --arg filer "$FILER" '
    def clean(max): gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | if length > max then .[:max - 3] + "..." else . end;
    def model(m): if m == "" then "model not recorded" else m end;
    (if .merger.who == "outside Juggernaut" then "Merged outside Juggernaut"
       else "Merged by \(.merger.who) (\(model(.merger.model)))" end) as $by
    | (if .worker.harness == "" and .worker.model == "" then "" else " Built by worker \(.task) (\(.worker.harness) \(model(.worker.model)))." end) as $built
    | {contract: 1, kind: "evidence", schema: 1, key: .key, filer: $filer, status: "Fixed",
       title: ("Merged: \(.outcome)" | clean(160)),
       about: ("Project \(.project). PR \(.pr). \($by).\($built) " + (if $proof != "" then "Proof card: \($proof)." else "No proof card on the board." end) | clean(500))}
    + (if $link != "" then {link: $link} else {} end)' "$file" > "$card" || { rm -f -- "$card"; deliver_fail "$file" "$key" "cannot build the card"; return 1; }
  out=$(jg_run_timed 30 sign-off-axi post "$board" --kind evidence --from "$card" --filer "$FILER" 2>&1) || rc=$?
  rm -f -- "$card"
  [ "$rc" -eq 0 ] || { deliver_fail "$file" "$key" "sign-off-axi post exited $rc: ${out//$'\n'/ }"; return 1; }
  sent_mark "$file"
  say "posted $key"
}

sent_mark() {  # <pending-file>
  local file=$1 base
  base=${file##*/}
  # shellcheck disable=SC2016 # jq variable, not a shell one
  envelope_set "$file" --argjson at "$(now)" '.posted_at = $at' || true
  mv -f -- "$file" "$SENT/$base" || true
}

cmd_drain() {
  local f n=0
  command -v jq >/dev/null 2>&1 || return 0
  for f in "$PENDING"/*.json; do
    [ -f "$f" ] || continue
    n=$((n + 1)); [ "$n" -le 20 ] || break
    deliver "$f" || true
  done
  return 0
}

case "${1:-}" in
  post) shift; cmd_post "$@" ;;
  drain) cmd_drain ;;
  *) die "unknown command: ${1:-}" 2 ;;
esac
