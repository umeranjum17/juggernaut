#!/usr/bin/env bash
# delivery.sh - observer of the delivery machine (core/machines/tables/delivery.tsv): where one change stands between
# "on the trunk" and "doing its job in the homes", read from records that already exist.
#
# Usage:
#   delivery.sh <id>          print the state word of the registered change <id>; print nothing for an unregistered id
#   delivery.sh detail <id>   print key<TAB>value lines: state, commit, switch (config/<file> or none), proof (what held, or none)
#   delivery.sh stage <id>    print the delivery word of the change: Landed, In homes - off: <switch names> (the homes run it
#                             but a switch is off), In use, or nothing for an unlanded, pinned-behind or reverted change
#   delivery.sh ids           print every registered change id
#   delivery.sh mentions      read text on stdin; print each registered id the text names, by its id or by its switch name
#                             (hyphens, case and punctuation do not matter: "the machine view" names the machine-view switch)
#   delivery.sh check         lint the registry and print each defect; exit 1 when there is one
#
# The registry is core/machines/changes.tsv (override: JG_DELIVERY_CHANGES), one change per line, tab separated:
#   id, project, commit (a sha, or - to find the trunk commit whose message has the trailer line `Change: <id>`),
#   switch (the file in config/ that turns it on, or -), proof (see below, or -), what (one plain line).
# A change that ships behind a switch names that switch there, so this observer finds it; a `Change: <id>` trailer on
# its commit names the commit. The proof is `switch` (the switch file is present), `log:<file>:<regex>`, where <file>
# is under config/, data/ or state/ of the home and the regex matches one line of it (a log line, a counter file), or
# `exercise`: data/exercises.tsv (core/machines/exercise.sh writes it) holds a row for the change that names the exact
# commit each home runs, so a row for an older or newer commit, or for another change, proves nothing.
# The state, first match wins:
#   unlanded       the commit is not on the trunk (state/trunk-tip-<project>; HEAD when that is absent)
#   reverted       the trunk holds a revert of it (`reverts: <sha>` or `This reverts commit <sha>`)
#   in-homes*      every home row of the project in data/trunk-in-use.tsv runs a commit that holds the change
#                  (the last `live*` row of each home, so a skipped or rolled-back home keeps its older commit), then:
#       in-homes-off   the switch file is absent
#       in-use         the switch file is present (when one is named) and the proof holds
#       in-homes       otherwise: no proof is named, or the proof does not hold
#   pinned-behind  a home was pinned back (`live,pinned-back-from:*`) to a commit that lacks the change
#   landed         anything else: on the trunk, and some home does not run it yet
# The switch and the proof are read in the home that asks, because config/ is per home.
# A change with rows in the switch manifest (core/machines/switches.tsv, override JG_SWITCH_MANIFEST) is read there instead
# of from its switch column: bin/jg-switch.sh reads each of its rows in every home of the fleet (the registered local leads
# and Main), and a row that is off in any home gives in-homes-off, with `detail` naming the home and the row. All rows on
# in every home is in-use. A change with no manifest row keeps the switch column. `check` also refuses a manifest id with no
# row in changes.tsv.
# A home with no row of the project (Main, for a project a Squad Lead runs) reads the go-live record of the lead whose
# entry in data/squad_leads.md lists the project: that home's data/trunk-in-use.tsv, state/trunk-tip-<project> and
# projects/<project>. Nothing is copied or written; a lead home that is missing leaves the word as read here and prints one stderr line.
# The command only reads: it writes no record and runs no move.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}; CONFIG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
CHANGES=${JG_DELIVERY_CHANGES:-$here/../changes.tsv}
MANIFEST=${JG_SWITCH_MANIFEST:-$here/../switches.tsv}

