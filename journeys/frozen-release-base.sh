#!/usr/bin/env bash
# done-done journey: a frozen release branch cannot be targeted by accident,
# driven by the real bin/jg-brief.sh, bin/jg-spawn.sh and bin/jg-pr-check.sh.
#
# The freeze is one line in config/version-branch-frozen. The fixture project has
# release/c-4 (frozen) and release/c-5 (current). The journey shows that:
#   1. a brief and a spawn aimed at release/c-4 stop with one line naming it and
#      release/c-5, before any endpoint or task record exists;
#   2. the same work aimed at release/c-5 goes on to create its endpoint;
#   3. work declared a fix to release/c-4's own red checks (--red-fix-of) is
#      allowed, and only for the branch it names;
#   4. a lane that retargets its pull request at release/c-4 later is refused by
#      the pull request check, and a declared red-fix lane is not.
# The forge is a recording `gh` and the terminal a recording `tmux` that refuses
# to start a window, so the proof needs no network and no live endpoint: a spawn
# that gets past the freeze is the one that asks tmux for a new window.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
LOG=$OUT/frozen-release-base.txt
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
export HOME=$T/user-home
mkdir -p "$HOME"

H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$T/fakebin" "$T/projects"

# A project whose origin carries main, release/c-4 and release/c-5.
git init -q --bare "$T/origin.git" || fail "cannot create the fixture origin"
git -C "$T/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin.git" "$T/projects/proj" 2>/dev/null || fail "cannot clone the fixture"
P=$T/projects/proj
printf 'v1\n' > "$P/README.md"
git -C "$P" add -A
git -C "$P" commit -qm c1 || fail "cannot seed the fixture"
for b in main release/c-4 release/c-5; do
  git -C "$P" push -q origin "HEAD:refs/heads/$b" || fail "cannot push $b"
done
git -C "$P" fetch -q

# The spawn core is a Go program the spawn builds on first use; build it here so
# the restricted PATH below needs no toolchain.
(cd "$REPO/core/spawn" && go build -o "$T/spawn-core" ./cmd/jg-spawn-core) || fail "cannot build the spawn core"

printf '#!/bin/sh\necho "$@" >> %s/tmux.log\nexit 1\n' "$T" > "$T/fakebin/tmux"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *isDraft*) printf '{"isDraft":false}\n' ;;
  *baseRefName*) printf '%s\t%s\n' "${JG_TEST_GH_BASE:-}" "${JG_TEST_GH_HEAD_REF:-}" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/tmux" "$T/fakebin/gh"
: > "$T/tmux.log"

# The backlog is a Beads store (pinned bd and dolt, run only through bin/jg-beads.sh): a spawn reads it
# first and refuses a task with no item there, so the home gets its own store and the two spawned tasks
# get their items.
BD=${JG_BEADS_BD:-${JG_BEADS_TEST_BD:-$(command -v bd)}}
DOLT=${JG_BEADS_DOLT:-${JG_BEADS_TEST_DOLT:-$(command -v dolt)}}
[ -n "$BD" ] && [ -n "$DOLT" ] || fail "the pinned bd and dolt are required (bin/jg-bootstrap.sh install bd dolt)"
mkdir -p "$T/beads"
printf '%s\n' "$T/beads/.beads" > "$H/config/beads-dir"
JG_BEADS_BD=$BD JG_BEADS_DOLT=$DOLT BEADS_DIR="$T/beads/.beads" "$REPO/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 \
  || fail "cannot create the Beads store"
env_run() {
  env JG_BEADS_BD="$BD" JG_BEADS_DOLT="$DOLT" JG_TASK_PRIORITY_CHECK=/nonexistent \
    JG_SPAWN_CORE_BIN="$T/spawn-core" JG_ROOT_OVERRIDE='' JG_HOME="$H" \
    JG_STATE_OVERRIDE="$H/state" JG_DATA_OVERRIDE="$H/data" JG_CONFIG_OVERRIDE="$H/config" \
    JG_PROJECTS_OVERRIDE="$T/projects" JG_SPAWN_NO_GUARD=1 JG_BACKEND=tmux \
    PATH="$T/fakebin:/usr/bin:/bin" "$@"
}
brief() {  # <id> <brief-args...>
  local id=$1
  shift
  env_run "$REPO/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$P" "$@" 2>&1
}
fill() { sed -i 's/{TASK}/the task/;s/{JUGGERNAUT_SPEC}/the spec/' "$H/data/$1/brief.md"; }
spawn() {  # <id> <spawn-args...>
  local id=$1
  shift
  env_run "$REPO/bin/jg-spawn.sh" "$id" "$P" claude --model claude-sonnet-5-5 --mode direct-PR --yolo off "$@" 2>&1
}
launched() { grep -q 'new-window' "$T/tmux.log"; }
reset_tmux() { : > "$T/tmux.log"; }
LINE='release/c-4 is frozen and takes no new work; target release/c-5 instead'
file_item() {  # <id>: the backlog item a spawn of that task needs
  env_run "$REPO/bin/jg-backlog.sh" add "$1" "[feature] Frozen-release fixture $1" --priority 1 --kind ship \
    --repo proj --body "Fixture ticket $1" >/dev/null 2>&1 || fail "cannot file the backlog item $1"
}
file_item next-ok
file_item red-ok

