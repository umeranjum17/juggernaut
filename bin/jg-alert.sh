#!/usr/bin/env bash
# jg-alert.sh - the alert ladder (read from the store) and the one function that raises an alert from it (section 6.7 and machine 5 of section 6.12).
#
# Usage:
#   jg-alert.sh row <alert>                 print the row: name, fires on, fires at, precedence, first rung, quiet when
#   jg-alert.sh limit <kind>                print the slow-delivery limit in seconds for a kind of work (0 = none)
#   jg-alert.sh timers                      print the wait ladder's timers, one "<name> <seconds>" line each: escalate (the stuck-wait
#                                           precedence's seconds to the next rung), card (two such steps), realert (its repeat), ready-stall
#   jg-alert.sh raise <alert> <subject> [--mode <delivery word>] [--kind <kind>] [--held <seconds>] [--fact k=v | word]...
#                     [--home H] [--project P] [--route R] [--machine M] [--ticket T] [--rung N] [--wake <kind> --text <line>] [--repeat]
#                     [--note <text>] [--deliver | --print]
#                     [--owner-gate G --ticket T --origin O | --security-source S]
# Owner delivery requires a current open gate for that ticket/origin or an allowed typed security producer.
# Team alerts stop at Main, including derived escalation-stuck alerts; facts never grant owner authority.
# --source-alert K is reserved for escalation-stuck derivation from K's stuck episode.
#   jg-alert.sh capacity <producer> <text> [--deliver | --print]   raise the capacity alert for a quota, account, model or machine-slot event
#   jg-alert.sh climb <key> [--now <epoch>]   take the next rung when the rung's timer ran out; at the top rung repeat the ring when the repeat timer ran
#                                           out, and after the ladder's repeats make the alert stuck (see below)
#   jg-alert.sh ack <key>                   the one it rang took it: it never takes the alert's deadline
#   jg-alert.sh reopen <key> [--now <epoch>]  an acknowledged alert whose deadline ran out reopens and rings its rung again (the deadline's
#                                           one owner; it refuses before the deadline)
#   jg-alert.sh resolve <key> --proof <kind>:<pointer>
#                                           the cause is gone: source:<observed> from the producer that re-read it, or the action evidence
#                                           (status, task, commit, pr or reply: the kinds bin/jg-delivery.sh handled takes). A close with no
#                                           proof is refused, so a read notice or a vanished queue row can never clear an alert. resolve
#                                           also releases the alerts it covered
#   jg-alert.sh overdue [--now <epoch>]     the live alerts whose action deadline ran out: one line each, exit 1 when it lists any
#   jg-alert.sh show <key> | word <key> | list   print a record, its state word, or every live key
#   jg-alert.sh deliver                      read ring lines on stdin (what raise, climb and resolve print) and deliver each to its holder
# A key is <alert>--<subject>. The record is state/alerts/<key>.rec (key=value lines); rung, precedence and deadline_at are fields of it.
# Every live alert carries one action deadline (deadline_at): the epoch its state's next move is due. It is set when the rung is raised or
# moves (raise, climb, repeat, reopen, release) and when an acknowledgement is taken (that state's own timeout in the machine table). No read,
# acknowledgement or queue change moves it, so an acknowledged alert still comes due: report section 5.2 and ban B10.
#
# raise refuses an unknown alert or mode and a state that has not held for the row's time (--held below fires at), prints nothing
# for a quiet row (a fact of its "quiet when" holds), records the alert `inhibited` when a rule I1 to I5 covers it, and otherwise
# records it `open` and prints one ring line: ring<TAB>key<TAB>rung<TAB>holder. Rule I6 (fact presence=away) holds rung 4 for P1 to P3.
# --rung N starts the climb at rung N instead of the row's first rung (the tick-driven climb is not built, so a producer that must
# wake someone now starts at 1). --wake <kind> --text <line> make deliver append that kind of wake, keyed by the subject, carrying the
# line, instead of the `check` wake, so a consumer of an older wake kind keeps reading what it read. --repeat rings an alert that is
# still open again (a producer that fires every window), with the new text, instead of staying silent; a repeat carrying the same note
# and text the record already rang is a replay of one episode, so it rings and delivers nothing (one alert per episode).
# The row is the same in every delivery mode; the mode is recorded and checked against bin/jg-delivery-style.sh.
# --note records the producer's own text (one line) in the record and the wake; --deliver pipes the ring through `deliver` at once; --print prints the wake line a registered check hands the watcher instead of a ring.
# capacity is the one entry every capacity producer calls: the subject is the producer, and a new event of it resolves its last one.
# A stuck alert (the ladder's column 7 gives the repeats) is quiet and does not climb. Its climb prints a `stuck` line once and the ring of one
# escalation-stuck alert with the source's authority; resolving the stuck alert resolves that recovery too. escalation-stuck never repeats.
# A row whose fires-at is `limit` reads the limit of --kind, or of the kind named like the alert when no --kind is given (stranded: 48 h, or
# --kind stranded-release: 4 h).
# deliver turns a ring into the wake its holder reads: the tick only records it (settled, no wake); worker, lead, main and owner get one
# `check` wake with key alert-<key> that names the alert, its precedence, the rung and the holder. A line that is not a ring is refused.
# Main's rung in a Squad Lead home goes up the parent channel instead (_route_main), and resolve closes it there; a --wake record keeps
# the local consumer its producer named.
# Exit 0 is success, 1 a refusal, 2 a usage error. The rules are the store's views (core/item-store/schema.sql, read through core/item-store/alertrules.py).
set -u
export LC_ALL=C
_root=$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/.." && pwd)
_dir() { local s=${JG_STATE_OVERRIDE:-${JG_HOME:-$_root}/state}; printf '%s/alerts\n' "$s"; }
_die() { printf 'jg-alert: %s\n' "$*" >&2; exit "${_rc:-1}"; }
_get() { sed -n "s/^$2=//p" "$1" | head -1; }
# _rows <kind>: the rules of one kind (alert, rule, ladder, limit, authority, security-source), one tab-separated line each, read once from the store's views.
_rows() {
  [ -n "${_rules:-}" ] || _rules=$(python3 -I "$_root/core/item-store/alertrules.py" dump) || _die "cannot read the alert rules from the store views"
  awk -F'\t' -v k="$1" '$1==k' <<<"$_rules"
}
_holder() { case $1 in 0) echo tick ;; 1) echo worker ;; 2) echo lead ;; 3) echo main ;; *) echo owner ;; esac; }
# The four state words come from the machine table (kind initial, mode waiting after it, mode rest, kind terminal), never typed here.
_names() { awk -F'\t' -v k="$1" -v m="$2" -v l="${3:-}" '$1=="state" && (k=="" || $3==k) && (m=="" || $6==m) && (l=="" || $7==l) {print $2}' "$_root/core/machines/tables/alert.tsv"; }
s_open=$(_names initial ""); s_ack=$(_names normal waiting); s_inh=$(_names normal rest release); s_stuck=$(_names normal rest resolve); s_res=$(_names terminal "")
_put() { local f=$1; shift; mkdir -p "$(dirname "$f")"; printf '%s\n' "$@" >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }
_set() { local f=$1 k=$2 v=$3; { grep -v "^$k=" "$f" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } >"$f.tmp.$$" && mv "$f.tmp.$$" "$f"; }

