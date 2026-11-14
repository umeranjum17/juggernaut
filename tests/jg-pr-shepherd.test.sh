#!/usr/bin/env bash
# Journey: a lead turns a paged pull request into a shepherd lane whose only job is that merge, and the next page reaches the
# lane and not the lead. Every step runs the real script: the brief scaffold, the spawn intake core, and the installed pager shim
# with a forge stub; the steer command is a recorder.
# a) bin/jg-brief.sh --shepherd writes a Shepherd section naming the address, forbidding a waived or removed check, and
#    naming bin/jg-pr-merge.sh as the only merge path; it refuses a scout, a bad address and a mode with no pull request;
# b) the spawn intake takes --shepherd on a publishing ship, refuses it on a scout, on a mode that publishes nothing and on a relaunch;
# c) a page for a pull request with a live shepherd goes to that lane and the lead's queue gets no line;
# d) a lane that is done, one with no record for this address, and a failed send all leave the page for the lead;
# e) the page keeps one episode, so the second page an hour later reaches the lane too;
# f) a foreign pull request (another author, no task record) beside the own one gets no page, no lane message and no episode.
# Usage: tests/jg-pr-shepherd.test.sh   (at most 60 s)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null XDG_DATA_HOME=$d/share
unset GIT_CONFIG_COUNT JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_DATA_OVERRIDE
mkdir -p "$HOME" "$d/stub/prs" "$d/stub/steps"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
fails=0; LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/pr-shepherd.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
URL=https://github.com/o/ra/pull/11

# A home whose bin and core are the real ones.
H=$d/home1; mkdir -p "$H/state" "$H/data" "$H/config" "$H/bin" "$H/projects"
ln -sn "$ROOT/core" "$H/core"; for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/${f##*/}"; done
printf -- '- ra - fixture\n' > "$H/data/projects.md"; printf 'release-after-commits=3\nrelease-after-hours=48\n' > "$H/config/trunk-policy"
git init -q "$H/projects/ra"; git -C "$H/projects/ra" commit -q --allow-empty -m base; git -C "$H/projects/ra" remote add origin https://github.com/o/ra

# a) the brief
brief() { JG_HOME=$H "$H/bin/jg-brief.sh" "$@" 2>&1; }
out=$(brief shep1 ra --mode direct-PR --shepherd "$URL"); B=$H/data/shep1/brief.md
[ -f "$B" ] || { say "FAIL: a) no brief written: $out"; exit 1; }
check 'a) the brief names the address' "$(grep -c "^Shepherd of: $URL\$" "$B")" 1
check 'a) the brief forbids a waived or removed check' "$(grep -c 'Never waive, skip, disable, loosen, re-run past or remove a check' "$B")" 1
check 'a) the brief names jg-pr-merge.sh as the only merge path' "$(grep -c 'Merge only through .*bin/jg-pr-merge.sh' "$B")" 1
check 'a) a brief without --shepherd has no section' "$(brief plain1 ra --mode direct-PR >/dev/null; grep -c '^# Shepherd' "$H/data/plain1/brief.md" || true)" 0
check 'a) a scout is refused' "$(brief shep2 ra --scout --shepherd "$URL" | grep -c 'applies only to ship briefs')" 1
check 'a) an address that is not a pull request is refused' "$(brief shep3 ra --mode direct-PR --shepherd 'PR 11' | grep -c 'full https:// address')" 1
check 'a) a mode with no pull request is refused' "$(brief shep4 ra --mode local --shepherd "$URL" | grep -c 'meaningless on local')" 1

# b) the spawn intake, through the dispatcher the spawn calls
if command -v "${JG_SPAWN_CORE_GO:-go}" >/dev/null 2>&1; then
  export JG_STATE_OVERRIDE=$d/corestate; core=$ROOT/bin/jg-spawn-core.sh
  intake() { "$core" intake "$@" 2>&1; }
  check 'b) a publishing ship takes the address' "$(intake shep1 ra --mode direct-PR --yolo off --ticket jg-1 --shepherd "$URL" | sed -n "s/^SHEPHERD=//p")" "'$URL'"
  check 'b) a scout is refused' "$(intake shep1 ra --scout --ticket jg-1 --shepherd "$URL" | grep -c -- '--shepherd applies only to ship spawns')" 1
  check 'b) a mode that publishes nothing is refused' "$(intake shep1 ra --mode local --yolo off --ticket jg-1 --shepherd "$URL" | grep -c 'meaningless on local')" 1
  check 'b) a relaunch reuses the recorded address' "$(intake shep1 --relaunch --shepherd "$URL" | grep -c 'recorded shepherd address')" 1
  check 'b) an empty address is refused' "$(intake shep1 ra --mode direct-PR --yolo off --ticket jg-1 --shepherd= | grep -c 'non-empty pull request address')" 1
  unset JG_STATE_OVERRIDE
else
  say 'skip: b) no Go toolchain on PATH'
fi

# c-e) the pager
cat > "$d/stub/gh-axi" <<'STUB'
#!/usr/bin/env bash
case $2 in
  repos/*/pulls\?state=open*) cat "$STUB/prs/$(printf '%s' "${2#repos/}" | sed 's#/pulls.*##; s#/#__#')" 2>/dev/null; exit 0 ;;
  user) echo me ;;
  repos/*/pulls/*) echo 3 ;;
  *) exit 1 ;;
esac
STUB
cat > "$d/stub/state" <<'STUB'
#!/usr/bin/env bash
n=${!#}; n=${n##*/}; [ -e "$STUB/steps/$n" ] || exit 1
printf 'juggernaut/waiting-for: %s\n' "$(cat "$STUB/steps/$n")"
STUB
cat > "$d/stub/send" <<'STUB'
#!/usr/bin/env bash
# the steer command: records "<lane> <text>"; stub/send-fails makes it refuse.
[ ! -e "$STUB/send-fails" ] || exit 1
[ -n "${JG_HOME:-}" ] || exit 1
printf '%s\t%s\n' "$1" "$2" >> "$STUB/sent.log"
STUB
chmod +x "$d/stub/gh-axi" "$d/stub/state" "$d/stub/send"
export STUB=$d/stub JG_PR_PAGER_GH=$d/stub/gh-axi JG_PR_PAGER_STATE=$d/stub/state JG_PR_PAGER_SEND=$d/stub/send
JG_HOME=$H "$H/core/pr-pager/wiring.sh" "$H" >/dev/null
T0=$(date +%s); iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
printf '11\t%s\t%s\tfeature/x\tme\n' "$URL" "$(iso $((T0 - 30 * 60)))" > "$STUB/prs/o__ra"
echo 'a check is not passing: unit-tests' > "$STUB/steps/11"
run() { JG_HOME=$H JG_PR_PAGER_NOW=$((T0 + $1 * 60)) "$H/state/pr-pager.check.sh" 2>&1 || true; }
sent() { [ -f "$STUB/sent.log" ] && grep -c . "$STUB/sent.log" || echo 0; }
meta() { printf 'window=w\nkind=ship\nshepherd_of=%s\npr=%s\n' "$1" "$1" > "$H/state/$2.meta"; }
reset() { rm -rf "$H/state/.pr-pager" "$STUB/sent.log" "$STUB/send-fails" "$H/state/shep1.status"; }

