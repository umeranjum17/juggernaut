#!/usr/bin/env bash
# done-done journey: a release cut does not leave pull requests behind on a
# release branch that already shipped, driven by the real
# bin/jg-pr-check.sh, bin/jg-version-branch-sync.sh and
# bin/jg-release-readiness.sh.
#
# The fixture project has main, release/c-5 (shipped) and release/c-6 (current).
# Pull request 10 still targets release/c-5, pull request 11 is an ordinary
# feature on release/c-6, and pull request 20 is the release pull request from
# release/c-6 into main. The journey shows that:
#   1. arming pull request 20 is refused, naming pull request 10 and the fix,
#      and nothing is recorded;
#   2. the readiness pass holds the release as `orphaned` and says which pull
#      request and which branch, instead of counting it as ready;
#   3. when the c-5 release pull request (30) merges, the sync pass moves
#      pull request 10 to release/c-6 with `gh pr edit`, and an ordinary feature
#      merge moves nothing;
#   4. arming pull request 20 then passes and the release is no longer orphaned;
#   5. with a pull request orphaned again, a bare environment waiver changes
#      nothing at arm time, and only the merge-time waiver passes and is
#      recorded in the task record.
# The forge is a recording `gh` that keeps the pull request table in a file, so
# the proof needs no network: a retarget is the stub rewriting a base.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/release-cut-orphans.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export HOME=$T/user-home
mkdir -p "$HOME"

H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/fakebin" "$T/projects"

# A project whose origin carries main, release/c-5 and release/c-6, with one
# change on release/c-6 so the release has something to ship.
git init -q --bare "$T/origin.git" || fail "cannot create the fixture origin"
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/projects/proj" 2>/dev/null || fail "cannot clone the fixture"
P=$T/projects/proj
printf 'v1\n' > "$P/README.md"
git -C "$P" add -A
git -C "$P" commit -qm c1 || fail "cannot seed the fixture"
for b in main release/c-5 release/c-6; do
  git -C "$P" push -q origin "HEAD:refs/heads/$b" || fail "cannot push $b"
done
printf 'feature\n' > "$P/one.txt"
git -C "$P" add -A
git -C "$P" commit -qm 'Add a feature (#11)'
git -C "$P" push -q origin HEAD:refs/heads/release/c-6 || fail "cannot push the feature"
git -C "$P" reset -q --hard HEAD~1
git -C "$P" fetch -q
# The readiness pass reads a copy whose origin has the provider's URL shape.
git clone -q "$T/origin.git" "$T/rcopy" 2>/dev/null || fail "cannot clone the readiness copy"
git -C "$T/rcopy" remote set-head origin main >/dev/null 2>&1 || true
git -C "$T/rcopy" remote set-url origin https://github.com/acme/thing.git

# The pull request table: number, url, base, head. The stub reads and rewrites
# it, so a retarget is visible to every later read.
U=https://github.com/acme/thing/pull
{
  printf '10\t%s/10\trelease/c-5\tfm/old-feature\n' "$U"
  printf '11\t%s/11\trelease/c-6\tfm/new-feature\n' "$U"
  printf '20\t%s/20\tmain\trelease/c-6\n' "$U"
  printf '30\t%s/30\tmain\trelease/c-5\n' "$U"
} > "$T/prs.tsv"
: > "$T/gh.log"

cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# A recording forge: the pull request table is $PRS (number, url, base, head).
printf '%s\n' "$*" >> "$GH_LOG"
number_of() { local a; for a in "$@"; do case "$a" in */pull/[0-9]*) printf '%s\n' "${a##*/}"; return ;; [0-9]*) printf '%s\n' "$a"; return ;; esac; done; }
case "$1 $2" in
  "pr view")
    case "$*" in
      *headRefOid*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
      *isDraft*) printf '{"isDraft":false}\n' ;;
      *mergeable*) printf 'MERGEABLE\n' ;;
      *baseRefName*)
        n=$(number_of "${@:3}")
        awk -F '\t' -v n="$n" '$1 == n { print $3 "\t" $4 }' "$PRS" ;;
    esac ;;
  "pr list")
    case "$*" in
      *--base*)
        b=
        while [ "$#" -gt 0 ]; do [ "$1" = --base ] && { b=$2; break; }; shift; done
        awk -F '\t' -v b="$b" '$3 == b { print $1 "\t" $2 }' "$PRS" ;;
      *) awk -F '\t' '$3 != "main" { print $1 "\t" $2 "\t" $3 }' "$PRS" ;;
    esac ;;
  "pr edit")
    n=$3
    b=
    while [ "$#" -gt 0 ]; do [ "$1" = --base ] && { b=$2; break; }; shift; done
    awk -F '\t' -v n="$n" -v b="$b" 'BEGIN{OFS="\t"} $1 == n { $3 = b } { print }' "$PRS" > "$PRS.new" \
      && mv "$PRS.new" "$PRS" ;;
  "api "*)
    case "$*" in
      *state=all*) ;;
      *pulls\?state=open\&per_page*) awk -F '\t' '$3 != "main" { print $1 "\t" $2 "\t" $3 }' "$PRS" ;;
      *pulls\?*) printf '0\n' ;;
      *check-runs*) printf 'completed success @Smoke,completed success @Build\n' ;;
      *) exit 1 ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PRS=$T/prs.tsv GH_LOG=$T/gh.log

env_run() {
  env JG_ROOT_OVERRIDE='' JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" \
    JG_CONFIG_OVERRIDE="$H/config" JG_PROJECTS_OVERRIDE="$T/projects" PATH="$T/fakebin:/usr/bin:/bin" "$@"
}
mkmeta() {  # <id>
  printf 'window=jg-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' "$1" "$T" "$P" > "$H/state/$1.meta"
}
pr_check() {  # <id> <pr-number> [env...]
  local id=$1 n=$2
  shift 2
  env_run "$@" "$REPO/bin/jg-pr-check.sh" "$id" "$U/$n" 2>&1
}
rr() {  # <verb>
  mkdir -p "$T/rhome/config" "$T/rhome/data"
  printf 'project-dir=%s\n' "$T/rcopy" > "$T/rhome/config/release-readiness"
  env PATH="$T/fakebin:/usr/bin:/bin" JG_DATA_OVERRIDE="$T/rhome/data" JG_CONFIG_OVERRIDE="$T/rhome/config" \
    bash "$REPO/bin/jg-release-readiness.sh" "$T/rhome" "$1" --now 1800000000 2>&1
}
sync_features() {  # <merged-pr-number>
  env_run "$REPO/bin/jg-version-branch-sync.sh" features "$U/$1" "$P" 2>&1
}
base_of() { awk -F '\t' -v n="$1" '$1 == n { print $3 }' "$PRS"; }
edits() { grep -c '^pr edit' "$GH_LOG"; }

log "fixture: main, release/c-5 (shipped), release/c-6 (current); PR 10 on c-5, PR 11 on c-6, PR 20 = c-6 to main"

# 1. The release pull request is refused while pull request 10 sits on c-5.
mkmeta cut-a
out=$(pr_check cut-a 20); rc=$?
log "arm PR 20 with PR 10 on release/c-5 (rc=$rc): $(printf '%s' "$out" | head -n 2 | tr '\n' ' ')"
[ "$rc" -ne 0 ] || fail "the release pull request was armed with an orphan on release/c-5"
case "$out" in *"$U/10"*"release/c-5"*) ;; *) fail "the refusal does not name PR 10 and its base: $out" ;; esac
case "$out" in *"gh-axi pr edit 10 --base release/c-6"*) ;; *) fail "the refusal does not name the fix: $out" ;; esac
case "$out" in *"$U/11"*) fail "the refusal named a pull request that is not an orphan: $out" ;; esac
grep -q '^pr=' "$H/state/cut-a.meta" && fail "the refused release pull request was recorded anyway"

# 2. Readiness holds the release as orphaned and names the pull request.
out=$(rr tick)
log "readiness tick: $out"
case "$out" in *"not ready: orphaned"*) ;; *) fail "the readiness pass did not report orphaned: $out" ;; esac
out=$(rr show)
log "readiness line: $out"
case "$out" in *"1 pull request still targets release/c-5: $U/10"*) ;; *) fail "the digest line does not name the orphan: $out" ;; esac

