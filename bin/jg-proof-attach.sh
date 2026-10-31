#!/usr/bin/env bash
# jg-proof-attach.sh - put a task's proof on its ready, review or merged card and its PR body.
#
# Usage:
#   jg-proof-attach.sh find   <task-id> [--pr <url>] [--head <sha>]
#   jg-proof-attach.sh attach <ready|review|merged> <task-id> [--pr <url>] [--head <sha>] [--board <file>] [--require 1]
#
# The captain's rule (2026-10-29): a card for UI or video work is never text-only,
# and no model decides that. This script decides, from files:
#   - non-UI work is a merge that declares `screen: none` (merge-card screen-none);
#     it needs the sealed clean done-done receipt (merge-card receipt-json) at the head;
#   - every other task is UI or video work and needs proof media (png jpg webp gif
#     mp4 webm) under $JG_HOME/data/<task-id> (two folders deep, at most 12).
# attach refuses (exit 1, one line naming the fix) when that proof is missing.
# Otherwise it files one evidence card under the merge-card key (merge-<pr>), so the
# later merge card is the same card, not a second one, and it replaces a live card
# for the same PR that has no media. It then writes a `## Proof` section into the PR body
# (run id, file names, sha256 - never the board link, which carries the board token).
# GitHub has no upload path for a PR body, so the images live on the board card.
# The board is --board, else the one jg_board_file names (bin/jg-board-link-lib.sh).
# --require 1 is the merge gate's: a missing add-on, tool or board refuses instead of skipping.
# find prints `mode:`, `receipt:` and `media:` lines. Exit 0 also when the board tools
# or the merge-card add-on are absent (one line says proof was skipped).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-addons-dir-lib.sh
. "$SCRIPT_DIR/jg-addons-dir-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh
. "$SCRIPT_DIR/jg-board-link-lib.sh"
# shellcheck source=bin/jg-compat.sh
. "$SCRIPT_DIR/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"

die() { printf 'jg-proof-attach: %s\n' "$1" >&2; exit 1; }
refuse() { printf 'proof refused for %s: %s\n' "$ID" "$1"; exit 1; }
skip() {
  [ -z "$REQUIRE" ] || refuse "$1, and this merge needs the proof card on the board"
  printf 'proof skipped for %s: %s\n' "$ID" "$1" >&2; exit 0
}

KIND='' ID='' PR=- HEAD=- BOARD=${JG_PROOF_BOARD:-} REQUIRE=
CMD=${1:-}
case $CMD in find) shift ;; attach) KIND=${2:-}; [ $# -ge 3 ] || die "usage: attach <ready|review|merged> <task-id>"; shift 2 ;; *) die "usage: find|attach (see the header)" ;; esac
ID=${1:-}; shift
while [ $# -gt 0 ]; do
  [ -n "${2:-}" ] || die "$1 needs a value"
  case $1 in --pr) PR=$2 ;; --head) HEAD=$2 ;; --board) BOARD=$2 ;; --require) REQUIRE=$2 ;; *) die "unknown option $1" ;; esac
  shift 2
done
case $KIND in ''|ready|review|merged) ;; *) die "kind must be ready, review or merged" ;; esac
case $ID in ''|*[!A-Za-z0-9._-]*) die "bad task id" ;; esac
[ -n "${JG_HOME:-}" ] || die "JG_HOME is not set"
DIR=${JG_DATA_OVERRIDE:-$JG_HOME/data}/$ID
MC=$SCRIPT_DIR/../addons/merge-card/merge-card
[ -x "$MC" ] || skip "the merge-card add-on is not installed"
command -v jq >/dev/null 2>&1 || skip "jq is not installed"
if [ "$HEAD" = - ] && [ "$PR" != - ]; then
  HEAD=$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null) || HEAD=-
fi
[ "$HEAD" != - ] || refuse "no head commit: pass --head <sha> or a --pr the forge can read"

