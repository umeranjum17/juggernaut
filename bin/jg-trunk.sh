#!/usr/bin/env bash
# The local trunk flow: one proved commit per ticket lands on a local trunk branch and is
# live at once, and the accumulated trunk goes out in one batch release.
#
# Usage: jg-trunk.sh init <project-dir> [<base-ref>]   create the trunk (default: the newest release/c-N, else HEAD)
#        jg-trunk.sh proof <task-id>                   print the proof inputs the task's head still lacks (receipt, merge-card evidence, sealed run); exit 1 when any
#        jg-trunk.sh land <task-id>                    land the task's one proved commit on the trunk; never goes live
#        jg-trunk.sh classify <output-file> [<gate-log>...]   print wait, retry or final for a refused landing's output
#        jg-trunk.sh land-batch <id>[@<head>]...       land 2 to batch-max queued lanes as one stack: one gate over their changed files, one move; a red stack is halved to find and return only the lane that caused it
#        jg-trunk.sh flush <project-dir>               Overwatch only: land every ready lane of the project now, in batches, whatever the threshold says
#        jg-trunk.sh land-next <task-id>               Overwatch only: mark one ready lane so the landing check lands it at once, ahead of the queue
#        jg-trunk.sh verify <project-dir> [<sha>]      on demand only: run the whole suite at a landed commit (default: the tip), one verify at a time and the newest wins; a red it finds reverts the commit that caused it
#        jg-trunk.sh green-alarm <project-dir>         raise one alarm to Overwatch once the trunk has had no green commit for no-green-alarm-minutes (15)
#        jg-trunk.sh word live|release <project-dir> "<his words>"   record the captain's word for the commit that would go live or out (both: the last green commit, never the tip)
#        jg-trunk.sh recover <project-dir> [--prepare <task-id>|--land <task-id>]   report divergence, prepare a merge, or land its exact proved head
#        jg-trunk.sh adopt-tip <project-dir> --reason <text> [--carried-by <task-id>]   Overwatch only: record the trunk's present tip as the lander's own after something else moved it; only if the record is its ancestor or the tip is on origin/<default>
#        jg-trunk.sh live <project-dir> [--home <lead-home>]   move every home to the last fully green commit; refuses without his word (or a waiver); --home moves one lead only
#        jg-trunk.sh autolive <project-dir>            the batched live step: under a waiver, move every home to the green pin once the trunk is quiet or the hourly cap is due
#        jg-trunk.sh waiver <project-dir> --rule <owner-rule-id>   Overwatch only: the captain waived his word for this project's live until the stable point
#        jg-trunk.sh waiver <project-dir> --rule <owner-rule-id> --release   Overwatch only: the captain's standing word lets this project's green release pull request merge by itself
#        jg-trunk.sh ci <project-dir> <sha> green|red  record the CI result for a live commit; red moves the green pin, and every home, back to the last green one
#        jg-trunk.sh release <project-dir>             push the last green commit of the trunk and open the ONE release PR trunk -> default branch, owned by task release-<project>-<trunk>; refuses without his word
#        jg-trunk.sh rollover <project-dir>            after the release PR merged, cut the next trunk version (trunk-v2, ...) from the default branch
#        jg-trunk.sh retire <project-dir>              clean up an old trunk unforced: only when its release is proved on main and every hotfix is carried; unlanded work is kept and listed
#        jg-trunk.sh due <project-dir>                 exit 0 when the oldest unreleased commit is past release-after-hours
#
# The flow is the same for every project IN local-trunk MODE (data/projects.md `[local-trunk]`); every subcommand
# refuses any other project, whose own delivery rules are unchanged: a lane's one commit lands on the local trunk by itself once the
# lane reports done (core/trunk-landing is the registered check that calls `land`), the trunk
# goes live only on the captain's word, and the only pull request is the release one. There is no feature
# pull request and no release branch.
#
# A landing is ONE fast check and needs no worker turn and no Overwatch turn. `land` rebases the lane's one commit onto the
# trunk tip by itself (a clean three-way merge; the lane branch follows it), runs the lint over the changed files (gate-lint),
# runs the changed files' tests (gate-full: the fast required set, docs/fast-merge-path.md) judged against the trunk tip's own
# result (skipped when the lane's passing sealed done-done run is for the very tree it would test: gate=sealed-run), and lands.
# A landed commit is green at once: its gate is the trunk's green (the green pin), and the whole suite runs once, on the release
# pull request in GitHub CI, never on this machine per landing. Only a conflict in the lane's
# own change stops it, and the refusal names the paths. The captain hold, the design, demo and nav gates, the ticket reference,
# the linked-decision block and owner-guard still apply; a red trunk never stops a landing. A landing starts only on a head whose whole proof is there
# (jg_dod_trunk_proof_gaps in bin/jg-merge-gate-lib.sh, the same check the worker's done runs): a PASS completion receipt, approved
# merge-card evidence citing files, and a sealed done-done run holding them, all at the lane's own head. A missing input refuses
# before anything starts and is named; `proof <task-id>` prints them. The owner signature never refuses a landing: it is
# recorded after it (data/trunk-landing-proofs.tsv), absent when missing. That row names the account the proof was saved under and the lander's own (proof-account, lander-account; the lander clears CLAUDE_CONFIG_DIR before it reads a proof) and also keeps the gate's figures (gate=ran:<scripts>,
# failed:<on the first run>,secs:<whole gate>; absent when no gate ran), which the landing's Evidence card (core/landing-card) prints.
#
# The changed-files gate charges a lane only for what it broke. When it fails, the lander first reruns the failing scripts once on
# the lane, and a script that passes on the rerun is flaky and not charged: each such script is recorded
# (data/trunk/flaky-<project>.tsv) and filed once as its own [blocker] fix row, never a landing stop. A script that fails on the lane
# and passed the tip's first run is run twice more on the tip; one that fails in either run fails by itself there and is flaky too. It then reruns exactly the failing test
# scripts on the trunk tip's own tree in a clean clone, in the environment the gate ended with (policy gate-rerun),
# and compares each one's exit status and failing test names. A script that fails the same way on the tip is the tip's
# red: it does not block the lane, and it is reported once per script and tip tree (one wake, one note on the
# gate-red-ticket ticket). A script that fails only on the candidate, passes on the tip, or fails differently blocks
# the lane, and so does any failure no test script accounts for. The tip's result is kept by tree
# (data/trunk/tip-results-<project>-<tree>.tsv), so it is computed once. A landing that set a red or a flaky failure
# aside is recorded as full-tip-red or full-rerun. A gate shard that ran past its wall-clock budget is never a red: it runs
# every script, and each JG_TEST_OVERRUN line it printed becomes one row of the machine-load ledger
# (data/trunk/load-<project>.tsv: epoch, commit, shard, milliseconds, budget, host load, cpus) and one warning line.
#
# The merge queue: when 2 or more lanes are queued, the landing check calls `land-batch` for up to batch-max (5) of them, oldest done first.
# Each lane is admitted onto the top of the stack (rebased by the lander; a lane that conflicts drops out and is returned with its paths,
# as a single landing would refuse it). ONE gate (lint, then the tests of the union of the changed files, judged against the tip) runs on
# the stack's top and, on green, the trunk fast-forwards over the whole stack in one move. On red the stack is halved (the first half is
# judged alone and lands if green, the rest is judged on the new tip) until the guilty lane stands alone; only it is returned. A single
# queued lane keeps the path above. Every landed lane keeps its own data/trunk-landings.tsv row (with batch-from=<tip before the batch>).
# The prior art is bors-ng's batch and bisect and Kubernetes Tide's batch merge (both Apache-2.0): ideas only, nothing copied.
#
# A landing holds the trunk lock only to read the tip and to move it, never across its gates: it gates the candidate on the tip it read,
# and the trunk moves only if it is still there (else the lane is rebased onto the new tip and gated again). `verify` (run on demand,
# never per landing) never waits for a landing: it reads the tip as a ref and takes that lock only for its short pin write; it registers in a one-slot queue
# (state/trunk-verify-want-<project>) where the newest commit wins, so a verify for an older commit gives up at once and the newest runs.
# The queue's threshold: the landing check does not land ready lanes one by one. It holds them until flush-at-ready (default 3) are ready or the
# oldest has waited flush-after-minutes (default 20), then lands all of them (batch-max at a time, the rest at once after). `flush` skips the wait
# for one project: it records state/trunk-flush-<project>, which the check honours until the project has no ready lane left. `land-next` records
# state/<task>.land-next: that lane goes first and lands at once, with the others only when the threshold is also met. A worker never records either.
#
# `verify <project> <commit>` runs the whole suite (gate-verify) at a landed commit when someone asks for it; nothing starts it per
# landing. A script that fails there and passes on the commit's parent charges that one commit, which is reverted by itself (a new
# commit on the tip, never a rewind), takes the green pin back below it, and the lane's ticket is told. A run that fails with no
# failed test charged to a commit (a run over its time budget, a shard with no result, a runner that stopped) is a warning and runs
# once more; it never moves the pin and never reverts. Nothing a verify finds stops a landing: a charged red that stays (a revert
# that does not apply cleanly) takes the green pin, and with it live, back below that commit. `green-alarm`
# (run by the landing check every minute) raises ONE alarm to Overwatch on the trunk's wake path (jg_wake_append check, a
# `-stall` key that wakes at once) once the oldest commit above the green pin has waited no-green-alarm-minutes (default 15);
# one per green pin, so a stall that goes on is not raised twice.
#
# The ship branch (state/<id>.meta branch=, default fm/<id>) must hold EXACTLY ONE commit on
# top of the trunk tip or on a base it can be rebased from. A second commit refuses; a conflict names the conflicting paths.
# The lane fixes it, reports ready again and the check lands the new head; a conflicting change is never landed dirty.
# `land` runs the lander's own gates at the candidate's exact tree in a clean clone, then moves the trunk with a
# compare-and-swap `update-ref`, so a racing lander or a lane
# that moved the ref is refused rather than overwritten. The trunk tip is recorded in
# state/trunk-tip-<project>; a tip that differs from that record was moved by someone other than
# this script (a lane can `git branch -f`), and every subcommand refuses until it is explained.
# `adopt-tip` is that explanation, run by Overwatch (a worker is refused), under the trunk lock, without tip_ok. Equal record and tip:
# "nothing to adopt", nothing written. Two relations are allowed: `forward` (the record is an ancestor of the tip) and `on-default`
# (the tip is contained in origin/<default>, after a fetch of that one ref; a failed fetch refuses); any other is refused. The landed
# commits the tip lacks (git rev-list, less those git cherry marks carried) are listed and refused unless --carried-by <task-id> names
# a lane that is one commit on the tip whose tree equals `git merge-tree --write-tree <record> <tip>`. It writes, in order: the keep
# ref refs/jg/trunk-adopted/<trunk>/<epoch> at the old record; state/trunk-tip-<project>; the green pin (moved to the tip only for
# on-default when the old pin is not its ancestor); a red pin whose commit is not on the tip is removed; one row in
# data/trunk-adoptions.tsv (project, old record, new tip, epoch, relation, lost count, carried-by, reason[, red-removed=<sha>]).
# The released commit must be an ancestor of the tip. It takes no force or skip flag and never moves the trunk ref (the hook holds).
# A refusal for a moved trunk is class `wait`, and tip_ok raises one wake keyed by record and branch with the exact adopt-tip line.
# Only the lander moves the trunk. A worker never lands. A git reference-transaction hook that every
# subcommand installs in the project refuses any other write to the trunk branch, so `git branch -f trunk`
# or `git update-ref` by hand is stopped where it happens; the record check above stays as the second lock.
#
# The trunk stays SAFE until its release PR lands: nothing forces, rewrites or deletes it (the hook above refuses
# all three, even from this script), and a pin-back moves the home only to a green commit, never the trunk.
# When the release PR has merged, `rollover` (also run by `release`, and by the landing check) cuts the NEXT trunk
# version from the default branch, moves the project onto it and records it (state/trunk-branch-<project>,
# state/trunk-version-<project>, data/trunk-versions.tsv). The commits landed on the old trunk after its release are replayed onto the
# new one first, each with the tree of its original (else one line, nothing changed); the green pin follows its replayed commit.
# The old trunk is left exactly as it was.
# Pin-back: state/trunk-green-<project> is the newest commit whose gate passed: a landing moves it unless an unreverted red recorded
# in data/trunk-ci.tsv (a red CI, or a charged verify red that could not be reverted) lies below the landing, and a red found later
# takes it back below that commit. `live` moves the home only to that commit, so a red commit is never live.
# `release` ships only the green pin, never the tip. A red `ci` moves the green pin, and every home, back to the
# newest earlier commit that went live and was not red (else the last release); landings go on.
# The captain's word: `word` writes state/trunk-word-<live|release>-<project>, bound to the one commit
# it names and spent by the command it allows. A worker never records one.
#
# Live moves EVERY home: it exports the tip's own bin/ and core/ to state/trunk-live-tool/<sha>/ and runs that copy's
# bin/jg-update.sh --base <sha> (see its header for the rows and skips), so the first move is done by the new code even
# while the homes still run the old one. A project whose tip has no bin/jg-update.sh is moved by this script's own copy.
# The waiver (config/trunk-live-waiver, one line per project: `<project> <owner-rule-id> <epoch> until=stable`, written
# only by `waiver`) stands in for the word on every commit of that project: live then spends no word and its row says
# waiver=<rule>. Deleting the project's line restores the need for his word; docs/trunk-flow.md owns the condition.
#
# autolive is the live step the landing check (core/trunk-landing) runs on every tick for a project with a go-live waiver, with
# no model turn (none: nothing happens and the word rule stands). It never waits on or blocks a landing. It moves every home to
# the green pin once no landing has happened for `live-quiet-minutes` (default 20) or the oldest landing that is not live yet
# is `live-cap-minutes` (default 60) old, whichever comes first (bin/jg-trunk-policy-lib.sh). It moves only to the green pin, so a
# commit whose suite was red is never live (verify reverts it, or the pin stays below it). A commit already live is not moved
# again. A red CI (`ci red`) pins EVERY home back to the last green commit at once.
#
# Exit 3 means the home did not move (the live hook failed); a landed commit stays landed. A fleet move writes the project's `live` row only
# when EVERY home is at the commit; otherwise the row is `hook-failed:fleet: not every home is at <sha>: <the homes>`.
#
# Every open captain call is a key in bin/jg-trunk-policy-lib.sh with its safe default; nothing
# here changes with the answer. Records: data/trunk-landings.tsv (task, project, commit, epoch,
# gate), data/trunk-live.tsv (project, commit, epoch, status), data/trunk-releases.tsv, data/trunk-ci.tsv (project,
# commit, epoch, green|red, and `verify` for a charged verify red that could not be reverted), data/trunk-words.tsv.
# `live` runs config/live-hook.<project> <project-dir> <sha> when it is executable. With none, a
# project that shares this home's code origin is moved by bin/jg-trunk-live-home.sh; any other
# project is recorded as landed but not live.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
# The lander proves nothing, so the account it runs under never reaches a proof: merge-card's compare of the caller's account with
# the account a proof was saved under belongs to the worker's own done. The landing row names the lander's account (record_proofs).
LANDER_ACCOUNT="${CLAUDE_CONFIG_DIR:-}"; unset CLAUDE_CONFIG_DIR
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# shellcheck source=bin/jg-dod-lib.sh
. "$SCRIPT_DIR/jg-dod-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-lease-lib.sh
. "$SCRIPT_DIR/jg-lease-lib.sh"
# shellcheck source=bin/jg-version-branch-lib.sh
. "$SCRIPT_DIR/jg-version-branch-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
# shellcheck source=core/trunk-landing/refusal-reach.sh
. "$SCRIPT_DIR/../core/trunk-landing/refusal-reach.sh"
export JG_HOME JG_CONFIG_OVERRIDE="$CONFIG"

