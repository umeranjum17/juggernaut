#!/usr/bin/env bash
# jg-alert.sh - the alert table and the one function that raises an alert from it (section 6.7 and machine 5 of section 6.12).
#
# Usage:
#   jg-alert.sh row <alert>                 print the row: name, fires on, fires at, precedence, first rung, quiet when
#   jg-alert.sh limit <kind>                print the slow-delivery limit in seconds for a kind of work (0 = none)
#   jg-alert.sh raise <alert> <subject> [--mode <delivery word>] [--kind <kind>] [--held <seconds>] [--fact k=v | word]...
#                     [--home H] [--project P] [--route R] [--machine M] [--ticket T]
#   jg-alert.sh climb <key> [--now <epoch>]   take the next rung when the rung's timer ran out and the row's top is not reached
#   jg-alert.sh ack|reopen|resolve <key>      the other moves of the alert machine; resolve also releases the alerts it covered
#   jg-alert.sh show <key> | word <key> | list   print a record, its state word, or every live key
#   jg-alert.sh deliver                      read ring lines on stdin (what raise, climb and resolve print) and deliver each to its holder
# A key is <alert>--<subject>. The record is state/alerts/<key>.rec (key=value lines); rung and precedence are fields of it.
#
# raise refuses an unknown alert or mode and a state that has not held for the row's time (--held below fires at), prints nothing
# for a quiet row (a fact of its "quiet when" holds), records the alert `inhibited` when a rule I1 to I5 covers it, and otherwise
# records it `open` and prints one ring line: ring<TAB>key<TAB>rung<TAB>holder. Rule I6 (fact presence=away) holds rung 4 for P1 to P3.
# The row is the same in every delivery mode; the mode is recorded and checked against bin/jg-delivery-style.sh.
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
_names() { awk -F'\t' -v k="$1" -v m="$2" '$1=="state" && (k=="" || $3==k) && (m=="" || $6==m) {print $2}' "$_root/core/machines/tables/alert.tsv"; }
s_open=$(_names initial ""); s_ack=$(_names normal waiting); s_inh=$(_names normal rest); s_res=$(_names terminal "")
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

# _cap <precedence> <rung> <facts>: rule I6, rung 4 is held for P1 to P3 while presence is away.
_cap() { local p=$1 r=$2; shift 2; case " $* " in *" presence=away "*) [ "$r" -lt 4 ] || [ "$p" = P0 ] || r=3 ;; esac; echo "$r"; }

cmd_row() {
  _rows alert | awk -F'\t' -v a="${1:?usage: row <alert>}" '$2==a {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7; f=1} END {exit f?0:1}' \
    || _die "unknown alert '$1' (known: $(_rows alert | cut -f2 | paste -sd' ' -))"
}
cmd_limit() { _rows limit | awk -F'\t' -v k="${1:?usage: limit <kind>}" '$2==k {print $3; f=1} END {exit f?0:1}' || _die "unknown kind '$1' (known: $(_rows limit | cut -f2 | paste -sd' ' -))"; }

