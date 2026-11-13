#!/usr/bin/env bash
# jg-alert.sh - the alert table and the one function that raises an alert from it (section 6.7 and machine 5 of section 6.12).
#
# Usage:
#   jg-alert.sh row <alert>                 print the row: name, fires on, fires at, precedence, first rung, quiet when
#   jg-alert.sh limit <kind>                print the slow-delivery limit in seconds for a kind of work (0 = none)
#   jg-alert.sh timers                      print the wait ladder's timers, one "<name> <seconds>" line each: escalate (the stuck-wait
#                                           precedence's seconds to the next rung), card (two such steps), realert (its repeat), ready-stall
#   jg-alert.sh raise <alert> <subject> [--mode <delivery word>] [--kind <kind>] [--held <seconds>] [--fact k=v | word]...
#                     [--home H] [--project P] [--route R] [--machine M] [--ticket T] [--rung N] [--wake <kind> --text <line>] [--repeat]
#                     [--note <text>] [--deliver | --print]
#   jg-alert.sh capacity <producer> <text> [--deliver | --print]   raise the capacity alert for a quota, account, model or machine-slot event
#   jg-alert.sh climb <key> [--now <epoch>]   take the next rung when the rung's timer ran out; at the top rung repeat the ring when the repeat timer ran
#                                           out, and after the ladder's repeats make the alert stuck (see below)
#   jg-alert.sh ack|reopen|resolve <key>      the other moves of the alert machine; resolve also releases the alerts it covered
#   jg-alert.sh show <key> | word <key> | list   print a record, its state word, or every live key
#   jg-alert.sh deliver                      read ring lines on stdin (what raise, climb and resolve print) and deliver each to its holder
# A key is <alert>--<subject>. The record is state/alerts/<key>.rec (key=value lines); rung and precedence are fields of it.
#
# raise refuses an unknown alert or mode and a state that has not held for the row's time (--held below fires at), prints nothing
# for a quiet row (a fact of its "quiet when" holds), records the alert `inhibited` when a rule I1 to I5 covers it, and otherwise
# records it `open` and prints one ring line: ring<TAB>key<TAB>rung<TAB>holder. Rule I6 (fact presence=away) holds rung 4 for P1 to P3.
# --rung N starts the climb at rung N instead of the row's first rung (the tick-driven climb is not built, so a producer that must
# wake someone now starts at 1). --wake <kind> --text <line> make deliver append that kind of wake, keyed by the subject, carrying the
# line, instead of the `check` wake, so a consumer of an older wake kind keeps reading what it read. --repeat rings an alert that is
# still open again (a producer that fires every window), with the new text, instead of staying silent.
# The row is the same in every delivery mode; the mode is recorded and checked against bin/jg-delivery-style.sh.
# --note records the producer's own text (one line) in the record and the wake; --deliver pipes the ring through `deliver` at once; --print prints the wake line a registered check hands the watcher instead of a ring.
# capacity is the one entry every capacity producer calls: the subject is the producer, and a new event of it resolves its last one.
# A stuck alert (the ladder's column 7 gives the repeats) is quiet and does not climb. Its climb prints a `stuck` line once and the ring of one
# escalation-stuck alert (the owner's card and page); resolving the stuck alert resolves that card too. escalation-stuck never repeats.
# A row whose fires-at is `limit` reads the limit of --kind, or of the kind named like the alert when no --kind is given (stranded: 48 h, or
# --kind stranded-release: 4 h).
# deliver turns a ring into the wake its holder reads: the tick only records it (settled, no wake); worker, lead, main and owner get one
# `check` wake with key alert-<key> that names the alert, its precedence, the rung and the holder. A line that is not a ring is refused.
# Exit 0 is success, 1 a refusal, 2 a usage error. The table is core/machines/styles/alert-table.tsv (override: JG_ALERT_TABLE).
set -u
export LC_ALL=C
_root=$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/.." && pwd)
_table() { printf '%s\n' "${JG_ALERT_TABLE:-$_root/core/machines/styles/alert-table.tsv}"; }
_dir() { local s=${JG_STATE_OVERRIDE:-${JG_HOME:-$_root}/state}; printf '%s/alerts\n' "$s"; }
_die() { printf 'jg-alert: %s\n' "$*" >&2; exit "${_rc:-1}"; }
_get() { sed -n "s/^$2=//p" "$1" | head -1; }
_rows() { awk -F'\t' -v k="$1" '$1==k' "$(_table)"; }
_holder() { case $1 in 0) echo tick ;; 1) echo worker ;; 2) echo lead ;; 3) echo main ;; *) echo owner ;; esac; }
_edge() { bash "$_root/bin/jg-machine.sh" edge-check alert "$1" "$2" >/dev/null 2>&1; }
# The four state words come from the machine table (kind initial, mode waiting after it, mode rest, kind terminal), never typed here.
_names() { awk -F'\t' -v k="$1" -v m="$2" -v l="${3:-}" '$1=="state" && (k=="" || $3==k) && (m=="" || $6==m) && (l=="" || $7==l) {print $2}' "$_root/core/machines/tables/alert.tsv"; }
s_open=$(_names initial ""); s_ack=$(_names normal waiting); s_inh=$(_names normal rest release); s_stuck=$(_names normal rest resolve); s_res=$(_names terminal "")
_put() { local f=$1; shift; mkdir -p "$(dirname "$f")"; printf '%s\n' "$@" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }
_set() { local f=$1 k=$2 v=$3; { grep -v "^$k=" "$f" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }

# _quiet <quiet-when> <fact>...: 0 when a fact set matches. `+` separates alternatives, `,` joins facts that must all hold, `a|b` lists values.
_quiet() {
  local q=$1 alt part k v f ok hit; shift
  [ "$q" != never ] || return 1
  while IFS= read -r alt; do
    ok=1
    while IFS= read -r part; do
      hit=0
      for f in "$@"; do
        if [ "${part#*=}" = "$part" ]; then [ "$f" != "$part" ] || hit=1
        else k=${part%%=*}; v=${part#*=}; [ "${f%%=*}" = "$k" ] && case "|$v|" in *"|${f#*=}|"*) hit=1 ;; esac; fi
      done
      [ "$hit" = 1 ] || { ok=0; break; }
    done < <(tr ',' '\n' <<<"$alt")
    [ "$ok" = 0 ] || return 0
  done < <(tr '+' '\n' <<<"$q")
  return 1
}

# _top <precedence> <first rung> <fact>...: the highest rung the ladder may reach.
_top() {
  local p=$1 s=$2 t lift f; shift 2
  read -r t lift < <(_rows ladder | awk -F'\t' '$2==p {print $5, $6}' p="$p")
  [ "$t" != start+2 ] || { t=$((s + 2)); [ "$t" -le 3 ] || t=3; }
  for f in "$@"; do [ "$lift" = - ] || [ "$f" != "$lift" ] || t=4; done
  echo "$t"
}

# _cap <alert> <precedence> <rung> <facts>: rule I6, rung 4 is held for the precedences its list names while presence is away; "!alert" exempts one.
_cap() {
  local n=$1 p=$2 r=$3 kept; shift 3
  kept=$(_rows rule | awk -F'\t' '$2=="I6" {print $5}')
  case " $* " in *" presence=away "*) [ "$r" -lt 4 ] || case ",${kept#*:}" in *",!$n"*) ;; *",$p"*) r=3 ;; esac ;; esac
  echo "$r"
}

