#!/usr/bin/env bash
# lane-delivery.sh - observer of the lane-delivery machine (core/machines/tables/lane-delivery.tsv): where one lane's change
# stands between the worker's done line and the main branch, read from records that already exist. It writes none.
#
# Usage:
#   lane-delivery.sh <lane>          print the state word; print nothing for a lane with no record
#   lane-delivery.sh detail <lane>   print key<TAB>value lines: state, from (the state of an older table it was read from,
#                                    <table>:<state>, or none for a state no older table holds), commit, chain
#                                    (the place of the change itself while a refused cleanup stands), evidence
#
# The records, first match wins:
#   before the landing (no row of the lane in data/trunk-landings.tsv):
#     parked        state/<lane>.parked exists (bin/jg-teardown.sh --park); the branch it names is the commit
#     coding        the last line of state/<lane>.status is not a done line
#     landing       data/jg-trunk-landing/<lane>.<head>.state says running (head: the ship branch of state/<lane>.meta)
#     refused       that state file says wait, retry or final
#     landed        that state file says landed and the row is not there
#     admitted      no state file, and `bin/jg-trunk.sh proof <lane>` finds the whole proof at the head
#     ready         otherwise: a done line and the proof is not complete
#   after the landing (the lane's last row in data/trunk-landings.tsv names commit C in project P):
#     reverted          a revert-<lane> row follows it
#     cleanup-refused   state/<lane>.meta still stands and a landing state file of the lane says `landed cleanup refused`
#     live              the last live row of P in data/trunk-live.tsv (its project row is written only when every home moved) holds C
#     live-partial      the last live row of some home P:<home> holds C
#     home-behind       a move row of P or a home of P was written at a commit that holds C
#     landed            anything else
# A change in a release pull request is read by core/machines/observers/release.sh, and ticket.sh joins the two.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}; MEM=$DATA/jg-trunk-landing

mval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
holds() { git -C "$REPO" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
# The data/trunk-live.tsv rows of project P (with the argument `homes`: of its homes P:<home>), as key, sha, status, in file order.
live_rows() { awk -F'\t' -v p="$P" -v h="${1:-}" '(h == "" && $1 == p) || (h != "" && index($1, p ":") == 1) { print $1 "\t" $2 "\t" $4 }' "$DATA/trunk-live.tsv" 2>/dev/null; }

# Before the landing: sets WORD and FROM from the lane's status, meta and landing state file.
lane_state() {
  local meta=$STATE/$ID.meta line proj br head w
  if [ -e "$STATE/$ID.parked" ]; then
    WORD=parked; FROM=none; C=$(mval "$STATE/$ID.parked" head); EVIDENCE="$STATE/$ID.parked"; return 0
  fi
  line=$(tail -n 1 "$STATE/$ID.status" 2>/dev/null)
  [ -e "$meta" ] || [ -n "$line" ] || return 1
  case $line in done\ *|done:*) ;; *) WORD=coding; FROM=none; EVIDENCE="last status line: ${line:0:120}"; return 0 ;; esac
  proj=$(mval "$meta" project); br=$(mval "$meta" branch); br=${br:-fm/$ID}
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$br^{commit}" 2>/dev/null) || head=
  w=; [ -z "$head" ] || read -r w _ 2>/dev/null < "$MEM/$ID.$head.state"
  C=$head; EVIDENCE="$MEM/$ID.$head.state: $(cut -c1-160 "$MEM/$ID.$head.state" 2>/dev/null)"
  case $w in
    running) WORD=landing; FROM=landing:running ;;
    wait|retry|final) WORD=refused; FROM=landing:$w ;;
    landed) WORD=landed; FROM=landing:landed ;;
    *) if [ -n "$head" ] && JG_HOME=$JG_HOME "$root/bin/jg-trunk.sh" proof "$ID" >/dev/null 2>&1; then WORD=admitted; FROM=landing:new
       else WORD=ready; FROM=none; fi
       EVIDENCE="bin/jg-trunk.sh proof $ID at ${head:-no head}: $([ "$WORD" = admitted ] && echo complete || echo incomplete)" ;;
  esac
}

# After the landing, on the trunk side: sets WORD and FROM for commit C of project P.
trunk_state() {
  local key sha st last moved=
  last=$(live_rows | awk -F'\t' '$3 ~ /^live/ { s = $2 } END { print s }')
  if [ -n "$last" ] && holds "$C" "$last"; then WORD=live; FROM=delivery:in-homes; EVIDENCE="data/trunk-live.tsv: $P live at ${last:0:12}"; return 0; fi
  while IFS=$'\t' read -r key sha; do
    [ -n "$sha" ] && holds "$C" "$sha" && { WORD=live-partial; FROM=delivery:landed; EVIDENCE="data/trunk-live.tsv: $key live at ${sha:0:12}"; return 0; }
  done < <(live_rows homes | awk -F'\t' '$3 ~ /^live/ { s[$1] = $2 } END { for (k in s) print k "\t" s[k] }')
  while IFS=$'\t' read -r key sha st; do
    case $st in held:*) continue ;; esac
    [ -n "$sha" ] && holds "$C" "$sha" && moved="$key ${st:0:80}"
  done < <(live_rows; live_rows homes)
  if [ -n "$moved" ]; then WORD=home-behind; FROM=trunk-pointers:hook-failed; EVIDENCE="data/trunk-live.tsv: $moved"; return 0; fi
  WORD=landed; FROM=landing:landed; EVIDENCE="data/trunk-landings.tsv: $ID at ${C:0:12}"
}

classify() {  # <lane>: sets WORD FROM C CHAIN EVIDENCE
  local row rev f
  ID=$1; WORD=; FROM=none; C=; CHAIN=; EVIDENCE=
  row=$(awk -F'\t' -v i="$ID" '$1 == i { r = $2 "\t" $3; v = 0 } $1 == "revert-" i && r != "" { v = 1 } END { if (r != "") print r "\t" v }' "$DATA/trunk-landings.tsv" 2>/dev/null)
  [ -n "$row" ] || { lane_state; return; }
  IFS=$'\t' read -r P C rev <<< "$row"
  REPO=$JG_HOME/projects/$P; git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || REPO=$JG_HOME
  if [ "$rev" = 1 ]; then WORD=reverted; FROM=delivery:reverted; EVIDENCE="data/trunk-landings.tsv: revert-$ID"; return 0; fi
  trunk_state
  [ -e "$STATE/$ID.meta" ] || return 0
  for f in "$MEM/$ID".*.state; do
    case $(head -n 1 "$f" 2>/dev/null) in "landed cleanup refused"*)
      CHAIN=$WORD; WORD=cleanup-refused; FROM=landing:landed; EVIDENCE="$f: $(cut -c1-160 "$f")"; return 0 ;;
    esac
  done
}

case ${1:-} in
  detail)
    [ -n "${2:-}" ] || { echo "usage: lane-delivery.sh detail <lane>" >&2; exit 2; }
    classify "$2" || exit 1
    printf 'state\t%s\nfrom\t%s\ncommit\t%s\nchain\t%s\nevidence\t%s\n' "$WORD" "$FROM" "${C:-none}" "${CHAIN:-none}" "${EVIDENCE:-none}" ;;
  ""|-*) echo "usage: lane-delivery.sh <lane> | detail <lane>" >&2; exit 2 ;;
  *) classify "$1" && printf '%s\n' "$WORD" ;;
esac
