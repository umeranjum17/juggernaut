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
# Per queue (slice H29i): the lander splits ready lanes into queues by the tests they select and records `queue=<name>` and `beside=<the
# other live queues>` on each landing row (bin/jg-trunk.sh). When every commit above the pin has a queue and every landing names every other
# queue of the range as live beside it, the queues ran apart the whole time, so each is verified apart and all of them at once: a queue's
# commits are grafted one by one onto the green pin (git merge-tree, no checkout) into a chain of its own, its milestones are cut from that
# chain and judged on it, so another queue's red never enters its tree, and each queue has its own pin (state/trunk-green-queues-<project>).
# The trunk's green pin follows the longest run of commits that are green in their own queue. A halving gates its halves at once as before,
# and a queue's milestone takes a heavy slot of the fleet budget (this host's and every usable runner's, core/lane-scale/fleet.sh), so the
# gates of every queue are placed on the runners a free slot belongs to. A commit found bad in its queue's chain is charged only when it is
# bad on the trunk as well (against its own parent); one that passes there is a hidden dependency between queues and is charged to no one.
# A range that does not meet those conditions, or whose commits cannot be grafted apart, is verified in one line as before.
# Needs from the caller: PROJ PN TRUNK STATE DATA, pol, lock, unlock, tip_ok, pin_green, unpin_green, row, put, full_gate, gate_from,
# revert_commit, line_red, miss_charge (core/trunk-verify/miss.sh), green_short, batch_run and batch_slot (core/trunk-landing/batch.sh).

MS_FIRST=(); MS_LAST=(); MS_TOP=(); MS_CNT=(); MS_BAD=(); MS_UNACC=''
MS_Q=''; MS_UNITS_FILE=''; MS_RAW=''; MSQ_DIR=''; MSQ_GREEN=''

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

# The units after <from>, oldest first: the commits of <from>..<top> in one line, or those of the queue chain MS_UNITS_FILE holds.
ms_unit_stream() {  # <from> <top>
  if [ -z "$MS_UNITS_FILE" ]; then ms_units "$1" "$2"; return; fi
  awk -v j="$1" -v g="$MSQ_GREEN" 'BEGIN { on = (j == g) } on { print } $2 == j { on = 1 }' "$MS_UNITS_FILE"
}

# The next milestone of <from>..<top>: MS_FIRST, MS_LAST, MS_TOP (the commit that is gated: MS_LAST, or its graft in a queue chain) and
# MS_CNT hold its units. It always holds one unit.
ms_cut() {  # <from> <top> <most commits> <minutes>
  local first last cnt t0 t1 cand total=0 start=0
  MS_FIRST=(); MS_LAST=(); MS_TOP=(); MS_CNT=()
  while read -r first last cnt t0 t1 cand; do
    if [ "${#MS_TOP[@]}" -eq 0 ]; then start=$t0
    else
      [ $(( total + cnt )) -le "$3" ] || break
      [ $(( t1 - start )) -le $(( $4 * 60 )) ] || break
    fi
    MS_FIRST+=("$first"); MS_LAST+=("$last"); MS_TOP+=("${cand:-$last}"); MS_CNT+=("$cnt"); total=$(( total + cnt ))
  done < <(ms_unit_stream "$1" "$2")
}

# The pin follows a green run only when it stands on the run's base: a green above a red never moves it. In a queue chain the pin is the
# queue's own, and the trunk's follows the commits that are green in their queues (ms_advance).
ms_pin() {  # <top> <base>: commits of the trunk
  if [ -n "$MS_Q" ]; then ms_qpin "$1" "$2"; return; fi
  [ "$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)" = "$2" ] || return 0
  lock "$STATE/.trunk-$PN.lock"; tip_ok; pin_green "$1"; unlock "$STATE/.trunk-$PN.lock"
}

# A bad commit of a chain stands alone and is charged only when it is bad on the trunk too (against its own parent).
ms_confirm() {  # <commit>
  local rc=0
  full_gate "$1" "$(gate_from "$MS_RAW" "$1^")" "$1^" || rc=$?
  [ "$rc" -eq 2 ] && return 0
  echo "verify: ${1:0:12} is red in its queue's chain and passes on the trunk against its parent, so it is charged to no one (a dependency between queues)" >&2
  return 1
}