cmd_row() {
  _rows alert | awk -F'\t' -v a="${1:?usage: row <alert>}" '$2==a {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7; f=1} END {exit f?0:1}' \
    || _die "unknown alert '$1' (known: $(_rows alert | cut -f2 | paste -sd' ' -))"
}
cmd_limit() { _rows limit | awk -F'\t' -v k="${1:?usage: limit <kind>}" '$2==k {print $3; f=1} END {exit f?0:1}' || _die "unknown kind '$1' (known: $(_rows limit | cut -f2 | paste -sd' ' -))"; }

# The wait ladder (core/wait-timers) reads every rung timer here, so the table is its only owner.
cmd_timers() {
  local prec step repeat stall
  prec=$(_rows alert | awk -F'\t' '$2=="stuck-wait" {print $5}')
  read -r step repeat < <(_rows ladder | awk -F'\t' -v p="$prec" '$2==p {print $3, $4}')
  stall=$(_rows alert | awk -F'\t' '$2=="ready-idle" {print $4}')
  [ "${step:-0}" -gt 0 ] && [ "${repeat:-0}" -gt 0 ] && [ "${stall:-0}" -gt 0 ] || _die "the alert table has no usable stuck-wait ladder or ready-idle timer"
  printf 'escalate\t%s\ncard\t%s\nrealert\t%s\nready-stall\t%s\n' "$step" $((step * 2)) "$repeat" "$stall"
}

