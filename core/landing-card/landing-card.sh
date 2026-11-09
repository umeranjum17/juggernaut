#!/usr/bin/env bash
# landing-card watcher check: every landed commit of this home has exactly one Evidence card on the board, never skipped,
# and every go-live batch has one more.
# Usage: landing-card.sh check <jg-home>   (silent unless a card could not be posted)
#        landing-card.sh run   <jg-home>   (the same, and prints `landing-card: posted N, M already on the board`)
#        landing-card.sh summary <jg-home> <YYYY-MM-DD>   (one card for a UTC day's landings; a one-off backfill, never part of check)
#
# A landing card is a fact sheet of records the lander already wrote, not a judge: data/trunk-landings.tsv (lane, project,
# commit, epoch, gate kind), data/trunk-landing-proofs.tsv (receipt, signature, merge-card) and, when it exists, the
# done-done verdict in data/<lane>/merge-card.json. A missing piece is written as "not checked"; it never skips the card.
# The title is the lane's name (a commit subject is too long for a phone row) and the about starts with the commit subject.
# The card has the key `landing-<commit>` and is posted once: a commit whose key is already on the board, live or archived,
# is left alone, so a second run posts nothing. The status pill is "In progress" because a landing is on the trunk, not yet
# live. Cards go one at a time through sign-off-axi, which holds the board's own lock; a failed post stops the run (one line,
# the rest wait for the next beat) instead of queueing behind a busy board.
# A go-live card (key `live-<commit>`, status "In progress": live in the homes is not proof the change is in use) is posted for each `live*` row of data/trunk-live.tsv that names the project
# itself, not one home (`<project>:<home>` rows only give the count of homes that moved). It lists the landings since the previous
# live commit (the landed commits that the new commit holds and the previous one does not) and the delivery word of each of them
# that core/machines/changes.tsv registers, read only through `jg-machine.sh show delivery`; a lane the registry does not name
# gets no word, so a card never says "in use" without the machine's proof. A go-live row whose commit is not in the clone still
# gets its card, with no lanes listed.
# The summary card (key `landings-<day>`) counts one UTC day's landings by gate kind and how many are live now; a sign-off card
# cannot change once posted, so it says "as of" its time and the per-landing and go-live cards carry the detail.
# The board is the one merge cards use (jg_board_file). JG_LANDING_CARD_SIGNOFF names the sign-off-axi command (tests).
set -u
case ${1:-} in check|run|summary) MODE=$1 ;; *) MODE='' ;; esac
DAY=${3:-}
case $MODE:$# in check:2|run:2) ;; summary:3) [[ $DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || MODE='' ;; *) MODE='' ;; esac
[ -n "$MODE" ] && [ -d "$2/state" ] || { echo "usage: landing-card.sh check|run <jg-home> | summary <jg-home> <YYYY-MM-DD>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
DATA=$FMH/data
SIGNOFF=${JG_LANDING_CARD_SIGNOFF:-sign-off-axi}
# shellcheck source=bin/jg-board-link-lib.sh
. "$FMH/bin/jg-board-link-lib.sh"
command -v jq >/dev/null 2>&1 || exit 0
command -v "$SIGNOFF" >/dev/null 2>&1 || exit 0
BOARD=$(jg_board_file "$FMH") || exit 0
[ -s "$DATA/trunk-landings.tsv" ] || { [ "$MODE" = check ] || echo 'landing-card: posted 0, 0 already on the board'; exit 0; }

# gate_words <kind>: what the gate kind means, in plain words.
gate_words() {
  case $1 in
    full) echo 'All required tests passed.' ;;
    full-rerun) echo 'Required tests passed after one rerun of a flaky failure.' ;;
    full-tip-red) echo 'Required tests failed only where the trunk already failed; not charged to this lane.' ;;
    no-gate) echo 'This project has no landing gate; no tests ran.' ;;
    reverts-*) echo "Revert of ${1#reverts-}." ;;
    *) echo "Gate: $1." ;;
  esac
}

# proof_field <proofs row> <name>: the value of one name=value column of trunk-landing-proofs.tsv, else absent.
proof_field() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -n 1 | grep . || echo absent; }

