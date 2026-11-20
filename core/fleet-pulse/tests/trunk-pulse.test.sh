#!/usr/bin/env bash
# Integration test: the fleet pulse 2h report in the trunk era (fric-pulse-trunk-landed).
# A fixture main home carries a pulse check whose 2h report has the old blocks verbatim (landings = merged
# PRs, the inline asks fold, the old flow-check copy). Run as it is, it reports the trunk home landed0 with
# open unknown and counts closed, unkeyed and parent-owned asks. wiring.sh retargets it; run again, it reads
# the ticket stamps (landed, live, rtl), counts only open keyed lead asks to Main, reads the open row from
# core/fleet-flow, and a merged-PR home still counts its merged PRs. Direct cases pin trunk-pulse.sh's
# pin-back, release and no-records rules. The check starts registered, as a live home's is, and the watcher's own
# gate (bin/jg-check-lib.sh) accepts it after the retarget with no hand registration.
# The trunk home's landings, go-lives and release are the stamps on tickets in the home's tickets tables.
# Throwaway HOME, XDG and TMPDIR; gh is a stub; nothing real is read.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
feature=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
repo=$(cd "$feature/../.." && pwd -P)
# A fixture home on the tickets tables (fleet.db).
core_tables_home() {  # <checkout> <home>
  mkdir -p "$2/config" "$2/data" && : > "$2/config/backlog-intake-loose"
  case ":$PATH:" in *":$1/bin:"*) ;; *) PATH=$1/bin:$PATH; export PATH ;; esac
  JG_HOME=$2 python3 -I "$1/core/item-store/adapters/tickets.py" import --home main /dev/null >/dev/null
}
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user XDG_CACHE_HOME=$d/cache TMPDIR=$d/tmp
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$TMPDIR"

fail=0
expect() {  # <name> <want-substring> <got>
  case "$3" in *"$2"*) echo "ok $1" ;; *) echo "FAIL $1: want '$2' in: $3" >&2; fail=1 ;; esac
}
refute() {  # <name> <unwanted-substring> <got>
  case "$3" in *"$2"*) echo "FAIL $1: did not want '$2' in: $3" >&2; fail=1 ;; *) echo "ok $1" ;; esac
}
pass_if() {  # <name> <command...>: ok when the command succeeds
  local name=$1; shift
  if "$@"; then echo "ok $name"; else echo "FAIL $name: $*" >&2; fail=1; fi
}

now=1794200000
ago() { echo $((now - $1 * 60)); }  # minutes ago -> epoch
main=$d/main trunk=$d/pool/1/juggernaut pr=$d/pool/2/juggernaut
mkdir -p "$main/bin" "$main/config" "$main/state" "$d/stub" \
  "$trunk/state" "$pr/state" "$pr/data"

# Main's backlog and the forge are stubs: no ready work; only owner/pr-repo merged two PRs in the window.
cat > "$main/bin/jg-backlog.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in markdown) exit 0 ;; ready) echo 'ready[0]{id,state}:'; exit 0 ;; esac
exit 2
EOF
cat > "$d/stub/gh" <<'EOF'
#!/usr/bin/env bash
case " $* " in *" -R owner/pr-repo "*) printf '%s\n' https://github.com/owner/pr-repo/pull/7 https://github.com/owner/pr-repo/pull/8 ;; esac
EOF
chmod +x "$main/bin/jg-backlog.sh" "$d/stub/gh"
export PATH="$d/stub:$PATH"
printf 'tr\t%s\towner/trunk-repo\npr\t%s\towner/pr-repo\n' "$trunk" "$pr" > "$main/config/homes.tsv"

# The trunk home: a ticket per landing, stamped as the trunk writers stamp it (landed_at at the landing, live_at
# when a go-live range carried it, released_at when a release did, pinned_back_at on a pin-back). Project p landed
# four commits (t1..t4) and went live at the third: t1..t3 carry live_at; a hook failure at the fourth writes
# nothing. Project q landed tq1, which a release then carried, and tq2 since, which waits. In the 2 h window:
# landed 3 (t3, tq2, t4), live 1 (t3). Waiting: t4 (30 min) and tq2 (100 min), so the oldest waits 100 min.
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
core_tables_home "$repo" "$trunk"
ln -sn "$repo/bin" "$trunk/bin"
tick() {  # <home> <ticket> <key=minutes-ago>...: file a ticket and lay stamps on it, as the trunk writers do
  local home=$1 id=$2 args=() kv
  shift 2
  JG_HOME=$home "$repo/bin/jg-backlog.sh" add "$id" "[feature] fixture $id" --priority 2 --body why >/dev/null
  for kv in "$@"; do args+=(--set-metadata "${kv%%=*}=$(iso "$(ago "${kv#*=}")")"); done
  JG_HOME=$home python3 -I "$repo/core/item-store/adapters/bd_compat.py" update "$id" "${args[@]}" >/dev/null
}
tick "$trunk" jg-t1 landed_at=300 live_at=150
tick "$trunk" jg-t2 landed_at=180 live_at=150
tick "$trunk" jg-tq1 landed_at=240 released_at=200
tick "$trunk" jg-t3 landed_at=90 live_at=60
tick "$trunk" jg-tq2 landed_at=100
tick "$trunk" jg-t4 landed_at=30

