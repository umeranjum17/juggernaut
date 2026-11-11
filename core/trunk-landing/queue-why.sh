#!/usr/bin/env bash
# Why a ready lane waited before its landing started: sourced by core/trunk-landing/trunk-landing.sh, read by core/trunk-latency.
# The lander writes one record, $MEM/<task>.<head>.queue-why, when it starts the lane's landing, holding one of
#   behind <lane>              another lane's landing ended between this lane's done line and now
#   behind attempt of <lane>   another lane's attempt ended refused (final, env-wait or retry) in that window
#   first seen +<N> s          nothing was ahead of it; the lander first saw the lane N seconds after its done line (N over 60)
# and the first sight of a lane is $MEM/<task>.<head>.seen (an epoch). Both are written once; a lane that starts on time has no why.

# queue_seen <mem> <task> <head>: record the first tick that saw the lane ready with its whole proof.
queue_seen() { [ -e "$1/$2.$3.seen" ] || date +%s > "$1/$2.$3.seen" 2>/dev/null || :; }

# queue_why_record <mem> <task> <head> <done epoch> <now> [<other lane of the same stack>...]
queue_why_record() {
  local mem=$1 task=$2 head=$3 at=$4 now=$5 f b h t w m best="" bestm=0 seen why=""; shift 5
  [ ! -e "$mem/$task.$head.queue-why" ] || return 0
  for f in "$mem"/*.state; do
    [ -f "$f" ] || continue
    b=${f##*/}; b=${b%.state}; h=${b##*.}; t=${b%.*}
    [[ $h =~ ^[0-9a-f]{40,64}$ ]] && [[ ! $t =~ \.[0-9a-f]{40,64}$ ]] || continue  # a lane's own record, not an admission record
    [ "$t" != "$task" ] || continue
    for w in "$@"; do [ "$t" != "$w" ] || continue 2; done
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$m" -ge "$at" ] && [ "$m" -le "$now" ] && [ "$m" -ge "$bestm" ] || continue
    case $(cat "$f" 2>/dev/null) in
      landed*) why="behind $t" ;;
      final*|env-wait*|retry*) why="behind attempt of $t" ;;
      *) continue ;;
    esac
    best=$why bestm=$m
  done
  if [ -z "$best" ]; then
    seen=$(cat "$mem/$task.$head.seen" 2>/dev/null) || seen=
    [[ $seen =~ ^[0-9]+$ ]] && [ $((seen - at)) -gt 60 ] && best="first seen +$((seen - at)) s"
  fi
  [ -z "$best" ] || printf '%s\n' "$best" > "$mem/$task.$head.queue-why" 2>/dev/null || :
}
