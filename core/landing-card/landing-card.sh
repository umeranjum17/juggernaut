#!/usr/bin/env bash
# landing-card watcher check: every landed commit of this home has exactly one Evidence card on the board, never skipped.
# Usage: landing-card.sh check <jg-home>   (silent unless a card could not be posted)
#        landing-card.sh run   <jg-home>   (the same, and prints `landing-card: posted N, M already on the board`)
#
# A landing card is a fact sheet of records the lander already wrote, not a judge: data/trunk-landings.tsv (lane, project,
# commit, epoch, gate kind), data/trunk-landing-proofs.tsv (receipt, signature, merge-card) and, when it exists, the
# done-done verdict in data/<lane>/merge-card.json. A missing piece is written as "not checked"; it never skips the card.
# The title is the lane's name (a commit subject is too long for a phone row) and the about starts with the commit subject.
# The card has the key `landing-<commit>` and is posted once: a commit whose key is already on the board, live or archived,
# is left alone, so a second run posts nothing. The status pill is "In progress" because a landing is on the trunk, not yet
# live; a go-live card is a separate slice. Cards go one at a time through sign-off-axi, which holds the board's own lock;
# a failed post stops the run (one line, the rest wait for the next beat) instead of queueing behind a busy board.
# The board is the one merge cards use (jg_board_file). JG_LANDING_CARD_SIGNOFF names the sign-off-axi command (tests).
set -u
case ${1:-} in check|run) MODE=$1 ;; *) MODE='' ;; esac
[ "$#" -eq 2 ] && [ -n "$MODE" ] && [ -d "$2/state" ] || { echo "usage: landing-card.sh check|run <jg-home>" >&2; exit 2; }
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

have=$("$SIGNOFF" list "$BOARD" --json --full 2>/dev/null | jq -r '.decisions[]?.key // empty') || { echo "landing-card: could not read the board $BOARD"; exit 0; }
work=$(mktemp -d) || exit 0
trap 'rm -rf -- "$work"' EXIT
posted=0 already=0
while IFS=$'\t' read -r id proj commit at kind _; do
  [ -n "$commit" ] || continue
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "landing-card: $id has no full commit in trunk-landings.tsv; no card"; continue; }
  if printf '%s\n' "$have" | grep -qxF "landing-$commit"; then already=$((already + 1)); continue; fi
  card_json "$id" "$proj" "$commit" "$at" "$kind" > "$work/card.json" || { echo "landing-card: could not build the card for $id"; break; }
  if out=$("$SIGNOFF" post "$BOARD" --kind evidence --from "$work/card.json" --filer juggernaut-landing 2>&1); then
    posted=$((posted + 1))
  else
    echo "landing-card: card for $id not posted ($(printf '%s' "$out" | tail -n 1 | cut -c1-160)); the rest wait for the next beat"; break
  fi
done < "$DATA/trunk-landings.tsv"
[ "$MODE" = check ] || echo "landing-card: posted $posted, $already already on the board"
exit 0