# card_json <lane> <project> <commit> <epoch> <gate kind>: the evidence card for one landing, on stdout.
card_json() {
  local id=$1 proj=$2 commit=$3 at=$4 kind=$5 subject title proofs verdict='not checked' when
  subject=$(git -C "$FMH/projects/$proj" log -1 --format=%s "$commit" 2>/dev/null) || subject=
  [ -n "$subject" ] || subject='The commit is not in the local copy'
  case $kind in reverts-*) title="Reverted: ${id#revert-}" ;; *) title="Landed: $id" ;; esac
  proofs=$(awk -F'\t' -v c="$commit" '$3 == c { l = $0 } END { print l }' "$DATA/trunk-landing-proofs.tsv" 2>/dev/null)
  [ "$(proof_field "$proofs" merge-card)" != present ] || verdict=$(jq -r '.verdict // "not checked"' "$DATA/$id/merge-card.json" 2>/dev/null | cut -c1-80)
  when=$(date -u -d "@$at" '+%Y-%m-%d %H:%M UTC' 2>/dev/null) || when=$at
  jq -n --arg key "landing-$commit" --arg commit "$commit" --arg title "$title" \
    --arg about "$(printf '%s. Landed on the %s trunk at %s, not live yet. %s Test receipt: %s. Owner signature: %s. Done-done verdict: %s.' \
      "${subject:0:200}" "$proj" "$when" "$(gate_words "$kind")" "$(proof_field "$proofs" receipt)" "$(proof_field "$proofs" signature)" "$verdict")" '
    def clean(max): gsub("[\u0000-\u0009\u000b-\u001f\u007f-\u009f]"; " ") | if length > max then .[:max - 3] + "..." else . end;
    {contract: 1, kind: "evidence", schema: 1, key: $key, title: ($title | clean(160)), about: ($about | clean(500)), link: $commit, status: "In progress"}'
}

# live_json <project> <commit> <epoch> <status> <previous live commit or empty>: the card for one go-live, on stdout.
live_json() {
  local proj=$1 commit=$2 at=$3 status=$4 prev=$5 count repo="$FMH/projects/$1" lane lanes='' n=0 more='' words='' w homes note='' when
  while IFS=$'\t' read -r lane c; do
    git -C "$repo" merge-base --is-ancestor "$c" "$commit" 2>/dev/null || continue
    [ -z "$prev" ] || ! git -C "$repo" merge-base --is-ancestor "$c" "$prev" 2>/dev/null || continue
    n=$((n + 1))
    if [ "$n" -le 8 ]; then lanes="$lanes${lanes:+, }$lane"; else more=" and $((n - 8)) more"; fi
    w=$(JG_HOME=$FMH "$FMH/bin/jg-machine.sh" show delivery "$lane" 2>/dev/null | awk -F'\t' '$1 == "state" { print $2 }')
    [ -z "$w" ] || words="$words${words:+, }$lane is $w"
  done < <(awk -F'\t' -v p="$proj" '$2 == p { print $1 "\t" $3 }' "$DATA/trunk-landings.tsv")
  homes=$(awk -F'\t' -v p="$proj:" -v s="$commit" 'index($1, p) == 1 && $2 == s && $4 ~ /^live/ { h[$1] = 1 } END { print length(h) }' "$DATA/trunk-live.tsv")
  case $status in *pinned-behind-*) note=" A red check pinned this go-live behind the trunk tip $(printf '%s' "${status##*pinned-behind-}" | cut -d, -f1)." ;; esac
  if [ "$homes" -gt 0 ]; then homes=" in $homes home(s)"; else homes=''; fi
  [ "$n" -eq 1 ] && count='1 landing' || count="$n landings"
  when=$(date -u -d "@$at" '+%Y-%m-%d %H:%M UTC' 2>/dev/null) || when=$at
  jq -n --arg key "live-$commit" --arg commit "$commit" --arg title "Live: ${commit:0:8}, $count" \
    --arg about "$(printf 'Live%s at %s. Landings since the last go-live: %s%s.%s Delivery now: %s.' \
      "$homes" "$when" "${lanes:-none}" "$more" "$note" "${words:-no lane here is in the delivery registry, so no proof of use}")" '
    def clean(max): gsub("[\u0000-\u0009\u000b-\u001f\u007f-\u009f]"; " ") | if length > max then .[:max - 3] + "..." else . end;
    {contract: 1, kind: "evidence", schema: 1, key: $key, title: ($title | clean(160)), about: ($about | clean(500)), link: $commit, status: "In progress"}'
}