meta "$URL" shep1; echo 'working [at=1]: fixing' > "$H/state/shep1.status"
out=$(run 0)
check 'c) the lead gets no line' "$(grep -c '^pr-pager: ' <<< "$out" || true)" 0
check 'c) the lane got one page' "$(sent)" 1
check 'c) the page went to the shepherd lane' "$(cut -f1 "$STUB/sent.log")" shep1
case $(cut -f2 "$STUB/sent.log") in *"$URL"*'unit-tests'*'never re-run or waive it'*'page 1'*) say 'ok: c) the page names the address, the check and the next step' ;; *) say "FAIL: c) page text: $(cat "$STUB/sent.log")"; fails=$((fails + 1)) ;; esac
check 'e) inside the hour nothing more' "$(run 30 | grep -c . || true)$(sent)" 01
run 60 >/dev/null
check 'e) an hour later the lane gets page 2' "$(grep -c 'page 2' "$STUB/sent.log")" 1

reset; echo 'done [at=2]: merged' > "$H/state/shep1.status"
out=$(run 0)
check 'd) a finished lane leaves the page for the lead' "$(grep -c '^pr-pager: .*page 1' <<< "$out")$(sent)" 10
reset; echo 'working [at=1]: x' > "$H/state/shep1.status"; : > "$STUB/send-fails"
out=$(run 0)
check 'd) a failed send leaves the page for the lead' "$(grep -c '^pr-pager: .*page 1' <<< "$out")$(sent)" 10
reset; meta https://github.com/o/ra/pull/99 shep1; echo 'working [at=1]: x' > "$H/state/shep1.status"
out=$(run 0)
check 'd) a lane that shepherds another pull request is not paged' "$(grep -c '^pr-pager: .*page 1' <<< "$out")$(sent)" 10

reset; printf '12\t%s\t%s\tfeature/y\tsomeone-else\n' "${URL%/*}/12" "$(iso $((T0 - 30 * 60)))" >> "$STUB/prs/o__ra"; echo 'a check is not passing: lint' > "$STUB/steps/12"
out=$(run 0)
check 'f) the own pull request is paged and the foreign one is not' "$(grep -c "${URL%/*}/11" <<< "$out")$(grep -c "${URL%/*}/12" <<< "$out" || true)" 10
check 'f) the foreign pull request leaves no episode' "$([ -e "$H/state/.pr-pager/o__ra/12" ] && echo yes || echo no)" no

[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say 'all pr-shepherd checks passed'