# Host memory pressure on the machine running this proof must not hold a launch
# the journey means to see reach its window step.
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"
printf 'release/c-4\n' > "$H/config/version-branch-frozen"
log "freeze record: config/version-branch-frozen = release/c-4; current version branch = release/c-5"

# 1a. The brief scaffold refuses the frozen base.
out=$(brief ice-brief --base-branch release/c-4); rc=$?
log "brief onto release/c-4 (rc=$rc): $out"
[ "$rc" -ne 0 ] || fail "the brief scaffold accepted the frozen base"
case "$out" in *"$LINE"*) ;; *) fail "the brief refusal does not name the frozen branch and release/c-5" ;; esac
[ ! -e "$H/data/ice-brief/brief.md" ] || fail "a refused brief was written anyway"

# 1b. The spawn refuses the frozen base, even for a hand-written brief that
# records it, and creates nothing.
out=$(brief ice-spawn --base-branch release/c-4 --red-fix-of release/c-4); rc=$?
[ "$rc" -eq 0 ] || fail "could not scaffold the red-fix brief used as a hand-written one: $out"
fill ice-spawn
sed -i '/^Red-fix of:/d' "$H/data/ice-spawn/brief.md"
reset_tmux
out=$(spawn ice-spawn --base-branch release/c-4); rc=$?
log "spawn onto release/c-4 (rc=$rc): $out"
[ "$rc" -ne 0 ] || fail "the spawn accepted the frozen base"
case "$out" in *"$LINE"*) ;; *) fail "the spawn refusal does not name the frozen branch and release/c-5" ;; esac
[ "$(printf '%s\n' "$out" | grep -c 'is frozen')" -eq 1 ] || fail "the refusal is not exactly one line"
launched && fail "the refused spawn still asked for a window"
[ ! -e "$H/state/ice-spawn.meta" ] || fail "the refused spawn wrote a task record"

# 2. The same work onto the next release branch goes on to create its endpoint.
out=$(brief next-ok); rc=$?
[ "$rc" -eq 0 ] || fail "the brief for the current version branch was refused: $out"
fill next-ok
grep -qx 'Base branch: release/c-5' "$H/data/next-ok/brief.md" || fail "the brief did not record release/c-5"
reset_tmux
out=$(spawn next-ok); rc=$?
log "spawn onto release/c-5 (rc=$rc): reached the window step"
case "$out" in *"is frozen"*) fail "the next release branch was refused as frozen: $out" ;; esac
launched || fail "the spawn onto release/c-5 never reached the window step: $out"

# 3. A declared red-fix onto the frozen branch is allowed, and only that branch.
out=$(brief red-ok --base-branch release/c-4 --red-fix-of release/c-4); rc=$?
[ "$rc" -eq 0 ] || fail "the declared red-fix brief was refused: $out"
fill red-ok
grep -q '^Red-fix of: release/c-4' "$H/data/red-ok/brief.md" || fail "the brief did not record the red-fix declaration"
reset_tmux
out=$(spawn red-ok --base-branch release/c-4 --red-fix-of release/c-4); rc=$?
log "spawn onto release/c-4 declared a red-fix (rc=$rc): reached the window step"
case "$out" in *"is frozen"*) fail "the declared red-fix was refused as frozen: $out" ;; esac
launched || fail "the declared red-fix spawn never reached the window step: $out"
reset_tmux
out=$(spawn red-ok --base-branch release/c-4); rc=$?
[ "$rc" -ne 0 ] || fail "a spawn without the declaration took the frozen base"
case "$out" in *"$LINE"*) ;; *) fail "the undeclared spawn did not get the frozen-branch line: $out" ;; esac
out=$(brief red-wrong --base-branch release/c-5 --red-fix-of release/c-4); rc=$?
[ "$rc" -ne 0 ] || fail "a red-fix of one branch was accepted onto another base"
log "red-fix declared for a branch other than the base (rc=$rc): $out"