usage() { sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '$d'; }
die() { echo "error: $*" >&2; exit 1; }
refuse() { echo "REFUSED: $*" >&2; exit 1; }
pol() { jg_trunk_policy "$1" "${PN:-}"; }
put() { printf '%s\n' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"; }
row() { mkdir -p "$DATA"; local f=$1; shift; printf '%s\n' "$(IFS=$'\t'; echo "$*")" >> "$DATA/$f"; }
rev() { git -C "$PROJ" rev-parse --verify --quiet "$1^{commit}"; }

LOCKS=''; VERIFY_WANT=''
cleanup() {
  local l q
  # A verify that leaves clears its own place in the queue, so a verify that died leaves nothing to wait for.
  if [ -n "${VERIFY_WANT:-}" ]; then
    q="$STATE/.trunk-verify-queue-$PN.lock"
    if jg_lock_acquire_wait_max "$q" 5; then
      [ "$(cat "$STATE/trunk-verify-want-$PN" 2>/dev/null || true)" != "$VERIFY_WANT" ] || rm -f -- "$STATE/trunk-verify-want-$PN"
      jg_lock_release "$q" || true
    fi
  fi
  for l in $LOCKS; do jg_lock_release "$l" || true; done; [ -z "${WORK:-}" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT
lock() { jg_lock_acquire_wait "$1"; LOCKS="$1 $LOCKS"; }

open_project() {  # <project-dir>: sets PROJ PN TRUNK
  local mode
  PROJ=${1:?project directory required}
  git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || die "$PROJ is not a git repository"
  PN=$(basename "$PROJ")
  TRUNK=$(jg_trunk_branch "$PN" "$STATE")
  git check-ref-format --branch "$TRUNK" >/dev/null 2>&1 || die "invalid trunk-branch '$TRUNK'"
  # The trunk flow is for local-trunk projects ONLY: a no-mistakes, direct-PR or local-only project keeps its own rules.
  mode=$(JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-project-mode.sh" --raw "$PN" 2>/dev/null | cut -d' ' -f1 || true)
  [ "$mode" = local-trunk ] || refuse "$PN is registered ${mode:-as nothing} in data/projects.md, not local-trunk; the trunk flow applies to local-trunk projects only and this project's own delivery rules are unchanged"
  [ "${2:-}" = read-only ] || ensure_guard
  [ "$(pol trunk-owner)" = this-home ] || refuse "trunk-owner=$(pol trunk-owner) is not built; only this-home is, and the owner is an open captain call"
}

# The trunk is safe: only this script writes it (JG_TRUNK_WRITER=1 on its own update-ref calls), and even
# this script can only create it or fast-forward it. A rewind, a force or a delete of refs/heads/<trunk> or
# a later trunk version (<trunk>-v2, ...) is refused by the project's reference-transaction hook, so no
# subcommand and no hand can lose a trunk whose release is still open. A transaction that leaves the ref where it
# is (git 2.56 opens one when a worktree is added on the branch) moves nothing and passes. The one delete it allows is `retire`'s
# (JG_TRUNK_RETIRE=<ref>), which runs only after the old trunk's release merged and its work is carried.
ensure_guard() {
  local hook want base effective delegate
  base=$(pol trunk-branch)
  hook="$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir)/hooks/reference-transaction"
  # shellcheck disable=SC2016 # the hook body is written out verbatim; its variables expand in the hook
  want=$(printf '#!/bin/sh\n# managed by bin/jg-trunk.sh: only the lander moves the trunk, and only forward\n[ "$1" = prepared ] || exit 0\nwhile read -r old new ref; do\n  case "$ref" in refs/heads/%s|refs/heads/%s-v[0-9]*) ;; *) continue ;; esac\n  cur=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)\n  [ -z "$cur" ] || [ "$cur" != "$new" ] || continue\n  case "$new" in *[!0]*) ;; *) [ "${JG_TRUNK_RETIRE:-}" = "$ref" ] && continue; echo "refused: $ref is a trunk and is never deleted" >&2; exit 1 ;; esac\n  [ -n "${JG_TRUNK_WRITER:-}" ] || { echo "refused: $ref moves only through bin/jg-trunk.sh land; nothing writes it by hand (transaction: $old -> $new, now ${cur:-none})" >&2; exit 1; }\n  [ -z "$cur" ] || git merge-base --is-ancestor "$cur" "$new" || { echo "refused: $ref is never rewound or forced; the trunk only moves forward" >&2; exit 1; }\ndone\nexit 0\n' "$base" "$base")
  # A home guard (bin/jg-home-guard.sh) holding the hook file runs this guard first from its chained slot, so it lives there.
  if [ -f "$hook" ] && grep -q '^# managed by bin/jg-home-guard.sh' "$hook"; then
    install_trunk_hook "$hook.chained" "$want"
  else
    install_trunk_hook "$hook" "$want"
  fi
  effective=$(git -C "$PROJ" rev-parse --path-format=absolute --git-path hooks/reference-transaction) || die "cannot resolve the effective reference-transaction hook"
  if [ -f "$effective" ] && grep -q '^# managed by bin/jg-git-strip-ai-trailers.sh$' "$effective"; then
    effective=$("$SCRIPT_DIR/jg-git-strip-ai-trailers.sh" upstream-hooks "$(dirname "$effective")" "$PROJ")/reference-transaction || die "cannot resolve the repository hook beneath the launch overlay"
  fi
  [ "$effective" != "$hook" ] || return 0
  # The managed owner-guard wrapper already chains the repository's common
  # hook. Preserve that installer's file instead of trying to replace it.
  if [ -x "$effective" ] && grep -q '^# jg-owner-guard global hook template ' "$effective"; then return 0; fi
  # A configured shared directory delegates to each repository's own guard, never
  # captures one project's branch policy or replaces an unrecognized user hook.
  # shellcheck disable=SC2016 # The delegate resolves the repository when Git invokes it.
  delegate='#!/bin/sh
# managed by bin/jg-trunk.sh: delegate to the repository trunk guard
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1
hook=$common/hooks/reference-transaction
[ ! -x "$hook" ] || exec "$hook" "$@"
exit 0'
  install_trunk_hook "$effective" "$delegate"

}

install_trunk_hook() {  # <path> <body>: install atomically; never replace another owner's hook.
  local hook=$1 want=$2 tmp
  if [ -e "$hook" ]; then
    [ "$(cat "$hook")" != "$want" ] || return 0
    grep -q '^# managed by bin/jg-trunk.sh:' "$hook" || die "$hook is not the trunk guard; preserve it and compose its owner before using this hook directory"
  fi
  mkdir -p "$(dirname "$hook")" || die "cannot create the active hook directory"
  tmp=$(mktemp "$(dirname "$hook")/.trunk-hook.XXXXXX") || die "cannot install $hook; refresh a read-only launch overlay through its installer"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod +x "$tmp" || ! mv -f "$tmp" "$hook"; then
    rm -f "$tmp"; die "cannot install trunk protection at $hook"
  fi
}

# The trunk must be where the lander last left it.
tip_ok() {
  local want have
  want=$(cat "$STATE/trunk-tip-$PN" 2>/dev/null) || refuse "no trunk for $PN; run: jg-trunk.sh init $PROJ"
  have=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  [ "$want" = "$have" ] || {
    adopt_facts "$want" "$have"
    [ ! -e "$STATE/trunk-moved-wake-$PN-${want:0:12}-${have:0:12}" ] && : > "$STATE/trunk-moved-wake-$PN-${want:0:12}-${have:0:12}" && \
    jg_wake_append check "trunk-moved-$PN-${want:0:12}-${have:0:12}" "$TRUNK in $PN is at ${have:0:12} but the lander left it at ${want:0:12} (relation to the record: $ADOPT_REL, unverified until adopt-tip fetches origin; $ADOPT_LOST_N landed commit(s) off the tip). If the move is known, run: $SCRIPT_DIR/jg-trunk.sh adopt-tip $PROJ --reason \"<what moved it>\"$([ "$ADOPT_LOST_N" -eq 0 ] || printf ' --carried-by <task-id>')" >/dev/null 2>&1 || :
    refuse "$TRUNK is at ${have:0:12} but the lander last left it at ${want:0:12}; something else moved it, so nothing lands or releases until that is explained"
  }
}

# Reconcile only a proven fast-forward while the caller holds the trunk lock.
# Rewinds and divergent moves retain the ordinary alarm and manual recovery path.
tip_adopt_forward() {
  local want have released epoch keep
  want=$(cat "$STATE/trunk-tip-$PN" 2>/dev/null) || return 0
  have=$(rev "refs/heads/$TRUNK") || return 0
  [ "$want" != "$have" ] || return 0
  git -C "$PROJ" merge-base --is-ancestor "$want" "$have" 2>/dev/null || return 0
  released=$(cat "$STATE/trunk-released-$PN" 2>/dev/null || true)
  [ -z "$released" ] || git -C "$PROJ" merge-base --is-ancestor "$released" "$have" 2>/dev/null || return 0
  epoch=$(date +%s); keep="refs/jg/trunk-adopted/$TRUNK/$epoch-${want:0:12}"
  git -C "$PROJ" update-ref "$keep" "$want" || die "cannot write the keep ref $keep"
  row trunk-adoptions.tsv "$PN" "$want" "$have" "$epoch" forward 0 - 'automatic fast-forward during landing'
  put "$STATE/trunk-tip-$PN" "$have"
}

# The only variables a gate takes from whoever starts it. A gate gives one result from every caller (a worker session,
# the lead, the watcher, a bare shell), so its clone and its command start from an empty environment plus these names:
# a session's git hook settings, task id or account never reach the tests. JG_HOME is the home this script resolved.
# A gate that needs another variable goes red on its first run, and the miss is added here by name.
GATE_ENV='HOME PATH USER LOGNAME SHELL LANG LC_ALL TMPDIR JG_HOME'

# A gate marks itself while it runs (state/.trunk-gate-<project>-<pid>.lock) and never starts while a move of the homes is pending
# (state/.trunk-move-<project>.lock): the move (go_live, begin_move) waits for every marked gate to end, and a gate that would start
# waits for the move, so a move never kills a running gate and no gate runs twice because a home moved. The gate takes its mark
# first and then looks for the move; the move takes its place first and then looks for marks, so one of them always sees the other.
gate_enter() {
  local mark="$STATE/.trunk-gate-$PN-${BASHPID:-$$}.lock" move="$STATE/.trunk-move-$PN.lock"
  while :; do
    jg_lock_try_acquire "$mark" || die "cannot mark the gate as running"
    LOCKS="$mark $LOCKS"
    if jg_lock_try_acquire "$move"; then jg_lock_release "$move"; return 0; fi
    unlock "$mark"; sleep 0.2  # the homes are moving: the gate starts after the move
  done
}
gate_leave() { unlock "$STATE/.trunk-gate-$PN-${BASHPID:-$$}.lock"; }

# Run a command at a commit's exact tree in a clean clone, logging to <log>; returns the command's exit status.
# <envfile>, when given, receives the environment the command ended with (NUL separated), so a rerun can use the same one.
gate_exec() {  # <commit> <command> <log> [<envfile>]
  local rc=0 cmd=$2 name
  gate_enter
  local -a clean=(env -i)
  for name in $GATE_ENV; do [ -z "${!name+set}" ] || clean+=("$name=${!name}"); done
  mkdir -p "$DATA/trunk"
  WORK=$(mktemp -d)
  "${clean[@]}" git clone -q --shared --no-checkout "$PROJ" "$WORK/tree" || die "cannot clone $PROJ for the gate"
  "${clean[@]}" git -C "$WORK/tree" checkout -q --detach "$1" || die "cannot check out ${1:0:12} for the gate"
  # shellcheck disable=SC2016 # the trap body expands in the gate's shell
  [ -z "${4:-}" ] || cmd="trap 'env -0 > \"\$JG_GATE_ENV_OUT\"' EXIT; $2"
  (cd "$WORK/tree" && "${clean[@]}" JG_GATE_ENV_OUT="${4:-/dev/null}" JG_TRUNK_GATE_OUTPUT="${3%.log}.proof" bash -c "$cmd") > "$3" 2>&1 || rc=$?
  rm -rf -- "$WORK"; WORK=
  gate_leave
  record_overruns "$1" "$3"
  return "$rc"
}

# A gate shard past its wall-clock budget was slowed by the machine, so it is a warning and a row of the machine-load ledger
# (data/trunk/load-<project>.tsv: epoch, commit, shard, milliseconds, budget, host load, cpus), one per JG_TEST_OVERRUN line in <log>;
# whether the gate is red is left to its failed scripts alone.
record_overruns() {  # <commit> <log>
  local rows
  rows=$(awk -v t="$(date +%s)" -v c="$1" '
    /^JG_TEST_OVERRUN / {
      delete f; for (i = 2; i <= NF; i++) { k = $i; sub(/=.*/, "", k); v = $i; sub(/^[^=]*=/, "", v); f[k] = v }
      sh = ";" f["selection"]; if (match(sh, /;shard=[^;]*/)) sh = substr(sh, RSTART + 7, RLENGTH - 7); else sh = "-"
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t, c, sh, f["duration_ms"], f["budget_ms"], f["load"], f["cpus"]
    }' "$2" 2>/dev/null) || rows=
  [ -n "$rows" ] || return 0
  mkdir -p "$DATA/trunk"; printf '%s\n' "$rows" >> "$DATA/trunk/load-$PN.tsv"
  printf '%s\n' "$rows" | awk -F'\t' -v c="${1:0:12}" -v p="$PN" '
    { s = s (s == "" ? "" : ", ") $3 " " $4 "ms of " $5 "ms at host load " $6 " on " $7 " cpus" }
    END { print "warning: at " c " " NR " gate shard(s) ran past the wall-clock budget, a warning and never a red (data/trunk/load-" p ".tsv): " s }' >&2
}

# Run a gate command at a commit's exact tree in a clean clone; the log is kept under data/.
run_gate() {  # <commit> <command> <label>
  local log="${LAND_ATTEMPT:-$DATA/trunk/gate-$PN-${1:0:12}-$(date +%s)-$$}-$3.log" rc=0
  gate_exec "$1" "$2" "$log" || rc=$?
  [ "$rc" -eq 0 ] || { tail -n 20 "$log" >&2; refuse "gate '$3' failed (exit $rc) at ${1:0:12}; full log: $log"; }
}

# What a refused landing means, read from its output (and any gate logs after it): `wait` (only time clears it), `retry` (the machine failed it, not the lane: a full
# or quota-limited temp directory, a failed checkout, a gate shard whose result is missing, a slow backlog read) or `final` (a change is
# needed: a conflict, a lint or test red charged to the lane). The last refusal line decides; a gate or read refusal is a `retry` only when
# the output also shows the machine failure. The landing check (core/trunk-landing/trunk-landing.sh) reads this verdict from the
# `refusal-class` line, and owns the retry count and backoff: this function is the only list of either phrase set.
classify_refusal() {  # <output file> [<gate log>...]
  local last
  last=$(grep -E '^(REFUSED|error):' "$1" | tail -n 1)
  if grep -q '^ENV:' "$@" 2>/dev/null; then echo env-wait; return; fi
  case $last in
    *'away mode'*|*'something else moved it'*|*'linked to a decision'*|*'still held'*|*'changed while landing'*|*'kept moving'*|*'proof inputs are incomplete'*) echo wait; return ;;
    "REFUSED: gate "*|"REFUSED: could not read the decisions"*|"REFUSED: this lane is the red"*|"error: cannot check out"*) ;;
    *) echo final; return ;;
  esac
  # Single-quoted, so the slow-read phrase stays the exact text tests/jg-backlog-row-show.test.sh pins in this file.
  if grep -qE 'Disk quota exceeded$|No space left on device$|^jg-test-run: aggregate input not found: |^error: cannot check out |backlog read bound( after [0-9]+ attempts \([0-9s, ]+\))?$|^REFUSED: could not read the decisions' "$@" 2>/dev/null
  then echo retry; else echo final; fi
}

# Every script the test runner finished in a gate log, as: script TAB exit status TAB failure signature.
# The signature of a pass is "-". Of a failure it is the script's own "not ok" lines (else its last three lines),
# sorted, with temp paths, long numbers and elapsed seconds masked so a pid, a mktemp name or a run time cannot make one red look like two.
gate_results() {  # <log>
  awk '
    function norm(s) { gsub(/\/(tmp|var\/folders)\/[^ \t:]*/, "PATH", s); gsub(/[0-9][0-9][0-9][0-9]+/, "N", s); gsub(/[0-9]+\.[0-9]+s/, "Ns", s); return s }
    /^JG_TEST_BEGIN / { cur = $3; nf = 0; nt = 0; split("", f); split("", t); next }
    /^JG_TEST_END / {
      ex = $0; sub(/.* exit=/, "", ex); sub(/ .*/, "", ex); sig = "-"
      if (ex != "0") {
        sig = ""
        if (nf > 0) {
          for (i = 2; i <= nf; i++) { v = f[i]; for (j = i - 1; j >= 1 && f[j] > v; j--) f[j + 1] = f[j]; f[j + 1] = v }
          for (i = 1; i <= nf; i++) if (i == 1 || f[i] != f[i - 1]) sig = sig (sig == "" ? "" : " | ") f[i]
        } else {
          for (i = (nt > 3 ? nt - 2 : 1); i <= nt; i++) sig = sig (sig == "" ? "" : " | ") t[i]
        }
      }
      print $3 "\t" ex "\t" sig; cur = ""; next
    }
    cur != "" && $0 !~ /^[ \t]*$/ { l = norm($0); t[++nt] = l; if ($0 ~ /^not ok/) f[++nf] = l }
  ' "$1"
}

# The failures a full gate left behind that no test script accounts for: a gate that failed for another reason
# (a check before the runner, a runner that died) is never forgiven. Prints nothing when every failure is a script's.
gate_unexplained() {  # <log> <results>
  local counted claimed
  claimed=$(printf '%s\n' "$2" | awk -F'\t' '$2 != "0"' | grep -c . || true)
  counted=$(sed -n 's/^JG_TEST_SUMMARY .* failed=\([0-9][0-9]*\) .*/\1/p' "$1" | awk '{ n += $1 } END { print n + 0 }')
  [ "$claimed" -gt 0 ] && [ "$claimed" = "$counted" ] || echo "the runner reported $counted failed scripts and $claimed finished red"
}

# Rerun test scripts (policy gate-rerun) at a commit's tree in a clean clone, in the environment a gate ended with
# (<envfile>, minus what only describes that one shell). <scripts> are already shell-quoted, each led by a space.
rerun_scripts() {  # <commit> <envfile> <log> <quoted scripts>
  # shellcheck disable=SC2016 # the loop expands in the rerun's shell
  gate_exec "$1" "$(printf 'while IFS= read -r -d "" kv; do case "$kv" in PWD=*|OLDPWD=*|SHLVL=*|_=*|JG_GATE_ENV_OUT=*) ;; *) export "$kv" ;; esac; done < %q; %s%s' "$2" "$(pol gate-rerun)" "$4")" "$3" || :
}

# What the trunk tip's own tree does with <scripts>, keyed by tree: computed once, reused by every lane.
# Prints script TAB exit TAB signature for each script the tip has a result for.
tip_results() {  # <tip> <envfile> <script>...
  local tip=$1 envf=$2 tree cache log s line need=''
  shift 2
  tree=$(git -C "$PROJ" rev-parse "$tip^{tree}")
  cache="$DATA/trunk/tip-results-$PN-$tree.tsv"
  touch "$cache"
  for s in "$@"; do
    git -C "$PROJ" cat-file -e "$tip:$s" 2>/dev/null || continue
    awk -F'\t' -v s="$s" '$1 == s { f = 1 } END { exit !f }' "$cache" || need="$need $(printf '%q' "$s")"
  done
  if [ -n "$need" ]; then
    log="$DATA/trunk/gate-$PN-${tip:0:12}-tip-$(date +%s).log"
    rerun_scripts "$tip" "$envf" "$log" "$need"
    while IFS= read -r line; do
      s=${line%%$'\t'*}
      case " $need " in *" $(printf '%q' "$s") "*) printf '%s\n' "$line" >> "$cache" ;; esac
    done < <(gate_results "$log")
  fi
  for s in "$@"; do awk -F'\t' -v s="$s" '$1 == s' "$cache" | head -n 1; done
}

# Which of <scripts> fail by themselves on <base>: each is run twice more there (its first run is the tip's result), and one that
# fails in either run is flaky. A lane is charged for a script only when its base passes it three times of three.
flaky_on_base() {  # <base> <envfile> <script>...
  local base=$1 envf=$2 quoted='' s n log
  shift 2
  for s in "$@"; do quoted="$quoted $(printf '%q' "$s")"; done
  for n in 1 2; do
    log="$DATA/trunk/gate-$PN-${base:0:12}-parent-$n-$(date +%s).log"
    rerun_scripts "$base" "$envf" "$log" "$quoted"
    gate_results "$log" | awk -F'\t' '$2 != "0" { print $1 }'
  done | sort -u
}

# One alert and one note per pre-existing red script and tip tree, however many lanes meet it.
report_tip_red() {  # <tip> <script>...
  local tip=$1 tree ledger fresh='' s ticket note
  shift
  tree=$(git -C "$PROJ" rev-parse "$tip^{tree}")
  ledger="$DATA/trunk/tip-red-reported-$PN.tsv"; touch "$ledger"
  for s in "$@"; do grep -qxF "$tree	$s" "$ledger" || fresh="$fresh $s"; done
  [ -n "$fresh" ] || return 0
  note="$TRUNK tip ${tip:0:12} is red in:$fresh. It was red before any lane touched it, so no lane is charged for it."
  jg_wake_append check "trunk-tip-red-$PN-${tree:0:12}" "$note" >/dev/null 2>&1 || echo "warning: could not raise the tip-red alert" >&2
  ticket=$(pol gate-red-ticket)
  if [ -n "$ticket" ]; then
    JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-backlog.sh" update "$ticket" --append-notes "$note" >/dev/null 2>&1 \
      || echo "warning: could not add the tip-red note to $ticket" >&2
  fi
  for s in $fresh; do printf '%s\t%s\n' "$tree" "$s" >> "$ledger"; done
}

# A script that failed and passed on its rerun is flaky: never a stop, but every occurrence is recorded and each script gets its own
# fix row, filed once (data/trunk/flaky-<project>.tsv: epoch, commit, script, the row it was filed as; "-" until a filing works).
record_flaky() {  # <commit> <script>...
  local sha=$1 ledger s id filed
  shift
  ledger="$DATA/trunk/flaky-$PN.tsv"; mkdir -p "$DATA/trunk"; touch "$ledger"
  for s in "$@"; do
    id=$(basename "$s"); id=${id%.sh}; id=${id%.test}
    id="flaky-$PN-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
    filed=$(awk -F'\t' -v s="$s" '$3 == s && $4 != "-" { f = $4 } END { print f }' "$ledger")
    if [ -z "$filed" ] && JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-backlog.sh" add "$id" \
      "[blocker] flaky test $s on $PN" --kind ship --priority 2 \
      --body "$s failed and then passed on its one rerun at ${sha:0:12}; the gate set it aside.
Why: a flaky test hides real reds and costs every gate a rerun.
Done when: $s passes every run, or its flaky case is removed." >/dev/null 2>&1; then filed=$id
    elif [ -z "$filed" ]; then echo "warning: could not file the flaky-test row $id" >&2; fi
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$sha" "$s" "${filed:--}" >> "$ledger"
  done
}

# GATE_FIGURES for the landing's proofs row (ran:<scripts>,failed:<first run>,secs:<whole gate>): the scripts the first run reported
# (its JG_TEST_SUMMARY lines; "-" when the gate prints none) and the seconds since <start epoch>. Landed commits read it back in record_proofs.
gate_figures() {  # <first-run log> <start epoch>
  local ran failed
  read -r ran failed <<< "$(sed -n 's/^JG_TEST_SUMMARY total=\([0-9][0-9]*\) failed=\([0-9][0-9]*\) .*/\1 \2/p' "$1" 2>/dev/null | awk '{ r += $1; f += $2; n++ } END { if (n) print r, f; else print "- -" }')"
  GATE_FIGURES="ran:${ran:--},failed:${failed:--},secs:$(( $(date +%s) - $2 ))"
}

# The lander's full gate. A red candidate is judged against the trunk tip's own result for the same scripts:
# a script that fails the same way on the tip is the tip's red, reported once and not charged to the lane;
# a script that fails only on the candidate, passes on the tip, or fails differently blocks it.
# Sets GATE_KIND to full, to full-rerun when every failure passed on its one rerun, or to full-tip-red when the tip's own reds were set aside.
# Returns 0 when the candidate is cleared, 2 when it is charged with a failure its base does not have, and 1 when it failed for a
# reason no test script accounts for. The base is the trunk tip for a landing and the commit's parent for a verify.
full_gate() {  # <candidate> <command> <base>
  local cand=$1 log="${LAND_ATTEMPT:-$DATA/trunk/gate-$PN-${1:0:12}}-full.log" envf rc=0 mine tipres line s ex sig tex tsig bad='' old='' unexplained quoted again settled now flaky='' t0 passing='' byself='' byparent=''
  t0=$(date +%s); GATE_KIND=full; GATE_FIGURES=; GATE_BAD=
  envf=$(mktemp "$DATA/trunk/.gate-env.XXXXXX" 2>/dev/null) || { mkdir -p "$DATA/trunk"; envf=$(mktemp "$DATA/trunk/.gate-env.XXXXXX"); }
  gate_exec "$cand" "$2" "$log" "$envf" || rc=$?
  [ "$rc" -ne 0 ] || { rm -f -- "$envf"; gate_figures "$log" "$t0"; return 0; }
  mine=$(gate_results "$log" | awk -F'\t' '$2 != "0"')
  unexplained=$(gate_unexplained "$log" "$mine")
  if [ -n "$unexplained" ] || [ ! -s "$envf" ]; then
    rm -f -- "$envf"; tail -n 20 "$log" >&2
    echo "REFUSED: gate 'full' failed (exit $rc) at ${cand:0:12}; full log: $log" >&2
    return 1
  fi
  # A flaky failure gets one rerun before it is judged: the scripts are rerun once on the candidate, and only
  # what fails again counts (as that second run saw it). A script the rerun does not report keeps its first result.
  quoted=$(printf '%s\n' "$mine" | while IFS= read -r line; do printf ' %q' "${line%%$'\t'*}"; done)
  rerun_scripts "$cand" "$envf" "$DATA/trunk/gate-$PN-${cand:0:12}-full-rerun.log" "$quoted"
  again=$(gate_results "$DATA/trunk/gate-$PN-${cand:0:12}-full-rerun.log")
  settled=''
  while IFS= read -r line; do
    s=${line%%$'\t'*}
    now=$(printf '%s\n' "$again" | awk -F'\t' -v s="$s" '$1 == s { print; exit }')
    if [ -z "$now" ]; then settled="$settled$line"$'\n'
    elif [ "$(printf '%s' "$now" | cut -f2)" != 0 ]; then settled="$settled$now"$'\n'
    else flaky="$flaky $s"; fi
  done <<< "$mine"
  mine=$(printf '%s' "$settled")
  # shellcheck disable=SC2086
  [ -z "$flaky" ] || { echo "note: passed on the rerun, so judged flaky and not charged (each recorded and filed as its own fix row):$flaky" >&2; record_flaky "$cand" $flaky; }
  if [ -z "$mine" ]; then rm -f -- "$envf"; GATE_KIND="full-rerun"; gate_figures "$log" "$t0"; return 0; fi
  # shellcheck disable=SC2046
  tipres=$(tip_results "$3" "$envf" $(printf '%s\n' "$mine" | cut -f1))
  while IFS= read -r line; do
    s=${line%%$'\t'*}
    [ "$(printf '%s\n' "$tipres" | awk -F'\t' -v s="$s" '$1 == s { print $2; exit }')" = 0 ] && passing="$passing $s"
  done <<< "$mine"
  # shellcheck disable=SC2086
  [ -z "$passing" ] || byself=$(flaky_on_base "$3" "$envf" $passing)
  rm -f -- "$envf"
  while IFS= read -r line; do
    s=${line%%$'\t'*}; ex=$(printf '%s' "$line" | cut -f2); sig=$(printf '%s' "$line" | cut -f3-)
    tex=$(printf '%s\n' "$tipres" | awk -F'\t' -v s="$s" '$1 == s { print $2; exit }')
    tsig=$(printf '%s\n' "$tipres" | awk -F'\t' -v s="$s" '$1 == s { sub(/^[^\t]*\t[^\t]*\t/, ""); print; exit }')
    if [ -n "$sig" ] && [ "$tex" = "$ex" ] && [ "$tsig" = "$sig" ]; then old="$old $s"
    elif printf '%s\n' "$byself" | grep -qxF -- "$s"; then byparent="$byparent $s"
    else bad="$bad $s"; fi
  done <<< "$mine"
  # shellcheck disable=SC2086
  [ -z "$byparent" ] || { echo "note: $byparent fails by itself on the parent ${3:0:12}, so no lane is charged for it (each recorded and filed as its own fix row)" >&2; record_flaky "$cand" $byparent; }
  # The tip's own red is a fact about the tip, so it is reported even when this lane is also refused.
  # shellcheck disable=SC2086
  [ -z "$old" ] || report_tip_red "$3" $old
  if [ -n "$bad" ]; then
    GATE_BAD=${bad# }
    tail -n 20 "$log" >&2
    echo "REFUSED: gate 'full' failed (exit $rc) at ${cand:0:12}; this lane introduced or changed the failure of:$bad; full log: $log" >&2
    return 2
  fi
  if [ -z "$old" ]; then GATE_KIND="full-rerun"; gate_figures "$log" "$t0"; return 0; fi
  echo "note: ${cand:0:12} fails only what the $TRUNK tip ${3:0:12} already fails the same way; set aside, not charged to this lane:$old" >&2
  GATE_KIND="full-tip-red"; gate_figures "$log" "$t0"
}

# The paths where <candidate> cannot merge cleanly onto <tip>; prints nothing when it merges clean.
conflict_paths() {  # <tip> <candidate>
  local out; out=$(git -C "$PROJ" merge-tree --write-tree --name-only --no-messages "$1" "$2" 2>/dev/null) && return 0
  printf '%s\n' "$out" | sed 1d | paste -sd' ' -
}

# The captain's recorded word: spent by the command it allows, valid for one commit only.
need_word() {  # <live|release> <sha>
  local f="$STATE/trunk-word-$1-$PN"
  [ -f "$f" ] && [ "$(cut -f1 "$f")" = "$2" ] || refuse "no recorded word from the captain to $1 ${2:0:12}; record it with: jg-trunk.sh word $1 $PROJ \"<his words>\""
}
spend_word() { rm -f -- "$STATE/trunk-word-$1-$PN"; }

touches_protected() {  # <commit-a> <commit-b>: prints the first protected path the diff touches
  local path glob globs
  read -r -a globs <<< "$(pol protected-paths)"
  while IFS= read -r path; do
    for glob in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case $path in $glob) printf '%s\n' "$path"; return 0 ;; esac
    done
  done < <(git -C "$PROJ" diff --name-only "$1" "$2")
  return 1
}

cmd_init() {
  local base=${2-} vb r
  open_project "${1-}"
  [ ! -e "$STATE/trunk-tip-$PN" ] || die "trunk for $PN already exists"
  if [ -z "$base" ]; then
    base=HEAD; vb=$(jg_current_version_branch "$PROJ" || true)
    for r in ${vb:+"origin/$vb" "$vb"}; do if rev "$r" >/dev/null; then base=$r; break; fi; done
  fi
  base=$(rev "$base") || die "base ref '$base' does not resolve in $PROJ"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: init" "refs/heads/$TRUNK" "$base" ""
  mkdir -p "$STATE"
  put "$STATE/trunk-tip-$PN" "$base"; put "$STATE/trunk-green-$PN" "$base"; put "$STATE/trunk-released-$PN" "$base"
  put "$STATE/trunk-branch-$PN" "$TRUNK"; put "$STATE/trunk-version-$PN" 1; row trunk-versions.tsv "$PN" 1 "$TRUNK" "$base" "$(date +%s)"
  echo "trunk $TRUNK created at ${base:0:12} in $PROJ"
}

# The lane's one commit on the latest tip, made by the lander itself: a three-way merge of the commit onto the tip, committed
# with the lane's own author, date and message. Prints the new commit; prints nothing when the merge conflicts.
rebase_commit() {  # <tip> <candidate>
  local tree ident=()
  tree=$(git -C "$PROJ" merge-tree --write-tree --merge-base="$2^" "$1" "$2" 2>/dev/null) || return 1
  [ -n "$(git -C "$PROJ" config user.name 2>/dev/null || true)" ] || ident=(-c user.name=jg-trunk -c user.email=jg-trunk@localhost)
  git -C "$PROJ" log -1 --format=%B "$2" | GIT_AUTHOR_NAME=$(git -C "$PROJ" log -1 --format=%an "$2") GIT_AUTHOR_EMAIL=$(git -C "$PROJ" log -1 --format=%ae "$2") \
    GIT_AUTHOR_DATE=$(git -C "$PROJ" log -1 --format=%aI "$2") git -C "$PROJ" "${ident[@]+"${ident[@]}"}" commit-tree "$tree" -p "$1"
}

# The lane follows its rebased commit, so cleanup finds the branch where the trunk is: in its own clean worktree by
# `reset --keep`, or by a compare-and-swap ref move when no worktree holds the branch. Dirty work is never touched.
lane_follow() {  # <branch> <old> <new> <worktree>
  if [ -d "${4:-}" ] && [ "$(git -C "$4" symbolic-ref -q HEAD 2>/dev/null)" = "refs/heads/$1" ]; then
    [ -n "$(git -C "$4" status --porcelain 2>/dev/null)" ] || git -C "$4" reset -q --keep "$3" 2>/dev/null || :
  elif ! git -C "$PROJ" worktree list --porcelain | grep -qx "branch refs/heads/$1"; then
    git -C "$PROJ" update-ref -m "trunk: follow the rebased lane" "refs/heads/$1" "$3" "$2" 2>/dev/null || :
  fi
}

# What the proof gate already required is recorded after the landing as a fact about the landed commit; the owner signature
# is the one input that never gates it, and is recorded as absent when missing.
record_proofs() {  # <id> <lane head> <landed commit>
  local r="$STATE/$1.run-receipt.json" d="$DATA/$1" receipt=absent sig=absent card=absent proof_account='' done_at
  # The lane's last done epoch, read while its status file still exists: cleanup removes the file, and core/trunk-latency needs the number.
  done_at=$(sed -n 's/^done.*\[at=\([0-9][0-9]*\)\].*/\1/p' "$STATE/$1.status" 2>/dev/null | tail -n 1)
  if [ -f "$r" ] && command -v jq >/dev/null 2>&1; then receipt="$(jq -r '.verdict // "unreadable"' "$r" 2>/dev/null || echo unreadable)@$(jq -r '.head // ""' "$r" 2>/dev/null | cut -c1-12)"; fi
  [ ! -e "$d/proof-authorizations/$2.sig" ] || sig=present
  { [ -f "$d/merge-card.json" ] && grep -q "$2" "$d/merge-card.json"; } && card=present
  [ "$card" = present ] && command -v jq >/dev/null 2>&1 &&
    proof_account=$(jq -r --arg h "$2" 'select(.head == $h) | .context.account // empty' "$d/merge-card.json" 2>/dev/null | tail -n 1)
  row trunk-landing-proofs.tsv "$1" "$PN" "$3" "$(date +%s)" "receipt=$receipt" "signature=$sig" "merge-card=$card" \
    "proof-account=${proof_account:-none}" "lander-account=${LANDER_ACCOUNT:-none}" "gate=${GATE_FIGURES:-absent}" "done=${done_at:-absent}"
}

# Tell the lane's ticket and Overwatch that its landed commit was reverted, with the reason. Best effort: the revert stands.
tell_lane() {  # <id> <note> [<head>]
  local FMH=$JG_HOME DATA_DIR=$DATA REFUSAL_BIN=$SCRIPT_DIR MEM=$DATA/jg-trunk-landing QUIET='' branch project
  mkdir -p "$MEM"
  if [ -n "${3:-}" ]; then
    branch=$(jg_dod_meta_value "$STATE/$1.meta" branch); branch=${branch:-fm/$1}
    project=$(jg_dod_meta_value "$STATE/$1.meta" project)
    lane_refusal_reach "$1" "$3" "$project" "$branch" "$2" final
    return
  fi
  jg_wake_append check "trunk-reverted-$PN-$(printf '%s' "$2" | cksum | cut -d' ' -f1)" "$2" >/dev/null 2>&1 || echo "warning: could not raise the revert alert" >&2
  refusal_deliver note "$1" "$2" || echo "warning: could not add the revert note to $1" >&2
  refusal_deliver steer "$1" "$2" || echo "warning: could not steer $1" >&2
}

# The lane's record and its project, with the registered-mode check. Sets META (and PROJ, PN, TRUNK through open_project).
lane_meta() {  # <task-id>
  jg_pr_task_id_valid "$1" || die "invalid task id"
  META="$STATE/$1.meta"; [ -f "$META" ] || die "no meta for task $1 at $META"
  open_project "$(jg_dod_meta_value "$META" project)"
  case $(jg_dod_meta_value "$META" mode) in local-trunk|local-only|trunk) ;; *) die "task $1 is not a local-trunk task (legacy local-only/trunk also accepted); merge PR tasks with bin/jg-pr-merge.sh" ;; esac
}