# summary_json <day>: the one card for a UTC day's landings, on stdout.
summary_json() {
  local day=$1 id proj commit at kind _ total=0 first='' last='' pass=0 red=0 rev=0 other=0 live=0 lsha
  while IFS=$'\t' read -r id proj commit at kind _; do
    [ "$(date -u -d "@$at" +%F 2>/dev/null)" = "$day" ] || continue
    total=$((total + 1)); [ -n "$first" ] || first=$at; last=$at
    case $kind in full|full-rerun) pass=$((pass + 1)) ;; full-tip-red) red=$((red + 1)) ;; reverts-*) rev=$((rev + 1)) ;; *) other=$((other + 1)) ;; esac
    lsha=$(awk -F'\t' -v p="$proj" '$1 == p && $4 ~ /^live/ { s = $2 } END { print s }' "$DATA/trunk-live.tsv")
    [ -z "$lsha" ] || ! git -C "$FMH/projects/$proj" merge-base --is-ancestor "$commit" "$lsha" 2>/dev/null || live=$((live + 1))
  done < "$DATA/trunk-landings.tsv"
  [ "$total" -gt 0 ] || return 1
  jq -n --arg day "$day" --argjson total "$total" --arg first "$(date -u -d "@$first" +%H:%M)" --arg last "$(date -u -d "@$last" +%H:%M)" \
    --arg asof "$(date -u '+%H:%M UTC')" --arg about "$pass passed every required test, $red failed only where the trunk was already red, $rev are reverts, $other other. $live of $total are live in the homes; $((total - live)) are not live yet. Each landing and go-live has its own card." '
    {contract: 1, kind: "evidence", schema: 1, key: ("landings-" + $day), title: ("Landed on " + $day + ": " + ($total | tostring) + " lanes"),
     about: ($total | tostring) + " landings from " + $first + " to " + $last + " UTC, as of " + $asof + ". " + $about, status: "In progress"}'
}

# post_card <label> <card json file>: one post; a failure says why once and returns 1, so the caller stops and the rest wait.
post_card() {
  local out
  if out=$("$SIGNOFF" post "$BOARD" --kind evidence --from "$2" --filer juggernaut-landing 2>&1); then posted=$((posted + 1)); return 0; fi
  echo "landing-card: card for $1 not posted ($(printf '%s' "$out" | tail -n 1 | cut -c1-160)); the rest wait for the next beat"; return 1
}

# land_cards: one card per landing row; live_cards: one per go-live row. Both skip a key already on the board, live or archived.
land_cards() {
  local id proj commit at kind _
  while IFS=$'\t' read -r id proj commit at kind _; do
    [ -n "$commit" ] || continue
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "landing-card: $id has no full commit in trunk-landings.tsv; no card"; continue; }
    if printf '%s\n' "$have" | grep -qxF "landing-$commit"; then already=$((already + 1)); continue; fi
    card_json "$id" "$proj" "$commit" "$at" "$kind" > "$work/card.json" || { echo "landing-card: could not build the card for $id"; return 1; }
    post_card "$id" "$work/card.json" || return 1
  done < "$DATA/trunk-landings.tsv"
}
live_cards() {
  local proj commit at status _ prev
  declare -A last=()
  [ -s "$DATA/trunk-live.tsv" ] || return 0
  while IFS=$'\t' read -r proj commit at status _; do
    case $status in live*) ;; *) continue ;; esac
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || continue
    prev=${last[$proj]:-}; last[$proj]=$commit
    if printf '%s\n' "$have" | grep -qxF "live-$commit"; then already=$((already + 1)); continue; fi
    live_json "$proj" "$commit" "$at" "$status" "$prev" > "$work/card.json" || { echo "landing-card: could not build the go-live card for ${commit:0:12}"; return 1; }
    post_card "go-live ${commit:0:12}" "$work/card.json" || return 1
  done < <(awk -F'\t' '$1 !~ /:/' "$DATA/trunk-live.tsv")
}

have=$("$SIGNOFF" list "$BOARD" --json --full 2>/dev/null | jq -r '.decisions[]?.key // empty') || { echo "landing-card: could not read the board $BOARD"; exit 0; }
work=$(mktemp -d) || exit 0
trap 'rm -rf -- "$work"' EXIT
posted=0 already=0
if [ "$MODE" = summary ]; then
  if printf '%s\n' "$have" | grep -qxF "landings-$DAY"; then echo "landing-card: the card landings-$DAY is already on the board"; exit 0; fi
  summary_json "$DAY" > "$work/card.json" || { echo "landing-card: no landings on $DAY; no card"; exit 0; }
  post_card "$DAY" "$work/card.json" && echo "landing-card: posted the card landings-$DAY"
  exit 0
fi
land_cards && live_cards
[ "$MODE" = check ] || echo "landing-card: posted $posted, $already already on the board"
exit 0