# The trunk lead's channel in Main: one real open keyed ask to Main over 2 h. The rest must not count:
# answered, superseded by a keyed working line, closed by a keyed done, unkeyed, a relayed captain hold, the
# parent's own continuity key, and one under 2 h.
printf 'kind=squad_lead\n' > "$main/state/tr.meta"
printf '%s\n' \
  "needs-decision [key=old-ask] [at=$(ago 180)]: pick A or B for the cache layout" \
  "blocked [key=answered] [at=$(ago 180)]: need the staging token" \
  "resolved [key=answered] [at=$(ago 170)]: token placed" \
  "blocked [key=superseded] [at=$(ago 180)]: waiting on the lander" \
  "working [key=superseded] [at=$(ago 160)]: lander back, landing now" \
  "blocked [key=shipped] [at=$(ago 180)]: lane waits for the trunk" \
  "done [key=shipped] [at=$(ago 150)]: landed" \
  "blocked [at=$(ago 180)]: unkeyed prose about the watcher" \
  "needs-decision [key=captain-hold-tq9] [at=$(ago 180)]: held for the captain" \
  "blocked [key=remote-reply-continuity-tr] [at=$(ago 180)]: parent reply continuity" \
  "needs-decision [key=young] [at=$(ago 30)]: a fresh ask" \
  > "$main/state/tr.status"

