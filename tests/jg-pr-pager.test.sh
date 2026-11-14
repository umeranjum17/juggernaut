#!/usr/bin/env bash
# Journey: every open pull request pages the lead that answers for it, through the real wiring and the installed check shim,
# with a forge stub (gh-axi and the pull request state) and two fixture homes: Main and one lead.
# a) an open pull request 30 minutes old with a red check: one page in the lead home with the address, the check's name and the next step;
# b) the same pull request one hour later: a second page; inside the hour: nothing;
# c) six pages with the same next step: one note on the lead's parent channel (Main), and no second one;
# d) a changed next step restarts the count; merged or closed: no page, and the episode is gone;
# e) a repository of another lead, or of Main: no page and no episode in the lead home, and the lead's repository pages nothing in Main;
# f) a local-trunk release that is due with no pull request: one page; with its pull request open: no release page;
# g) no call of bin/jg-captain-say.sh at any step.
# Usage: tests/jg-pr-pager.test.sh   (at most 30 s)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null XDG_DATA_HOME=$d/share
unset GIT_CONFIG_COUNT JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_DATA_OVERRIDE
mkdir -p "$HOME" "$d/stub/prs" "$d/stub/steps"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
fails=0; LOG=${DONE_DONE_EVIDENCE_ROOT:+$DONE_DONE_EVIDENCE_ROOT/pr-pager.log}
say() { printf '%s\n' "$*" | tee -a "${LOG:-/dev/null}"; }
check() { if [ "$2" = "$3" ]; then say "ok: $1"; else say "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }

# A home whose bin is the real bin, except that bin/jg-captain-say.sh records any call.
mkhome() {  # <dir>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/bin" "$1/projects"
  ln -sn "$ROOT/core" "$1/core"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$1/bin/${f##*/}"; done
  rm "$1/bin/jg-captain-say.sh"; printf '#!/bin/sh\necho "$@" >> %s\n' "$d/captain-say.log" > "$1/bin/jg-captain-say.sh"; chmod +x "$1/bin/jg-captain-say.sh"
  : > "$1/data/projects.md"; printf 'release-after-commits=3\nrelease-after-hours=48\n' > "$1/config/trunk-policy"
}
clone() {  # <home> <name> <owner/repo> [mode]
  git init -q "$1/projects/$2"; git -C "$1/projects/$2" commit -q --allow-empty -m base
  git -C "$1/projects/$2" remote add origin "https://github.com/$3"
  printf -- '- %s%s - fixture\n' "$2" "${4:+ [$4]}" >> "$1/data/projects.md"
}
M=$d/main; L=$d/lead; mkhome "$M"; mkhome "$L"
printf 'lead1' > "$L/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$M" > "$L/.jg-squad-lead-parent"
for h in "$M" "$L"; do clone "$h" ra o/ra; clone "$h" rb o/rb; done
JG_HOME=$M "$M/bin/jg-pr-owner.sh" set o/ra lead1 >/dev/null

cat > "$d/stub/gh-axi" <<'STUB'
#!/usr/bin/env bash
# api <path> --jq <expr>: the open list of a repository is stub/prs/<owner__repo>; pulls/<n> answers the commit count.
case $2 in
  repos/*/pulls\?state=open*) cat "$STUB/prs/$(printf '%s' "${2#repos/}" | sed 's#/pulls.*##; s#/#__#')" 2>/dev/null; [ -e "$STUB/prs/forge-down" ] && exit 1; exit 0 ;;
  repos/*/pulls/*) echo 7 ;;
  *) exit 1 ;;
esac
STUB
cat > "$d/stub/state" <<'STUB'
#!/usr/bin/env bash
# the pull request state command: the last argument is the address; stub/steps/<number> holds the waiting-for text.
n=${!#}; n=${n##*/}
[ -e "$STUB/steps/$n" ] || exit 1
printf 'juggernaut/waiting-for: %s\n' "$(cat "$STUB/steps/$n")"
STUB
chmod +x "$d/stub/gh-axi" "$d/stub/state"
export STUB=$d/stub JG_PR_PAGER_GH=$d/stub/gh-axi JG_PR_PAGER_STATE=$d/stub/state

for h in "$M" "$L"; do JG_HOME=$h "$ROOT/core/pr-pager/wiring.sh" "$h" >/dev/null; done
T0=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# pr <repo file> <number> <age minutes> [head ref]
pr() { printf '%s\t%s\t%s\t%s\n' "$2" "https://github.com/${1//__//}/pull/$2" "$(iso $((T0 - $3 * 60)))" "${4:-feature/x}" >> "$STUB/prs/$1"; }
run() {  # <home> <minutes after T0>: the installed shim, as the watcher runs it
  JG_HOME=$1 JG_PR_PAGER_NOW=$((T0 + $2 * 60)) "$1/state/pr-pager.check.sh" 2>&1 || true
}
pages() { grep -c '^pr-pager: ' <<< "$1" || true; }

pr o__ra 11 30; pr o__rb 21 45
echo 'a check is not passing: unit-tests' > "$STUB/steps/11"; echo 'a check is not passing: lint' > "$STUB/steps/21"

out=$(run "$L" 0)
check 'a) one page for the lead repository' "$(pages "$out")" 1
case $out in *'https://github.com/o/ra/pull/11'*'unit-tests'*'fix its cause and push'*'page 1'*) say 'ok: a) the page names the address, the check and the next step' ;; *) say "FAIL: a) page text: $out"; fails=$((fails + 1)) ;; esac
check 'a) 7 commits are in the page' "$(grep -c '7 commits' <<< "$out")" 1
check 'e) no page for Main repository in the lead home' "$(grep -c 'o/rb' <<< "$out" || true)" 0
check 'e) no episode for it in the lead home' "$([ -e "$L/state/.pr-pager/o__rb" ] && echo yes || echo no)" no
out=$(run "$M" 0)
check 'e) Main does not page the lead repository' "$(grep -c 'o/ra' <<< "$out" || true)" 0
check 'e) Main pages its own repository' "$(grep -c 'o/rb/pull/21' <<< "$out")" 1
out=''