# Units <lo>..<hi> of the milestone are red against <base> (<real base> on the trunk): split them in two halves that run at once and settle each.
ms_resolve() {  # <gate> <base> <real base> <lo> <hi>
  local gate=$1 base=$2 rbase=$3 lo=$4 hi=$5 mid ta tb dir ra rb
  if [ "$lo" -eq "$hi" ]; then
    if [ "${MS_CNT[lo]}" -eq 1 ]; then
      if [ -z "$MS_Q" ] || ms_confirm "${MS_FIRST[lo]}"; then MS_BAD+=("${MS_FIRST[lo]}"); else MS_UNACC=1; fi
    else
      MS_UNACC=1
      echo "verify: ${MS_FIRST[lo]:0:12}..${MS_LAST[lo]:0:12} is red and holds ${MS_CNT[lo]} commits that undo each other, so no one commit is charged and nothing is reverted" >&2
    fi
    return 0
  fi
  mid=$(( (lo + hi) / 2 )); ta=${MS_TOP[mid]}; tb=${MS_TOP[hi]}; dir=$DATA/trunk/ms-$PN-$$-${MS_Q:-line}-$lo-$hi
  echo "verify: red from ${base:0:12} to ${tb:0:12}; its two halves (to ${ta:0:12} and to ${tb:0:12}) run at once" >&2
  batch_run "$gate" "$dir" "a:$ta:$base" "b:$tb:$ta"
  ra=$(cat "$dir/a.rc" 2>/dev/null || echo 1); rb=$(cat "$dir/b.rc" 2>/dev/null || echo 1)
  cat "$dir"/*.out >&2 2>/dev/null || true; rm -rf -- "$dir"
  case $ra in 0) ms_pin "${MS_LAST[mid]}" "$rbase" ;; 2) ms_resolve "$gate" "$base" "$rbase" "$lo" "$mid" ;; *) MS_UNACC=1 ;; esac
  case $rb in 0) ms_pin "${MS_LAST[hi]}" "${MS_LAST[mid]}" ;; 2) ms_resolve "$gate" "$ta" "${MS_LAST[mid]}" "$(( mid + 1 ))" "$hi" ;; *) MS_UNACC=1 ;; esac
}

ms_verify() {  # <top> <gate with HEAD^> <green>
  local top=$1 raw=$2 base=$3 judge n mins gate m cnt i rc
  judge=$base; n=$(ms_size); mins=$(ms_num verify-milestone-minutes 15)
  MS_BAD=(); MS_UNACC=''; MS_RAW=$raw; MS_Q=''; MS_UNITS_FILE=''
  if ms_queue_units "$base" "$top" && ms_graft_queues "$base"; then ms_verify_queues "$raw" "$base" "$n" "$mins"; return; fi
  ms_queue_clean
  while [ "$judge" != "$top" ]; do
    ms_cut "$judge" "$top" "$n" "$mins"
    [ "${#MS_TOP[@]}" -gt 0 ] || break
    m=${MS_LAST[${#MS_LAST[@]}-1]}; cnt=0; for i in "${MS_CNT[@]}"; do cnt=$(( cnt + i )); done
    gate=$(gate_from "$raw" "$judge")
    echo "verify: milestone of $cnt commits ${judge:0:12}..${m:0:12} (at most $n commits or $mins minutes)" >&2
    rc=0; full_gate "$m" "$gate" "$judge" || rc=$?
    case $rc in
      0) ms_pin "$m" "$judge" ;;
      2) ms_resolve "$gate" "$judge" "$judge" 0 $(( ${#MS_TOP[@]} - 1 )) ;;
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
  if revert_commit "$c" "$why"; then line_red "$c" "$why; it was reverted by itself"; miss_charge "$c" "${sha:-}"; return 0; fi
  # The red stays recorded (data/trunk-ci.tsv, source verify) so no later landing moves the pin over it.
  lock "$STATE/.trunk-$PN.lock"; unpin_green "$c"; row trunk-ci.tsv "$PN" "$c" "$(date +%s)" red verify; unlock "$STATE/.trunk-$PN.lock"
  line_red "$c" "$TRUNK is red at ${c:0:12}: $why, and it could not be reverted by itself; landings go on, and live stays on the last green commit $(green_short)"
  miss_charge "$c" "${sha:-}"
}

# --- Per queue (slice H29i) ---

ms_key() { tr -c 'A-Za-z0-9._,\n-' _; }  # a queue name as a file name

# <field> of the landing row of <commit> (`queue=` or `beside=`).
ms_row_field() {  # <commit> <key>
  awk -F'\t' -v p="$PN" -v c="$1" -v k="$2=" '$2 == p && $3 == c { for (i = 6; i <= NF; i++) if (index($i, k) == 1) v = substr($i, length(k) + 1) } END { print v }' \
    "$DATA/trunk-landings.tsv" 2>/dev/null
}

# The commits above <green> as one line each in $MSQ_DIR/units: first last 1 first-time last-time queue beside. Returns 1, writing nothing
# more, unless the range holds one commit to a unit, a queue on every landing, two or more queues, and every landing names every other
# queue of the range as live beside it.
ms_queue_units() {  # <green> <top>
  local first last cnt t0 t1 q b
  MSQ_DIR=$DATA/trunk/msq-$PN-$$; MSQ_GREEN=$1; rm -rf -- "$MSQ_DIR"; mkdir -p "$MSQ_DIR" || return 1
  while read -r first last cnt t0 t1; do
    [ "$cnt" -eq 1 ] || return 1
    q=$(ms_row_field "$first" queue | ms_key); [ -n "$q" ] || return 1
    b=$(ms_row_field "$first" beside | ms_key)
    printf '%s %s %s %s %s %s %s\n' "$first" "$last" "$cnt" "$t0" "$t1" "$q" "${b:--}" >> "$MSQ_DIR/units"
  done < <(ms_units "$1" "$2")
  [ -s "$MSQ_DIR/units" ] || return 1
  awk '{ q[$6] = 1; line[NR] = $0 }
    END {
      for (k in q) nq++
      if (nq < 2) exit 1
      for (i = 1; i <= NR; i++) { split(line[i], f, " "); for (k in q) if (k != f[6] && !index("," f[7] ",", "," k ",")) exit 1 }
    }' "$MSQ_DIR/units"
}

ms_queue_clean() {
  [ -z "$MSQ_DIR" ] || { git -C "$PROJ" for-each-ref --format='%(refname)' "refs/jg-verify/$PN-$$-*" | while read -r r; do git -C "$PROJ" update-ref -d "$r"; done; rm -rf -- "$MSQ_DIR"; }
  MSQ_DIR=''
}

# Graft the commits of each queue, one by one, onto <green>: $MSQ_DIR/chain.<queue> holds `first last 1 t0 t1 graft` lines, and a ref keeps
# each chain. Returns 1 when a commit does not apply apart from the others (the queues are not apart in the files either).
ms_graft_queues() {  # <green>
  local first last cnt t0 t1 q b tree new
  declare -A cur=()
  while read -r first last cnt t0 t1 q b; do
    tree=$(git -C "$PROJ" merge-tree --write-tree --merge-base="$first^" "${cur[$q]:-$1}" "$first" 2>/dev/null) || return 1
    new=$(GIT_AUTHOR_NAME=jg-verify GIT_AUTHOR_EMAIL=jg-verify@localhost GIT_COMMITTER_NAME=jg-verify GIT_COMMITTER_EMAIL=jg-verify@localhost \
      git -C "$PROJ" commit-tree "$tree" -p "${cur[$q]:-$1}" -m "verify chain $q: ${first:0:12}") || return 1
    cur[$q]=$new
    printf '%s %s %s %s %s %s\n' "$first" "$last" "$cnt" "$t0" "$t1" "$new" >> "$MSQ_DIR/chain.$q"
  done < "$MSQ_DIR/units"
  for q in "${!cur[@]}"; do git -C "$PROJ" update-ref "refs/jg-verify/$PN-$$-$q" "${cur[$q]}"; done
}

# The pins of the queues: lines `<queue> <commit>`. Only a pin on a commit of this range, above the green pin, is read.
ms_qpins() { awk -v k="$1" '$1 == k { print $2 }' "$STATE/trunk-green-queues-$PN" 2>/dev/null | tail -n 1; }

ms_qpin() {  # <top> <base>: the queue's pin moves when it stands on the run's base, then the trunk's follows
  local cur
  lock "$STATE/.trunk-$PN.lock"
  cur=$(ms_qpins "$MS_Q"); [ -n "$cur" ] && grep -q " $cur " "$MSQ_DIR/units" || cur=$MSQ_GREEN
  if [ "$cur" = "$2" ]; then
    { grep -v "^$MS_Q " "$STATE/trunk-green-queues-$PN" 2>/dev/null || true; printf '%s %s\n' "$MS_Q" "$1"; } > "$STATE/trunk-green-queues-$PN.tmp.$$" \
      && mv -f -- "$STATE/trunk-green-queues-$PN.tmp.$$" "$STATE/trunk-green-queues-$PN"
    ms_advance
  fi
  unlock "$STATE/.trunk-$PN.lock"
}

# With the trunk lock held: the green pin follows the longest run of commits, oldest first, that are green in their own queue.
ms_advance() {
  local to
  to=$(awk 'NR == FNR { pin[$1] = $2; next }
    { n++; q[n] = $6; c[n] = $1 }
    END { for (k in pin) for (i = 1; i <= n; i++) if (q[i] == k && c[i] == pin[k]) at[k] = i
      for (i = 1; i <= n; i++) { if (!(q[i] in at) || at[q[i]] < i) break; out = c[i] }
      print out }' "$STATE/trunk-green-queues-$PN" "$MSQ_DIR/units")
  [ -z "$to" ] || { tip_ok; pin_green "$to"; }
}

# One queue's milestones, judged on its chain (run in the background, one per queue): the bad commits and the unaccounted flag it found
# are left in $MSQ_DIR/bad.<queue> and $MSQ_DIR/unacc.<queue>.
ms_chain() {  # <queue> <gate> <most commits> <minutes>
  local q=$1 raw=$2 n=$3 mins=$4 rc m_c m_r jc jr pin cnt i gate
  MS_Q=$q; MS_UNITS_FILE=$MSQ_DIR/chain.$q; MS_BAD=(); MS_UNACC=''
  jr=$MSQ_GREEN; jc=$MSQ_GREEN
  pin=$(ms_qpins "$q")
  if [ -n "$pin" ] && git -C "$PROJ" merge-base --is-ancestor "$MSQ_GREEN" "$pin" 2>/dev/null && awk -v p="$pin" '$2 == p { f = 1 } END { exit !f }' "$MS_UNITS_FILE"; then
    jr=$pin; jc=$(awk -v p="$pin" '$2 == p { print $6 }' "$MS_UNITS_FILE")
  fi
  while :; do
    ms_cut "$jr" "" "$n" "$mins"
    [ "${#MS_TOP[@]}" -gt 0 ] || break
    m_c=${MS_TOP[${#MS_TOP[@]}-1]}; m_r=${MS_LAST[${#MS_LAST[@]}-1]}; cnt=0; for i in "${MS_CNT[@]}"; do cnt=$(( cnt + i )); done
    gate=$(gate_from "$raw" "$jc")
    echo "verify: queue $q: milestone of $cnt commits ${jr:0:12}..${m_r:0:12} (at most $n commits or $mins minutes)" >&2
    for i in $(seq 1 120); do batch_slot take "q-$q" && break; sleep 1; done  # a host with no free slot still runs, as batch_run does
    rc=0; full_gate "$m_c" "$gate" "$jc" || rc=$?
    batch_slot give "q-$q" || true
    case $rc in
      0) ms_pin "$m_r" "$jr" ;;
      2) ms_resolve "$gate" "$jc" "$jr" 0 $(( ${#MS_TOP[@]} - 1 )) ;;
      *) MS_UNACC=1 ;;
    esac
    [ "$rc" -ne 1 ] || break
    jc=$m_c; jr=$m_r
  done
  printf '%s\n' "${MS_BAD[@]}" > "$MSQ_DIR/bad.$q"; printf '%s\n' "$MS_UNACC" > "$MSQ_DIR/unacc.$q"
}

ms_verify_queues() {  # <gate> <green> <most commits> <minutes>
  local q f bad unacc=''
  for f in "$MSQ_DIR"/chain.*; do q=${f##*/chain.}; ms_chain "$q" "$1" "$3" "$4" & done
  wait || true
  MS_BAD=()
  # A chain that left no answer ended without one (it stopped on a refusal), so it counts as unaccounted.
  for f in "$MSQ_DIR"/chain.*; do q=${f##*/chain.}; [ -f "$MSQ_DIR/unacc.$q" ] && [ -z "$(cat "$MSQ_DIR/unacc.$q")" ] || unacc=1; done
  bad=$(cat "$MSQ_DIR"/bad.* 2>/dev/null | sed '/^$/d' || true)
  if [ -n "$bad" ]; then mapfile -t MS_BAD < <(awk 'NR == FNR { b[$1] = 1; next } ($1 in b) { print $1 }' <(printf '%s\n' "$bad") "$MSQ_DIR/units"); fi
  MS_UNACC=$unacc
  ms_queue_clean
  [ "${#MS_BAD[@]}" -eq 0 ] || return 2
  [ -z "$MS_UNACC" ] || return 1
}