registry() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$CHANGES" 2>/dev/null; }
load() {  # <id>: sets ID PROJECT COMMIT SWITCH PROOF from the registry, or returns 1
  local line; line=$(registry | awk -F'\t' -v i="$1" '$1 == i { print; exit }'); [ -n "$line" ] || return 1
  IFS=$'\t' read -r ID PROJECT COMMIT SWITCH PROOF _ <<< "$line"
}
manifest_rows() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$MANIFEST" 2>/dev/null; }
# The homes of the fleet, one directory per line: every registered local lead, then Main (bin/jg-fleet-homes-lib.sh).
fleet_dirs() {
  ( b=$root/bin
    # shellcheck source=bin/jg-compat.sh
    . "$b/jg-compat.sh"; . "$b/jg-squad-lead-parent-lib.sh"; . "$b/jg-squad-lead-registry-lib.sh"; . "$b/jg-fleet-homes-lib.sh"
    jg_fleet_homes "$JG_HOME" "$JG_HOME" | cut -f3 ) 2>/dev/null
}
# One line per off manifest row of $ID in the fleet's homes: `<home> <kind> <name> <reason>`; nothing when all are on.
manifest_off() {
  local h out
  manifest_rows | awk -F'\t' -v i="$ID" '$1 == i { f = 1 } END { exit !f }' || return 0
  while IFS= read -r h; do
    out=$(JG_SWITCH_MANIFEST=$MANIFEST bash "$root/bin/jg-switch.sh" status --home "$h" "$ID" 2>/dev/null) || continue
    printf '%s\n' "$out" | awk -v h="$(basename "$h")" '$1 == "off" && $2 == i { print h, $3, $4, $5 }' i="$ID"
  done < <(fleet_dirs)
}
holds() { git -C "$REPO" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# The commit that carries the change on the trunk, or nothing.
commit_on_trunk() {
  local c
  if [ "$COMMIT" = - ]; then c=$(git -C "$REPO" log "$TIP" -n 1 --format=%H --grep="^Change: $ID\$" 2>/dev/null)
  else c=$(git -C "$REPO" rev-parse --verify --quiet "$COMMIT^{commit}" 2>/dev/null); fi
  [ -n "$c" ] && holds "$c" "$TIP" && printf '%s\n' "$c"
}
# The proof, as one line of what held; nothing when it does not hold or none is named.
proof_held() {
  local file re
  case $PROOF in
    switch) [ "$SWITCH" != - ] && [ -e "$CONFIG/$SWITCH" ] && printf 'switch config/%s is present\n' "$SWITCH" ;;
    exercise) exercised ;;
    log:*) file=${PROOF#log:}; re=${file#*:}; file=${file%%:*}
      grep -Eq -- "$re" "$JG_HOME/$file" 2>/dev/null && printf '%s has a line that matches %s\n' "$file" "$re" ;;
  esac
}

# Sets ROWS (the go-live record), and TIP and REPO, from the lead home that runs the project, when the asking home has no
# row of it. The lead is the first local entry of data/squad_leads.md whose projects: list names the project and whose
# (home: ...) holds data/trunk-in-use.tsv. Nothing is copied or written.
record_home() {
  local h
  grep -q "^$PROJECT:" "$ROWS" 2>/dev/null && return 0
  h=$(sed -nE '/^- [A-Za-z0-9._-]+ - .*\(home:/ {
    s/^.*\(home:[[:space:]]*([^;)]*);.*projects:[[:space:]]*([^;)]*);.*$/\1\t\2/p }' "$DATA/squad_leads.md" 2>/dev/null |
    awk -F'\t' -v p="$PROJECT" '{ n = split($2, a, /[ ,]+/); for (i = 1; i <= n; i++) if (a[i] == p) { print $1; exit } }')
  [ -n "$h" ] || return 0
  if [ ! -f "$h/data/trunk-in-use.tsv" ]; then echo "delivery.sh: lead home $h has no data/trunk-in-use.tsv; $ID stays as read here" >&2; return 0; fi
  ROWS=$h/data/trunk-in-use.tsv
  [ -f "$h/state/trunk-tip-$PROJECT" ] && TIP=$(cat "$h/state/trunk-tip-$PROJECT")
  git -C "$h/projects/$PROJECT" rev-parse --git-dir >/dev/null 2>&1 && REPO=$h/projects/$PROJECT
  return 0
}

# One line naming the exercise row of the change at every commit a home runs; nothing when any home's commit has none.
exercised() {
  local h full row out=''
  [ -n "$HEADS" ] || return 0
  for h in $HEADS; do
    row=$(awk -F'\t' -v i="$ID" -v h="$h" '$2 == i && $3 == h { w = $4 } END { print w }' "$DATA/exercises.tsv" 2>/dev/null)
    [ -n "$row" ] || return 0
    out="${out:+$out; }${h:0:12}: $row"
  done
  printf 'exercised at %s\n' "$out"
}

# Sets WORD (the state) and EVIDENCE (what the proof showed, when in-use).
classify() {  # <id>
  local c behind=0 pinned=0 homes=0 sha st full
  WORD=''; HEADS=''; EVIDENCE=''; C=''; OFF=''
  load "$1" || return 1
  REPO=$JG_HOME/projects/$PROJECT; git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || REPO=$JG_HOME
  TIP=$(cat "$STATE/trunk-tip-$PROJECT" 2>/dev/null); TIP=${TIP:-HEAD}
  ROWS=$DATA/trunk-in-use.tsv; record_home; TIP=${TIP:-HEAD}
  c=$(commit_on_trunk); C=$c
  [ -n "$c" ] || { WORD=unlanded; return 0; }
  if [ -n "$(git -C "$REPO" log "$TIP" -n 1 --format=%H --grep="^reverts: $c" --grep="This reverts commit $c" 2>/dev/null)" ]; then WORD=reverted; return 0; fi
  while IFS=$'\t' read -r _ sha st; do
    homes=$((homes + 1))
    if [ "$sha" != - ] && holds "$c" "$sha"; then
      full=$(git -C "$REPO" rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null)
      case " $HEADS " in *" $full "*) ;; *) HEADS="$HEADS $full" ;; esac
      continue
    fi
    behind=$((behind + 1)); case $st in live,pinned-back*) pinned=1 ;; esac
  done < <(awk -F'\t' -v p="$PROJECT:" 'index($1, p) == 1 { k = $1; last[k] = $4; if ($4 ~ /^live/) sha[k] = $2 }
    END { for (k in last) print k "\t" (sha[k] == "" ? "-" : sha[k]) "\t" last[k] }' "$ROWS" 2>/dev/null)
  if [ "$homes" -eq 0 ] || [ "$behind" -gt 0 ]; then
    if [ "$pinned" = 1 ]; then WORD="pinned-behind"; else WORD=landed; fi; return 0
  fi
  if manifest_rows | awk -F'\t' -v i="$ID" '$1 == i { f = 1 } END { exit !f }'; then
    OFF=$(manifest_off)
    if [ -n "$OFF" ]; then WORD=in-homes-off; return 0; fi
    EVIDENCE=$(proof_held); : "${EVIDENCE:=every manifest row is on in every home}"; WORD=in-use; return 0
  fi
  if [ "$SWITCH" != - ] && [ ! -e "$CONFIG/$SWITCH" ]; then WORD=in-homes-off; return 0; fi
  EVIDENCE=$(proof_held)
  if [ -n "$EVIDENCE" ]; then WORD=in-use; else WORD=in-homes; fi
}