# The action deadline (report section 5.2, ban B10). One number per live record, deadline_at: the epoch its state's next move is due.
# _secs turns the table's duration words ("10m") into seconds.
_secs() {
  local t=${1:-} n u
  case $t in '' | *[!0-9smhd]*) echo 0; return 0 ;; esac
  n=${t%?}; u=${t#"${t%?}"}
  case $n in '' | *[!0-9]*) echo 0; return 0 ;; esac
  case $u in s) echo "$n" ;; m) echo $((n * 60)) ;; h) echo $((n * 3600)) ;; d) echo $((n * 86400)) ;; *) echo 0 ;; esac
}
# _state_timer <state>: the timeout that state declares in the machine table ("10m -> reopen"), in seconds; 0 when it declares none.
_state_timer() {
  local t; t=$(awk -F'\t' -v k="$1" '$1=="state" && $2==k {print $7}' "$_root/core/machines/tables/alert.tsv")
  _secs "${t%% -> *}"
}
# _ladder_timer <precedence> <rung> <top>: seconds until the rung's next move is due: the next rung's step, else the top rung's repeat.
_ladder_timer() {
  local step repeat; read -r step repeat < <(_rows ladder | awk -F'\t' -v p="$1" 'p==$2 {print $3, $4}')
  if [ "${2:-0}" -lt "${3:-0}" ] && [ "${step:-0}" -gt 0 ]; then echo "$step"; else echo "${repeat:-0}"; fi
}
# _due <file>: the record's action deadline. A record written before deadlines were recorded derives it: an open alert from its rung's
# ladder timer, an acknowledged one from the timeout its own state declares. A state with neither is not due at all.
_due() {
  local dl st base secs; dl=$(_get "$1" deadline_at); if [ -n "$dl" ]; then echo "$dl"; return 0; fi
  st=$(_get "$1" state); base=$(_get "$1" rung_at); [ -n "$base" ] || base=$(_get "$1" since)
  case $st in
    "$s_open") secs=$(_ladder_timer "$(_get "$1" precedence)" "$(_get "$1" rung)" "$(_get "$1" top)") ;;
    "$s_ack") secs=$(_state_timer "$st") ;;
    *) echo 0; return 0 ;;
  esac
  echo $(( ${base:-0} + secs ))
}
# _stamp_due <file> <now> <seconds>: the state began now, so its next move is due <seconds> later.
_stamp_due() { _set "$1" rung_at "$2"; _set "$1" deadline_at $(( $2 + $3 )); }
# shellcheck source=bin/jg-alert-authority-lib.sh
. "$_root/bin/jg-alert-authority-lib.sh"