# One lane's admission onto <tip>: the trunk tip for a single landing, the top of the stack for a batch. The lander rebases the
# lane's one commit onto <tip> by itself and only a conflict stops it; then the ticket reference, protected paths,
# linked decisions, the design/demo/nav gates and owner-guard. Refuses (exits) on any failure. Sets LANE_BRANCH, LANE_HEAD, LANE_CAND
# (the commit to land) and LANE_LANDED (1 when the lane is already on <tip>). <follow> 1 moves the lane branch to its rebased commit now.
lane_admit() {  # <id> <tip> <expected head or -> <follow 0|1>
  local id=$1 tip=$2 base n hit rc=0 linked fresh gaps
  LANE_BRANCH=$(jg_dod_meta_value "$META" branch); LANE_BRANCH=${LANE_BRANCH:-fm/$id}
  git check-ref-format --branch "$LANE_BRANCH" >/dev/null 2>&1 || die "task $id has an invalid ship branch '$LANE_BRANCH'"
  LANE_HEAD=$(rev "refs/heads/$LANE_BRANCH") || die "branch $LANE_BRANCH does not exist in $PROJ"
  [ "$3" = - ] || [ "$LANE_HEAD" = "$3" ] || refuse "branch changed during admission; request and prove its new head"
  LANE_CAND=$LANE_HEAD; LANE_LANDED=
  if git -C "$PROJ" merge-base --is-ancestor "$LANE_CAND" "$tip"; then LANE_LANDED=1; return 0; fi
  # The whole proof at the lane's own head, before anything starts (single landing and stack alike): a PASS receipt alone is not enough.
  gaps=$(jg_dod_trunk_proof_gaps "$JG_HOME" "$STATE" "$id" "$META" "$LANE_HEAD") || refuse "the proof inputs are incomplete for $id, so no landing starts: $(printf '%s' "$gaps" | tr '\n' ';'); the lane completes its proof at this head and reports ready again"
  # The lander rebases the lane's one commit onto the latest tip by itself. Only a conflict stops it, and the lane resolves that.
  if ! git -C "$PROJ" merge-base --is-ancestor "$tip" "$LANE_CAND"; then
    base=$(git -C "$PROJ" merge-base "$tip" "$LANE_CAND" 2>/dev/null) || refuse "$LANE_BRANCH shares no history with $TRUNK (${tip:0:12}); start the lane on the trunk tip"
    n=$(git -C "$PROJ" rev-list --count "$base..$LANE_CAND")
    [ "$n" = 1 ] || refuse "one commit per ticket: $LANE_BRANCH has $n commits over $TRUNK; squash it to one"
    fresh=$(rebase_commit "$tip" "$LANE_CAND") || {
      hit=$(conflict_paths "$tip" "$LANE_CAND")
      refuse "$LANE_BRANCH conflicts with $TRUNK (${tip:0:12}) in: ${hit:-an unreadable merge}; a lane rebases and fixes it, then reports ready again; it is never landed dirty"
    }
    [ "$4" != 1 ] || lane_follow "$LANE_BRANCH" "$LANE_CAND" "$fresh" "$(jg_dod_meta_value "$META" worktree)"
    LANE_CAND=$fresh
  fi
  n=$(git -C "$PROJ" rev-list --count "$tip..$LANE_CAND")
  [ "$n" = 1 ] && [ "$(git -C "$PROJ" rev-list --parents -n 1 "$LANE_CAND" | wc -w)" = 2 ] || refuse "one commit per ticket: $LANE_BRANCH has $n commits over $TRUNK; squash it to one"
  git -C "$PROJ" log -1 --format=%B "$LANE_CAND" | grep -Eq "(^|[^[:alnum:]-])($id|[A-Z]{2,4}-[0-9]+)([^[:alnum:]-]|$)" \
    || refuse "the commit must carry its ticket reference (the task id $id or its ticket key) in its message"
  if hit=$(touches_protected "$tip" "$LANE_CAND") && [ "$(pol protected-landing)" = refuse ]; then
    refuse "$hit is a protected path; landing requires approval of protected-landing=gate (current protected-landing=refuse)"
  fi
  linked=$(JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-captain-hold.sh" blocking "$id") || rc=$?
  case $rc in
    0) refuse "task $id is linked to a decision still open for the captain: $(printf '%s' "$linked" | tr '\t\n' ' ;')" ;;
    1) ;;
    *) refuse "could not read the decisions linked to task $id" ;;
  esac
  jg_dod_local_landing_gates "$SCRIPT_DIR" "$CONFIG" "$JG_HOME" "$STATE" "$id" "$META" "$PROJ" "$tip" "$LANE_CAND" trunk || exit 1
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$LANE_CAND" "$TRUNK" "$tip" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused $id"
}