cmd_raise() {
  local name=${1:-} subj=${2:-} mode='' kind='' held='' facts=() sc_home='' sc_project='' sc_route='' sc_machine='' sc_ticket='' note='' now_deliver=0 now_print=0 rung='' wake='' text='' again=''
  [ -n "$name" ] && [ -n "$subj" ] || { _rc=2 _die "usage: raise <alert> <subject> [options]"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$1" != --deliver ] || { now_deliver=1; shift; continue; }
    [ "$1" != --print ] || { now_print=1; shift; continue; }
    [ "$1" != --repeat ] || { again=1; shift; continue; }
    [ "$#" -ge 2 ] || { _rc=2 _die "option $1 needs a value"; }
    case $1 in
      --mode) mode=$2 ;; --kind) kind=$2 ;; --held) held=$2 ;; --fact) facts+=("$2") ;;
      --home) sc_home=$2 ;; --project) sc_project=$2 ;; --route) sc_route=$2 ;; --machine) sc_machine=$2 ;; --ticket) sc_ticket=$2 ;; --rung) rung=$2 ;; --wake) wake=$2 ;; --text) text=$2 ;; --note) note=$(printf '%s' "$2" | tr '\t\r\n' '   ') ;;
      *) _rc=2 _die "unknown option $1" ;;
    esac
    shift 2
  done
  local row; row=$(cmd_row "$name") || exit 1
  local at prec first quiet; IFS=$'\t' read -r _ _ at prec first quiet <<<"$row"
  if [ -n "$mode" ]; then
    # shellcheck source=bin/jg-delivery-style.sh disable=SC1091
    . "$_root/bin/jg-delivery-style.sh"; jg_delivery_style_accepts "$mode" || _die "unknown delivery mode '$mode'"
  fi
  case $at in limit) at=$(cmd_limit "${kind:-$name}") || exit 1 ;; beats:*) at= ;; esac
  [ -z "$held" ] || [ -z "$at" ] || [ "$held" -ge "$at" ] || _die "$name has not held for $at s yet (held $held s)"
  _quiet "$quiet" "${facts[@]}" && return 0
  local start=$first f
  if [ "$first" = wait ]; then
    for f in "${facts[@]}"; do [ "${f%%=*}" != wait ] || case ${f#*=} in worker) start=1 ;; lead) start=2 ;; main) start=3 ;; esac; done
    case $start in [0-4]) ;; *) _die "stuck-wait needs --fact wait=worker|lead|main" ;; esac
  fi
  case $rung in '') ;; [0-4]) start=$rung ;; *) _rc=2 _die "--rung is 0 to 4" ;; esac
  text=$(printf '%s' "$text" | tr '\n\t' '  ')
  local key="$name--$subj" file; file="$(_dir)/$key.rec"
  case $key in */*|*..*) _die "bad subject '$subj'" ;; esac
  if [ -r "$file" ]; then
    local cur; cur=$(_get "$file" state)
    if [ "$cur" != "$s_res" ]; then   # one live record for one key
      if [ -n "$again" ] && [ "$cur" = "$s_open" ]; then
        _set "$file" text "$text"; _set "$file" wake "$wake"
        printf 'ring\t%s\t%s\t%s\n' "$key" "$(_get "$file" rung)" "$(_holder "$(_get "$file" rung)")"
      fi
      return 0
    fi
  fi
  start=$(_cap "$name" "$prec" "$start" "${facts[@]}")
  local now cover; now=${JG_ALERT_NOW:-$(date +%s)}
  cover=$(_cover "$name" "$prec" "$sc_home" "$sc_project" "$sc_route" "$sc_machine" "$sc_ticket" || true)
  local st=$s_open
  _put "$file" "alert=$name" "subject=$subj" "mode=$mode" "precedence=$prec" "rung=$start" "top=$(_top "$prec" "$start" "${facts[@]}")" \
    "since=$now" "rung_at=$now" "home=$sc_home" "project=$sc_project" "route=$sc_route" "machine=$sc_machine" "ticket=$sc_ticket" "note=$note" "wake=$wake" "text=$text" "repeats=0" "state=$st"
  if [ -n "$cover" ]; then
    _edge "$st" "$s_inh" || _die "the alert table has no inhibit move"
    _set "$file" state "$s_inh"; _set "$file" covered_by "$cover"
    return 0
  fi
  if [ "$now_print" = 1 ]; then _payload "$key" "$start" "$(_holder "$start")"
  elif [ "$now_deliver" = 1 ]; then printf 'ring\t%s\t%s\t%s\n' "$key" "$start" "$(_holder "$start")" | cmd_deliver
  else printf 'ring\t%s\t%s\t%s\n' "$key" "$start" "$(_holder "$start")"; fi
}

# _cover <alert> <precedence> <home> <project> <route> <machine> <ticket>: the key of a live alert that rules I1 to I5 say covers this one.
_cover() {
  local name=$1 prec=$2 rec id cov scope kept val
  for rec in "$(_dir)"/*.rec; do
    [ -r "$rec" ] || continue
    case $(_get "$rec" state) in "$s_open"|"$s_ack"|"$s_stuck") ;; *) continue ;; esac
    while IFS=$'\t' read -r _ id cov scope kept _; do
      [ "$id" != I6 ] || continue
      val=$(_get "$rec" "$scope"); [ -n "$val" ] && [ "$val" = "$(_scope_of "$scope" "$3" "$4" "$5" "$6" "$7")" ] || continue
      if [ "$cov" = '*' ]; then [ "$(_get "$rec" precedence)" \< "$prec" ] || continue   # P0 < P1 < P2 < P3: only a higher precedence covers
      else
        [ "$(_get "$rec" alert)" = "$cov" ] || continue
        case ",$kept," in *",$name,"*) ;; *) continue ;; esac
      fi
      echo "$(_get "$rec" alert)--$(_get "$rec" subject)"; return 0
    done < <(_rows rule)
  done
  return 1
}
_scope_of() { case $1 in home) echo "$2" ;; project) echo "$3" ;; route) echo "$4" ;; machine) echo "$5" ;; ticket) echo "$6" ;; esac; }

_rec() { local f; f="$(_dir)/${1:?usage: $2 <key>}.rec"; [ -r "$f" ] || _die "no alert '$1'"; printf '%s\n' "$f"; }

cmd_climb() {
  local f now=${JG_ALERT_NOW:-$(date +%s)}; f=$(_rec "${1:-}" climb) || exit 1
  [ "${2:-}" != --now ] || now=${3:?--now needs an epoch}
  local st rung top prec after; st=$(_get "$f" state); rung=$(_get "$f" rung); top=$(_get "$f" top); prec=$(_get "$f" precedence)
  _edge "$st" "$st" && [ "$st" = "$s_open" ] || _die "alert '$1' is $st: only an open alert climbs"
  [ "$rung" -lt "$top" ] || { _repeat "$f" "$1" "$now" "$prec" "$rung"; return; }
  after=$(_rows ladder | awk -F'\t' '$2==p {print $3}' p="$prec")
  [ "$after" -gt 0 ] || _die "$prec has no climb timer"
  [ $((now - $(_get "$f" rung_at))) -ge "$after" ] || _die "rung timer of $after s has not run out"
  _set "$f" rung $((rung + 1)); _set "$f" rung_at "$now"
  printf 'ring\t%s\t%s\t%s\n' "$1" $((rung + 1)) "$(_holder $((rung + 1)))"
}
# _repeat <file> <key> <now> <precedence> <rung>: the climb of an alert at its top rung. Each repeat timer that runs out rings the rung again, up
# to the ladder's repeats; the next one makes the alert stuck: one `stuck` line, then the ring of its one escalation-stuck card, and no more rings.
_repeat() {
  local f=$1 key=$2 now=$3 prec=$4 rung=$5 gap max n name; name=$(_get "$f" alert)
  [ "$name" != escalation-stuck ] || _die "alert '$key' is at its top rung $rung: escalation-stuck is the page and does not repeat"
  read -r gap max < <(_rows ladder | awk -F'\t' '$2==p {print $4, $7}' p="$prec")
  [ "${gap:-0}" -gt 0 ] && [ "${max:-0}" -gt 0 ] || _die "$prec has no repeat timer or repeat count in the ladder"
  [ $((now - $(_get "$f" rung_at))) -ge "$gap" ] || _die "alert '$key' is at its top rung $rung: repeat timer of $gap s has not run out"
  n=$(_get "$f" repeats); n=${n:-0}
  _set "$f" rung_at "$now"
  if [ "$n" -lt "$max" ]; then
    _set "$f" repeats $((n + 1))
    printf 'ring\t%s\t%s\t%s\n' "$key" "$rung" "$(_holder "$rung")"
    return 0
  fi
  _edge "$s_open" "$s_stuck" || _die "the alert table has no stuck move"
  _set "$f" state "$s_stuck"
  printf 'stuck\t%s\t%s\t%s\n' "$key" "$rung" "$(_holder "$rung")"
  cmd_raise escalation-stuck "$key" --note "$name sat at rung $rung through $max repeats with no answer"
}
_move() {  # _move <key> <from word> <to word>
  local f; f=$(_rec "$1" move) || exit 1
  [ "$(_get "$f" state)" = "$2" ] || _die "alert '$1' is $(_get "$f" state), not $2"
  _edge "$2" "$3" || _die "no move from $2 to $3"
  _set "$f" state "$3"
}
cmd_ack() { _move "${1:-}" "$s_open" "$s_ack"; }
cmd_reopen() { _move "${1:-}" "$s_ack" "$s_open"; }
cmd_resolve() {
  local f cur rec; f=$(_rec "${1:-}" resolve) || exit 1
  cur=$(_get "$f" state); [ "$cur" != "$s_res" ] || return 0
  _edge "$cur" "$s_res" || _die "no move from $cur to resolved"
  _set "$f" state "$s_res"
  # The card of a stuck alert goes with it, so a new episode of the key can be stuck again.
  local card; card="$(_dir)/escalation-stuck--$1.rec"
  [ "$cur" != "$s_stuck" ] || [ ! -r "$card" ] || [ "$(_get "$card" state)" = "$s_res" ] || _set "$card" state "$s_res"
  for rec in "$(_dir)"/*.rec; do   # release what this alert covered
    [ -r "$rec" ] && [ "$(_get "$rec" covered_by)" = "$1" ] || continue
    _set "$rec" state "$s_open"; _set "$rec" covered_by ""
    printf 'ring\t%s--%s\t%s\t%s\n' "$(_get "$rec" alert)" "$(_get "$rec" subject)" "$(_get "$rec" rung)" "$(_holder "$(_get "$rec" rung)")"
  done
}
cmd_show() { cat "$(_rec "${1:-}" show)"; }
cmd_word() { _get "$(_rec "${1:-}" word)" state; }
cmd_list() { local r; for r in "$(_dir)"/*.rec; do [ -r "$r" ] && case $(_get "$r" state) in resolved) ;; *) basename "$r" .rec ;; esac; done; return 0; }

# _payload <key> <rung> <holder>: the one line a delivered or printed alert carries.
_payload() {
  local rec note; rec=$(_rec "$1" payload) || exit 1; note=$(_get "$rec" note)
  printf 'alert %s (%s) at rung %s for %s: %s%s\n' "$(_get "$rec" alert)" "$(_get "$rec" precedence)" "$2" "$3" "$(_get "$rec" subject)" "${note:+ - $note}"
}
cmd_capacity() {
  local producer=${1:-} text=${2:-}
  [ -n "$producer" ] && [ -n "$text" ] || { _rc=2 _die "usage: capacity <producer> <text> [--deliver | --print]"; }
  shift 2
  # A new event of one producer supersedes its last one: the old record resolves in place (its cover, if any, is the same key).
  local old; old="$(_dir)/capacity--$producer.rec"
  if [ -r "$old" ] && [ "$(_get "$old" state)" != "$s_res" ]; then _edge "$(_get "$old" state)" "$s_res" && _set "$old" state "$s_res"; fi
  cmd_raise capacity "$producer" --note "$text" "$@"
}

cmd_deliver() {
  local tag key rung holder rec payload kind
  # shellcheck source=bin/jg-wake-lib.sh disable=SC1091
  . "$_root/bin/jg-wake-lib.sh"
  while IFS=$'\t' read -r tag key rung holder; do
    [ -n "$tag" ] || continue
    [ "$tag" != stuck ] || continue   # the stuck line only tells the caller; the card's ring is the page
    [ "$tag" = ring ] && [ -n "$holder" ] || _die "not a ring line: '$tag'"
    rec=$(_rec "$key" deliver) || exit 1
    payload=$(_payload "$key" "$rung" "$holder")
    kind=$(_get "$rec" wake)
    if [ -n "$kind" ] && [ "$holder" != tick ]; then jg_wake_append "$kind" "$(_get "$rec" subject)" "$(_get "$rec" text)" || _die "the wake for $key was not appended"
    elif [ "$holder" = tick ]; then jg_wake_settle check "alert-$key" "$payload"
    else jg_wake_append check "alert-$key" "$payload" || _die "the wake for $key was not appended"; fi
  done
}

[ "$#" -gt 0 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
c=$1; shift
case $c in
  row|limit|timers|raise|capacity|climb|ack|reopen|resolve|show|word|list|deliver) "cmd_$c" "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