# 4. A lane that retargets later is refused at the pull request; a red-fix lane is not.
mkmeta() {  # <id> [extra-line]
  { printf 'window=jg-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\n' "$1" "$T" "$P"; [ -z "${2:-}" ] || printf '%s\n' "$2"; } > "$H/state/$1.meta"
}
pr_check() {  # <id> <base> <url>
  env_run JG_TEST_GH_BASE="$2" JG_TEST_GH_HEAD_REF="fm/$1" "$REPO/bin/jg-pr-check.sh" "$1" "$3" 2>&1
}
mkmeta retarget-a
out=$(pr_check retarget-a release/c-4 https://github.com/example/repo/pull/41); rc=$?
log "pull request retargeted at release/c-4 (rc=$rc): $(printf '%s' "$out" | head -n 1)"
[ "$rc" -ne 0 ] || fail "a pull request retargeted at the frozen branch was armed"
case "$out" in *"$LINE"*) ;; *) fail "the retarget refusal does not name the frozen branch and release/c-5: $out" ;; esac
grep -q '^pr=' "$H/state/retarget-a.meta" && fail "the refused pull request was recorded anyway"
mkmeta retarget-b
out=$(pr_check retarget-b release/c-5 https://github.com/example/repo/pull/42)
case "$out" in *"is frozen"*) fail "a pull request on release/c-5 was refused as frozen: $out" ;; esac
mkmeta retarget-c 'red_fix_of=release/c-4'
out=$(pr_check retarget-c release/c-4 https://github.com/example/repo/pull/43)
case "$out" in *"is frozen"*) fail "a declared red-fix pull request was refused as frozen: $out" ;; esac

# 5. The release in flight is the release pull request even with a newer branch.
# config/frozen-release names release/c-4 while it ships; release/c-5 is the
# highest-numbered branch. The c-4 -> main pull request is accepted, a feature
# pull request to main is still refused, and with the marker cleared c-5 is
# current again (so c-4 -> main is refused). An unreadable marker changes nothing.
printf 'release/c-4\n' > "$H/config/frozen-release"
mkmeta rel-a
out=$(env_run JG_TEST_GH_BASE=main JG_TEST_GH_HEAD_REF=release/c-4 "$REPO/bin/jg-pr-check.sh" rel-a https://github.com/example/repo/pull/51 2>&1)
case "$out" in *"targets the default branch"*) fail "the release in flight (c-4 to main) was refused with the marker set: $out" ;; esac
log "marker=release/c-4, release/c-5 present: release pull request c-4 -> main accepted"
mkmeta rel-b
out=$(env_run JG_TEST_GH_BASE=main JG_TEST_GH_HEAD_REF=fm/feature "$REPO/bin/jg-pr-check.sh" rel-b https://github.com/example/repo/pull/52 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a feature pull request to main was accepted with the marker set"
case "$out" in *"targets the default branch"*) ;; *) fail "the feature refusal changed: $out" ;; esac
log "marker=release/c-4: feature pull request -> main still refused"
: > "$H/config/frozen-release"
mkmeta rel-c
out=$(env_run JG_TEST_GH_BASE=main JG_TEST_GH_HEAD_REF=release/c-4 "$REPO/bin/jg-pr-check.sh" rel-c https://github.com/example/repo/pull/53 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "an empty marker still admitted c-4 -> main"
mkmeta rel-d
out=$(env_run JG_TEST_GH_BASE=main JG_TEST_GH_HEAD_REF=release/c-5 "$REPO/bin/jg-pr-check.sh" rel-d https://github.com/example/repo/pull/54 2>&1)
case "$out" in *"targets the default branch"*) fail "with the marker cleared c-5 is not current again: $out" ;; esac
log "marker cleared: release/c-5 is current again (c-5 -> main accepted, c-4 -> main refused)"
printf 'release/c-9\n' > "$H/config/frozen-release"
mkmeta rel-e
out=$(env_run JG_TEST_GH_BASE=main JG_TEST_GH_HEAD_REF=release/c-9 "$REPO/bin/jg-pr-check.sh" rel-e https://github.com/example/repo/pull/55 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "a marker naming a branch the project lacks was trusted"
log "marker names an unknown branch: falls back to the highest-numbered rule"
rm -f "$H/config/frozen-release"

cat > "$OUT/steps.json" <<'JSON'
{"target":{"version":"jg-brief.sh, jg-spawn.sh, jg-pr-check.sh"},"start":"a fixture project with release/c-4 frozen in config/version-branch-frozen and release/c-5 current","steps":["scaffold and spawn onto release/c-4: refused with one line naming it and release/c-5, no record or window","scaffold and spawn onto release/c-5: reaches the window step","scaffold and spawn onto release/c-4 with --red-fix-of release/c-4: reaches the window step; without it, refused","arm a pull request based on release/c-4: refused; on release/c-5 or with red_fix_of: not refused","with config/frozen-release set to release/c-4 and release/c-5 present: c-4 to main accepted, a feature pull request to main refused; marker cleared: c-5 current again; unknown marker ignored"],"result":"a frozen release branch is refused at the brief, the spawn and the pull request check unless the work is declared a fix to its own red checks"}
JSON
log "PASS: a frozen release branch is refused at brief, spawn and pull request unless declared a red-fix"