# What every landing does after the trunk moved: the proofs that exist, the merged event and the ticket close. The landing's Evidence card
# is core/landing-card's, an observer of these records; the PR-flow post-merge hook (merge-card) does not run for a landing.
landed_effects() {  # <id> <lane head> <landed commit>   (META is the lane's record)
  record_proofs "$1" "$2" "$3" || :
  # The latency row is written by this landing, not by a watcher; the check stays as the backstop for rows still missing. An over-limit alert becomes a check wake.
  local late; late=$(bash "$JG_ROOT/core/trunk-latency/latency.sh" check "$JG_HOME" 2>/dev/null) || :
  [ -z "$late" ] || jg_wake_append check "trunk-latency-$1" "$late" >/dev/null 2>&1 || :
  # The same merge alert as bin/jg-merge-local.sh: the opt-in fleet ledger's merged event and the ticket close.
  [ ! -e "$CONFIG/fleet-ledger" ] || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-fleet-ledger.sh" merged "$1" local || true
  JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$1" --stage "done" --state "done" || true
}

# True when a sealed done-done run of the lane passed, clean, at a commit whose tree is the tree <candidate> would be tested at: the
# tree hash decides, so a trunk that moved under the lane (a rebased tree) or a run that failed or was dirty never counts.
sealed_run_covers() {  # <id> <candidate>
  local want c f; [ "${JG_TRUNK_SEALED_REUSE:-1}" != 0 ] || return 1  # 0 always runs the tests (the suites that test the gate itself)
  want=$(git -C "$PROJ" rev-parse --verify --quiet "$2^{tree}") || return 1
  for f in "$DATA/$1/.done-done/runs/"*.json; do
    [ -f "$f" ] || continue
    c=$(jq -r 'select(.exit == 0 and .dirty == false) | .commit // empty' "$f" 2>/dev/null) || continue
    [ -n "$c" ] || continue
    [ "$(git -C "$PROJ" rev-parse --verify --quiet "$c^{tree}")" = "$want" ] && return 0
  done
  return 1
}

# The green pin is the newest trunk commit whose gate passed. A landing's own gate (the changed files' tests and the fast required
# set) is the trunk's green, and the whole suite runs on the release pull request in GitHub CI; a whole-suite pass (verify, a green
# CI) moves it too. It only moves forward. Called with the trunk lock held.
pin_green() {  # <sha>
  local green; green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  if [ -z "$green" ] || git -C "$PROJ" merge-base --is-ancestor "$green" "$1"; then put "$STATE/trunk-green-$PN" "$1"; fi
}

# A landing moves the green pin to its commit, except over a recorded red: a commit between the pin and the landing that a red CI
# or a charged verify red recorded in data/trunk-ci.tsv, and that no commit up to the landing reverts. The landing still lands
# (a red never stops a landing); only the pin, and with it live, waits, until a whole-suite pass past the red moves it, or the
# no-green alarm tells Overwatch. Called with the trunk lock held.
pin_landed() {  # <landed sha>
  local green r
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  if [ -n "$green" ]; then
    while IFS= read -r r; do
      git -C "$PROJ" merge-base --is-ancestor "$r" "$1" 2>/dev/null || continue
      ! git -C "$PROJ" merge-base --is-ancestor "$r" "$green" 2>/dev/null || continue
      git -C "$PROJ" log --format=%B "$r..$1" | grep -qx "reverts: $r" || return 0
    done < <(awk -F'\t' -v p="$PN" '$1 == p && $4 == "red" { print $2 }' "$DATA/trunk-ci.tsv" 2>/dev/null | sort -u)
  fi
  pin_green "$1"
}

# A commit found red after it landed takes the green pin with it: a pin at or above it goes back to its parent, so no home goes
# live on it. Called with the trunk lock held.
unpin_green() {  # <red sha>
  local green; green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  [ -n "$green" ] && git -C "$PROJ" merge-base --is-ancestor "$1" "$green" || return 0
  put "$STATE/trunk-green-$PN" "$(rev "$1^")"
}

land_candidate() {
  local id=${1-} tip cand gate GATE_KIND='' GATE_FIGURES='' still=
  case " $* " in *" --force"*|*" -f "*|*" --no-verify "*|*" --skip"*) refuse "a landing is never forced: land takes only the task id; there is no flag that lands past a conflict, a stale base or a failing check" ;; esac
  [ $# -le 1 ] || refuse "land takes only the task id; there is no option that forces or skips a gate"
  lane_meta "$id"
  if [ "$(pol away-landing)" = held ] && [ -e "$STATE/.afk" ]; then refuse "away mode: trunk landings stay held until the captain returns (away-landing=held)"; fi
  jg_lease_forbid_branch "trunk landing (jg-trunk)"
  lock "$STATE/.control-$id.lock"
  # The trunk lock is held only to read the tip and, after the gate, to move it, never across the gate's run: the lane is admitted
  # and gated on the tip it read, and the trunk moves only if it is still there. If a landing or a revert moved it meanwhile, the
  # lane is rebased onto the new tip (a conflict refuses, with its paths) and gated again.
  for _ in 1 2 3; do
    lock "$STATE/.trunk-$PN.lock"; tip_adopt_forward; tip_ok; tip=$(rev "refs/heads/$TRUNK"); unlock "$STATE/.trunk-$PN.lock"
    lane_admit "$id" "$tip" "$LAND_HEAD" 0
    cand=$LANE_CAND
    if [ -n "$LANE_LANDED" ]; then echo "already landed $id at $cand; not live"; return 0; fi
    # One fast check: the lint over the changed files, then the changed files' tests judged against the tip's own result.
    # Only a repository that carries Juggernaut's own suite gets its default gates; any other project runs the gates its home set for it, if any.
    if gate=$(jg_trunk_gate gate-lint "$PN" "$PROJ" "$cand"); then run_gate "$cand" "$gate" lint; else echo "land: $PN has no lint gate; none run" >&2; fi
    if gate=$(jg_trunk_gate gate-full "$PN" "$PROJ" "$cand") && sealed_run_covers "$id" "$cand"; then GATE_KIND=sealed-run; echo "land: ${cand:0:12} has the tree of $id's passing sealed run; the tests ran there, so only the lint ran here" >&2
    elif gate=$(jg_trunk_gate gate-full "$PN" "$PROJ" "$cand"); then full_gate "$cand" "$gate" "$tip" || exit 1; else GATE_KIND=no-gate; echo "land: $PN has no landing gate (no gate-full@$PN); none run" >&2; fi
    lock "$STATE/.trunk-$PN.lock"; tip_adopt_forward; tip_ok
    if [ "$(rev "refs/heads/$TRUNK")" = "$tip" ]; then still=1; break; fi
    unlock "$STATE/.trunk-$PN.lock"; echo "note: $TRUNK moved to $(rev "refs/heads/$TRUNK" | cut -c1-12) while $id was gated at ${tip:0:12}; rebasing it onto the new tip and gating it again" >&2
  done
  [ -n "$still" ] || refuse "the trunk kept moving while $id was gated; it lands on the next try"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: land $id" "refs/heads/$TRUNK" "$cand" "$tip" || refuse "$TRUNK changed while landing $id"
  put "$STATE/trunk-tip-$PN" "$cand"; pin_landed "$cand"
  row trunk-landings.tsv "$id" "$PN" "$cand" "$(date +%s)" "$GATE_KIND"
  unlock "$STATE/.trunk-$PN.lock"
  [ "$cand" = "$LANE_HEAD" ] || lane_follow "$LANE_BRANCH" "$LANE_HEAD" "$cand" "$(jg_dod_meta_value "$META" worktree)"
  landed_effects "$id" "$LANE_HEAD" "$cand"
  echo "landed $id on $TRUNK (${tip:0:12} -> ${cand:0:12}, gate=$GATE_KIND) in $PROJ; not live: it goes live only on the captain's word"
}

# --- The merge queue: two or more queued lanes land as one stack (docs/trunk-flow.md "Batch landing") ---
# B_* are the lanes of one batch, by position: id, original lane commit (C0), its commit as it now sits in the stack (CUR), lane head, branch, record, why it was returned.
B_ID=(); B_C0=(); B_CUR=(); B_HEAD=(); B_BRANCH=(); B_META=(); B_WHY=(); B_CLASS=(); B_TIP=; B_BASE0=; CHAIN=(); CHAIN_CHANGED=; LANDED=(); LAST_RED=; LAST_RED_CLASS=; GATE_BAD=

# The lanes <idx>... stacked on <top>, in order: a commit already on its place stays, any other is rebased by the lander onto it.
# A lane that no longer merges clean drops out (B_WHY). Sets CHAIN (the lanes that stack) and CHAIN_CHANGED (1 when any commit was rebuilt or dropped).
chain_on() {  # <top> <idx>...
  local top=$1 i fresh hit; shift
  CHAIN=(); CHAIN_CHANGED=
  for i in "$@"; do
    if [ "$(rev "${B_CUR[$i]}^")" != "$top" ]; then
      CHAIN_CHANGED=1
      if fresh=$(rebase_commit "$top" "${B_C0[$i]}"); then B_CUR[i]=$fresh; else
        hit=$(conflict_paths "$top" "${B_C0[$i]}")
        B_WHY[i]="REFUSED: ${B_BRANCH[$i]} conflicts with $TRUNK (${top:0:12}) in: ${hit:-an unreadable merge}; a lane rebases and fixes it, then reports ready again; it is never landed dirty"
        continue
      fi
    fi
    top=${B_CUR[$i]}; CHAIN+=("$i")
  done
}

# A gate command names the base of the change it judges as HEAD^ (the commit under a lane's one commit); a gate that judges a
# wider change names its base instead.
gate_from() {  # <gate command> <base>
  printf '%s\n' "${1//HEAD^/$2}"
}

# The default-branch commit this trunk version was cut from (data/trunk-versions.tsv) when <sha> is on top of it. The release
# pull request is this trunk against that commit, so CI maps the changed paths of every landing since it, not of one commit.
release_base() (  # <sha>
  local base default ref ver found
  base=$(awk -F'\t' -v p="$PN" -v t="$TRUNK" '$1 == p && $3 == t { b = $4 } END { print b }' "$DATA/trunk-versions.tsv" 2>/dev/null || true)
  found=$(awk -F'\t' -v p="$PN" -v t="$TRUNK" '$1 == p && $3 == t { print 1; exit }' "$DATA/trunk-versions.tsv" 2>/dev/null || true)
  if [ -z "$found" ]; then
    exec 9>"$STATE/.trunk-versions-$PN.lock"
    flock -x 9 || return 1
    base=$(awk -F'\t' -v p="$PN" -v t="$TRUNK" '$1 == p && $3 == t { b = $4; found = 1 } END { if (found) print b; else exit 1 }' "$DATA/trunk-versions.tsv" 2>/dev/null) || {
    default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
    ref="refs/remotes/origin/$default"
    rev "$ref" >/dev/null || ref="refs/heads/$default"
    base=$(git -C "$PROJ" merge-base "$TRUNK" "$ref") || return 1
    git -C "$PROJ" merge-base --is-ancestor "$base" "$1" || return 1
    ver=$(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1)
    row trunk-versions.tsv "$PN" "$ver" "$TRUNK" "$base" "$(date +%s)"
    }
  fi
  [ -n "$base" ] && git -C "$PROJ" merge-base --is-ancestor "$base" "$1" 2>/dev/null && printf '%s\n' "$base"
)

# ONE gate over the stack: the lint, then the tests of the union of the changed files, both judged against the trunk tip
# (HEAD^ in a gate command is the commit under the stack, so HEAD~<n> is). Returns 0 green; 1 red, with BG_WHY and LAST_RED set.
batch_gate() {  # <top> <stack size>   (B_TIP is the trunk tip the stack sits on)
  local rc=0 errf lint full
  lint=$(jg_trunk_gate gate-lint "$PN" "$PROJ" "$1" || true); full=$(jg_trunk_gate gate-full "$PN" "$PROJ" "$1" || true)
  errf=$(mktemp)
  ( [ -z "$lint" ] || run_gate "$1" "$(gate_from "$lint" "HEAD~$2")" lint ) 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then :
  elif [ -n "$full" ]; then full_gate "$1" "$(gate_from "$full" "HEAD~$2")" "$B_TIP" 2>>"$errf" || rc=$?
  else GATE_KIND=no-gate; echo "land: $PN has no landing gate (no gate-full@$PN); none run" >>"$errf"; fi
  cat "$errf" >&2
  [ "$rc" -eq 0 ] || { LAST_RED=$(grep -E '^(REFUSED|error):' "$errf" | tail -n 1 | sed 's/^[A-Za-z]*: //'); LAST_RED_CLASS=$(classify_refusal "$errf"); }
  rm -f -- "$errf"
  [ "$rc" -eq 0 ]
}

# The one lane of CHAIN that owns every script the last gate blamed (GATE_BAD): the script is among that lane's own changed files and no
# other lane of the stack changed it. Prints its index; prints nothing, and the red is unclear, when a blamed script has no owner or two,
# when the owners differ, or when the red was not charged to a script. An unclear red is halved.
red_pick() {
  local s i owner='' hit
  [ -n "$GATE_BAD" ] && [ "${LAST_RED_CLASS:-final}" = final ] || return 0
  for s in $GATE_BAD; do
    hit=
    for i in "${CHAIN[@]}"; do
      git -C "$PROJ" diff-tree --no-commit-id --name-only -r "${B_CUR[$i]}" | grep -qxF -- "$s" || continue
      [ -z "$hit" ] || return 0
      hit=$i
    done
    [ -n "$hit" ] || return 0
    [ -z "$owner" ] || [ "$owner" = "$hit" ] || return 0
    owner=$hit
  done
  printf '%s\n' "$owner"
}

# A red stack with a clear owner costs one more gate: the owner is set aside and the rest of CHAIN is gated once on the tip. Green: the
# rest lands and the owner is returned (it never ran alone: its red is the stack's gate's). Returns 0 then, 1 when the pick did not hold
# (the rest is red too, so the caller halves the whole stack as before) and 2 when the trunk moved while the rest was gated.
red_pick_try() {  # <idx>   (LAST_RED and LAST_RED_CLASS hold the stack's red)
  local pick=$1 why=$LAST_RED class=$LAST_RED_CLASS i rest=()
  for i in "${CHAIN[@]}"; do [ "$i" = "$pick" ] || rest+=("$i"); done
  chain_on "$B_TIP" "${rest[@]}"
  [ "${#CHAIN[@]}" -gt 0 ] || return 1
  batch_gate "${B_CUR[${CHAIN[${#CHAIN[@]}-1]}]}" "${#CHAIN[@]}" || return 1
  land_group || return 2
  B_WHY[pick]="REFUSED: this lane is the red in its batch: $why"; B_CLASS[pick]=$class
}