# The pulse check's 2h report with the old blocks verbatim (paths point into the fixture main home).
cat > "$main/state/fleet-pulse.check.sh" <<'EOF'
#!/usr/bin/env bash
# Every 2 h: one line so Main reviews gaps (fixture of the 2h report only).
set -u
MAIN=__MAIN__
now=__NOW__
since=$(date -u -d "@$((now - 7200))" +%FT%TZ)
line=""
while IFS=$'\t' read -r name hp repos; do
  m=0 by=0; for repo in $repos; do
    u=$(timeout 20 gh pr list -R "$repo" --state merged --limit 60 --json mergedAt,url,author \
        -q ".[] | select(.mergedAt >= \"$since\") | select(.author.is_bot | not) | .url" 2>/dev/null) || { m="?"; break; }
    for x in $u; do m=$((m + 1)); done
  done
  w=0 p=0 b=0
  for s in "$hp"/state/*.status; do
    case "$(tail -n1 "$s" 2>/dev/null)" in working*) w=$((w+1));; paused*) p=$((p+1));; blocked*) b=$((b+1));; esac
  done
  # Home flow row (playbook M2/M3): open lanes, ready, done-not-landed, oldest wait, minutes since working.
  IFS=$'\t' read -r _ o fw rd dw ow ms ct dy <<<"$(timeout 25 $MAIN/config/fm-flow-check.sh "$hp" --summary 2>/dev/null)"
  lk=$(python3 - "$MAIN/state/$name.status" "$now" <<'PY'
import re,sys
op={};last=0
for l in open(sys.argv[1],errors='replace'):
    a=re.search(r'\[at=(\d+)\]',l);last=int(a.group(1)) if a else last
    v=re.match(r'([a-z-]+)',l);v=v.group(1) if v else '';k=re.search(r'\[key=([^\]]+)\]',l);k=k.group(1) if k else 'default'
    if k.startswith('captain-hold') or k.startswith('pending-reply'):continue
    if v in('needs-decision','blocked'):op.setdefault(k,last)
    elif v=='resolved':op.pop(k,None)
print(sum(1 for a in op.values() if int(sys.argv[2])-a>7200))
PY
)
  flag="" st="" bp=""
  line="$line $name:landed$m/open${o:-?}$flag(w${fw:-?} done${dw:-?} asks>2h${lk:-?} dry=${dy:-?})$st$bp"
done < "$MAIN/config/homes.tsv"
echo "fleet-pulse 2h (landings = merged PRs; open target 4, ! = over, UNDER = free slots with ready work; rule words 1):$line - answer lead asks over 2 h"
EOF
sed -i -e "s|__MAIN__|'$main'|" -e "s|__NOW__|$now|" "$main/state/fleet-pulse.check.sh"
chmod 700 "$main/state/fleet-pulse.check.sh"
# The home's register script is this checkout's; the check is registered before the wiring, as on a live home.
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$repo/bin/jg-check-register.sh" > "$main/bin/jg-check-register.sh"
chmod +x "$main/bin/jg-check-register.sh"
JG_HOME=$main "$main/bin/jg-check-register.sh" fleet-pulse >/dev/null
accepted() {  # the gate the watcher applies before it runs a state check
  bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" fleet-pulse' _ "$repo" "$main/state"
}
pass_if registered-before-wiring accepted

echo "== before: the old 2h report is blind to the trunk"
before=$("$main/state/fleet-pulse.check.sh")
echo "$before"
expect old-trunk-home-landed0-open-unknown ' tr:landed0/open?(' "$before"
expect old-asks-count-closed-unkeyed-parent 'asks>2h5 ' "$before"
expect old-pr-home-counts-merged-prs ' pr:landed2/open?(' "$before"

echo "== wiring: dry run names every block and writes nothing"
copy=$(cat "$main/state/fleet-pulse.check.sh")
dry=$("$feature/wiring.sh" --dry-run "$main")
expect dry-run-names-blocks 'onto the trunk era: landed landed-line legend flow asks' "$dry"
pass_if dry-run-writes-nothing test "$copy" = "$(cat "$main/state/fleet-pulse.check.sh")"
"$feature/wiring.sh" "$main"
pass_if retargeted-check-parses bash -n "$main/state/fleet-pulse.check.sh"
pass_if watcher-accepts-retargeted-check accepted
again=$("$feature/wiring.sh" "$main")
pass_if rerun-is-silent test -z "$again"

echo "== after: the 2h report reads the trunk records and real asks"
after=$("$main/state/fleet-pulse.check.sh")
echo "$after"
expect trunk-home-landed-live-rtl ' tr:landed3/live1/rtl100m/open0(w0 done0 asks>2h1 dry=1)' "$after"
expect pr-home-still-counts-merged-prs ' pr:landed2/open0(w0 done0 asks>2h0 dry=1)' "$after"
expect legend-names-trunk-landings 'fleet-pulse 2h (landed = trunk landings, else merged PRs;' "$after"
refute pr-home-has-no-trunk-fields 'pr:landed2/live' "$after"

echo "== trunk-pulse rules"
tp=$feature/bin/trunk-pulse.sh
got=$("$tp" "$pr" "$(ago 120)" "$now") && rc=0 || rc=$?
pass_if no-trunk-records-exit-1 test "$rc:$got" = 1:
# A pin-back: all three landings went live, then the home went back to the first, which gives the two above it
# pinned_back_at; they wait again from their landing. Live counts each ticket's live_at in the window.
pin=$d/pin
core_tables_home "$repo" "$pin"; ln -sn "$repo/bin" "$pin/bin"
tick "$pin" jg-p1 landed_at=300 live_at=90
tick "$pin" jg-p2 landed_at=200 live_at=90 pinned_back_at=10
tick "$pin" jg-p3 landed_at=100 live_at=90 pinned_back_at=10
expect pin-back-waits-again "$(printf '3\t3\t200')" "$("$tp" "$pin" "$(ago 400)" "$now")"
# Every ticket live again after the pin-back: nothing waits.
JG_HOME=$pin python3 -I "$repo/core/item-store/adapters/bd_compat.py" update jg-p2 --set-metadata "live_at=$(iso "$(ago 5)")" >/dev/null
JG_HOME=$pin python3 -I "$repo/core/item-store/adapters/bd_compat.py" update jg-p3 --set-metadata "live_at=$(iso "$(ago 5)")" >/dev/null
expect all-live-nothing-waits "$(printf '1\t3\t-')" "$("$tp" "$pin" "$(ago 120)" "$now")"
# A reverted landing does not wait.
tick "$pin" jg-p4 landed_at=50 reverted_at=40
expect reverted-landing-does-not-wait "$(printf '1\t2\t-')" "$("$tp" "$pin" "$(ago 60)" "$now")"

echo "== lead-asks rules"
la=$feature/bin/lead-asks.sh
expect missing-status-is-zero 0 "$("$la" "$main/state/none.status" "$now")"
expect young-ask-counts-past-its-age 2 "$("$la" "$main/state/tr.status" "$now" 600)"
JG_CLASSIFY_BIN=$d/none/jg-classify JG_CLASSIFY_GO=$d/no-such-go "$la" "$main/state/tr.status" "$now" >"$d/out" 2>/dev/null && rc=0 || rc=$?
pass_if broken-classifier-exits-2 test "$rc:$(cat "$d/out")" = 2:

if [ "$fail" = 0 ]; then echo "PASS trunk-pulse"; else echo "FAIL trunk-pulse" >&2; exit 1; fi