check 'b) nothing again inside the hour' "$(pages "$(run "$L" 30)")" 0
check 'b) a second page an hour later' "$(run "$L" 60 | grep -c 'page 2')" 1

for k in 2 3 4 5; do out=$(run "$L" $((60 * k))); done   # pages 3..6
check 'c) the sixth page is page 6' "$(grep -c 'page 6' <<< "$out")" 1
check 'c) one note reached the parent channel' "$(grep -c 'pr-pager' "$M/state/lead1.status" 2>/dev/null || true)" 1
run "$L" 360 >/dev/null
check 'c) no second note' "$(grep -c 'pr-pager' "$M/state/lead1.status")" 1

echo 'merge conflicts, which someone has to reconcile' > "$STUB/steps/11"
check 'd) a changed step pages again as page 8' "$(run "$L" 420 | grep -c 'conflict: rebase')" 1
: > "$STUB/prs/o__ra"
out=$(run "$L" 480)
check 'd) closed or merged: no page' "$(pages "$out")" 0
check 'd) closed or merged: no episode' "$(find "$L/state/.pr-pager/o__ra" -type f 2>/dev/null | wc -l | tr -d ' ')" 0

# f) a due release of a local-trunk project with no pull request
clone "$L" lt o/lt local-trunk; JG_HOME=$M "$M/bin/jg-pr-owner.sh" set o/lt lead1 >/dev/null
P=$L/projects/lt; base=$(git -C "$P" rev-parse HEAD)
git -C "$P" branch trunk-v1; git -C "$P" checkout -q -b trunk-v1x 2>/dev/null || true
for i in 1 2 3; do git -C "$P" commit -q --allow-empty -m "c$i"; done
tipsha=$(git -C "$P" rev-parse HEAD)
git -C "$P" branch -f trunk "$tipsha"; git -C "$P" checkout -q trunk
printf '%s\n' "$tipsha" > "$L/state/trunk-tip-lt"; printf '%s\n' "$base" > "$L/state/trunk-released-lt"
: > "$STUB/prs/o__lt"
out=$(run "$L" 500)
check 'f) a due release with no pull request: one page' "$(grep -c 'release due, 3 unreleased commits' <<< "$out")" 1
pr o__lt 31 20 trunk; echo 'the merge call' > "$STUB/steps/31"
out=$(run "$L" 700)
check 'f) with its pull request open: no release page' "$(grep -c 'release due' <<< "$out" || true)" 0
check 'f) with its pull request open: that pull request is paged' "$(grep -c 'green: merge it' <<< "$out")" 1

check 'g) bin/jg-captain-say.sh was never called' "$(cat "$d/captain-say.log" 2>/dev/null | wc -l | tr -d ' ')" 0
[ "$fails" -eq 0 ] || { say "$fails check(s) failed"; exit 1; }
say 'all pr-pager checks passed'