mc() { JG_HOME=$JG_HOME "$MC" "$@"; }
mode=ui receipt=
mc screen-none "$ID" "$PR" >/dev/null 2>&1 && mode=text
receipt=$(mc receipt-json "$ID" "$HEAD" 2>/dev/null | jq -c . 2>/dev/null)
media=$([ ! -d "$DIR" ] || find "$DIR" -maxdepth 2 \( -name merge-card-media -o -name proof-card -o -name .done-done \) -prune \
  -o -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.mp4' -o -iname '*.webm' \) -print | LC_ALL=C sort | head -n 12)
if [ "$CMD" = find ]; then
  printf 'mode: %s\nreceipt: %s\n' "$mode" "$(jq -r '.run_id // "none"' <<<"${receipt:-null}")"
  printf '%s\n' "$media" | sed '/^$/d; s/^/media: /'
  exit 0
fi

# The gate: what a card for this kind of work must carry.
if [ "$mode" = text ]; then
  [ -n "$receipt" ] || refuse "non-UI work (screen: none) needs a sealed clean done-done run at $HEAD; run: done-done run -- <the command that proves it>"
elif [ -z "$media" ]; then
  refuse "UI or video work has no proof media under $DIR; add a screenshot or clip there, or declare \`screen: none\` in the PR's ## Checks block when there is no screen"
fi
command -v sign-off-axi >/dev/null 2>&1 || skip "sign-off-axi is not installed"

if [ -z "$BOARD" ]; then
  BOARD=$(jg_board_file "$JG_HOME") || BOARD=''
fi
[ -n "$BOARD" ] || refuse "no board: pass --board <file> or set JG_PROOF_BOARD"
if [ "$PR" != - ]; then key=$(jg_board_merge_key "$PR") link=$PR; else key=merge-$HEAD link=$HEAD; fi
key=${key:0:128}

# One live card per PR: skip when this head is already there with the proof, else replace.
card_key=$key restore='' old_keys=''
cards=$([ ! -f "$BOARD" ] || sign-off-axi list "$BOARD" --json --full | jq -c --arg k "$key" '
  [.decisions[]? | select(.key == $k or (.key | startswith($k + "-") and length == ($k | length) + 13))
   | {key, live: (.dismissed != true), commit: (.evidence.commit? // null), media: ((.media // []) | length)}]') || die "sign-off-axi could not list $BOARD"
if [ -n "$cards" ] && [ "$cards" != '[]' ]; then
  card_key=$(jq -r --arg h "$HEAD" '[.[] | select(.commit == $h and (.live | not)) | .key][0] // empty' <<<"$cards")
  if [ -n "$card_key" ]; then restore=1; else card_key=$key-$(printf '%s' "$HEAD$(date +%s)" | sha1sum | cut -c1-12); fi
  old_keys=$(jq -r '.[] | select(.live) | .key' <<<"$cards")
fi
card_done=
if [ -n "$cards" ] && jq -e --arg h "$HEAD" --argjson w "$([ "$mode" = ui ] && echo 1 || echo 0)" \
  'any(.[]; .live and (.commit == $h or .commit == null) and .media >= $w)' <<<"$cards" >/dev/null; then
  card_done=1
  echo "proof: $key is already on the board with its proof"
fi

outcome=$(jq -r '.outcome // empty' <<<"${receipt:-null}")
[ "$PR" = - ] || [ -n "$outcome" ] || outcome=$(gh pr view "$PR" --json body --jq .body 2>/dev/null | sed -n 's/^outcome: *//p' | head -n 1)
label=$([ "$PR" = - ] || printf '%s' "${PR#*://}" | awk -F/ 'NF >= 5 { printf "%s #%s", $3, $5 }')
case $KIND in ready) verb="Ready for review" ;; review) verb="Needs review" ;; *) verb="Merged" ;; esac
title=${outcome:-${label:-$ID}: $verb}
# sign-off wants text in both fields of the run's receipt.
[ -z "$receipt" ] || receipt=$(jq -c --arg o "${outcome:-$title}" '.outcome = ($o[:1000]) | .evidence = (if (.evidence // "") == "" then "sealed done-done run \(.run_id)" else .evidence end)' <<<"$receipt")
n=0
out_dir=$DIR/proof-card
if [ -z "$card_done" ]; then
  rm -rf -- "$out_dir"; mkdir -p "$out_dir" || die "cannot create $out_dir"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1)); cp -- "$f" "$out_dir/$n.$(printf '%s' "${f##*.}" | tr '[:upper:]' '[:lower:]')"
  done <<<"$media"
  list=$(cd "$out_dir" && for i in $(seq 1 "$n"); do printf '%s\n' "$i".*; done | jq -R . | jq -s .)
  [ "$n" -gt 0 ] || list='[]'
  about="$verb. Proof attached by script: $n media file(s), done-done receipt $(jq -r '.run_id // "none"' <<<"${receipt:-null}")."
  jq -n --arg key "$card_key" --arg title "$title" --arg about "$about" --arg link "$link" --argjson media "$list" --argjson run "${receipt:-null}" '
    def clean(max): gsub("[\u0000-\u0009\u000b-\u001f\u007f-\u009f]"; " ") | if length > max then .[:max - 3] + "..." else . end;
    {contract: 1, kind: "evidence", schema: 1, key: $key, title: ($title | clean(160)), about: ($about | clean(500)), link: $link}
    + (if $media != [] then {media: $media} else {} end) + (if $run != null then {run: ($run | del(.files))} else {} end)' > "$out_dir/card.json" || die "cannot write the card"
  if [ -n "$restore" ]; then sign-off-axi restore "$card_key" "$BOARD" || die "sign-off-axi could not restore $card_key"
  else sign-off-axi post "$BOARD" --kind evidence --from "$out_dir/card.json" --filer juggernaut-proof || die "sign-off-axi could not post $card_key"; fi
  for k in $old_keys; do sign-off-axi dismiss "$k" "$BOARD" >/dev/null || die "could not archive the old card $k"; done
  sweep="$(dirname "$MC")/one-card-per-pr"
  [ ! -x "$sweep" ] || "$sweep" --apply "$BOARD" >/dev/null 2>&1 || true
  echo "proof: posted $card_key ($KIND, $n media)"
  link_out=$(jg_board_link reports "$card_key") && echo "proof: link: $link_out"
fi

# The PR body carries the same facts as text (the board link carries a token, so it stays off).
if [ "$PR" != - ]; then
  section="<!-- jg-proof -->
## Proof
mode: $mode ($KIND)
receipt: $(jq -r '.run_id // "none"' <<<"${receipt:-null}")
$(while IFS= read -r f; do [ -z "$f" ] || printf -- '- %s sha256:%s\n' "${f##*/}" "$(sha256sum "$f" | cut -c1-12)"; done <<<"$media")
<!-- /jg-proof -->"
  body=$(gh pr view "$PR" --json body --jq .body 2>/dev/null) || die "cannot read the PR body of $PR"
  new=$(printf '%s\n' "$body" | awk '/<!-- jg-proof -->/ {skip=1} !skip {print} /<!-- \/jg-proof -->/ {skip=0}')
  printf '%s\n\n%s\n' "$new" "$section" > "$DIR/.pr-body.$$" || die "cannot stage the PR body"
  gh pr edit "$PR" --body-file "$DIR/.pr-body.$$" >/dev/null || { rm -f -- "$DIR/.pr-body.$$"; die "could not update the PR body of $PR"; }
  rm -f -- "$DIR/.pr-body.$$"
  echo "proof: PR body updated"
fi