# 3. The c-5 release pull request merges: PR 10 moves to c-6. A feature merge moves nothing.
: > "$GH_LOG"
out=$(sync_features 11)
log "sync after the feature merge (PR 11): ${out:-<silent>}"
[ "$(edits)" -eq 0 ] || fail "an ordinary feature merge retargeted a pull request"
out=$(sync_features 30)
log "sync after the c-5 release merge (PR 30): $out"
case "$out" in *"moved pull request 10 to release/c-6"*) ;; *) fail "the release cut did not report the move: $out" ;; esac
grep -q '^pr edit 10 .*--base release/c-6' "$GH_LOG" || fail "the sync never ran gh pr edit 10 --base release/c-6"
[ "$(base_of 10)" = release/c-6 ] || fail "PR 10 still targets $(base_of 10)"
[ "$(base_of 11)" = release/c-6 ] || fail "PR 11 was moved"
[ "$(edits)" -eq 1 ] || fail "the release cut edited more than the orphan"

# 4. Arming the release pull request now passes; the release is no longer orphaned.
mkmeta cut-b
out=$(pr_check cut-b 20); rc=$?
log "arm PR 20 after the move (rc=$rc): $(printf '%s' "$out" | tail -n 1)"
[ "$rc" -eq 0 ] || fail "the release pull request was refused after the orphan moved: $out"
grep -qx "pr=$U/20" "$H/state/cut-b.meta" || fail "the release pull request was not recorded"
out=$(rr show)
log "readiness line after the move: $out"
case "$out" in *orphan*|*"still target"*) fail "readiness still reports an orphan: $out" ;; esac

# 5. Orphaned again: the arm-time refusal ignores a bare waiver; only the merge-time waiver passes.
awk -F '\t' 'BEGIN{OFS="\t"} $1 == 10 { $3 = "release/c-5" } { print }' "$PRS" > "$PRS.new" && mv "$PRS.new" "$PRS"
mkmeta cut-c
out=$(pr_check cut-c 20 JG_PR_ALLOW_ORPHANS="the captain said ship it"); rc=$?
[ "$rc" -ne 0 ] || fail "a bare environment waiver passed the arm-time refusal"
mkmeta cut-d
out=$(pr_check cut-d 20 JG_PR_CHECK_MERGE=1 JG_PR_ALLOW_ORPHANS="the captain said ship it"); rc=$?
log "merge-time record with the waiver (rc=$rc): $(printf '%s' "$out" | grep -m1 '^waived' )"
[ "$rc" -eq 0 ] || fail "the merge-time waiver was refused: $(printf "%s" "$out" | head -n 12)"
grep -qx 'orphans_waived=the captain said ship it' "$H/state/cut-d.meta" || fail "the waiver was not recorded in the task record"
mkmeta cut-e
out=$(pr_check cut-e 20 JG_PR_CHECK_MERGE=1); rc=$?
[ "$rc" -ne 0 ] || fail "the merge-time record passed without a waiver"
log "merge-time record without a waiver (rc=$rc): refused"

cat > "$OUT/steps.json" <<'JSON'
{"target":{"version":"jg-pr-check.sh, jg-version-branch-sync.sh, jg-release-readiness.sh"},"start":"a fixture project with release/c-5 shipped, release/c-6 current, a pull request still on c-5 and the c-6 release pull request","steps":["arm the release pull request: refused, naming the pull request on release/c-5 and the gh-axi pr edit fix","readiness tick and show: orphaned, naming one pull request and release/c-5","the c-5 release pull request merges: the sync pass runs gh pr edit 10 --base release/c-6; a feature merge edits nothing","arm the release pull request again: passes; readiness no longer reports an orphan","orphaned again: a bare environment waiver changes nothing at arm time; the merge-time waiver passes and is recorded as orphans_waived"],"result":"a release cut moves the pull requests left on the shipped branch, and the release pull request is refused until they are moved"}
JSON
log "PASS: the release cut retargets orphans and the release pull request waits for them"