# The lanes in CHAIN land in one move: the trunk fast-forwards over the whole stack. One trunk-landings.tsv row per lane.
land_group() {
  local top=${B_CUR[${CHAIN[${#CHAIN[@]}-1]}]} i
  # The trunk lock is held only to move the trunk. Returns 1, moving nothing, when the trunk is no longer where the stack was gated.
  lock "$STATE/.trunk-$PN.lock"; tip_adopt_forward; tip_ok
  [ "$(rev "refs/heads/$TRUNK")" = "$B_TIP" ] || { unlock "$STATE/.trunk-$PN.lock"; return 1; }
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: land a batch of ${#CHAIN[@]}" "refs/heads/$TRUNK" "$top" "$B_TIP" || refuse "$TRUNK changed while landing the batch"
  put "$STATE/trunk-tip-$PN" "$top"; pin_landed "$top"
  for i in "${CHAIN[@]}"; do row trunk-landings.tsv "${B_ID[$i]}" "$PN" "${B_CUR[$i]}" "$(date +%s)" "$GATE_KIND" "batch-from=$B_BASE0"; done
  unlock "$STATE/.trunk-$PN.lock"
  for i in "${CHAIN[@]}"; do
    META=${B_META[$i]}
    lane_follow "${B_BRANCH[$i]}" "${B_HEAD[$i]}" "${B_CUR[$i]}" "$(jg_dod_meta_value "$META" worktree)"
    landed_effects "${B_ID[$i]}" "${B_HEAD[$i]}" "${B_CUR[$i]}"
    LANDED+=("$i")
    echo "landed ${B_ID[$i]} on $TRUNK (${B_TIP:0:12} -> ${top:0:12}, gate=$GATE_KIND, one stack of ${#CHAIN[@]}) in $PROJ; not live: it goes live only on the captain's word"
  done
  B_TIP=$top
}

# Land 2 to batch-max queued lanes as one stack: `land-batch <id>[@<head>]...` in landing order. Each lane is admitted onto the top of the
# stack (auto-rebased; a lane that conflicts drops out and is returned, as a single landing would refuse it). One gate runs over the union
# of the stack's changed files and, on green, the trunk fast-forwards over the whole stack in one move. On red the stack is halved: the first
# half is judged alone, lands if green, and the rest is judged on the new tip, until the lane that caused the red stands alone; only it is
# returned; a red whose failing scripts one lane owns skips the halving (red_pick). Prints `landed <id> ...` or `returned <id>: <reason>` for every lane. Exit 0 once every lane has an outcome.
cmd_land_batch() {
  local a id i n max proj0='' errf g flag top half res moved rounds=0 l branch head pick
  local -a exp todo stack members first rest remaining orig
  case " $* " in *" --force"*|*" -f "*|*" --no-verify "*|*" --skip"*) refuse "a landing is never forced: there is no flag that lands past a conflict, a stale base or a failing check" ;; esac
  n=$#; [ "$n" -ge 2 ] || refuse "a batch stacks 2 or more queued lanes; one lane lands with: jg-trunk.sh land <task>"
  i=0
  for a in "$@"; do
    id=${a%%@*}; exp[i]=-; [ "$a" = "$id" ] || exp[i]=${a#*@}
    lane_meta "$id"
    [ -z "$proj0" ] || [ "$PROJ" = "$proj0" ] || refuse "a batch lands lanes of one project; $id belongs to $PROJ, not $proj0"
    for g in "${B_ID[@]}"; do [ "$g" != "$id" ] || refuse "task $id is in the batch twice"; done
    proj0=$PROJ; B_ID[i]=$id; B_META[i]=$META; i=$((i + 1))
  done
  max=$(pol batch-max); [ "$n" -le "$max" ] || refuse "a batch stacks at most $max lanes (batch-max); the rest land next"
  if [ "$(pol away-landing)" = held ] && [ -e "$STATE/.afk" ]; then refuse "away mode: trunk landings stay held until the captain returns (away-landing=held)"; fi
  jg_lease_forbid_branch "trunk landing (jg-trunk)"
  for id in "${B_ID[@]}"; do lock "$STATE/.control-$id.lock"; done
  lock "$STATE/.trunk-$PN.lock"; tip_adopt_forward; tip_ok; B_TIP=$(rev "refs/heads/$TRUNK"); unlock "$STATE/.trunk-$PN.lock"
  B_BASE0=$B_TIP; GATE_KIND=full; GATE_FIGURES=; top=$B_TIP; todo=()
  for ((i = 0; i < n; i++)); do
    META=${B_META[$i]}; id=${B_ID[$i]}; errf=$(mktemp)
    # shellcheck disable=SC2030 # the admission subshell starts with no locks and no work directory of its own
    if ( LOCKS=''; WORK=''; lane_admit "$id" "$top" "${exp[$i]}" 0 && printf '%s\t%s\t%s\t%s\n' "$LANE_HEAD" "$LANE_CAND" "$LANE_BRANCH" "$LANE_LANDED" > "$errf.res" ) 2>"$errf"; then
      IFS=$'\t' read -r "B_HEAD[i]" "B_CUR[i]" "B_BRANCH[i]" res < "$errf.res"
      if [ -n "$res" ]; then B_WHY[i]="already landed $id at ${B_CUR[$i]}; not live"; else B_C0[i]=${B_HEAD[$i]}; top=${B_CUR[$i]}; todo+=("$i"); fi
    else
      B_WHY[i]=$(grep -E '^(REFUSED|error):' "$errf" | tail -n 1); B_WHY[i]=${B_WHY[$i]:-"REFUSED: admission failed for $id"}; B_CLASS[i]=$(classify_refusal "$errf")
    fi
    cat "$errf" >&2; rm -f -- "$errf" "$errf.res"
  done
  # Judge the stack; a red one is halved until the guilty lane stands alone. A group stacked above a landed first half is already
  # known red when its commits are unchanged, so it is halved without a second run.
  # The trunk lock is taken only to move it (land_group). If the trunk moved while a stack was gated, nothing of it lands: the lanes
  # still waiting are rebased onto the new tip (a conflict returns that lane with its paths) and judged again.
  while :; do
  moved=
  stack=("0:${todo[*]}")
  while [ "${#stack[@]}" -gt 0 ]; do
    g=${stack[${#stack[@]}-1]}; unset 'stack[${#stack[@]}-1]'; flag=${g%%:*}; read -r -a members <<< "${g#*:}"
    [ "${#members[@]}" -gt 0 ] || continue
    chain_on "$B_TIP" "${members[@]}"
    [ "${#CHAIN[@]}" -gt 0 ] || continue
    top=${B_CUR[${CHAIN[${#CHAIN[@]}-1]}]}
    GATE_BAD=
    if [ "$flag" = 1 ] && [ -z "$CHAIN_CHANGED" ]; then :; elif batch_gate "$top" "${#CHAIN[@]}"; then if land_group; then continue; fi; moved=1; break; fi
    if [ "${#CHAIN[@]}" -eq 1 ]; then
      B_WHY[CHAIN[0]]="REFUSED: this lane is the red in its batch: $LAST_RED"; B_CLASS[CHAIN[0]]=$LAST_RED_CLASS; continue
    fi
    pick=$(red_pick); orig=("${CHAIN[@]}")
    if [ -n "$pick" ]; then
      res=0; red_pick_try "$pick" || res=$?
      [ "$res" -ne 0 ] || continue
      [ "$res" -ne 2 ] || { moved=1; break; }
      CHAIN=("${orig[@]}")
    fi
    half=$(( ${#CHAIN[@]} / 2 )); first=("${CHAIN[@]:0:half}"); rest=("${CHAIN[@]:half}")
    stack+=("1:${rest[*]}" "0:${first[*]}")
  done
  [ -n "$moved" ] || break
  remaining=()
  for i in "${todo[@]}"; do
    [ -z "${B_WHY[$i]:-}" ] || continue
    for l in ${LANDED[@]+"${LANDED[@]}"}; do [ "$l" != "$i" ] || continue 2; done
    remaining+=("$i")
  done
  [ "${#remaining[@]}" -gt 0 ] || break
  rounds=$((rounds + 1))
  if [ "$rounds" -ge 3 ]; then
    for i in "${remaining[@]}"; do B_WHY[i]="REFUSED: the trunk kept moving while its batch was gated; it lands on the next try"; B_CLASS[i]="wait"; done
    break
  fi
  todo=("${remaining[@]}"); B_TIP=$(rev "refs/heads/$TRUNK"); B_BASE0=$B_TIP
  echo "note: $TRUNK moved while the stack was gated; judging the ${#todo[@]} lanes still waiting on ${B_TIP:0:12}" >&2
  done
  for ((i = 0; i < n; i++)); do
    [ -n "${B_WHY[$i]:-}" ] || continue
    case ${B_WHY[$i]} in "already landed"*) echo "${B_WHY[$i]}" ;; *)
      echo "returned ${B_ID[$i]}: ${B_WHY[$i]}"; echo "refusal-class ${B_ID[$i]}: ${B_CLASS[$i]:-final}"
      if [ "${B_CLASS[$i]:-final}" = final ]; then
        META=${B_META[$i]}; branch=$(jg_dod_meta_value "$META" branch); branch=${branch:-fm/${B_ID[$i]}}
        head=$(rev "refs/heads/$branch") || head=
        [ -z "$head" ] || tell_lane "${B_ID[$i]}" "${B_WHY[$i]}" "$head"
      fi ;;
    esac
  done
}

# The effective reference-transaction hook is an environment fact of an admission attempt: a hook-install refusal is cached per
# context, so the context names where the hook is, whether its directory takes a write, and the bytes of any hook this script does
# not own. The guard this script installs is not a fact (the first attempt writes it), so an absent or managed hook reads `ours`.
# A repaired overlay or permission changes the fact and admits exactly one new attempt; an unchanged one admits none.
hook_fact() {  # <project-dir>
  local effective common f
  effective=$(git -C "$1" rev-parse --path-format=absolute --git-path hooks/reference-transaction 2>/dev/null || true)
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)/hooks/reference-transaction
  if [ -n "$effective" ] && [ -d "$(dirname "$effective")" ]; then
    find "$(dirname "$effective")" -maxdepth 1 ! -name reference-transaction -printf '%f %m %y\n' | LC_ALL=C sort
  fi
  printf 'hook-fact %s dir-writable=%s\n' "$effective" "$([ -n "$effective" ] && [ -w "$(dirname "$effective")" ] && echo yes || echo no)"
  for f in "$effective" "$common"; do
    printf '%s ' "$f"
    if [ ! -f "$f" ] || grep -q '^# managed by bin/jg-trunk.sh:' "$f"; then echo ours
    else printf '%s %s\n' "$([ -x "$f" ] && echo x || echo -)" "$(git hash-object "$f")"; fi
  done
}

# Manual and automatic callers share admission before either can wait on the project lock.
# Exit 75 is in progress, 74 a refusal classed retry (classify_refusal: the machine failed, not the lane), 1 any other refusal. A refusal
# also prints `refusal-class <id>: wait|retry|final`, which the landing check acts on; the count and the backoff are its own.
# Context changes admit a new attempt; every attempt keeps its own output and gate logs.
cmd_land() {
  local id=${1:-} meta proj branch cand mem context key previous count=0 kind reason attempt rc=0 proof_home account run_lock held_by key_home hops
  if [ "$#" -ne 1 ] || ! jg_pr_task_id_valid "$id"; then refuse "land takes only the task id; a landing is never forced"; fi
  meta=$STATE/$id.meta; [ -f "$meta" ] || die "no meta for task $id at $meta"
  proj=$(jg_dod_meta_value "$meta" project)
  branch=$(jg_dod_meta_value "$meta" branch); branch=${branch:-fm/$id}
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || refuse "invalid ship branch"
  cand=$(git -C "$proj" rev-parse --verify "refs/heads/$branch^{commit}") || die "branch $branch does not exist in $proj"
  [ -z "${JG_TRUNK_EXPECT_HEAD:-}" ] || [ "$cand" = "$JG_TRUNK_EXPECT_HEAD" ] || refuse "the requested head changed before admission"
  proof_home=${DONE_DONE_HOME:-$HOME/.done-done}; account=${CLAUDE_CONFIG_DIR:-}
  if [ -f "$DATA/$id/merge-card.json" ]; then
    previous=$(jq -c --arg h "$cand" 'select(.head == $h and .verdict == "pass") | .context // {}' "$DATA/$id/merge-card.json") || refuse "cannot read the declared proof context"
    previous=${previous:-\{\}}
    proof_home=${DONE_DONE_HOME:-$(jq -r '.home // empty' <<<"$previous")}; proof_home=${proof_home:-$HOME/.done-done}
    account=${CLAUDE_CONFIG_DIR:-$(jq -r '.account // empty' <<<"$previous")}
  fi
  key_home=${JG_MAIN_HOME:-$JG_HOME}; hops=0
  if [ -z "${JG_MAIN_HOME:-}" ]; then
    # shellcheck source=bin/jg-squad-lead-parent-lib.sh
    . "$SCRIPT_DIR/jg-squad-lead-parent-lib.sh"
    while [ -e "$key_home/.jg-squad-lead-parent" ] && [ "$hops" -lt 8 ]; do
      jg_squad_lead_parent_record_parse "$key_home/.jg-squad-lead-parent" || break
      [ -n "$JG_SQUAD_LEAD_PARENT_HOME" ] || break
      key_home=$JG_SQUAD_LEAD_PARENT_HOME; hops=$((hops + 1))
    done
  fi
  mem=$DATA/jg-trunk-landing; mkdir -p "$mem"
  # No runtime status, clocks or attempt output belong to the declared context.
  context=$({
    printf '%s\n' "$proj" "$cand" "$proof_home" "$account" "$PATH" \
      "${JG_BEADS_TEST_BD:-}" "${JG_BEADS_TEST_DOLT:-}" "${GOCACHE:-}" "${GOMODCACHE:-}"
    hook_fact "$proj"
    for key in git openssl jq; do command -v "$key" 2>/dev/null || true; "$key" --version 2>/dev/null | head -n 1 || true; done
    key=$key_home/config/owner-rules-proof.pub
    printf '%s ' "$key"; [ ! -f "$key" ] || git hash-object "$key"; [ ! -r "$key" ] || echo readable
    cat "$meta"
    jq -Sc 'del(.at)' "$STATE/$id.run-receipt.json" 2>/dev/null || true
    for key in "$STATE/trunk-tip-$(basename "$proj")" \
      "$CONFIG/trunk-policy" "$CONFIG/merge-gate" "$CONFIG/owner-details-patterns" \
      "$DATA/$id/checks.md" "$DATA/$id/proof-authorizations/$cand.sig" \
      "$proof_home/config.yaml"; do
      printf '%s\n' "$key"; [ ! -f "$key" ] || git hash-object "$key"
    done
    awk -F'\t' -v h="$cand" -v p="$DATA/$id/" '($3 == h || index($2,p) == 1) && $4 != "card" {r=$2 FS $3 FS $4 FS $5} END {print r}' "$DATA/checks-gate.log" 2>/dev/null || true
  } | git hash-object --stdin)
  key=$mem/$id.$cand.$context
  run_lock=$STATE/.trunk-run-$id-$cand.lock
  held_by=${JG_TRUNK_RUN_HELD_BY:-}
  if [ -z "$held_by" ] || ! jg_pid_alive "$held_by" || [ "$(cat "$run_lock/pid" 2>/dev/null || true)" != "$held_by" ]; then
    if ! jg_lock_try_acquire "$run_lock"; then
      echo "IN_PROGRESS: $id at $cand already has an active landing or cleanup"; return 75
    fi
    # shellcheck disable=SC2031 # LOCKS is the top-level list; the subshells keep their own copy
    LOCKS="$run_lock $LOCKS"
  fi
  if ! jg_lock_try_acquire "$STATE/.landing-$id-$cand.lock"; then
    echo "IN_PROGRESS: $id at $cand already has an active landing attempt"; return 75
  fi
  LOCKS="$STATE/.landing-$id-$cand.lock $LOCKS"
  # Superseded context keys are history, not a second active admission decision.
  for previous in "$mem/$id.$cand".*.state; do
    [ -f "$previous" ] && [ "$previous" != "$key.state" ] || continue
    case $(cat "$previous" 2>/dev/null) in final*|env-wait*)
      mkdir -p "$mem/retired" && mv -n -- "$previous" "$mem/retired/" ;;
    esac
  done
  previous=$(cat "$key.state" 2>/dev/null || true)
  read -r kind count reason <<<"${previous:-new 0}"
  case $kind in
    env-wait|final-env)
      if [ "$kind" = env-wait ]; then
        count=$((count + 1)); [ "$count" -lt 3 ] || kind=final-env
        printf '%s %s %s\n' "$kind" "$count" "$reason" > "$key.state"
      fi
      printf '%s\n' "$reason"; printf 'refusal-class %s: env-wait\n' "$id"; return 1 ;;
    final) printf '%s\n' "$reason"; printf 'refusal-class %s: %s\n' "$id" "$kind"; tell_lane "$id" "$reason" "$cand"; return 1 ;;
  esac
  attempt=$(mktemp -d "$mem/$id.$cand.attempt-XXXXXX") || die "cannot retain landing attempt"
  LAND_ATTEMPT=$attempt/gate LAND_HEAD=$cand
  printf 'running %s\n' "$count" > "$key.state"
  # shellcheck disable=SC2030 # the landing subshell starts with no locks of its own
  ( LOCKS=''; trap cleanup EXIT
    printf 'landing context: project=%s target=%s head=%s context=%s\n' "$proj" "$(cat "$STATE/trunk-tip-$(basename "$proj")" 2>/dev/null || true)" "$cand" "$context"
    land_candidate "$id"
  ) > "$attempt/landing.log" 2>&1 || rc=$?
  cat "$attempt/landing.log"
  reason=$(grep -E '^(REFUSED|error):' "$attempt/landing.log" | tail -n 1)
  reason=${reason:-"REFUSED: landing failed (exit $rc); see $attempt/landing.log"}
  reason="$reason; full log: $attempt/landing.log"
  if [ "$rc" -eq 0 ]; then kind=landed; reason="landed $id at $cand; not live"
  else
    kind=$(classify_refusal "$attempt/landing.log" "$attempt"/gate-*.log)
    printf '%s\n' "$reason"; printf 'refusal-class %s: %s\n' "$id" "$kind"
    [ "$kind" != final ] || tell_lane "$id" "$reason" "$cand"
    [ "$kind" != retry ] || { count=$((count + 1)); rc=74; }
  fi
  printf '%s %s %s\n' "$kind" "$count" "$reason" > "$key.state"
  return "$rc"
}

# Take the lock off early so a long run does not hold it; the exit trap releases only what is still held.
# shellcheck disable=SC2031 # LOCKS is the top-level list; the landing subshell has its own copy and never calls this
unlock() { jg_lock_release "$1" || true; LOCKS=${LOCKS/"$1 "/}; }

# Undo one landed commit by itself: a new commit on the tip that carries the commit's inverse, so the trunk only moves forward.
# Returns 1, changing nothing, when the commit cannot be undone cleanly or is itself an undo.
revert_commit() {  # <sha> <reason>
  local sha=$1 tip tree msg id ident=() new
  lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  msg=$(git -C "$PROJ" log -1 --format=%B "$sha")
  if printf '%s\n' "$msg" | grep -q '^reverts: '; then unlock "$STATE/.trunk-$PN.lock"; return 1; fi
  tree=$(git -C "$PROJ" merge-tree --write-tree --merge-base="$sha" "$tip" "$sha^" 2>/dev/null) || { unlock "$STATE/.trunk-$PN.lock"; return 1; }
  id=$(awk -F'\t' -v c="$sha" '$3 == c { i = $1 } END { print i }' "$DATA/trunk-landings.tsv" 2>/dev/null)
  [ -n "$(git -C "$PROJ" config user.name 2>/dev/null || true)" ] || ident=(-c user.name=jg-trunk -c user.email=jg-trunk@localhost)
  new=$(printf 'Revert "%s"\n\nreverts: %s\nticket: %s\n\n%s\n' "$(git -C "$PROJ" log -1 --format=%s "$sha")" "$sha" "${id:-unknown}" "$2" \
    | git -C "$PROJ" "${ident[@]+"${ident[@]}"}" commit-tree "$tree" -p "$tip") || { unlock "$STATE/.trunk-$PN.lock"; return 1; }
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: revert ${sha:0:12}" "refs/heads/$TRUNK" "$new" "$tip" || { unlock "$STATE/.trunk-$PN.lock"; return 1; }
  put "$STATE/trunk-tip-$PN" "$new"; unpin_green "$sha"
  row trunk-landings.tsv "revert-${id:-unknown}" "$PN" "$new" "$(date +%s)" reverts-"${sha:0:12}"
  unlock "$STATE/.trunk-$PN.lock"
  tell_lane "${id:-unknown}" "$TRUNK commit ${sha:0:12} (${id:-unknown}) went red after it landed and was reverted by itself in ${new:0:12}: $2. Fix it on a new lane."
  echo "reverted ${sha:0:12} (${id:-unknown}) in ${new:0:12}: $2"
}

# This project's one verify slot, newest wins. A verify registers its commit as the newest wanted one, then waits for the slot; it
# gives up at once (returns 1) when a newer commit of the trunk is registered, before or while it waits, because a green result at
# the newer commit moves the pin over this one too. Only the slot's own short lock is taken, never the landing lock.
verify_slot() {  # <sha>
  local sha=$1 q="$STATE/.trunk-verify-queue-$PN.lock" wf="$STATE/trunk-verify-want-$PN" want
  lock "$q"
  want=$(cat "$wf" 2>/dev/null || true)
  if [ -n "$want" ] && [ "$want" != "$sha" ] && git -C "$PROJ" merge-base --is-ancestor "$sha" "$want" 2>/dev/null; then unlock "$q"; return 1; fi
  put "$wf" "$sha"; VERIFY_WANT=$sha; unlock "$q"
  until jg_lock_try_acquire "$STATE/.trunk-verify-$PN.lock"; do
    [ "$(cat "$wf" 2>/dev/null || true)" = "$sha" ] || return 1
    sleep 0.2
  done
  LOCKS="$STATE/.trunk-verify-$PN.lock $LOCKS"
  [ "$(cat "$wf" 2>/dev/null || true)" = "$sha" ]
}

# The whole suite at a landed commit, on demand: nothing starts it per landing (the whole suite runs on the release pull request in
# GitHub CI). Green moves the pin; a script that fails there and passes on the commit's parent charges that one commit, which is
# reverted, and the green pin goes back below it. A failure no test accounts for runs once more and never moves the pin or reverts.
# Nothing here stops a landing.
# The commit of a landed batch that caused the red its top commit shows: the lowest commit of <from>..<top> whose whole suite
# already fails against <from> (halving, so a few whole-suite runs, and only on a red). Prints nothing when it cannot be found.
batch_culprit() {  # <from> <top> <verify gate>
  local from=$1 gate=$3 lo=1 hi mid rc c
  local -a cs
  mapfile -t cs < <(git -C "$PROJ" rev-list --reverse "$from..$2")
  hi=${#cs[@]}; [ "$hi" -gt 1 ] || return 0
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 )); rc=0; c=${cs[mid-1]}
    full_gate "$c" "$gate" "$from" || rc=$?
    case $rc in 0) lo=$((mid + 1)) ;; 2) hi=$mid ;; *) return 0 ;; esac
  done
  printf '%s\n' "${cs[lo-1]}"
}

cmd_verify() {
  local sha tip rc=0 parent why from culprit='' gate base attempt bad
  open_project "${1-}"
  # The tip is a ref read, which is atomic, so reading it never waits for a landing; the trunk lock is taken only for a short write.
  tip=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  sha=$tip; [ -z "${2-}" ] || sha=$(rev "$2") || die "'${2-}' does not resolve in $PROJ"
  git -C "$PROJ" merge-base --is-ancestor "$sha" "$tip" || refuse "${sha:0:12} is not on $TRUNK"
  verify_slot "$sha" || { echo "verify: ${sha:0:12} is superseded by a newer verify, so it does not run; a green result there moves the pin over it too"; return 0; }
  parent=$(rev "$sha^" || true)
  # The top of a batch is judged against the trunk before the batch (its row says where that was), so one run covers the whole stack.
  from=$(awk -F'\t' -v c="$sha" '$3 == c && $6 ~ /^batch-from=/ { f = substr($6, 12) } END { print f }' "$DATA/trunk-landings.tsv" 2>/dev/null || true)
  if [ -n "$from" ] && git -C "$PROJ" merge-base --is-ancestor "$from" "$sha"; then parent=$from; else from=; fi
  if ! gate=$(jg_trunk_gate gate-verify "$PN" "$PROJ" "$sha"); then
    # No gate for this project (not Juggernaut, and neither gate-verify@$PN nor gate-full@$PN set): nothing can fail, so nothing goes red.
    echo "verify: no verify gate for $PN (no gate-verify@$PN or gate-full@$PN); nothing run, nothing marked red" >&2; gate=
  elif base=$(release_base "$sha"); then
    # Verify judges what the release pull request carries: every change since this trunk's release base, the set CI maps for it.
    gate=$(gate_from "$gate" "$base"); echo "verify: judging every change since the release base ${base:0:12}" >&2
  else echo "verify: $TRUNK has no recorded release base under ${sha:0:12}; its gate runs as written" >&2; fi
  # A failure no test script accounts for (failed=0: a shard over its time budget, a shard with no result, a runner that stopped)
  # says nothing about the commit, so it is a warning and runs once more; only a failed test is ever charged.
  for attempt in 1 2; do
    rc=0
    if [ -z "$gate" ]; then :
    elif [ -n "$parent" ]; then full_gate "$sha" "$gate" "$parent" || rc=$?
    else run_gate "$sha" "$gate" full || rc=$?; fi
    [ "$rc" -eq 1 ] && [ "$attempt" = 1 ] || break
    echo "warning: the whole suite at ${sha:0:12} failed with no failed test charged to a commit; it is not pinned or reverted, and it runs once more" >&2
  done
  case $rc in
    0)
      # A pass on the rerun moves the pin (the gate filed each flaky script as its own fix row), and so does a failure the commit's own
      # parent has in the same way, a red the commit did not add (the gate reported it once as the tip's red): the green pin is the last
      # commit that added no failure.
      lock "$STATE/.trunk-$PN.lock"; tip_ok; pin_green "$sha"
      unlock "$STATE/.trunk-$PN.lock"
      case ${GATE_KIND:-} in
        full-tip-red) echo "trunk green at ${sha:0:12}, with the failures its parent already had set aside" ;;
        full-rerun) echo "trunk green at ${sha:0:12}, with the scripts that passed on their rerun set aside and filed as flaky" ;;
        *) echo "trunk green at ${sha:0:12}" ;;
      esac ;;
    2)
      why="the whole suite fails on it where its parent ${parent:0:12} passes"
      [ -z "$from" ] || culprit=$(batch_culprit "$from" "$sha" "$gate")
      if [ -n "$culprit" ] && [ "$culprit" != "$sha" ]; then
        why="the whole suite fails on it where the trunk before its batch ${from:0:12} passes"
        if revert_commit "$culprit" "$why"; then exit 1; fi
      elif revert_commit "$sha" "$why"; then exit 1; fi
      # The red stays recorded (data/trunk-ci.tsv, source verify) so no later landing moves the pin over it.
      bad=$sha; [ -z "$culprit" ] || bad=$culprit
      lock "$STATE/.trunk-$PN.lock"; unpin_green "$bad"; row trunk-ci.tsv "$PN" "$bad" "$(date +%s)" red verify; unlock "$STATE/.trunk-$PN.lock"
      why="$TRUNK is red at ${bad:0:12}: $why, and it could not be reverted by itself; landings go on, and live stays on the last green commit $(green_short)"
      jg_wake_append check "trunk-red-$PN-${bad:0:12}" "$why" >/dev/null 2>&1 || echo "warning: could not raise the red alert" >&2
      echo "verify: $why" >&2; exit 1 ;;
    *)
      echo "verify: ${sha:0:12} is not green after its one rerun, and no failed test is charged to a commit; nothing is reverted and the green pin stays at $(green_short): landings go on" >&2; exit 1 ;;
  esac
}

green_short() { cut -c1-12 "$STATE/trunk-green-$PN" 2>/dev/null || echo none; }

# The trunk with no green commit for no-green-alarm-minutes raises ONE alarm to Overwatch, on the same wake path as the trunk's other
# alarms (jg_wake_append check); its key ends in -stall, which the wake routing wakes at once. The wait is counted from the landing of
# the oldest commit above the green pin (its data/trunk-landings.tsv row, else its commit time). One alarm per green pin
# (state/trunk-green-alarm-<project> holds the pin it was raised for): a stall that goes on is not raised again, and once the pin moves
# a new stall can be. Read-only for the trunk; the landing check runs it every minute.
cmd_green_alarm() {
  local tip green first at mins age n note
  open_project "${1-}"
  tip=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  [ -n "$green" ] || { echo "green-alarm: $PN has no green pin yet"; return 0; }
  first=$(git -C "$PROJ" rev-list --reverse "$green..$tip" | head -n 1)
  [ -n "$first" ] || { echo "green-alarm: $TRUNK is green at ${green:0:12}"; return 0; }
  at=$(awk -F'\t' -v c="$first" '$3 == c { t = $4 } END { print t }' "$DATA/trunk-landings.tsv" 2>/dev/null || true)
  case $at in ''|*[!0-9]*) at=$(git -C "$PROJ" log -1 --format=%ct "$first") ;; esac
  mins=$(pol no-green-alarm-minutes); case $mins in ''|*[!0-9]*) mins=15 ;; esac
  age=$(( $(date +%s) - at ))
  [ "$age" -ge $(( mins * 60 )) ] || { echo "green-alarm: no green above ${green:0:12} for $(( age / 60 )) of $mins minutes"; return 0; }
  lock "$STATE/.trunk-green-alarm-$PN.lock"
  [ "$(cat "$STATE/trunk-green-alarm-$PN" 2>/dev/null || true)" != "$green" ] || { echo "green-alarm: already raised for the green pin ${green:0:12}"; return 0; }
  n=$(git -C "$PROJ" rev-list --count "$green..$tip")
  note="$TRUNK has had no green commit for $(( age / 60 )) minutes: the tip ${tip:0:12} is $n commit(s) above the last green ${green:0:12}. Landings go on and live stays on ${green:0:12}; a red a hand-run verify or a red CI found took the pin back there."
  jg_wake_append check "trunk-no-green-$PN-${green:0:12}-stall" "$note" >/dev/null 2>&1 || die "could not raise the no-green alarm"
  put "$STATE/trunk-green-alarm-$PN" "$green"
  echo "green-alarm: raised: $note"
}

