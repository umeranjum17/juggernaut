#!/usr/bin/env bash
# jg-swarm-words.sh - tend a home's swarm word rows from its swarm records, with no model turn.
# Usage: jg-swarm-words.sh <jg-home>
#
# Prints nothing. A home or plan it cannot read is named on stderr and skipped; the exit code is 0 either way.
# Acts on each plan with data/swarm/<plan>/swarm.json `running` (Main: every word row of the plan) or
# data/swarm/<plan>/arm.json `armed` (a lead home, the one with .jg-squad-lead-home: the word rows of its own slices),
# reading the derived plan the record names. For each slice with a word row, in this order:
#   1. Lead home only: when this home has an open gate for the slice's card and Main's gate for that card is closed
#      with resolution `answered`, run `jg-captain-hold.sh design-pick <card> --words "<his words>"` here, so the
#      slice starts on the next beat. Main is only read.
#   2. When the word row here is not done and `jg-captain-hold.sh open <word row>` exits 1, close it with
#      `jg-backlog.sh done <word row> --note "answered on the board"`.
# Safe to run twice: a closed gate and a done row are never touched again. The swarm check runs this every beat.
set -u
export LC_ALL=C
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: jg-swarm-words.sh <jg-home>" >&2; exit 2; }
HOME_DIR=$(cd "$1" && pwd -P)
LEAD=''
[ ! -f "$HOME_DIR/.jg-squad-lead-home" ] || read -r LEAD < "$HOME_DIR/.jg-squad-lead-home" || true

# in_home <home> <script> <args...>: one of that home's scripts against that home's own store and files.
in_home() {
  local h=$1 s=$2 b=$1/bin
  shift 2
  [ -x "$b/$s" ] || b=$SELF
  env -u JG_STATE_OVERRIDE -u JG_DATA_OVERRIDE -u JG_CONFIG_OVERRIDE JG_HOME="$h" "$b/$s" "$@"
}

# take_pick <card> <main home>: close this home's open gate for the card with the words Main's answer holds.
take_pick() {
  local card=$1 main=$2 mine words
  mine=$(in_home "$HOME_DIR" jg-backlog.sh questions --all --json 2> /dev/null \
    | jq -r --arg k "$card" 'first(.[] | select(.card == $k and .state == "open") | .card) // empty') || mine=''
  [ -n "$mine" ] || return 0
  if [ ! -d "$main" ] || ! words=$(in_home "$main" jg-backlog.sh questions --all --json 2> /dev/null \
    | jq -r --arg k "$card" 'first(.[] | select(.card == $k and .state == "closed" and .resolution == "answered") | .words) // empty'); then
    echo "jg-swarm-words: cannot read the answers of $main" >&2
    return 0
  fi
  [ -n "$words" ] || return 0
  in_home "$HOME_DIR" jg-captain-hold.sh design-pick "$card" --words "$words" > /dev/null \
    || echo "jg-swarm-words: could not record the pick for $card in $HOME_DIR" >&2
}

# close_word <word row>: close the row once its gate is answered.
close_word() {
  local row=$1 rc=0 state
  state=$(in_home "$HOME_DIR" jg-backlog.sh list --all 2> /dev/null | sed -n "s/^  $row,\\([a-z_]*\\),.*/\\1/p")
  [ -n "$state" ] && [ "$state" != "done" ] || return 0
  in_home "$HOME_DIR" jg-captain-hold.sh open "$row" > /dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || return 0
  in_home "$HOME_DIR" jg-backlog.sh "done" "$row" --note "answered on the board" > /dev/null \
    || echo "jg-swarm-words: could not close $row in $HOME_DIR" >&2
}

tend() { # <record file> <running|armed>
  local rec=$1 pf main owner card word
  [ "$(jq -r '.state' "$rec" 2> /dev/null)" = "$2" ] || return 0
  pf=$(jq -r '.plan_file // empty' "$rec" 2> /dev/null)
  if [ ! -f "$pf" ] || ! main=$(jq -r '.main_home' "$pf" 2> /dev/null); then
    echo "jg-swarm-words: cannot read the plan of $rec" >&2
    return 0
  fi
  while IFS=$'\t' read -r owner word card; do
    [ -n "$word" ] || continue
    [ -z "$LEAD" ] || [ "$owner" = "$LEAD" ] || continue
    [ -z "$LEAD" ] || [ -z "$card" ] || take_pick "$card" "$main"
    close_word "$word"
  done < <(jq -r '.slices[] | [.owner_home, (.word_row // ""), (.card // "")] | @tsv' "$pf")
}

for rec in "$HOME_DIR"/data/swarm/*/swarm.json; do [ -z "$LEAD" ] && [ -f "$rec" ] && tend "$rec" running; done
for rec in "$HOME_DIR"/data/swarm/*/arm.json; do [ -n "$LEAD" ] && [ -f "$rec" ] && tend "$rec" armed; done
exit 0
