#!/usr/bin/env bash
# Verify by milestone (slice H29h): sourced by bin/jg-trunk.sh, never run.
#
# The line's verify judges the commits above the green pin in milestones, oldest first. A milestone holds at most N commits, or the
# commits that landed within verify-milestone-minutes (default 15) of its first one, whichever ends first. N comes from the measured
# bad-commit share p so that a milestone is red at most half the time: 1-(1-p)^N <= 0.5, so N = floor(ln 0.5 / ln(1-p)): 13 at 5%,
# 2 at 24%. The share is the reverted or unrevertable commits of data/trunk-landings.tsv and data/trunk-ci.tsv over the landings;
# a home with under 20 landings uses policy verify-bad-share (percent, default 5). N is at most verify-milestone-max (default 50).
# A green milestone moves the green pin to its top. A red one is split in two halves that run at once (core/trunk-landing/batch.sh
# batch_run: one heavy slot each) and each red half is split again until every bad commit stands alone: about log2(N) rounds a bad
# commit. The pin moves to the last commit before the first bad one at each step. The bad commits are not reverted here: the caller
# reverts each one (MS_BAD), and the later milestones are judged against the one before them, so one verify finds every bad commit
# of its range.
#   ms_verify <top> <gate with HEAD^> <green>   0 every milestone to <top> green, 2 the commits of MS_BAD are charged, 1 a run ended
#                                               for a reason no test accounts for (nothing charged)
#   ms_charge <commit>                          revert one charged commit (or record it red when it cannot be undone)
# A commit and its revert (`reverts: <sha>`) are one unit that no cut splits, so a tree that holds a reverted commit is never judged.
# Needs from the caller: PROJ PN TRUNK STATE DATA, pol, lock, unlock, tip_ok, pin_green, unpin_green, row, put, full_gate, gate_from,
# revert_commit, line_red, green_short and batch_run.

MS_FIRST=(); MS_TOP=(); MS_CNT=(); MS_BAD=(); MS_UNACC=''

ms_num() {  # <policy key> <default>
  local v; v=$(pol "$1" 2>/dev/null || true)
  case $v in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s\n' "$v"
}

# N for the measured bad-commit share (see the header).
ms_size() {
  local landings bad red pct max
  max=$(ms_num verify-milestone-max 50); [ "$max" -ge 1 ] || max=1
  read -r landings bad <<< "$(awk -F'\t' -v p="$PN" '$2 == p { if ($1 ~ /^revert-/) b++; else l++ } END { print l + 0, b + 0 }' "$DATA/trunk-landings.tsv" 2>/dev/null || echo '0 0')"
  red=$(awk -F'\t' -v p="$PN" '$1 == p && $4 == "red" && $5 == "verify" { n++ } END { print n + 0 }' "$DATA/trunk-ci.tsv" 2>/dev/null || echo 0)
  bad=$(( ${bad:-0} + ${red:-0} ))
  if [ "${landings:-0}" -ge 20 ]; then pct=$(awk -v l="$landings" -v b="$bad" 'BEGIN { printf "%.4f", 100 * b / l }')
  else pct=$(ms_num verify-bad-share 5); fi
  awk -v p="$pct" -v m="$max" 'BEGIN {
    p /= 100
    if (p <= 0) n = m; else if (p >= 0.5) n = 1; else n = int(log(0.5) / log(1 - p))
    if (n < 1) n = 1; if (n > m) n = m
    print n }'
}

# The commits of <from>..<top> as units, oldest first, one line each: first, last, commit count, first and last commit time.
ms_units() {  # <from> <top>
  git -C "$PROJ" log --reverse --format='@%H %ct%n%B' "$1..$2" | awk '
    /^@[0-9a-f]+ [0-9]+$/ { n++; h[n] = substr($1, 2); t[n] = $2; pos[h[n]] = n; next }
    n && /^reverts: [0-9a-f]+[ \t]*$/ { tg[n] = $2 }
    END {
      for (i = 1; i <= n; i++) reach[i] = i
      for (i = 1; i <= n; i++) if (tg[i] in pos && pos[tg[i]] < i && reach[pos[tg[i]]] < i) reach[pos[tg[i]]] = i
      for (i = 1; i <= n; i = e + 1) {
        e = reach[i]; for (k = i; k <= e; k++) if (reach[k] > e) e = reach[k]
        print h[i], h[e], e - i + 1, t[i], t[e]
      }
    }'
}

# The next milestone of <from>..<top>: MS_FIRST, MS_TOP and MS_CNT hold its units. It always holds one unit.
ms_cut() {  # <from> <top> <most commits> <minutes>
  local first last cnt t0 t1 total=0 start=0
  MS_FIRST=(); MS_TOP=(); MS_CNT=()
  while read -r first last cnt t0 t1; do
    if [ "${#MS_TOP[@]}" -eq 0 ]; then start=$t0
    else
      [ $(( total + cnt )) -le "$3" ] || break
      [ $(( t1 - start )) -le $(( $4 * 60 )) ] || break
    fi
    MS_FIRST+=("$first"); MS_TOP+=("$last"); MS_CNT+=("$cnt"); total=$(( total + cnt ))
  done < <(ms_units "$1" "$2")
}