# A move of the homes never lands on a running gate. begin_move takes the move's place (state/.trunk-move-<project>.lock), so no new
# gate starts, and waits until every gate that is running has ended (gate_enter marks them). The trunk lock is let go while it waits,
# because a landing needs it to finish, and taken again before the move. The wait is bounded by JG_TRUNK_MOVE_WAIT_MAX seconds (default
# 2700); past it the move is not made and is tried again on the next tick. It runs in the process that holds the trunk lock, never in
# a `$(...)` subshell, which cannot release its parent's lock: a caller that captures go_live's output calls begin_move first.
running_gate() {  # prints the pid of a gate that is running, and returns 0; returns 1 when none is
  local m
  for m in "$STATE"/.trunk-gate-"$PN"-*.lock; do
    [ -e "$m" ] || continue
    if jg_lock_try_acquire "$m"; then jg_lock_release "$m"; else cat "$m/pid" 2>/dev/null || echo '?'; return 0; fi
  done
  return 1
}
begin_move() {
  local held='' busy said='' deadline
  [ "$BASHPID" = "$$" ] || die "begin_move must run in the main process, before go_live is captured in a subshell"
  case " $LOCKS" in *" $STATE/.trunk-$PN.lock "*) held=1; unlock "$STATE/.trunk-$PN.lock" ;; esac
  lock "$STATE/.trunk-move-$PN.lock"
  deadline=$(( SECONDS + ${JG_TRUNK_MOVE_WAIT_MAX:-2700} ))
  while busy=$(running_gate); do
    [ -n "$said" ] || { echo "live: waiting: a landing's gate is running (pid $busy); the homes move when it ends, before the next gate starts"; said=1; }
    if [ "$SECONDS" -ge "$deadline" ]; then
      row trunk-live.tsv "$PN" "${1:-none}" "$(date +%s)" "hook-failed:a landing's gate still ran after ${JG_TRUNK_MOVE_WAIT_MAX:-2700}s; the homes stay where they were"
      echo "error: the move waited ${JG_TRUNK_MOVE_WAIT_MAX:-2700}s for a landing's gate and made no move; the next tick tries again" >&2; exit 3
    fi
    sleep 0.2
  done
  [ -z "$held" ] || { lock "$STATE/.trunk-$PN.lock"; tip_ok; }
  MOVE_HELD=1
}

# Move the home to <sha> through the project's live hook and record it. Exit 3 when the home did not move.
go_live() {  # <sha> <tip>   LIVE_FLEET=1 (cmd_live) moves every home; a pin-back moves this one
  local sha=$1 hook status=landed-not-live here there why hook_out hook_rc reason
  [ -n "${MOVE_HELD:-}" ] || begin_move "$sha"
  set -- "$sha" "$(rev "refs/heads/$TRUNK")"  # the tip as it stands once the gates have ended
  hook="$CONFIG/live-hook.$PN"
  if [ ! -x "$hook" ]; then
    here=$(git -C "$JG_ROOT" remote get-url origin 2>/dev/null || echo a); there=$(git -C "$PROJ" remote get-url origin 2>/dev/null || echo b)
    [ "$here" != "$there" ] || hook="$SCRIPT_DIR/jg-trunk-live-home.sh"
    [ "$here" != "$there" ] || [ -z "${LIVE_FLEET:-}" ] || hook=fleet
  fi
  if [ "$hook" = fleet ]; then
    if why=$(fleet_move "$sha" "$2" 2>&1); then status=live; else
      row trunk-live.tsv "$PN" "$sha" "$(date +%s)" "hook-failed:$(printf '%s' "$why" | tail -n 1 | cut -c1-200)"
      echo "error: the fleet move failed for ${sha:0:12}; see the rows in trunk-live.tsv" >&2
      printf '%s\n' "$why"; exit 3  # the move's own last line (the homes left behind) stays last: autolive reports it
    fi
    printf '%s\n' "$why"
    [ -z "${LIVE_HOME:-}" ] || status=canary
  elif [ -x "$hook" ]; then
    hook_out=$("$hook" "$PROJ" "$sha" 2>&1) && hook_rc=0 || hook_rc=$?
    [ -z "$hook_out" ] || printf '%s\n' "$hook_out" >&2
    if [ "$hook_rc" -ne 0 ]; then  # the hook's last line is its reason (bin/jg-trunk-live-home.sh)
      reason=$(printf '%s\n' "$hook_out" | tr '\t' ' ' | awk 'NF { l = $0 } END { print substr(l, 1, 200) }')
      row trunk-live.tsv "$PN" "$sha" "$(date +%s)" "hook-failed:${reason:-hook exited $hook_rc}"
      echo "error: live hook failed for ${sha:0:12}: ${reason:-hook exited $hook_rc}; the home stays where it was" >&2; exit 3
    fi
    status=live
  fi
  [ "$sha" = "$2" ] || status="$status,pinned-behind-${2:0:12}"
  [ -z "${LIVE_WAIVER:-}" ] || status="$status,waiver=$LIVE_WAIVER"
  row trunk-live.tsv "$PN" "$sha" "$(date +%s)" "$status"
  echo "live: $PN at ${sha:0:12} ($status)"
}

# Run the tip's own mover (an export of its bin/ and core/) over every home; its exit code and last line are the verdict.
# Only the tip's own copy is used: a pin-back or a pinned-behind move (sha != tip) runs this home's own mover.
fleet_move() {  # <sha> <tip>
  local sha=$1 tool="$STATE/trunk-live-tool/$1" tmp mover="$SCRIPT_DIR/jg-update.sh" paths args
  if [ "$sha" = "$2" ] && git -C "$PROJ" cat-file -e "$sha:bin/jg-update.sh" 2>/dev/null; then
    if [ ! -x "$tool/bin/jg-update.sh" ]; then
      mkdir -p "$STATE/trunk-live-tool"; tmp=$(mktemp -d "$STATE/trunk-live-tool/.export.XXXXXX") || die "cannot make the export directory"
      paths=$(git -C "$PROJ" ls-tree --name-only "$sha" bin core | paste -sd' ' -)
      # shellcheck disable=SC2086 # the paths are plain names, split on purpose
      git -C "$PROJ" archive "$sha" $paths | tar -x -C "$tmp" || die "cannot export ${sha:0:12} from $PROJ"
      rm -rf -- "$tool"; mv -- "$tmp" "$tool"
    fi
    find "$STATE/trunk-live-tool" -mindepth 1 -maxdepth 1 ! -name "$sha" -exec rm -rf -- {} +
    mover="$tool/bin/jg-update.sh"
  fi
  echo "live: moving every home with $mover"
  args=(--base "$sha" --project "$PROJ" --branch "$TRUNK")
  [ -z "${LIVE_HOME:-}" ] || args+=(--home "$LIVE_HOME")
  JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" JG_STATE_OVERRIDE="$STATE" JG_DATA_OVERRIDE="$DATA" "$mover" "${args[@]}"
}

waiver_rule() { jg_trunk_waiver_rule "$CONFIG/trunk-live-waiver" "$PN"; }
release_waiver_rule() { jg_trunk_waiver_rule "$CONFIG/trunk-release-waiver" "$PN"; }

# The batched live step, run on every tick of the landing check for a project with a go-live waiver. It moves every home to the
# green pin once the trunk has been quiet (no landing for live-quiet-minutes) or the oldest landing that is not live yet is
# live-cap-minutes old, whichever comes first, so landings never wait on a go-live and a busy trunk still goes live hourly.
# Prints one `autolive: ...` line last; exit 0 for live or waiting, 3 when the move failed.
cmd_autolive() {
  local green tip out rc now last quiet cap newest oldest wait_s failed_at
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never runs the live step"
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  LIVE_WAIVER=$(waiver_rule)
  [ -n "$LIVE_WAIVER" ] || { echo "autolive: not live: it needs the captain's word (no go-live waiver for $PN)"; return 0; }
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  if [ -z "$green" ]; then echo "autolive: waiting: no fully green trunk commit yet"; return 0
  elif awk -F'\t' -v p="$PN" -v g="$green" '$1 == p && $2 == g && $4 ~ /^live/ { f = 1 } END { exit !f }' "$DATA/trunk-live.tsv" 2>/dev/null; then
    echo "autolive: already live at ${green:0:12}"; return 0
  fi
  now=$(date +%s); quiet=$(( $(pol live-quiet-minutes) * 60 )); cap=$(( $(pol live-cap-minutes) * 60 ))
  # A move that failed (some home did not reach the pin) is tried again after the quiet window, not on every tick: each try writes a row per home.
  failed_at=$(awk -F'\t' -v p="$PN" -v g="$green" '$1 == p && $2 == g && $4 ~ /^hook-failed/ { t = $3 } END { print t + 0 }' "$DATA/trunk-live.tsv" 2>/dev/null || echo 0)
  if [ "$failed_at" -gt 0 ] && [ $(( now - failed_at )) -lt "$quiet" ]; then
    echo "autolive: waiting: the last move failed; the next try is in about $(( (quiet - (now - failed_at) + 59) / 60 )) min"; return 0
  fi
  last=$(awk -F'\t' -v p="$PN" '$1 == p && $4 ~ /^live/ && $3 > m { m = $3 } END { print m + 0 }' "$DATA/trunk-live.tsv" 2>/dev/null || echo 0)
  read -r newest oldest <<< "$(awk -F'\t' -v p="$PN" -v l="$last" '$2 == p && $4 >= l { if (!n || $4 > n) n = $4; if (!o || $4 < o) o = $4 } END { print n + 0, o + 0 }' "$DATA/trunk-landings.tsv" 2>/dev/null || echo "0 0")"
  [ "${newest:-0}" -gt 0 ] || { echo "autolive: waiting: nothing has landed since the last go-live"; return 0; }
  if [ $(( now - newest )) -lt "$quiet" ] && [ $(( now - oldest )) -lt "$cap" ]; then
    wait_s=$(( quiet - (now - newest) )); [ $(( cap - (now - oldest) )) -ge "$wait_s" ] || wait_s=$(( cap - (now - oldest) ))
    echo "autolive: waiting: live in about $(( (wait_s + 59) / 60 )) min (quiet $(( quiet / 60 )) min, cap $(( cap / 60 )) min)"; return 0
  fi
  LIVE_FLEET=1; begin_move "$green"  # in this process: the capture below is a subshell, which cannot let go of the trunk lock
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || echo "$green"); tip=$(rev "refs/heads/$TRUNK")  # as they stand once the gates have ended
  out=$(go_live "$green" "$tip" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then echo "autolive: NOT live, the move failed: $(printf '%s' "$out" | tail -n 1 | cut -c1-200)"; return "$rc"; fi
  echo "autolive: live at ${green:0:12} on every home ($(awk -F'\t' -v s="$green" '$2 == s && $4 ~ /^skipped/ { n++ } END { print n + 0 }' "$DATA/trunk-live.tsv" 2>/dev/null || echo 0) skipped, see data/trunk-live.tsv)"
}