# _store_mirror <verb> <args>...: the item store mirrors every alert move (core/item-store/adapters/alerts.py). The home is JG_HOME, else the
# home that holds this state directory, so a producer that names only JG_STATE_OVERRIDE is mirrored too. Guarded: with no
# config/item-store it does nothing, and it never changes this script's output or exit.
_store_mirror() {
  local home=${JG_HOME:-$(dirname "$(dirname "$(_dir)")")}
  [ -e "$home/config/item-store" ] || return 0
  JG_HOME=$home python3 -I "$_root/core/item-store/adapters/alerts.py" "$@" >/dev/null 2>&1 || true
}

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
  [ "${step:-0}" -gt 0 ] && [ "${repeat:-0}" -gt 0 ] && [ "${stall:-0}" -gt 0 ] || _die "the store has no usable stuck-wait ladder or ready-idle timer"
  printf 'escalate\t%s\ncard\t%s\nrealert\t%s\nready-stall\t%s\n' "$step" $((step * 2)) "$repeat" "$stall"
}

cmd_raise() {
  local name=${1:-} subj=${2:-} mode='' kind='' held='' facts=() sc_home='' sc_project='' sc_route='' sc_machine='' sc_ticket='' note='' now_deliver=0 now_print=0 rung='' wake='' text='' again=''
  local cls=team-action gate='' origin='' security='' source='' source_episode='' authority_alert=$name ceiling top
  [ -n "$name" ] && [ -n "$subj" ] || { _rc=2 _die "usage: raise <alert> <subject> [options]"; }
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$1" != --deliver ] || { now_deliver=1; shift; continue; }
    [ "$1" != --print ] || { now_print=1; shift; continue; }
    [ "$1" != --repeat ] || { again=1; shift; continue; }
    [ "$#" -ge 2 ] || { _rc=2 _die "option $1 needs a value"; }
    case $1 in
      --mode) mode=$2 ;; --kind) kind=$2 ;; --held) held=$2 ;; --fact) facts+=("$2") ;;
      --owner-gate) gate=$2 ;; --origin) origin=$2 ;; --security-source) security=$2 ;; --source-alert) source=$2 ;;
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
  if [ -n "$source" ]; then
    local parent; parent=$(_rec "$source" authority) || exit 1
    [ "$name" = escalation-stuck ] && [ "$subj" = "$source" ] && [ "$(_get "$parent" state)" = "$s_stuck" ] \
      || _die "derived alert needs its exact stuck source; Main recovery required"
    cls=$(_get "$parent" authority_class); cls=${cls:-team-action}
    gate=$(_get "$parent" owner_gate); origin=$(_get "$parent" origin); security=$(_get "$parent" security_source)
    authority_alert=$(_get "$parent" authority_alert); sc_ticket=$(_get "$parent" ticket)
    source_episode=$(_get "$parent" episode)
  elif [ -n "$gate" ]; then cls='owner-call'
  elif [ "$name" = security ]; then cls='security-awareness'
  fi
  _authority_check "$cls" "$gate" "$sc_ticket" "$origin" "$security" "$authority_alert" \
    || _die "invalid $cls authority for $name; Main recovery required"
  ceiling=$(_rows authority | awk -F'\t' -v c="$cls" '$2==c {print $3}')
  [ -n "$ceiling" ] || _die "no authority ceiling for $cls"
  [ "$start" -le "$ceiling" ] || _die "rung $start exceeds $cls authority; Main recovery required"
  text=$(printf '%s' "$text" | tr '\n\t' '  ')
  local key="$name--$subj" file; file="$(_dir)/$key.rec"
  case $key in */*|*..*) _die "bad subject '$subj'" ;; esac
  # A repeat of an open key is a note in the store.
  _store_mirror raise "$name" "$subj" ${security:+--security-source "$security"} --source "raise:$name:$subj@${JG_ALERT_NOW:-$(date +%s)}"
  if [ -r "$file" ]; then
    local cur; cur=$(_get "$file" state)
    if [ "$cur" != "$s_res" ]; then   # one live record for one key
      if [ -n "$again" ] && [ "$cur" = "$s_open" ]; then
        # Deduplicate by key: one episode rings once. The record holds the words it last rang, so a
        # producer that fires every window - or a wake loop replaying one episode - delivers nothing
        # while those words are unchanged, which drains the repeat on the delivery already made.
        if [ "$note" = "$(_get "$file" note)" ] && [ "$text" = "$(_get "$file" text)" ]; then return 0; fi
        _set "$file" text "$text"; _set "$file" wake "$wake"; _set "$file" note "$note"
        start=$(_get "$file" rung)
        if [ "$now_print" = 1 ]; then _payload "$key" "$start" "$(_holder "$start")"
        elif [ "$now_deliver" = 1 ]; then printf 'ring\t%s\t%s\t%s\n' "$key" "$start" "$(_holder "$start")" | cmd_deliver
        else printf 'ring\t%s\t%s\t%s\n' "$key" "$start" "$(_holder "$start")"; fi
        return $?
      fi
      return 0
    fi
  fi
  start=$(_cap "$name" "$prec" "$start" "${facts[@]}")
  top=$(_top "$prec" "$start" "${facts[@]}")
  [ "$cls" != owner-call ] || top=$ceiling
  [ "$top" -le "$ceiling" ] || top=$ceiling
  local now cover; now=${JG_ALERT_NOW:-$(date +%s)}
  cover=$(_cover "$name" "$prec" "$sc_home" "$sc_project" "$sc_route" "$sc_machine" "$sc_ticket" || true)
  local st=$s_open
  _put "$file" "alert=$name" "subject=$subj" "mode=$mode" "precedence=$prec" "rung=$start" "top=$top" \
    "authority_class=$cls" "owner_gate=$gate" "origin=$origin" "security_source=$security" "authority_alert=$authority_alert" \
    "episode=$now-$$-$RANDOM" "source_key=$source" "source_episode=$source_episode" \
    "since=$now" "rung_at=$now" "deadline_at=$(( now + $(_ladder_timer "$prec" "$start" "$top") ))" \
    "home=$sc_home" "project=$sc_project" "route=$sc_route" "machine=$sc_machine" "ticket=$sc_ticket" "note=$note" "wake=$wake" "text=$text" "repeats=0" "state=$st"
  if [ -n "$cover" ]; then
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

_rec() {
  case ${1:-} in ''|*/*|*..*) _die "invalid alert key; Main recovery required" ;; esac
  local f; f="$(_dir)/$1.rec"; [ -r "$f" ] || _die "no alert '$1'"; printf '%s\n' "$f"
}

