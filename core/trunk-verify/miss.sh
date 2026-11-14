#!/usr/bin/env bash
# miss.sh - a red the day's proofs did not select (slice J31): sourced by bin/jg-trunk.sh, never run.
#
# The nightly whole run and the line's verify charge a red to one commit and revert it (the same code for both, so the ticket of that
# commit reads building with health red). When the commit's failed scripts are run by journeys of the project's .done-done.yaml, this
# asks done-done's own audit whether the commit's proof selected them: each journey runs again at the charged commit (a failed run is
# then on record), and `done-done affected --audit <commit>^..<commit>` compares those failed runs with the commit's receipt. For each
# journey the map did not select it adds the pair of the changed file and the journey to the verify skill's feature map (slice Q16).
# One row a journey goes to data/trunk/misses-<project>.tsv: epoch, commit, journey, `selected` or `missed`; the nightly report counts
# the rows its own run wrote. The map change is committed on the trunk tip the way a revert is (a new commit; the tip only moves
# forward); a map change that does not apply to the tip stays in data/trunk/map-miss-<project>-<commit 12>.patch.
#   miss_charge <commit> [<top>]   <top> is the commit the whole run judged: its verdict names the failed scripts when <commit> has none
# Needs from the caller: PROJ PN TRUNK STATE DATA, lock, unlock, tip_ok, rev, put and judge_show (core/trunk-verify/judge.sh).
# Nothing here changes the verdict, the revert or the pin. A missing done-done, verdict or journey is a note on stderr and no row.

# The scripts of the newest verify or nightly verdict on the tree of the first commit that has one, one a line.
miss_scripts() {  # <commit>...
  local c v
  for c in "$@"; do
    [ -n "$c" ] || continue
    v=$(judge_show "$PN" "$PROJ" "$DATA" "$c" 2>/dev/null | awk -F'\t' '$2 == "verify" || $2 == "nightly" { f = $4 } END { print f }')
    [ -z "$v" ] || { [ "$v" = green ] || printf '%s\n' "$v" | tr ',' '\n'; return 0; }
  done
}

# The journeys of the project's .done-done.yaml at the commit whose command names one of the scripts, one a line.
miss_journeys() {  # <commit> <script>...
  local c=$1
  shift
  git -C "$PROJ" show "$c:.done-done.yaml" 2>/dev/null | awk -v list="$(printf '%s\n' "$@")" '
    BEGIN { n = split(list, s, "\n") }
    /^journeys:/ { in_j = 1; next }
    /^[^ #]/ { in_j = 0 }
    in_j && /^  [^ #][^:]*:[ ]*$/ { name = $1; sub(/:$/, "", name); next }
    in_j && name != "" && /^    command:/ {
      for (i = 1; i <= n; i++) if (s[i] != "" && index($0, s[i])) { print name; break }
    }' | sort -u
}

# Commit the map change the audit made in <tree> onto the trunk tip; keep it as a patch when it does not apply.
miss_map() {  # <commit> <tree> <missed journeys>
  local c=$1 tree=$2 names patch tip idx new ticket ident=() t
  patch=$(git -C "$tree" diff --binary 2>/dev/null || true)
  [ -n "$patch" ] || return 0
  names=$(printf '%s' "$3" | paste -sd' ' -)
  printf '%s\n' "$patch" > "$tree/../map.patch"
  lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  idx=$tree/../map.index
  if GIT_INDEX_FILE=$idx git -C "$PROJ" read-tree "$tip" && GIT_INDEX_FILE=$idx git -C "$PROJ" apply --cached "$tree/../map.patch" 2>/dev/null \
    && t=$(GIT_INDEX_FILE=$idx git -C "$PROJ" write-tree); then
    ticket=$(git -C "$PROJ" log -1 --format=%B "$c" | git interpret-trailers --parse | sed -n 's/^Ticket: *//p' | tail -1)
    [ -n "$(git -C "$PROJ" config user.name 2>/dev/null || true)" ] || ident=(-c user.name=jg-trunk -c user.email=jg-trunk@localhost)
    new=$(printf 'Map the journeys %s fails: done-done audit of %s\n\nThe proof of %s did not select %s, so the pair of the changed file and the journey is added to the feature map.\n\nTicket: %s\n' \
      "$names" "${c:0:12}" "${c:0:12}" "$names" "${ticket:-unknown}" | git -C "$PROJ" "${ident[@]+"${ident[@]}"}" commit-tree "$t" -p "$tip") || new=
    if [ -n "$new" ] && JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: map the miss of ${c:0:12}" "refs/heads/$TRUNK" "$new" "$tip"; then
      put "$STATE/trunk-tip-$PN" "$new"; echo "miss: the map gets the pair in ${new:0:12}" >&2
      unlock "$STATE/.trunk-$PN.lock"; return 0
    fi
  fi
  unlock "$STATE/.trunk-$PN.lock"
  mkdir -p "$DATA/trunk"; cp -- "$tree/../map.patch" "$DATA/trunk/map-miss-$PN-${c:0:12}.patch"
  echo "miss: the map change could not be committed on the tip; it is kept in $DATA/trunk/map-miss-$PN-${c:0:12}.patch" >&2
}

miss_charge() {  # <commit> [<top>]
  local c=$1 scripts journeys work j out caught missed now n=0
  command -v done-done >/dev/null 2>&1 || { echo "miss: done-done is not installed, so the miss of ${c:0:12} is not recorded" >&2; return 0; }
  scripts=$(miss_scripts "$c" "${2:-}")
  [ -n "$scripts" ] || { echo "miss: no failed script is on record for ${c:0:12}; no miss is recorded" >&2; return 0; }
  # shellcheck disable=SC2086
  journeys=$(miss_journeys "$c" $scripts)
  [ -n "$journeys" ] || { echo "miss: no journey runs the failed scripts of ${c:0:12}; no miss is recorded" >&2; return 0; }
  work=$(mktemp -d) || return 0
  if ! { git clone -q --shared --no-checkout "$PROJ" "$work/tree" && git -C "$work/tree" checkout -q --detach "$c"; }; then rm -rf -- "$work"; return 0; fi
  # Each failed journey runs again at the charged commit, so done-done has a failed run of it on record to audit.
  for j in $journeys; do (cd "$work/tree" && done-done run "$j" >/dev/null 2>&1) || true; done
  out=$(cd "$work/tree" && done-done affected --audit "$c^..$c" --json 2>/dev/null) || true
  if ! printf '%s' "$out" | jq -e '.failures' >/dev/null 2>&1; then
    echo "miss: done-done's audit of ${c:0:12} gave no result; no miss is recorded" >&2; rm -rf -- "$work"; return 0
  fi
  caught=$(printf '%s' "$out" | jq -r '.caught // 0'); missed=$(printf '%s' "$out" | jq -r '.missed[]?.journey' | sort -u)
  now=$(date +%s); mkdir -p "$DATA/trunk"
  while [ "$n" -lt "$caught" ]; do n=$((n + 1)); printf '%s\t%s\t-\tselected\n' "$now" "$c" >> "$DATA/trunk/misses-$PN.tsv"; done
  for j in $missed; do printf '%s\t%s\t%s\tmissed\n' "$now" "$c" "$j" >> "$DATA/trunk/misses-$PN.tsv"; done
  echo "miss: ${c:0:12}: $caught failed journey(s) were selected by its proof, $(printf '%s' "$missed" | grep -c . || true) were not" >&2
  [ -z "$missed" ] || miss_map "$c" "$work/tree" "$missed"
  rm -rf -- "$work"
}