cmd_live() {
  local green tip
  case ${2-} in '') ;; --home) LIVE_HOME=${3:?--home needs a lead home path} ;; *) die "usage: jg-trunk.sh live <project-dir> [--home <lead-home>]" ;; esac
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null) || refuse "no fully green trunk commit yet; the home stays where it is"
  LIVE_WAIVER=$(waiver_rule); LIVE_FLEET=1
  [ -n "$LIVE_WAIVER" ] || need_word live "$green"
  go_live "$green" "$tip"
  [ -n "$LIVE_WAIVER" ] || [ -n "${LIVE_HOME:-}" ] || spend_word live
}

# The captain waived his go-live word for one project until the stable point; only the Overwatch path records it.
cmd_waiver() {
  local rule=${3-} others wfile=trunk-live-waiver what="go-live"
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never writes a waiver"
  case "${4-}" in '') ;; '--release') wfile='trunk-release-waiver'; what="release-merge" ;; *) refuse "unknown waiver option '${4}'; the only one is --release" ;; esac
  [ "${2-}" = --rule ] && [ -n "$rule" ] || refuse "a $what waiver names the owner rule that grants it: jg-trunk.sh waiver <project-dir> --rule <owner-rule-id> [--release]"
  case $rule in owner-rule-[A-Za-z0-9]*) ;; *) refuse "'$rule' is not an owner rule id (owner-rule-<id>)" ;; esac
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"
  mkdir -p "$CONFIG"
  others=$(grep -v "^$PN " "$CONFIG/$wfile" 2>/dev/null || true)
  put "$CONFIG/$wfile" "${others:+$others$'\n'}$PN $rule $(date +%s) until=stable"
  echo "$what waiver recorded for $PN under $rule; delete its line in config/$wfile to restore the word"
}

cmd_flush() {
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never flushes the queue"
  open_project "${1-}"
  put "$STATE/trunk-flush-$PN" "$(date +%s)"
  echo "flush requested for $PN: the landing check lands every ready lane now, in batches of up to $(pol batch-max), on its next sweep"
}

cmd_land_next() {
  local id=${1-}
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never marks a lane to land next"
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ -f "$STATE/$id.meta" ] || die "usage: jg-trunk.sh land-next <task-id> (a task with a record in state/)"
  open_project "$(sed -n 's/^project=//p' "$STATE/$id.meta" | tail -n 1)"
  put "$STATE/$id.land-next" "$(date +%s)"
  echo "land-next recorded for $id: the landing check lands it at once, ahead of the queue"
}

cmd_word() {
  local kind=${1-} sha quote=${3-}
  case $kind in live|release) ;; *) die "usage: jg-trunk.sh word live|release <project-dir> \"<his words>\"" ;; esac
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never records the captain's word"
  [ -n "$quote" ] || refuse "the captain's own words are required"
  open_project "${2-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  if [ "$kind" = live ]; then sha=$(cat "$STATE/trunk-green-$PN"); else sha=$(release_commit); fi
  put "$STATE/trunk-word-$kind-$PN" "$(printf '%s\t%s\t%s' "$sha" "$(date +%s)" "$quote")"
  row trunk-words.tsv "$PN" "$kind" "$sha" "$(date +%s)" "$quote"
  echo "word recorded: $kind ${sha:0:12} in $PN"
}

# How the branch tip <have> relates to the record <want>: `forward` (the record is an ancestor), `on-default` (the tip is contained in
# origin/<default>), else `none`. Sets ADOPT_REL, ADOPT_LOST (landed commits the tip lacks: git cherry marks the carried ones) and
# ADOPT_LOST_N. `fetch` as the third argument first fetches that one default ref and refuses when the fetch fails.
adopt_facts() {  # <record> <tip> [fetch]
  local default
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  if [ "${3-}" = fetch ]; then
    git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" 2>/dev/null || refuse "cannot fetch origin/$default, so the tip cannot be compared with it"
  fi
  ADOPT_REL=none
  if git -C "$PROJ" merge-base --is-ancestor "$1" "$2" 2>/dev/null; then ADOPT_REL=forward
  elif git -C "$PROJ" rev-parse --verify --quiet "refs/remotes/origin/$default^{commit}" >/dev/null \
       && git -C "$PROJ" merge-base --is-ancestor "$2" "refs/remotes/origin/$default"; then ADOPT_REL=on-default; fi
  ADOPT_LOST=$(git -C "$PROJ" rev-list --right-only --cherry-mark "$2...$1" 2>/dev/null | sed -n 's/^+//p' \
    | while IFS= read -r c; do git -C "$PROJ" log -1 --format='%h %s' "$c"; done)
  ADOPT_LOST_N=$(printf '%s' "$ADOPT_LOST" | grep -c . || true)
}

# Report divergent recorded and actual tips without modifying the project. Prepare retains both parents in a new
# task branch; land accepts only that exact merge with its complete head-bound proof and an unchanged record and ref.
cmd_recover() {
  local dir=${1-} action=${2-} id=${3-} pin actual tree branch merge meta gaps parents released linked hit rc=0
  [ "$#" -eq 1 ] || [ "$#" -eq 3 ] || die "usage: recover <project-dir> [--prepare <task-id>|--land <task-id>]"
  case "$action" in ''|--prepare|--land) ;; *) die "unknown recover action: $action" ;; esac
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never recovers a trunk"
  open_project "$dir" read-only
  [ -z "$action" ] || lock "$STATE/.trunk-$PN.lock"
  pin=$(cat "$STATE/trunk-tip-$PN" 2>/dev/null) || refuse "no recorded trunk tip"
  pin=$(rev "$pin") || refuse "recorded trunk tip is not a commit"
  actual=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing"
  printf 'recorded: %s\nactual: %s\n' "$pin" "$actual"
  [ -n "$action" ] || return 0
  jg_pr_task_id_valid "$id" || die "invalid task id"
  branch="fm/$id"
  if [ "$action" = --prepare ]; then
    [ "$pin" != "$actual" ] || refuse "recorded and actual tips already agree"
    ! git -C "$PROJ" merge-base --is-ancestor "$pin" "$actual" || refuse "recorded tip is already on the trunk"
    ! git -C "$PROJ" merge-base --is-ancestor "$actual" "$pin" || refuse "actual tip is a rewind, not divergence"
    tree=$(git -C "$PROJ" merge-tree --write-tree "$actual" "$pin") || refuse "tips do not merge cleanly; no branch was created"
    merge=$(git -C "$PROJ" commit-tree "$tree" -p "$actual" -p "$pin" -m "$id: recover divergent trunk") || die "cannot create recovery merge"
    git -C "$PROJ" update-ref "refs/heads/$branch" "$merge" "" || refuse "recovery branch $branch already exists"
    echo "prepared: $branch $merge; prove this exact head before landing"
    return
  fi
  meta=$STATE/$id.meta; [ -f "$meta" ] || refuse "no task record for $id"
  [ "$(jg_dod_meta_value "$meta" project)" = "$PROJ" ] || refuse "task project does not match"
  branch=$(jg_dod_meta_value "$meta" branch); branch=${branch:-fm/$id}
  merge=$(rev "refs/heads/$branch") || refuse "recovery branch is missing"
  parents=$(git -C "$PROJ" rev-list --parents -n 1 "$merge")
  [ "$parents" = "$merge $actual $pin" ] || refuse "recovery merge parents do not match the current actual and recorded tips"
  tree=$(git -C "$PROJ" merge-tree --write-tree "$actual" "$pin") || refuse "tips do not merge cleanly"
  [ "$(git -C "$PROJ" rev-parse "$merge^{tree}")" = "$tree" ] || refuse "recovery tree is not the merge of both tips"
  released=$(cat "$STATE/trunk-released-$PN" 2>/dev/null || true)
  [ -z "$released" ] || git -C "$PROJ" merge-base --is-ancestor "$released" "$merge" || refuse "recovery does not retain the release"
  gaps=$(jg_dod_trunk_proof_gaps "$JG_HOME" "$STATE" "$id" "$meta" "$merge") || refuse "recovery proof is incomplete: $(printf '%s' "$gaps" | tr '\n' ';')"
  if hit=$(touches_protected "$actual" "$merge") && [ "$(pol protected-landing)" = refuse ]; then
    refuse "$hit is a protected path; recovery requires approval of protected-landing=gate"
  fi
  linked=$(JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-captain-hold.sh" blocking "$id") || rc=$?
  case $rc in
    0) refuse "task $id has an open linked decision: $linked" ;;
    1) ;;
    *) refuse "could not read linked decisions for $id" ;;
  esac
  jg_dod_local_landing_gates "$SCRIPT_DIR" "$CONFIG" "$JG_HOME" "$STATE" "$id" "$meta" "$PROJ" "$actual" "$merge" trunk || refuse "recovery landing gates refused"
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$merge" "$TRUNK" "$actual" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused recovery"
  ensure_guard
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: recover $id" "refs/heads/$TRUNK" "$merge" "$actual" || refuse "trunk changed during recovery"
  put "$STATE/trunk-tip-$PN" "$merge"
  row trunk-landings.tsv "$id" "$PN" "$merge" "$(date +%s)" recovery
  echo "recovered $TRUNK at $merge; not live"
}

# The one command that ends a trunk the lander did not leave (tip_ok); Overwatch only.
cmd_adopt_tip() {
  local dir=${1-} reason='' carried='' want have epoch keep lane meta branch head red released green
  [ -n "$dir" ] || die "usage: jg-trunk.sh adopt-tip <project-dir> --reason <text> [--carried-by <task-id>]"
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --reason) [ "$#" -ge 2 ] || die "--reason takes a text"; reason=$2; shift 2 ;;
      --carried-by) [ "$#" -ge 2 ] || die "--carried-by takes a task id"; carried=$2; shift 2 ;;
      *) die "adopt-tip takes only --reason and --carried-by; no force or skip flag exists" ;;
    esac
  done
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never adopts a trunk tip"
  [ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ] || refuse "a reason is required: say what moved the trunk"
  open_project "$dir"; lock "$STATE/.trunk-$PN.lock"
  want=$(cat "$STATE/trunk-tip-$PN" 2>/dev/null) || refuse "no trunk for $PN; run: jg-trunk.sh init $PROJ"
  have=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  [ "$want" != "$have" ] || { echo "$TRUNK in $PN is at ${have:0:12}, where the lander left it; nothing to adopt"; return 0; }
  adopt_facts "$want" "$have" fetch
  [ "$ADOPT_REL" != none ] || refuse "$TRUNK is at ${have:0:12}, which does not hold the recorded tip ${want:0:12} and is not on origin's default branch; the move is not explained, so it is not adopted"
  if [ -n "$carried" ]; then
    jg_pr_task_id_valid "$carried" || die "invalid task id for --carried-by"
    meta=$STATE/$carried.meta; [ -f "$meta" ] || refuse "--carried-by $carried has no task record at $meta"
    branch=$(jg_dod_meta_value "$meta" branch); branch=${branch:-fm/$carried}
    head=$(rev "refs/heads/$branch") || refuse "--carried-by $carried: branch $branch does not exist in $PROJ"
    [ "$(git -C "$PROJ" rev-list --count "$have..$head")" = 1 ] && [ "$(git -C "$PROJ" rev-parse "$head^")" = "$have" ] \
      || refuse "--carried-by $carried: $branch must be exactly one commit on $TRUNK at ${have:0:12}"
    lane=$(git -C "$PROJ" merge-tree --write-tree "$want" "$have" 2>/dev/null) || refuse "--carried-by $carried: the recorded tip ${want:0:12} and $TRUNK do not merge cleanly, so no lane can carry the difference"
    [ "$(git -C "$PROJ" rev-parse "$head^{tree}")" = "$lane" ] || refuse "--carried-by $carried: the tree of $branch is not the merge of the recorded tip ${want:0:12} and $TRUNK, so it does not carry the lost commits"
  fi
  if [ "$ADOPT_LOST_N" -gt 0 ] && [ -z "$carried" ]; then
    refuse "adopting ${have:0:12} would leave $ADOPT_LOST_N landed commit(s) off $TRUNK; carry them in a lane and adopt with --carried-by <task-id>:
$ADOPT_LOST"
  fi
  released=$(cat "$STATE/trunk-released-$PN" 2>/dev/null || true)
  [ -z "$released" ] || git -C "$PROJ" merge-base --is-ancestor "$released" "$have" 2>/dev/null \
    || refuse "the released commit ${released:0:12} is not an ancestor of $TRUNK at ${have:0:12}; a trunk that lost its release is not adopted"
  epoch=$(date +%s); keep="refs/jg/trunk-adopted/$TRUNK/$epoch"
  git -C "$PROJ" update-ref "$keep" "$want" || die "cannot write the keep ref $keep"
  put "$STATE/trunk-tip-$PN" "$have"
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  if [ "$ADOPT_REL" = on-default ] && { [ -z "$green" ] || ! git -C "$PROJ" merge-base --is-ancestor "$green" "$have" 2>/dev/null; }; then put "$STATE/trunk-green-$PN" "$have"; fi
  red=''
  if [ -f "$STATE/trunk-red-$PN" ]; then
    red=$(cat "$STATE/trunk-red-$PN"); git -C "$PROJ" merge-base --is-ancestor "$red" "$have" 2>/dev/null || { rm -f -- "$STATE/trunk-red-$PN"; red="red-removed=$red"; }
    case $red in red-removed=*) ;; *) red='' ;; esac
  fi
  row trunk-adoptions.tsv "$PN" "$want" "$have" "$epoch" "$ADOPT_REL" "$ADOPT_LOST_N" "${carried:--}" "$(printf '%s' "$reason" | tr '\t\n' '  ')" ${red:+"$red"}
  echo "adopted: $TRUNK in $PN is at ${have:0:12} (was recorded at ${want:0:12}; relation $ADOPT_REL, $ADOPT_LOST_N lost; the old record is kept at $keep)"
}

# The newest earlier commit that went live and was not red; the last release when none did.
last_green_before() {  # <red sha>
  local c
  while IFS= read -r c; do
    [ "$c" != "$1" ] || continue
    grep -Eq "^$PN	$c	[0-9]+	red(	|$)" "$DATA/trunk-ci.tsv" 2>/dev/null && continue
    git -C "$PROJ" merge-base --is-ancestor "$c" "$1" 2>/dev/null || continue
    echo "$c"; return 0
  done < <(awk -F'\t' -v p="$PN" '$1 == p && $4 ~ /^live/ { print $2 }' "$DATA/trunk-live.tsv" 2>/dev/null | tac)
  cat "$STATE/trunk-released-$PN"
}

cmd_ci() {
  local sha tip back
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  sha=$(rev "${2-}") || die "'${2-}' does not resolve in $PROJ"
  git -C "$PROJ" merge-base --is-ancestor "$sha" "$tip" || refuse "${sha:0:12} is not on $TRUNK"
  case ${3-} in
    green)
      row trunk-ci.tsv "$PN" "$sha" "$(date +%s)" green
      git -C "$PROJ" merge-base --is-ancestor "$(cat "$STATE/trunk-green-$PN")" "$sha" && put "$STATE/trunk-green-$PN" "$sha"
      echo "ci green at ${sha:0:12}" ;;
    red)
      row trunk-ci.tsv "$PN" "$sha" "$(date +%s)" red
      back=$(last_green_before "$sha")
      put "$STATE/trunk-green-$PN" "$back"
      echo "ci RED at ${sha:0:12}; pinning the green pin and the home back to ${back:0:12}; landings go on" >&2
      LIVE_FLEET=1; go_live "$back" "$tip" ;;
    *) die "usage: jg-trunk.sh ci <project-dir> <sha> green|red" ;;
  esac
}

# The release PR of the last release, and whether it has merged. The trunk stays untouched until it has.
# A row holds one URL; a row written before that holds the create call's whole answer over several lines, and the URL is read out of it.
last_release_url() {
  awk -F'\t' -v p="$PN" 'NF >= 6 { mine = ($1 == p); if (mine) r = $6; next } mine { r = r "\n" $0 } END { print r }' \
    "$DATA/trunk-releases.tsv" 2>/dev/null | pr_urls | head -1
}
pr_urls() { { grep -Eo 'https?://[^"[:space:],]+/pull/[0-9]+' || true; } | awk '!seen[$0]++'; }  # stdin: each PR URL once, in order
pr_state() {  # <url>: open|merged|closed|unknown
  local st
  jg_pr_url_parse "$1" && [ "$JG_PR_PROVIDER" = github ] || { printf 'unknown\n'; return; }
  st=$( (cd "$PROJ" && gh-axi pr view "$JG_PR_NUMBER" --repo "$JG_PR_PATH") | awk '$1 == "state:" { print tolower($2); exit }')
  printf '%s\n' "${st:-unknown}"
}

# The landed commits the release did not ship, replayed onto <base> (the default branch once the release merged): every
# commit of this trunk above the commit its release shipped that <base> does not already hold by patch, oldest first, each
# made by rebase_commit and proved to have the tree of its original. It writes objects only and moves no ref; any doubt
# stops with one line, so a rollover either carries every landed commit or changes nothing. Sets CARRY_TIP (the commit the
# next trunk starts at: the last replayed commit, or <base> when nothing is above the release) and CARRY_MAP (one line
# "<old commit> <its commit on the next trunk>" for every commit above the release, a commit <base> already holds mapping
# to the commit before it), which the green pin follows.
carry_over() {  # <base>
  local tip rel mark c new
  tip=$(rev "refs/heads/$TRUNK") || refuse "the trunk branch $TRUNK is missing in $PROJ; no next trunk is cut"
  rel=$(awk -F'\t' -v p="$PN" -v b="$TRUNK" '$1 == p && $2 == b { t = $3 } END { print t }' "$DATA/trunk-releases.tsv" 2>/dev/null || true)
  [ -n "$rel" ] || refuse "no release of $TRUNK is recorded, so no one knows which of its commits are on the default branch; no next trunk is cut"
  git -C "$PROJ" merge-base --is-ancestor "$rel" "$tip" 2>/dev/null || refuse "the release ${rel:0:12} is not on $TRUNK (${tip:0:12}); no next trunk is cut"
  [ -z "$(git -C "$PROJ" rev-list --merges -n 1 "$rel..$tip")" ] || refuse "$TRUNK holds a merge commit above its release ${rel:0:12}, which cannot be replayed; no next trunk is cut"
  CARRY_TIP=$1; CARRY_MAP=
  while read -r mark c; do
    if [ "$mark" = + ]; then
      new=$(rebase_commit "$CARRY_TIP" "$c") && [ -n "$new" ] || refuse "cannot replay ${c:0:12} onto ${1:0:12}: it does not merge cleanly; $TRUNK is kept and no next trunk is cut"
      [ "$(git -C "$PROJ" rev-parse "$new^{tree}")" = "$(git -C "$PROJ" rev-parse "$c^{tree}")" ] \
        || refuse "the replay of ${c:0:12} has another tree than the original (the default branch holds more than the release did); $TRUNK is kept and no next trunk is cut"
      CARRY_TIP=$new
    fi
    CARRY_MAP+="$c $CARRY_TIP"$'\n'
  done < <(git -C "$PROJ" cherry "$1" "$tip" "$rel")
}