# One defect per line; the registry is data, so only its shape is checked (a sha is not looked up).
lint() {
  local n=0 bad=0 id project commit sw proof what extra seen=' ' f
  while IFS=$'\t' read -r id project commit sw proof what extra; do
    n=$((n + 1)); f="changes line $n"
    if [ -z "$what" ] || [ -n "$extra" ]; then echo "$f: needs six tab separated columns"; bad=1; continue; fi
    case $id in *[!A-Za-z0-9._-]*|'') echo "$f: id '$id' is not a plain id"; bad=1 ;; esac
    case $seen in *" $id "*) echo "$f: duplicate id $id"; bad=1 ;; esac; seen="$seen$id "
    case $project in *[!A-Za-z0-9._-]*|'') echo "$f: project '$project' is not a plain name"; bad=1 ;; esac
    case $commit in -) ;; *[!0-9a-f]*|'') echo "$f: commit must be - or a hex sha"; bad=1 ;; *) [ ${#commit} -ge 7 ] && [ ${#commit} -le 40 ] || { echo "$f: commit must be 7 to 40 hex characters"; bad=1; } ;; esac
    case $sw in -) ;; *[!A-Za-z0-9._-]*|'') echo "$f: switch '$sw' must be - or a file name in config/"; bad=1 ;; esac
    case $proof in
      -) ;;
      exercise) ;;
      switch) [ "$sw" != - ] || { echo "$f: proof switch needs a switch"; bad=1; } ;;
      log:config/*:?*|log:data/*:?*|log:state/*:?*) case $proof in *..*) echo "$f: proof path must stay in the home"; bad=1 ;; esac ;;
      *) echo "$f: proof must be -, switch, exercise or log:<config|data|state>/<file>:<regex>"; bad=1 ;;
    esac
  done < <(registry)
  while IFS=$'\t' read -r id _; do
    registry | awk -F'\t' -v i="$id" '$1 == i { f = 1 } END { exit !f }' || { echo "switches manifest: id $id has no row in changes.tsv"; bad=1; }
  done < <(manifest_rows | cut -f1 | sort -u)
  return "$bad"
}

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' '; }
mentions() {
  local text id sw
  text=" $(norm "$(cat)") "
  while IFS=$'\t' read -r id _ _ sw _; do
    case $text in *" $(norm "$id") "*) echo "$id"; continue ;; esac
    [ "$sw" = - ] || case $text in *" $(norm "$sw") "*) echo "$id" ;; esac
  done < <(registry)
}

case ${1:-} in
  ids) registry | cut -f1 ;;
  mentions) mentions ;;
  check) lint ;;
  detail)
    [ -n "${2:-}" ] || { echo "usage: delivery.sh detail <id>" >&2; exit 2; }
    classify "$2" || exit 1
    printf 'state\t%s\ncommit\t%s\nswitch\t%s\nproof\t%s\n' "$WORD" "${C:-none}" "$([ "$SWITCH" = - ] && echo none || echo "config/$SWITCH")" "${EVIDENCE:-none}"
    [ -z "$OFF" ] || printf '%s\n' "$OFF" | sed 's/^/off\t/' ;;
  stage)
    [ -n "${2:-}" ] || { echo "usage: delivery.sh stage <id>" >&2; exit 2; }
    classify "$2" || exit 1
    case $WORD in
      landed) echo Landed ;;
      in-use|in-homes) echo "In use" ;;
      in-homes-off)
        names=$(printf '%s\n' "$OFF" | awk 'NF >= 3 { print $3 }' | sort -u | paste -sd, - | sed 's/,/, /g')
        echo "In homes - off: ${names:-${SWITCH}}" ;;
    esac ;;
  ""|-*) echo "usage: delivery.sh <id> | detail <id> | stage <id> | ids | mentions | check" >&2; exit 2 ;;
  *) classify "$1" && printf '%s\n' "$WORD" ;;
esac