cmd_climb() {
  local f now=${JG_ALERT_NOW:-$(date +%s)}; f=$(_rec "${1:-}" climb) || exit 1
  [ "${2:-}" != --now ] || now=${3:?--now needs an epoch}
  local st rung top prec after; st=$(_get "$f" state); rung=$(_get "$f" rung); top=$(_get "$f" top); prec=$(_get "$f" precedence)
  local ceiling; ceiling=$(_authority_top "$f")
  [ "$top" -le "$ceiling" ] || { top=$ceiling; _set "$f" top "$top"; }
  [ "$rung" -le "$top" ] || _die "owner authority no longer valid; Main recovery required for $1"
  [ "$st" != "$s_ack" ] || { _reopen "$f" "$1" "$now"; return; }
  [ "$st" = "$s_open" ] || _die "alert '$1' is $st: only an open alert climbs"
  [ "$rung" -lt "$top" ] || { _repeat "$f" "$1" "$now" "$prec" "$rung"; return; }
  after=$(_rows ladder | awk -F'\t' '$2==p {print $3}' p="$prec")
  [ "$after" -gt 0 ] || _die "$prec has no climb timer"
  [ $((now - $(_get "$f" rung_at))) -ge "$after" ] || _die "rung timer of $after s has not run out"
  _set "$f" rung $((rung + 1)); _stamp_due "$f" "$now" "$(_ladder_timer "$prec" $((rung + 1)) "$top")"
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
  _stamp_due "$f" "$now" "$(_ladder_timer "$prec" "$rung" "$(_get "$f" top)")"
  if [ "$n" -lt "$max" ]; then
    _set "$f" repeats $((n + 1))
    printf 'ring\t%s\t%s\t%s\n' "$key" "$rung" "$(_holder "$rung")"
    return 0
  fi
  _set "$f" state "$s_stuck"
  printf 'stuck\t%s\t%s\t%s\n' "$key" "$rung" "$(_holder "$rung")"
  local recovery=$rung; [ "$recovery" -ge 3 ] || recovery=3
  cmd_raise escalation-stuck "$key" --source-alert "$key" --rung "$recovery" --note "Main recovery required: $name sat at rung $rung through $max repeats with no action"
}
_move() {  # _move <key> <from word> <to word>
  local f; f=$(_rec "$1" move) || exit 1
  [ "$(_get "$f" state)" = "$2" ] || _die "alert '$1' is $(_get "$f" state), not $2"
  _set "$f" state "$3"
}
cmd_ack() {  # the one it rang took the alert. It never takes the deadline: an acknowledged alert still comes due (B10).
  local f; f=$(_rec "${1:-}" ack) || exit 1
  _move "${1:-}" "$s_open" "$s_ack"
  _set "$f" ack_at "${JG_ALERT_NOW:-$(date +%s)}"
  _stamp_due "$f" "$(_get "$f" ack_at)" "$(_state_timer "$s_ack")"
}
cmd_reopen() {  # the deadline's one owner: an acknowledged alert reopens and rings its rung again once its deadline has run out.
  local f now=${JG_ALERT_NOW:-$(date +%s)}; f=$(_rec "${1:-}" reopen) || exit 1
  [ "${2:-}" != --now ] || now=${3:?--now needs an epoch}
  _reopen "$f" "${1:-}" "$now"
}
_reopen() {  # <file> <key> <now>
  local f=$1 key=$2 now=$3 st dl rung
  st=$(_get "$f" state); [ "$st" != "$s_open" ] || return 0   # another caller of the same deadline reopened it first
  [ "$st" = "$s_ack" ] || _die "alert '$key' is $st: only an acknowledged alert reopens"
  dl=$(_due "$f"); [ "$now" -ge "$dl" ] || _die "alert '$key' is acknowledged: its deadline is $dl, $((dl - now)) s away"
  rung=$(_get "$f" rung)
  _set "$f" state "$s_open"; _set "$f" reopened_at "$now"
  _stamp_due "$f" "$now" "$(_ladder_timer "$(_get "$f" precedence)" "$rung" "$(_get "$f" top)")"
  printf 'ring\t%s\t%s\t%s\n' "$key" "$rung" "$(_holder "$rung")"
}
# _proof <record> <kind:pointer>: 0 when the close carries domain evidence rather than a read notice. `source` is the producer's own re-read
# of the condition the alert fired on; status, task, commit, pr and reply are the fleet's action evidence, the kinds bin/jg-delivery.sh
# handled takes. A status or task pointer must name a record this home holds, so a typed word alone never closes an alert. A commit, pr or
# reply pointer is recorded as the caller's claim: its domain owner verifies the pointed evidence.
_proof() {
  local kind ptr state
  kind=${2%%:*}; ptr=${2#*:}
  [ "$2" != "$kind" ] && [ -n "$ptr" ] || return 1
  case $kind in
    source|commit|reply|pr) case $ptr in *[!A-Za-z0-9_./=:@+-]*) return 1 ;; esac ;;
    status|task)
      case $ptr in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
      state=$(dirname "$(_dir)")
      case $kind in status) [ -r "$state/$ptr.status" ] ;; task) [ -r "$state/$ptr.meta" ] ;; esac ;;
    *) return 1 ;;
  esac
}
cmd_resolve() {
  local key=${1:-} proof='' now=${JG_ALERT_NOW:-$(date +%s)}
  case ${2:-} in '' ) ;; --proof) [ "$#" -eq 3 ] || { _rc=2 _die "usage: resolve <key> --proof <kind>:<pointer>"; }; proof=${3:-} ;; *) _rc=2 _die "unknown option $2" ;; esac
  local f cur rec; f=$(_rec "$key" resolve) || exit 1
  cur=$(_get "$f" state); [ "$cur" != "$s_res" ] || return 0
  [ -n "$proof" ] || _die "resolve $key needs --proof <kind>:<pointer>: the source-clear observation or the action evidence; a read notice or a vanished queue row never closes an alert"
  _proof "$f" "$proof" || _die "'$proof' is not proof for $key: use source:<observed>, status:<task>, task:<ticket>, commit:<rev>, pr:<url> or reply:<id>, and a status or task pointer must name a record this home holds"
  # The card of a stuck alert goes with it, so a new episode of the key can be stuck again.
  local card; card="$(_dir)/escalation-stuck--$key.rec"
  if [ "$cur" = "$s_stuck" ] && [ -r "$card" ] && [ "$(_get "$card" state)" != "$s_res" ]; then
    _route_close "$card" "escalation-stuck--$key"; _set "$card" state "$s_res"
  fi
  _route_close "$f" "$key"
  _set "$f" state "$s_res"; _set "$f" proof "$proof"; _set "$f" resolved_at "$now"
  _store_mirror resolve "$key" --proof "$proof" --source "resolve:$key"
  for rec in "$(_dir)"/*.rec; do   # release what this alert covered
    [ -r "$rec" ] && [ "$(_get "$rec" covered_by)" = "$key" ] || continue
    _set "$rec" state "$s_open"; _set "$rec" covered_by ""
    _stamp_due "$rec" "$now" "$(_ladder_timer "$(_get "$rec" precedence)" "$(_get "$rec" rung)" "$(_get "$rec" top)")"
    printf 'ring\t%s--%s\t%s\t%s\n' "$(_get "$rec" alert)" "$(_get "$rec" subject)" "$(_get "$rec" rung)" "$(_holder "$(_get "$rec" rung)")"
  done
}
# cmd_overdue: the alerts whose action deadline ran out and still stand. It prints one line each and exits 1 when it lists any, so a caller
# reads it as the metric: an acknowledged alert with no action behind it is overdue, never silently cleared (report section 5.2).
cmd_overdue() {
  local now=${JG_ALERT_NOW:-$(date +%s)} rec st dl key rc=0
  [ "${1:-}" != --now ] || now=${2:?--now needs an epoch}
  for rec in "$(_dir)"/*.rec; do
    [ -r "$rec" ] || continue
    st=$(_get "$rec" state)
    case $st in "$s_open" | "$s_ack") ;; *) continue ;; esac
    dl=$(_due "$rec")
    [ "${dl:-0}" -le "$now" ] || continue
    key=$(basename "$rec" .rec)
    printf '%s\t%s\tdeadline=%s\toverdue=%ss\n' "$key" "$st" "$dl" $((now - dl))
    rc=1
  done
  return "$rc"
}
# _route_main <rec> <key> <payload>: Main's rung. A main home returns 1 (Main reads this home's queue); a Squad Lead home appends one
# `blocked` line keyed by the alert and its episode to its parent channel (bin/jg-parent-channel-lib.sh owns that binding), so a retry
# of one episode is one line and a new episode is a new one. An unusable identity or binding, a failed append or a record with no
# episode is an unknown destination: it is refused with a recovery wake in this home, never delivered to this home's own queue.
_route_main() {
  local rec=$1 key=$2 ep rc=0 why
  # shellcheck source=bin/jg-parent-channel-lib.sh
  . "$_root/bin/jg-parent-channel-lib.sh"
  jg_parent_channel_destination "${JG_HOME:-$_root}" "$(dirname "$(_dir)")" >/dev/null || rc=$?
  [ "$rc" != 1 ] || return 1
  ep=$(_get "$rec" episode)
  if [ "$rc" = 0 ] && [ -n "$ep" ]; then
    jg_parent_channel_report "${JG_HOME:-$_root}" "$(dirname "$(_dir)")" "blocked [key=alert-$key-g$ep]: alert-route: $3" || rc=$?
    [ "$rc" != 0 ] || { _set "$rec" route_key "alert-$key-g$ep"; return 0; }
  fi
  case $rc in 0) why="the record has no episode" ;; 2) why="the Squad Lead identity is unusable" ;; 3) why="the parent binding is missing or unreadable" ;; *) why="the parent channel append failed" ;; esac
  _set "$rec" route_refused "$why"
  jg_wake_append check "alert-route-$key" "Main delivery refused for $key: $why; repair the parent binding" || _die "the recovery wake for $key was not appended"
  _die "Main delivery refused for $key: $why"
}
# _route_close <rec> <key>: an alert that reached Main through the parent channel closes there with the same key before it resolves here.
_route_close() {
  local rk; rk=$(_get "$1" route_key); [ -n "$rk" ] || return 0
  # shellcheck source=bin/jg-parent-channel-lib.sh
  . "$_root/bin/jg-parent-channel-lib.sh"
  jg_parent_channel_report "${JG_HOME:-$_root}" "$(dirname "$(_dir)")" "resolved [key=$rk]: alert-cleared: $2" \
    || _die "the parent channel close of $2 failed; it stays open here"
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
  if [ -r "$old" ] && [ "$(_get "$old" state)" != "$s_res" ]; then _route_close "$old" "capacity--$producer" && _set "$old" state "$s_res" && _store_mirror resolve "capacity--$producer" --proof source:superseded --source "supersede:capacity--$producer@${JG_ALERT_NOW:-$(date +%s)}"; fi
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
    [ "$(_get "$rec" state)" != "$s_res" ] || _die "resolved alert cannot ring; Main must reconcile $key"
    [ "$rung" = "$(_get "$rec" rung)" ] && [ "$holder" = "$(_holder "$rung")" ] \
      || _die "ring does not match $key; Main recovery required"
    if [ "$holder" = owner ] && { ! _authority_record "$rec" || [ "$(_authority_top "$rec")" != 4 ]; }; then
      _set "$rec" recovery_owner main
      jg_wake_append check "alert-authority-$key" "Main recovery required: owner delivery refused for $key" \
        || _die "Main recovery wake failed for $key"
      _die "owner delivery refused for $key: missing, stale or invalid authority; Main recovery required"
    fi
    payload=$(_payload "$key" "$rung" "$holder")
    kind=$(_get "$rec" wake)
    if [ "$holder" = main ] && [ -z "$kind" ] && _route_main "$rec" "$key" "$payload"; then :
    elif [ -n "$kind" ] && [ "$holder" != tick ]; then jg_wake_append "$kind" "$(_get "$rec" subject)" "$(_get "$rec" text)" || _die "the wake for $key was not appended"
    elif [ "$holder" = tick ]; then jg_wake_settle check "alert-$key" "$payload"
    else jg_wake_append check "alert-$key" "$payload" || _die "the wake for $key was not appended"; fi
    # The owner's rung is the captain's chat: the same ring goes out as a captain-facing `alert` event (jg-bus.sh owns the Telegram send).
    [ "$holder" != owner ] || "$_root/bin/jg-bus.sh" publish alert "alert-$key" "$payload" >/dev/null \
      || _die "owner publication failed for $key; Main recovery required"
  done
}

usage() { sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "$0" >&2; exit 2; }
[ "$#" -gt 0 ] || usage
c=$1; shift
case $c in
  row|limit|timers|raise|capacity|climb|ack|reopen|resolve|overdue|show|word|list|deliver) "cmd_$c" "$@" ;;
  *) usage ;;
esac
