#!/usr/bin/env bash
# jg-owner-asks.sh - the owner's asks, in his words, grouped by what is left.
#
# Usage: jg-owner-asks.sh [--json] [--all-done] [-h|--help]
#
# Prints Needs you / Not done / Done (verified) as plain Simplified Technical English text that
# fits one Telegram message, or the same model as JSON (--json) for the board. It calls no model
# and no network, and it writes nothing.
#
# Source: this home's backlog and the backlog of every registered local Squad Lead home
# (data/squad_leads.md), read through `jg-fleet-snapshot.sh --contribution-input`, the snapshot's
# own backlog reader. The rows kept are every [captain-ask] ticket and every other task held for
# the captain. A remote Squad Lead home is not read; it is named as not read.
# The line for an ask is the owner's quoted words: the ticket body's `Captain:` line, else its
# first line of prose, else the title without its tag. The ticket id stays in the JSON only.
#
# Groups:
#   Needs you      the ticket is held for the owner and the hold is open; the hold reason is
#                  the decision. A hold that waits on other work or on a later date is Not done.
#   Done (verified) the ticket is closed AND the proof is recorded:
#                  - a merged PR that the home's release record carries (data/releases, prs=),
#                    where bin/jg-live-claim.sh says the release is live on this machine; or
#                  - a Recon report that exists, or the owner's own closing words
#                    (data/captain-closures.md), for an ask that ships no code.
#   Not done       everything else; the line gives the one reason it is not live: merged but not
#                  released, PR open, waits on other work, under way, not started, or closed with
#                  no proof recorded.
# A release, PR or proof appears only as that one reason. Done lists JG_OWNER_ASKS_DONE (default 8)
# rows unless --all-done is given; the count always shows the total.
# Environment: JG_HOME, JG_DATA_OVERRIDE, JG_STATE_OVERRIDE, JG_LIVE_SERVICES_BIN (passed to
# jg-live-claim.sh), JG_OWNER_ASKS_TIMEOUT (seconds for one home read, default 20).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-$JG_ROOT}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
TIMEOUT=${JG_OWNER_ASKS_TIMEOUT:-20}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=20 ;; esac
DONE_SHOWN=${JG_OWNER_ASKS_DONE:-8}
case "$DONE_SHOWN" in ''|*[!0-9]*) DONE_SHOWN=8 ;; esac
# shellcheck source=bin/jg-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-tasks-axi-lib.sh
. "$SCRIPT_DIR/jg-tasks-axi-lib.sh"

FORMAT=text
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --all-done) DONE_SHOWN=100000 ;;
    -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: jg-owner-asks.sh [--json] [--all-done]" >&2; exit 2 ;;
  esac
  shift
done
command -v jq >/dev/null 2>&1 || { echo "jg-owner-asks: jq not found" >&2; exit 1; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf -- "$WORK"' EXIT
: > "$WORK/rows.jsonl"
: > "$WORK/unread.jsonl"
declare -A LIVE_CACHE=()

unread() {  # <home id> <reason>
  jq -cn --arg id "$1" --arg reason "$2" '{home:$id,reason:$reason}' >> "$WORK/unread.jsonl"
}

# The release ref that carries PR <n> in <releases file>, or nothing.
release_ref_for_pr() {
  [ -r "$1" ] || return 0
  awk -v n="$2" '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    { for (i = 2; i <= NF; i++) if ($i ~ /^prs=/) {
        v = $i; sub(/^prs=/, "", v); gsub(/#/, "", v); c = split(v, p, ",")
        for (j = 1; j <= c; j++) if (p[j] == n) { print $1; exit }
    } }
  ' "$1"
}

# 0 when jg-live-claim.sh lets "live: <ref>" stand; the verdict is cached per release.
release_is_live() {  # <home path> <ref>
  local key="$1|$2" out
  if [ -z "${LIVE_CACHE[$key]+x}" ]; then
    out=$(JG_RELEASES_FILE="$1/data/releases" JG_STATE_OVERRIDE="$1/state" JG_DATA_OVERRIDE="$1/data" \
      "$SCRIPT_DIR/jg-live-claim.sh" "done" "fixed; live: $2 @ the running stack" 2>/dev/null)
    case "$out" in 'merged-not-released'*|'') LIVE_CACHE[$key]=no ;; *) LIVE_CACHE[$key]=yes ;; esac
  fi
  [ "${LIVE_CACHE[$key]}" = yes ]
}