# The pin follows a green run only when it stands on the run's base: a green above a red never moves it.
ms_pin() {  # <top> <base>
  [ "$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)" = "$2" ] || return 0
  lock "$STATE/.trunk-$PN.lock"; tip_ok; pin_green "$1"; unlock "$STATE/.trunk-$PN.lock"
}

# Units <lo>..<hi> of the milestone are red against <base>: split them in two halves that run at once and settle each.
ms_resolve() {  # <gate> <base> <lo> <hi>
  local gate=$1 base=$2 lo=$3 hi=$4 mid ta tb dir ra rb
  if [ "$lo" -eq "$hi" ]; then
    if [ "${MS_CNT[lo]}" -eq 1 ]; then MS_BAD+=("${MS_FIRST[lo]}")
    else
      MS_UNACC=1
      echo "verify: ${MS_FIRST[lo]:0:12}..${MS_TOP[lo]:0:12} is red and holds ${MS_CNT[lo]} commits that undo each other, so no one commit is charged and nothing is reverted" >&2
    fi
    return 0
  fi
  mid=$(( (lo + hi) / 2 )); ta=${MS_TOP[mid]}; tb=${MS_TOP[hi]}; dir=$DATA/trunk/ms-$PN-$$-$lo-$hi
  echo "verify: red from ${base:0:12} to ${tb:0:12}; its two halves (to ${ta:0:12} and to ${tb:0:12}) run at once" >&2
  batch_run "$gate" "$dir" "a:$ta:$base" "b:$tb:$ta"
  ra=$(cat "$dir/a.rc" 2>/dev/null || echo 1); rb=$(cat "$dir/b.rc" 2>/dev/null || echo 1)
  cat "$dir"/*.out >&2 2>/dev/null || true; rm -rf -- "$dir"
  case $ra in 0) ms_pin "$ta" "$base" ;; 2) ms_resolve "$gate" "$base" "$lo" "$mid" ;; *) MS_UNACC=1 ;; esac
  case $rb in 0) ms_pin "$tb" "$ta" ;; 2) ms_resolve "$gate" "$ta" "$(( mid + 1 ))" "$hi" ;; *) MS_UNACC=1 ;; esac
}

ms_verify() {  # <top> <gate with HEAD^> <green>
  local top=$1 raw=$2 base=$3 judge n mins gate m cnt i rc
  judge=$base; n=$(ms_size); mins=$(ms_num verify-milestone-minutes 15)
  MS_BAD=(); MS_UNACC=''
  while [ "$judge" != "$top" ]; do
    ms_cut "$judge" "$top" "$n" "$mins"
    [ "${#MS_TOP[@]}" -gt 0 ] || break
    m=${MS_TOP[${#MS_TOP[@]}-1]}; cnt=0; for i in "${MS_CNT[@]}"; do cnt=$(( cnt + i )); done
    gate=$(gate_from "$raw" "$judge")
    echo "verify: milestone of $cnt commits ${judge:0:12}..${m:0:12} (at most $n commits or $mins minutes)" >&2
    rc=0; full_gate "$m" "$gate" "$judge" || rc=$?
    case $rc in
      0) ms_pin "$m" "$judge" ;;
      2) ms_resolve "$gate" "$judge" 0 $(( ${#MS_TOP[@]} - 1 )) ;;
      *) MS_UNACC=1 ;;
    esac
    # A red milestone does not stop the walk: the next one is judged against this one, so every bad commit of the range is found now.
    [ "$rc" -ne 1 ] || break
    judge=$m
  done
  [ "${#MS_BAD[@]}" -eq 0 ] || return 2
  [ -z "$MS_UNACC" ] || return 1
}

ms_charge() {  # <commit>
  local c=$1 why="the whole suite fails on it where the commits before it pass"
  if git -C "$PROJ" log --format=%B "$c..refs/heads/$TRUNK" | grep -qx "reverts: $c"; then
    echo "verify: ${c:0:12} is red and $TRUNK already carries its revert" >&2; return 0
  fi
  if revert_commit "$c" "$why"; then line_red "$c" "$why; it was reverted by itself"; return 0; fi
  # The red stays recorded (data/trunk-ci.tsv, source verify) so no later landing moves the pin over it.
  lock "$STATE/.trunk-$PN.lock"; unpin_green "$c"; row trunk-ci.tsv "$PN" "$c" "$(date +%s)" red verify; unlock "$STATE/.trunk-$PN.lock"
  line_red "$c" "$TRUNK is red at ${c:0:12}: $why, and it could not be reverted by itself; landings go on, and live stays on the last green commit $(green_short)"
}