# Once the release PR has merged, the NEXT trunk version is cut from the default branch and the project moves onto
# it: <trunk>-v2, -v3, ... Every commit that landed on the old trunk after the release is replayed onto it first (carry_over),
# and the green pin follows its commit. The old trunk is left exactly as it was. Returns 1, changing nothing, while the PR is not merged.
rollover_if_merged() {
  local url ver new base default green
  url=$(last_release_url); [ -n "$url" ] || { ROLLOVER_SKIP="no release is recorded"; return 1; }
  [ "$(cat "$STATE/trunk-rolled-$PN" 2>/dev/null)" != "$url" ] || { ROLLOVER_SKIP="release $url was already rolled over"; return 1; }
  [ "$(pr_state "$url")" = merged ] || { ROLLOVER_SKIP="release $url is not merged"; return 1; }
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" || die "cannot fetch origin/$default to cut the next trunk"
  base=$(rev "refs/remotes/origin/$default") || die "origin/$default is not a commit"
  ver=$(( $(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1) + 1 )); new="$(pol trunk-branch)-v$ver"
  rev "refs/heads/$new" >/dev/null && die "$new already exists in $PROJ; the next trunk is never overwritten"
  carry_over "$base"
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true); green=$(awk -v g="$green" '$1 == g { print $2 }' <<<"$CARRY_MAP")
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: version $ver after $url" "refs/heads/$new" "$CARRY_TIP" ""
  put "$STATE/trunk-tip-$PN" "$CARRY_TIP"; put "$STATE/trunk-green-$PN" "${green:-$base}"; put "$STATE/trunk-released-$PN" "$base"
  put "$STATE/trunk-branch-$PN" "$new"; put "$STATE/trunk-version-$PN" "$ver"; put "$STATE/trunk-rolled-$PN" "$url"
  row trunk-versions.tsv "$PN" "$ver" "$new" "$base" "$(date +%s)"
  echo "release merged: the project is now on $new (version $ver) at $CARRY_TIP, cut from $default at $base"
  [ "$CARRY_TIP" = "$base" ] || echo "carried: $(git -C "$PROJ" rev-list --count "$base..$CARRY_TIP") landed commit(s) of $TRUNK above the release replayed onto $new with equal trees; the green pin is $(cut -c1-12 <<<"${green:-$base}")"
  local old=$TRUNK; TRUNK=$new
  echo "$old is cleaned up only when its work is proved on $default and carried into $new"
  retire_old
}

# Every commit of <old> is in <target>: by ancestry, or by patch when the release was squashed or the fix was cherry-picked.
carried() {  # <old> <target>
  git -C "$PROJ" merge-base --is-ancestor "$1" "$2" 2>/dev/null && return 0
  ! git -C "$PROJ" cherry "$2" "$1" 2>/dev/null | grep -q '^+'
}

# After a release merged and the next trunk was cut, clean the OLD trunk up: delete its remote branch, its local
# branch and any worktree on it. UNFORCED (no --force, no -D, a compare-and-swap ref delete), and only when its
# release is proved on the default branch (the tip it released is in it, by ancestry or by patch) AND every commit
# on it - every hotfix - is carried into the current trunk. A copy holding unlanded work (an uncommitted worktree, the project checkout itself, a tip not carried) is
# kept and listed, never deleted. Idempotent: it prints nothing when no old trunk is left.
retire_old() {
  local cur default main new v b lsha rsha tip wt kept blocked sha out
  cur=$(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1); [ "$cur" -gt 1 ] || return 0
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" || { echo "cannot fetch origin/$default; the old trunk is kept"; return 0; }
  main=$(rev "refs/remotes/origin/$default") || return 0; new=$(rev "refs/heads/$TRUNK") || return 0
  while IFS=$'\t' read -r v b; do
    [ -n "$b" ] && [ "$v" -lt "$cur" ] && [ "$b" != "$TRUNK" ] || continue
    lsha=$(rev "refs/heads/$b" || true); rsha=$(git -C "$PROJ" ls-remote --heads origin "refs/heads/$b" 2>/dev/null | cut -f1)
    [ -n "$lsha$rsha" ] || continue
    blocked=; rel=$(awk -F'\t' -v p="$PN" -v b="$b" '$1 == p && $2 == b { t = $3 } END { print t }' "$DATA/trunk-releases.tsv" 2>/dev/null || true)
    if [ -z "$rel" ]; then blocked="no release of $b is recorded"
    elif ! carried "$rel" "$main"; then blocked="its release ${rel:0:12} is not proved on origin/$default"; fi
    for tip in $lsha $rsha; do
      [ -z "$blocked" ] || break
      git -C "$PROJ" cat-file -e "$tip^{commit}" 2>/dev/null || git -C "$PROJ" fetch -q origin "refs/heads/$b" 2>/dev/null </dev/null || true
      git -C "$PROJ" cat-file -e "$tip^{commit}" 2>/dev/null || { blocked="the tip ${tip:0:12} cannot be read"; break; }
      if ! carried "$tip" "$new"; then
        out=$(git -C "$PROJ" cherry "$new" "$tip" | sed -n 's/^+ //p' | while read -r sha; do git -C "$PROJ" log -1 --format='%h %s' "$sha"; done | paste -sd';' -)
        blocked="hotfix not carried into $TRUNK: $out"; break
      fi
    done
    if [ -n "$blocked" ]; then echo "kept $b: $blocked"; continue; fi
    kept=
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then echo "kept worktree $wt: it holds uncommitted work on $b"; kept=1
      elif [ "$(realpath "$wt")" = "$(realpath "$PROJ")" ]; then echo "kept $PROJ: the project checkout itself is on $b"; kept=1
      elif git -C "$PROJ" worktree remove "$wt" 2>/dev/null </dev/null; then echo "removed worktree $wt"
      else echo "kept worktree $wt: it could not be removed without force"; kept=1; fi
    done < <(git -C "$PROJ" worktree list --porcelain | awk -v b="refs/heads/$b" '/^worktree /{w=substr($0,10)} $0=="branch " b {print w}')
    if [ -n "$rsha" ]; then
      git -C "$PROJ" push -q origin --delete "$b" 2>/dev/null </dev/null && echo "deleted remote $b" || echo "kept remote $b: the delete was refused"
    fi
    if [ -n "$lsha" ] && [ -z "$kept" ]; then
      JG_TRUNK_RETIRE="refs/heads/$b" git -C "$PROJ" update-ref -d "refs/heads/$b" "$lsha" && echo "deleted local $b" || echo "kept local $b: the delete was refused"
    elif [ -n "$lsha" ]; then echo "kept local $b: a copy of it holds unlanded work"; fi
    [ -n "$kept" ] || row trunk-retired.tsv "$PN" "$b" "$(date +%s)"
  done < <(awk -F'\t' -v p="$PN" '$1 == p { print $2 "\t" $3 }' "$DATA/trunk-versions.tsv" 2>/dev/null)
}

cmd_retire() {
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  retire_old
}

cmd_rollover() {
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  rollover_if_merged || refuse "rollover skipped: ${ROLLOVER_SKIP:-no merged release}; $TRUNK stays as it is"
}

# Sets REL_URL to the release PR of the trunk into <default>: the one URL the create call answers. When the create call
# fails or names no one URL, the release is the one open PR whose head is the trunk and whose base is <default>; with
# none the release stops as before, and with more than one it stops and names them all rather than pick one.
open_release_pr() {  # <default> <title> <body-file>
  local out urls
  if out=$(cd "$PROJ" && gh-axi pr create --base "$1" --head "$TRUNK" --title "$2" --body-file "$3"); then
    urls=$(pr_urls <<<"$out")
    [ "$(grep -c . <<<"$urls")" != 1 ] || { REL_URL=$urls; return 0; }
  fi
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  urls=$( (cd "$PROJ" && gh-axi pr list --state open --head "$TRUNK" --base "$1" --fields url) | pr_urls)
  case $(grep -c . <<<"$urls") in
    1) REL_URL=$urls ;;
    0) die "$TRUNK is pushed but the release PR was not opened; run release again" ;;
    *) die "$TRUNK is pushed and more than one open PR goes from $TRUNK into $1, so none is taken as the release: $(paste -sd' ' <<<"$urls")" ;;
  esac
}

# The release PR's owning task record, state/release-<project>-<trunk>.meta: the guarded merge path (bin/jg-pr-check.sh,
# bin/jg-pr-merge.sh) records, watches and merges a PR only under a task, and bin/jg-version-branch-lib.sh
# jg_is_release_head admits this trunk as the head of the one PR allowed into the default branch. No worker owns the
# release, so the record names no window, worktree or branch, and cleanup touches only the record. yolo=off stays, so
# merge-on-green merges the release only on the captain's standing word: under config/trunk-release-waiver the record
# carries `merge=approved` and `merge_rule=<owner rule>` (release_merge_authority), and without that line its merge is an
# explicit bin/jg-pr-merge.sh <id> <url>. A record already there is kept, and the PR is recorded and armed through
# jg-pr-check.sh unless the record already names this PR at this head.
record_release_task() {  # <url> [<head>]
  local id=release-$PN-$TRUNK meta proj
  jg_pr_task_id_valid "$id" || die "the release task id '$id' is not a valid task id; the release PR $1 is open but has no task record"
  meta=$STATE/$id.meta
  if [ ! -e "$meta" ]; then
    proj=$(cd "$PROJ" && pwd -P)
    (umask 077; printf 'kind=release\nproject=%s\nmode=local-trunk\nyolo=off\n' "$proj" > "$meta.tmp.$$") && mv -f "$meta.tmp.$$" "$meta"
  fi
  release_merge_authority "$meta"
  if [ "$(jg_dod_meta_value "$meta" pr)" = "$1" ] && { [ -z "${2-}" ] || [ "$(jg_dod_meta_value "$meta" pr_head)" = "$2" ]; }; then return 0; fi
  JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-pr-check.sh" "$id" "$1" >&2 \
    || die "the release PR $1 is open but its task $id was not recorded; fix the cause above, then run bin/jg-pr-check.sh $id $1"
  # jg-pr-check reads a head only from a worktree, and a release has none: the head this release pushed is the PR's head.
  if [ -n "${2-}" ]; then sed -i '/^pr_head=/d' "$meta"; printf 'pr_head=%s\n' "$2" >> "$meta"; fi
  echo "release task: $id owns the release PR"
}

# The merge authority of the release record: the captain's standing release word (config/trunk-release-waiver) writes
# `merge=approved` and the rule it comes from; with no such rule the lines are removed, so a record never outlives the word.
release_merge_authority() {  # <meta>
  local rule; rule=$(release_waiver_rule)
  sed -i -e '/^merge=approved$/d' -e '/^merge_rule=/d' "$1"
  [ -z "$rule" ] || printf 'merge=approved\nmerge_rule=%s\n' "$rule" >> "$1"
}

# The commit a release carries and the captain's release word names: the green pin (state/trunk-green-<project>), never the
# tip. A landing moves the pin, so the two differ only while a red found after a landing holds the pin below it; the
# commits after the pin stay on the trunk for the next release.
release_commit() {
  local green
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  [ -n "$green" ] || refuse "no green commit of $TRUNK is recorded yet; the next landing records one"
  git -C "$PROJ" merge-base --is-ancestor "$green" "refs/heads/$TRUNK" || refuse "the green commit ${green:0:12} is not on $TRUNK"
  printf '%s\n' "$green"
}

# A release that is already pushed (the last release row names the commit now released) whose record is missing: write the
# record and arm the check from the row's URL, with no push. A record of another kind under the id is refused, naming it;
# a record of kind release is kept (record_release_task only arms it when it does not name the PR yet). Returns 1 with no
# output when the last release row is not for this commit, so the caller says "nothing to release" as before.
adopt_pushed_release() {  # <commit>
  local url meta=$STATE/release-$PN-$TRUNK.meta kind
  [ "$(awk -F'\t' -v p="$PN" -v t="$TRUNK" 'NF >= 6 && $1 == p { c = ($2 == t ? $3 : "") } END { print c }' "$DATA/trunk-releases.tsv" 2>/dev/null)" = "$1" ] || return 1
  url=$(last_release_url); [ -n "$url" ] || return 1
  if [ -e "$meta" ]; then
    kind=$(jg_dod_meta_value "$meta" kind)
    [ "$kind" = release ] || refuse "the record ${meta##*/} is kind=${kind:-unset}, not kind=release, so the pushed release $url has no record; end that record first"
  fi
  record_release_task "$url" >&2
  REL_URL=$url
  echo "release already pushed: $url; resuming its proof, nothing pushed"
}

cmd_release() {
  local rel base n default body url prev waiting
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  rollover_if_merged || true
  rel=$(release_commit)
  base=$(cat "$STATE/trunk-released-$PN"); n=$(git -C "$PROJ" rev-list --count "$base..$rel")
  if [ "$n" -eq 0 ]; then
    if [ "$(cat "$STATE/trunk-release-pending-$PN" 2>/dev/null || true)" = "$rel" ]; then
      [ "$(cut -f1 "$STATE/trunk-word-release-$PN" 2>/dev/null || true)" != "$rel" ] || spend_word release
      rm -f -- "$STATE/trunk-release-pending-$PN"
    fi
    adopt_pushed_release "$rel" || refuse "nothing to release: $TRUNK has no commits since the last release"
    url=$REL_URL
    [ "$(pr_state "$url")" = open ] || refuse "the release PR $url is not open"
    base=$(release_base "$rel") || refuse "cannot find the release base for ${rel:0:12}"
    unlock "$STATE/.trunk-$PN.lock"
    "$SCRIPT_DIR/jg-trunk-release-proof.sh" "$PROJ" "$TRUNK" "$base" "$rel" "$url"
    return
  fi
  need_word release "$rel"
  prev=$(last_release_url)
  if [ -n "$prev" ] && [ -n "$(release_waiver_rule)" ] && [ "$(pr_state "$prev")" = open ]; then
    # The standing word merges a green release by itself: a push would restart its checks and move its head.
    waiting=$(JG_HOME=$JG_HOME "$SCRIPT_DIR/jg-pr-state.sh" --all "$prev") || refuse "cannot read the checks of the open release PR $prev; nothing is pushed into it"
    [ -n "$waiting" ] || refuse "the release PR $prev is green and merges on the captain's standing word; nothing is pushed into it, and the later commits go out in the release after it"
  fi
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$rel" "$TRUNK" "$base" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused the batch"
  git -C "$PROJ" push -q origin "$rel:refs/heads/$TRUNK" || die "push of $TRUNK failed (never forced)"
  # The release PR is the trunk itself going into the default branch: no release branch, one PR.
  # While the last release PR is still open, the push above already carried the new commits into it.
  if [ -n "$prev" ] && [ "$(pr_state "$prev")" = open ]; then
    url=$prev
  else
    body=$(mktemp); WORK=$body
    { echo "Release batch from the local $TRUNK: $n commits, one per ticket."; echo
      git -C "$PROJ" log --reverse --format='- %h %s' "$base..$rel"; } > "$body"
    open_release_pr "$default" "Release: $n tickets from the local $TRUNK" "$body"; url=$REL_URL
  fi
  put "$STATE/trunk-release-pending-$PN" "$rel"
  if ! awk -F '\t' -v p="$PN" -v t="$TRUNK" -v h="$rel" -v u="$url" '$1 == p && $2 == t && $3 == h && $6 == u { found=1 } END { exit !found }' "$DATA/trunk-releases.tsv" 2>/dev/null; then
    row trunk-releases.tsv "$PN" "$TRUNK" "$rel" "$n" "$(date +%s)" "$url"
  fi
  put "$STATE/trunk-released-$PN" "$rel"; spend_word release
  rm -f -- "$STATE/trunk-release-pending-$PN"
  echo "released $n commits from $TRUNK: $url"
  record_release_task "$url" "$rel"
  base=$(release_base "$rel") || refuse "cannot find the release base for ${rel:0:12}"
  unlock "$STATE/.trunk-$PN.lock"
  "$SCRIPT_DIR/jg-trunk-release-proof.sh" "$PROJ" "$TRUNK" "$base" "$rel" "$url"
}

# Reconcile an idle trunk from the landing check, under the same lock as a landing.
cmd_reconcile() {
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_adopt_forward; tip_ok
}

# The landing check's cheap pre-test: prints what proof the task's branch head still lacks, exit 1 when any, before a landing is started.
cmd_proof() {
  local id=${1:-} meta branch head gaps
  jg_pr_task_id_valid "$id" || die "invalid task id"
  meta=$STATE/$id.meta; [ -f "$meta" ] || die "no meta for task $id at $meta"
  branch=$(jg_dod_meta_value "$meta" branch); branch=${branch:-fm/$id}
  head=$(git -C "$(jg_dod_meta_value "$meta" project)" rev-parse --verify "refs/heads/$branch^{commit}") || die "branch $branch does not exist"
  gaps=$(jg_dod_trunk_proof_gaps "$JG_HOME" "$STATE" "$id" "$meta" "$head") || { printf '%s\n' "$gaps"; return 1; }
}

cmd_due() {
  local first
  open_project "${1-}"; tip_ok
  first=$(git -C "$PROJ" log --reverse --format=%ct "$(cat "$STATE/trunk-released-$PN")..refs/heads/$TRUNK" | head -1)
  [ -n "$first" ] && [ $(( $(date +%s) - first )) -ge $(( $(pol release-after-hours) * 3600 )) ]
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  land) shift; cmd_land "$@" ;;
  land-batch) shift; cmd_land_batch "$@" ;;
  flush) shift; cmd_flush "$@" ;;
  land-next) shift; cmd_land_next "$@" ;;
  classify) shift; [ "$#" -ge 1 ] && [ -f "$1" ] || die "classify takes an output file and, after it, any gate logs"; classify_refusal "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  green-alarm) shift; cmd_green_alarm "$@" ;;
  proof) shift; cmd_proof "$@" ;;
  word) shift; cmd_word "$@" ;;
  adopt-tip) shift; cmd_adopt_tip "$@" ;;
  recover) shift; cmd_recover "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  live) shift; cmd_live "$@" ;;
  autolive) shift; cmd_autolive "$@" ;;
  waiver) shift; cmd_waiver "$@" ;;
  ci) shift; cmd_ci "$@" ;;
  rollover) shift; cmd_rollover "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  release) shift; cmd_release "$@" ;;
  due) shift; cmd_due "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