cmd_raise() {
  local name=${1:-} subj=${2:-} mode='' kind='' held='' facts=() sc_home='' sc_project='' sc_route='' sc_machine='' sc_ticket=''
  [ -n "$name" ] && [ -n "$subj" ] || { _rc=2 _die "usage: raise <alert> <subject> [options]"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || { _rc=2 _die "option $1 needs a value"; }
    case $1 in
      --mode) mode=$2 ;; --kind) kind=$2 ;; --held) held=$2 ;; --fact) facts+=("$2") ;;
      --home) sc_home=$2 ;; --project) sc_project=$2 ;; --route) sc_route=$2 ;; --machine) sc_machine=$2 ;; --ticket) sc_ticket=$2 ;;
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
  case $at in limit) at=$(cmd_limit "${kind:?slow-delivery needs --kind}") || exit 1 ;; beats:*) at= ;; esac
  [ -z "$held" ] || [ -z "$at" ] || [ "$held" -ge "$at" ] || _die "$name has not held for $at s yet (held $held s)"
  _quiet "$quiet" "${facts[@]}" && return 0
  local start=$first f
  if [ "$first" = wait ]; then
    for f in "${facts[@]}"; do [ "${f%%=*}" != wait ] || case ${f#*=} in worker) start=1 ;; lead) start=2 ;; main) start=3 ;; esac; done
    case $start in [0-4]) ;; *) _die "stuck-wait needs --fact wait=worker|lead|main" ;; esac
  fi
  local key="$name--$subj" file; file="$(_dir)/$key.rec"
  case $key in */*|*..*) _die "bad subject '$subj'" ;; esac
  if [ -r "$file" ]; then
    local cur; cur=$(_get "$file" state)
    [ "$cur" = "$s_res" ] || return 0   # one live record for one key
  fi
  start=$(_cap "$prec" "$start" "${facts[@]}")
  local now cover; now=${JG_ALERT_NOW:-$(date +%s)}
  cover=$(_cover "$name" "$prec" "$sc_home" "$sc_project" "$sc_route" "$sc_machine" "$sc_ticket" || true)
  local st=$s_open
  _put "$file" "alert=$name" "subject=$subj" "mode=$mode" "precedence=$prec" "rung=$start" "top=$(_top "$prec" "$start" "${facts[@]}")" \
    "since=$now" "rung_at=$now" "home=$sc_home" "project=$sc_project" "route=$sc_route" "machine=$sc_machine" "ticket=$sc_ticket" "state=$st"
  if [ -n "$cover" ]; then
    _edge "$st" "$s_inh" || _die "the alert table has no inhibit move"
    _set "$file" state "$s_inh"; _set "$file" covered_by "$cover"
    return 0
  fi
  printf 'ring\t%s\t%s\t%s\n' "$key" "$start" "$(_holder "$start")"
}

# _cover <alert> <precedence> <home> <project> <route> <machine> <ticket>: the key of a live alert that rules I1 to I5 say covers this one.
_cover() {
  local name=$1 prec=$2 rec id cov scope kept val
  for rec in "$(_dir)"/*.rec; do
    [ -r "$rec" ] || continue
    case $(_get "$rec" state) in "$s_open"|"$s_ack") ;; *) continue ;; esac
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
  [ "$rung" -lt "$top" ] || _die "alert '$1' is at its top rung $top"
  after=$(_rows ladder | awk -F'\t' '$2==p {print $3}' p="$prec")
  [ "$after" -gt 0 ] || _die "$prec has no climb timer"
  [ $((now - $(_get "$f" rung_at))) -ge "$after" ] || _die "rung timer of $after s has not run out"
  _set "$f" rung $((rung + 1)); _set "$f" rung_at "$now"
  printf 'ring\t%s\t%s\t%s\n' "$1" $((rung + 1)) "$(_holder $((rung + 1)))"
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
  for rec in "$(_dir)"/*.rec; do   # release what this alert covered
    [ -r "$rec" ] && [ "$(_get "$rec" covered_by)" = "$1" ] || continue
    _set "$rec" state "$s_open"; _set "$rec" covered_by ""
    printf 'ring\t%s--%s\t%s\t%s\n' "$(_get "$rec" alert)" "$(_get "$rec" subject)" "$(_get "$rec" rung)" "$(_holder "$(_get "$rec" rung)")"
  done
}
cmd_show() { cat "$(_rec "${1:-}" show)"; }
cmd_word() { _get "$(_rec "${1:-}" word)" state; }
cmd_list() { local r; for r in "$(_dir)"/*.rec; do [ -r "$r" ] && case $(_get "$r" state) in resolved) ;; *) basename "$r" .rec ;; esac; done; return 0; }

cmd_deliver() {
  local tag key rung holder rec name prec payload
  # shellcheck source=bin/jg-wake-lib.sh disable=SC1091
  . "$_root/bin/jg-wake-lib.sh"
  while IFS=$'\t' read -r tag key rung holder; do
    [ -n "$tag" ] || continue
    [ "$tag" = ring ] && [ -n "$holder" ] || _die "not a ring line: '$tag'"
    rec=$(_rec "$key" deliver) || exit 1
    name=$(_get "$rec" alert); prec=$(_get "$rec" precedence)
    payload="alert $name ($prec) at rung $rung for $holder: $(_get "$rec" subject)"
    if [ "$holder" = tick ]; then jg_wake_settle check "alert-$key" "$payload"
    else jg_wake_append check "alert-$key" "$payload" || _die "the wake for $key was not appended"; fi
  done
}

[ "$#" -gt 0 ] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
c=$1; shift
case $c in
  row|limit|raise|climb|ack|reopen|resolve|show|word|list|deliver) "cmd_$c" "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