read_home() {  # <home id> <home path>
  local id=$1 path=$2 snap cands row url n ref live_ref='' blocked_ref='' report ok closure
  jg_backlog_present "$path/config" "$path/data/backlog.md" || { unread "$id" "no backlog in this home"; return 0; }
  if ! snap=$(JG_HOME="$path" JG_DATA_OVERRIDE="$path/data" JG_STATE_OVERRIDE="$path/state" JG_CONFIG_OVERRIDE="$path/config" \
      jg_run_timed "$TIMEOUT" "$SCRIPT_DIR/jg-fleet-snapshot.sh" --contribution-input 2>/dev/null); then
    unread "$id" "the backlog read failed"; return 0
  fi
  # shellcheck disable=SC2016  # jq program text
  cands=$(jq -c '
    def clean: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def system_line: test("^(Captain hold set|Captain hold origin|Resolution recorded|Why|Ask|Done when|Closed on|Hold):?"; "i");
    def words:
      ((.body_lines // []) as $b
       | ([$b[] | select(test("^Captain:[[:space:]]*"; "i")) | sub("^Captain:[[:space:]]*"; ""; "i")] | first) as $cap
       | ([$b[] | select(system_line | not)] | first) as $prose
       | ($cap // $prose // (.title | sub("^\\[captain-ask\\][[:space:]]*"; "")))
       | gsub("^[\"“”]+|[\"“”]+$"; "") | clean | .[0:200]);
    [ .backlog.records[]?
      | select(.structured == true)
      | (((.title // "") | contains("[captain-ask]"))) as $ask
      | select($ask or (.hold_kind == "captain" and .hold_reason != null and .state != "done"))
      | { id, state, ask: $ask, words: words,
          hold: (if .hold_kind == "captain" and .hold_reason != null and .state != "done"
                 then {reason: (.hold_reason | clean | .[0:240]), bucket: .hold_bucket, until: .hold_until} else null end),
          waits_on: (.unresolved_blocker_ids // []),
          prs: [ (.links // [])[] | select(test("/pull/[0-9]+")) ],
          merged: (.merged != null),
          report_path: .report_path } ]' <<<"$snap" 2>/dev/null) || { unread "$id" "the backlog could not be read"; return 0; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    live_ref='' blocked_ref=''
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      n=${url##*/pull/}; n=${n%%[!0-9]*}
      ref=$(release_ref_for_pr "$path/data/releases" "$n")
      [ -n "$ref" ] || continue
      if release_is_live "$path" "$ref"; then live_ref=$ref; break; else blocked_ref=$ref; fi
    done < <(jq -r '.prs[]' <<<"$row")
    report=$(jq -r '.report_path // ""' <<<"$row")
    ok=false
    [ -z "$report" ] || [ ! -s "$path/$report" ] || ok=true
    closure=false
    if [ -f "$path/data/captain-closures.md" ] \
      && awk -F'\t' -v id="$(jq -r .id <<<"$row")" '$2 == id { f = 1 } END { exit f ? 0 : 1 }' "$path/data/captain-closures.md"; then closure=true; fi
    jq -c --arg home "$id" --arg live "$live_ref" --arg blocked "$blocked_ref" \
      --argjson report "$ok" --argjson closure "$closure" \
      '. + {home: $home, live_ref: (if $live == "" then null else $live end),
            released_not_live: (if $blocked == "" then null else $blocked end),
            report_ok: $report, closure: $closure}' <<<"$row" >> "$WORK/rows.jsonl"
  done < <(jq -c '.[]' <<<"$cands")
}

# The main home first, then each registered Squad Lead home.
read_home main "$JG_HOME"
if [ -f "$DATA/squad_leads.md" ] && [ ! -L "$DATA/squad_leads.md" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    squad_lead_registry_parse_line "$line" || continue
    if [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 1 ]; then
      unread "$SQUAD_LEAD_REGISTRY_ID" "a remote home is not read here"; continue
    fi
    case "$SQUAD_LEAD_REGISTRY_HOME" in /*) ;; *) unread "$SQUAD_LEAD_REGISTRY_ID" "its home path is not absolute"; continue ;; esac
    read_home "$SQUAD_LEAD_REGISTRY_ID" "$SQUAD_LEAD_REGISTRY_HOME"
  done < "$DATA/squad_leads.md"
fi

# shellcheck disable=SC2016  # jq program text
MODEL='
  def reason($r):
    if $r.state == "done" then
      (if $r.released_not_live != null then "released, but the release is not running yet"
       elif ($r.prs | length) > 0 or $r.merged then "merged, not released"
       else "closed, but no proof is recorded" end)
    elif ($r.waits_on | length) > 0 then "waits on other work first"
    elif ($r.prs | length) > 0 then "PR is open: " + $r.prs[0]
    elif $r.state == "in_flight" then "work is under way"
    else "work has not started" end;
  . as $rows
  | [ $rows[]
      | if .state == "done" and .live_ref != null then
          {group: "done", proof: ("live in " + .live_ref)}
        elif .state == "done" and .live_ref == null and (.prs | length) == 0 and (.merged | not) and (.report_ok or .closure) then
          {group: "done", proof: (if .report_ok then "report delivered" else "you closed it" end)}
        elif .state != "done" and .hold != null and (.hold.bucket == "live" or .hold.bucket == "aged") then
          {group: "needs_you", decision: .hold.reason}
        elif .state != "done" and .hold != null and .hold.bucket == "dated" then
          {group: "not_done", reason: ("you deferred it to " + (.hold.until // "a later date"))}
        elif .state != "done" and .hold != null and .hold.bucket == "blocked" then
          {group: "not_done", reason: "waits on other work first"}
        else {group: "not_done", reason: reason(.)} end
        + {id, home, words, ask} ] as $all
  | { done: [$all[] | select(.group == "done")],
      not_done: [$all[] | select(.group == "not_done")],
      needs_you: [$all[] | select(.group == "needs_you")] }'

# $rows is a stream of objects; slurp it so the model sees one array.
if ! jq -s "$MODEL" "$WORK/rows.jsonl" > "$WORK/model.json" 2>"$WORK/err"; then
  echo "jg-owner-asks: the model could not be built: $(head -1 "$WORK/err")" >&2; exit 1
fi
jq -s '.' "$WORK/unread.jsonl" > "$WORK/unread.json"

# shellcheck disable=SC2016  # jq program text
OUT='
  def counts: {done: (.done | length), not_done: (.not_done | length), needs_you: (.needs_you | length)};
  . + {not_read: $unread[0], counts: counts, done_shown: ($shown | tonumber)}
  | .done |= .[0:($shown | tonumber)]'
if [ "$FORMAT" = json ]; then
  jq --slurpfile unread "$WORK/unread.json" --arg shown "$DONE_SHOWN" "$OUT" "$WORK/model.json"
  exit $?
fi
jq -r --slurpfile unread "$WORK/unread.json" --arg shown "$DONE_SHOWN" "$OUT"'
  | def line($t): "- " + $t;
  "Your asks, in your words.",
  "",
  "Needs you (\(.counts.needs_you))",
  (if .counts.needs_you == 0 then "- none" else (.needs_you[] | line(.words), "  Decision: " + .decision) end),
  "",
  "Not done (\(.counts.not_done))",
  (if .counts.not_done == 0 then "- none" else (.not_done[] | line(.words), "  Why: " + .reason) end),
  "",
  (if .counts.done > (.done | length) then "Done, verified (\(.done | length) of \(.counts.done) shown)"
   else "Done, verified (\(.counts.done))" end),
  (if .counts.done == 0 then "- none" else (.done[] | line(.words), "  Proof: " + .proof) end),
  (if (.not_read | length) > 0 then "", "Not read: " + ([.not_read[] | .home + " (" + .reason + ")"] | join(", ")) else empty end)
' "$WORK/model.json"
