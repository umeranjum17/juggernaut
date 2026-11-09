#!/usr/bin/env bash
# The local trunk flow: one proved commit per ticket lands on a local trunk branch and is
# live at once, and the accumulated trunk goes out in one batch release.
#
# Usage: jg-trunk.sh init <project-dir> [<base-ref>]   create the trunk (default: the newest release/c-N, else HEAD)
#        jg-trunk.sh proof <task-id>                   print the proof inputs the task's head still lacks (receipt, merge-card evidence, sealed run); exit 1 when any
#        jg-trunk.sh land <task-id>                    land the task's one proved commit on the trunk; never goes live
#        jg-trunk.sh land-batch <id>[@<head>]...       land 2 to batch-max queued lanes as one stack: one gate over their changed files, one move; a red stack is halved to find and return only the lane that caused it
#        jg-trunk.sh flush <project-dir>               Overwatch only: land every ready lane of the project now, in batches, whatever the threshold says
#        jg-trunk.sh land-next <task-id>               Overwatch only: mark one ready lane so the landing check lands it at once, ahead of the queue
#        jg-trunk.sh verify <project-dir> [<sha>]      run the whole suite at a landed commit (default: the tip), one verify at a time and the newest wins: green moves the pin, a red it caused reverts it
#        jg-trunk.sh word live|release <project-dir> "<his words>"   record the captain's word for the commit that would go live or out
#        jg-trunk.sh live <project-dir> [--home <lead-home>]   move every home to the last fully green commit; refuses without his word (or a waiver); --home moves one lead only
#        jg-trunk.sh autolive <project-dir>            the batched live step: under a waiver, move every home to the green pin once the trunk is quiet or the hourly cap is due
#        jg-trunk.sh waiver <project-dir> --rule <owner-rule-id>   Overwatch only: the captain waived his word for this project's live until the stable point
#        jg-trunk.sh ci <project-dir> <sha> green|red  record the CI result for a live commit; red pins the home back to the last green one
#        jg-trunk.sh release <project-dir>             push the trunk and open the ONE release PR trunk -> default branch; refuses without his word
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
# runs the changed files' tests (gate-full) judged against the trunk tip's own result, and lands. Only a conflict in the lane's
# own change stops it, and the refusal names the paths. The captain hold, the design, demo and nav gates, the ticket reference,
# the linked-decision block, a red trunk and owner-guard still apply. A landing starts only on a head whose whole proof is there
# (jg_dod_trunk_proof_gaps in bin/jg-merge-gate-lib.sh, the same check the worker's done runs): a PASS completion receipt, approved
# merge-card evidence citing files, and a sealed done-done run holding them, all at the lane's own head. A missing input refuses
# before anything starts and is named; `proof <task-id>` prints them. The owner signature never refuses a landing: it is
# recorded after it (data/trunk-landing-proofs.tsv), absent when missing. That row also keeps the gate's figures (gate=ran:<scripts>,
# failed:<on the first run>,secs:<whole gate>; absent when no gate ran), which the landing's Evidence card (core/landing-card) prints.
#
# The changed-files gate charges a lane only for what it broke. When it fails, the lander first reruns the failing scripts once on
# the lane, and a script that passes on the rerun is flaky and not charged. It then reruns exactly the failing test
# scripts on the trunk tip's own tree in a clean clone, in the environment the gate ended with (policy gate-rerun),
# and compares each one's exit status and failing test names. A script that fails the same way on the tip is the tip's
# red: it does not block the lane, and it is reported once per script and tip tree (one wake, one note on the
# gate-red-ticket ticket). A script that fails only on the candidate, passes on the tip, or fails differently blocks
# the lane, and so does any failure no test script accounts for. The tip's result is kept by tree
# (data/trunk/tip-results-<project>-<tree>.tsv), so it is computed once. A landing that set a red or a flaky failure
# aside is recorded as full-tip-red or full-rerun.
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
# and the trunk moves only if it is still there (else the lane is rebased onto the new tip and gated again). `verify` never waits for a
# landing: it reads the tip as a ref and takes that lock only for its short pin write; it registers in a one-slot queue
# (state/trunk-verify-want-<project>) where the newest commit wins, so a verify for an older commit gives up at once and the newest runs.
# The queue's threshold: the landing check does not land ready lanes one by one. It holds them until flush-at-ready (default 3) are ready or the
# oldest has waited flush-after-minutes (default 20), then lands all of them (batch-max at a time, the rest at once after). `flush` skips the wait
# for one project: it records state/trunk-flush-<project>, which the check honours until the project has no ready lane left. `land-next` records
# state/<task>.land-next: that lane goes first and lands at once, with the others only when the threshold is also met. A worker never records either.
#
# After the landing, `verify <project> <commit>` (started by the landing check) runs the whole suite (gate-verify) at that commit:
# green moves the green pin; a script that fails there and passes on the commit's parent charges that one commit, which is
# reverted by itself (a new commit on the tip, never a rewind) and the lane's ticket is told; a red that cannot be charged to one
# commit, or a revert that does not apply cleanly, writes the red pin and stops landings except a fixes-red commit.
#
# The ship branch (state/<id>.meta branch=, default fm/<id>) must hold EXACTLY ONE commit on
# top of the trunk tip or on a base it can be rebased from. A second commit refuses; a conflict names the conflicting paths.
# The lane fixes it, reports ready again and the check lands the new head; a conflicting change is never landed dirty.
# `land` runs the lander's own gates at the candidate's exact tree in a clean clone, then moves the trunk with a
# compare-and-swap `update-ref`, so a racing lander or a lane
# that moved the ref is refused rather than overwritten. The trunk tip is recorded in
# state/trunk-tip-<project>; a tip that differs from that record was moved by someone other than
# this script (a lane can `git branch -f`), and every subcommand refuses until it is explained.
# Only the lander moves the trunk. A worker never lands. A git reference-transaction hook that every
# subcommand installs in the project refuses any other write to the trunk branch, so `git branch -f trunk`
# or `git update-ref` by hand is stopped where it happens; the record check above stays as the second lock.
#
# The trunk stays SAFE until its release PR lands: nothing forces, rewrites or deletes it (the hook above refuses
# all three, even from this script), and a pin-back moves the home only to a green commit, never the trunk.
# When the release PR has merged, `rollover` (also run by `release`, and by the landing check) cuts the NEXT trunk
# version from the default branch, moves the project onto it and records it (state/trunk-branch-<project>,
# state/trunk-version-<project>, data/trunk-versions.tsv). The old trunk is left exactly as it was.
# Pin-back: state/trunk-green-<project> is the last commit that passed the whole suite. `live`
# moves the home only to that commit, so a landing is not live until `verify` passes.
# A red `verify` or a red `ci` writes state/trunk-red-<project>; while it exists only a commit whose
# message has the line `fixes-red: <red sha>` may land, and `release` refuses. A red `ci` also moves
# the home back to the newest earlier commit that went live and was not red (else the last release).
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
# is `live-cap-minutes` (default 60) old, whichever comes first (bin/jg-trunk-policy-lib.sh). A red pin holds it: no home moves
# and a `held:<reason>` row says why; a commit whose suite was red is never live (verify reverts it, or pins the trunk red). A
# commit already live is not moved again. A red CI (`ci red`) pins EVERY home back to the last green commit at once.
#
# Exit 3 means the home did not move (the live hook failed); a landed commit stays landed.
#
# Every open captain call is a key in bin/jg-trunk-policy-lib.sh with its safe default; nothing
# here changes with the answer. Records: data/trunk-landings.tsv (task, project, commit, epoch,
# gate), data/trunk-live.tsv (project, commit, epoch, status), data/trunk-releases.tsv, data/trunk-ci.tsv, data/trunk-words.tsv.
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
  ensure_guard
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
  install_trunk_hook "$hook" "$want"
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
  [ "$want" = "$have" ] || refuse "$TRUNK is at ${have:0:12} but the lander last left it at ${want:0:12}; something else moved it, so nothing lands or releases until that is explained"
}

# Run a command at a commit's exact tree in a clean clone, logging to <log>; returns the command's exit status.
# <envfile>, when given, receives the environment the command ended with (NUL separated), so a rerun can use the same one.
gate_exec() {  # <commit> <command> <log> [<envfile>]
  local rc=0 cmd=$2
  mkdir -p "$DATA/trunk"
  WORK=$(mktemp -d)
  git clone -q --shared --no-checkout "$PROJ" "$WORK/tree" || die "cannot clone $PROJ for the gate"
  git -C "$WORK/tree" checkout -q --detach "$1" || die "cannot check out ${1:0:12} for the gate"
  # shellcheck disable=SC2016 # the trap body expands in the gate's shell
  [ -z "${4:-}" ] || cmd="trap 'env -0 > \"\$JG_GATE_ENV_OUT\"' EXIT; $2"
  (cd "$WORK/tree" && JG_GATE_ENV_OUT="${4:-/dev/null}" JG_TRUNK_GATE_OUTPUT="${3%.log}.proof" env -u JG_TASK_ID bash -c "$cmd") > "$3" 2>&1 || rc=$?
  rm -rf -- "$WORK"; WORK=
  return "$rc"
}

# Run a gate command at a commit's exact tree in a clean clone; the log is kept under data/.
run_gate() {  # <commit> <command> <label>
  local log="${LAND_ATTEMPT:-$DATA/trunk/gate-$PN-${1:0:12}-$(date +%s)-$$}-$3.log" rc=0
  gate_exec "$1" "$2" "$log" || rc=$?
  [ "$rc" -eq 0 ] || { tail -n 20 "$log" >&2; refuse "gate '$3' failed (exit $rc) at ${1:0:12}; full log: $log"; }
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
  local cand=$1 log="${LAND_ATTEMPT:-$DATA/trunk/gate-$PN-${1:0:12}}-full.log" envf rc=0 mine tipres line s ex sig tex tsig bad='' old='' unexplained quoted again settled now flaky='' t0
  t0=$(date +%s); GATE_KIND=full; GATE_FIGURES=
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
  [ -z "$flaky" ] || echo "note: passed on the rerun, so judged flaky and not charged:$flaky" >&2
  if [ -z "$mine" ]; then rm -f -- "$envf"; GATE_KIND="full-rerun"; gate_figures "$log" "$t0"; return 0; fi
  # shellcheck disable=SC2046
  tipres=$(tip_results "$3" "$envf" $(printf '%s\n' "$mine" | cut -f1))
  rm -f -- "$envf"
  while IFS= read -r line; do
    s=${line%%$'\t'*}; ex=$(printf '%s' "$line" | cut -f2); sig=$(printf '%s' "$line" | cut -f3-)
    tex=$(printf '%s\n' "$tipres" | awk -F'\t' -v s="$s" '$1 == s { print $2; exit }')
    tsig=$(printf '%s\n' "$tipres" | awk -F'\t' -v s="$s" '$1 == s { sub(/^[^\t]*\t[^\t]*\t/, ""); print; exit }')
    if [ -n "$sig" ] && [ "$tex" = "$ex" ] && [ "$tsig" = "$sig" ]; then old="$old $s"; else bad="$bad $s"; fi
  done <<< "$mine"
  # The tip's own red is a fact about the tip, so it is reported even when this lane is also refused.
  # shellcheck disable=SC2086
  [ -z "$old" ] || report_tip_red "$3" $old
  if [ -n "$bad" ]; then
    tail -n 20 "$log" >&2
    echo "REFUSED: gate 'full' failed (exit $rc) at ${cand:0:12}; this lane introduced or changed the failure of:$bad; full log: $log" >&2
    return 2
  fi
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
  local r="$STATE/$1.run-receipt.json" d="$DATA/$1" receipt=absent sig=absent card=absent
  if [ -f "$r" ] && command -v jq >/dev/null 2>&1; then receipt="$(jq -r '.verdict // "unreadable"' "$r" 2>/dev/null || echo unreadable)@$(jq -r '.head // ""' "$r" 2>/dev/null | cut -c1-12)"; fi
  [ ! -e "$d/proof-authorizations/$2.sig" ] || sig=present
  { [ -f "$d/merge-card.json" ] && grep -q "$2" "$d/merge-card.json"; } && card=present
  row trunk-landing-proofs.tsv "$1" "$PN" "$3" "$(date +%s)" "receipt=$receipt" "signature=$sig" "merge-card=$card" "gate=${GATE_FIGURES:-absent}"
}

# Tell the lane's ticket and Overwatch that its landed commit was reverted, with the reason. Best effort: the revert stands.
tell_lane() {  # <id> <note>
  jg_wake_append check "trunk-reverted-$PN-$(printf '%s' "$2" | cksum | cut -d' ' -f1)" "$2" >/dev/null 2>&1 || echo "warning: could not raise the revert alert" >&2
  JG_HOME="$JG_HOME" JG_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/jg-backlog.sh" update "$1" --append-notes "$2" >/dev/null 2>&1 || echo "warning: could not add the revert note to $1" >&2
  [ ! -f "$STATE/$1.meta" ] || JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-send.sh" "$1" "$2" >/dev/null 2>&1 || :
}

# The lane's record and its project, with the registered-mode check. Sets META (and PROJ, PN, TRUNK through open_project).
lane_meta() {  # <task-id>
  jg_pr_task_id_valid "$1" || die "invalid task id"
  META="$STATE/$1.meta"; [ -f "$META" ] || die "no meta for task $1 at $META"
  open_project "$(jg_dod_meta_value "$META" project)"
  case $(jg_dod_meta_value "$META" mode) in local-trunk|local-only|trunk) ;; *) die "task $1 is not a local-trunk task (legacy local-only/trunk also accepted); merge PR tasks with bin/jg-pr-merge.sh" ;; esac
}

# One lane's admission onto <tip>: the trunk tip for a single landing, the top of the stack for a batch. The lander rebases the
# lane's one commit onto <tip> by itself and only a conflict stops it; then the ticket reference, a red trunk, protected paths,
# linked decisions, the design/demo/nav gates and owner-guard. Refuses (exits) on any failure. Sets LANE_BRANCH, LANE_HEAD, LANE_CAND
# (the commit to land) and LANE_LANDED (1 when the lane is already on <tip>). <follow> 1 moves the lane branch to its rebased commit now.
lane_admit() {  # <id> <tip> <expected head or -> <follow 0|1>
  local id=$1 tip=$2 base n red hit rc=0 linked fresh gaps
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
  if [ -e "$STATE/trunk-red-$PN" ]; then
    red=$(cat "$STATE/trunk-red-$PN")
    git -C "$PROJ" log -1 --format=%B "$LANE_CAND" | grep -qx "fixes-red: $red" || refuse "$TRUNK is red at ${red:0:12}; only a commit with the line 'fixes-red: $red' may land"
  fi
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
  # The same merge alert as bin/jg-merge-local.sh: the opt-in fleet ledger's merged event and the ticket close.
  [ ! -e "$CONFIG/fleet-ledger" ] || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-fleet-ledger.sh" merged "$1" local || true
  JG_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/jg-ticket.sh" "$1" --stage "done" --state "done" || true
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
    lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK"); unlock "$STATE/.trunk-$PN.lock"
    lane_admit "$id" "$tip" "$LAND_HEAD" 0
    cand=$LANE_CAND
    if [ -n "$LANE_LANDED" ]; then echo "already landed $id at $cand; not live"; return 0; fi
    # One fast check: the lint over the changed files, then the changed files' tests judged against the tip's own result.
    # Only a repository that carries Juggernaut's own suite gets its default gates; any other project runs the gates its home set for it, if any.
    if gate=$(jg_trunk_gate gate-lint "$PN" "$PROJ" "$cand"); then run_gate "$cand" "$gate" lint; else echo "land: $PN has no lint gate; none run" >&2; fi
    if gate=$(jg_trunk_gate gate-full "$PN" "$PROJ" "$cand"); then full_gate "$cand" "$gate" "$tip" || exit 1; else GATE_KIND=no-gate; echo "land: $PN has no landing gate (no gate-full@$PN); none run" >&2; fi
    lock "$STATE/.trunk-$PN.lock"; tip_ok
    if [ "$(rev "refs/heads/$TRUNK")" = "$tip" ]; then still=1; break; fi
    unlock "$STATE/.trunk-$PN.lock"; echo "note: $TRUNK moved to $(rev "refs/heads/$TRUNK" | cut -c1-12) while $id was gated at ${tip:0:12}; rebasing it onto the new tip and gating it again" >&2
  done
  [ -n "$still" ] || refuse "the trunk kept moving while $id was gated; it lands on the next try"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: land $id" "refs/heads/$TRUNK" "$cand" "$tip" || refuse "$TRUNK changed while landing $id"
  put "$STATE/trunk-tip-$PN" "$cand"
  # A landing never moves the green pin: only `verify` (the whole suite, after the landing) does.
  row trunk-landings.tsv "$id" "$PN" "$cand" "$(date +%s)" "$GATE_KIND"
  unlock "$STATE/.trunk-$PN.lock"
  [ "$cand" = "$LANE_HEAD" ] || lane_follow "$LANE_BRANCH" "$LANE_HEAD" "$cand" "$(jg_dod_meta_value "$META" worktree)"
  landed_effects "$id" "$LANE_HEAD" "$cand"
  echo "landed $id on $TRUNK (${tip:0:12} -> ${cand:0:12}, gate=$GATE_KIND) in $PROJ; not live: it goes live only on the captain's word"
}

# --- The merge queue: two or more queued lanes land as one stack (docs/trunk-flow.md "Batch landing") ---
# B_* are the lanes of one batch, by position: id, original lane commit (C0), its commit as it now sits in the stack (CUR), lane head, branch, record, why it was returned.
B_ID=(); B_C0=(); B_CUR=(); B_HEAD=(); B_BRANCH=(); B_META=(); B_WHY=(); B_TIP=; B_BASE0=; CHAIN=(); CHAIN_CHANGED=; LANDED=(); LAST_RED=

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

# ONE gate over the stack: the lint, then the tests of the union of the changed files, both judged against the trunk tip
# (HEAD^ in a gate command is the commit under the stack, so HEAD~<n> is). Returns 0 green; 1 red, with BG_WHY and LAST_RED set.
batch_gate() {  # <top> <stack size>   (B_TIP is the trunk tip the stack sits on)
  local rc=0 errf lint full
  lint=$(jg_trunk_gate gate-lint "$PN" "$PROJ" "$1" || true); full=$(jg_trunk_gate gate-full "$PN" "$PROJ" "$1" || true)
  errf=$(mktemp)
  ( [ -z "$lint" ] || run_gate "$1" "${lint//HEAD^/HEAD~$2}" lint ) 2>"$errf" || rc=$?
  if [ "$rc" -ne 0 ]; then :
  elif [ -n "$full" ]; then full_gate "$1" "${full//HEAD^/HEAD~$2}" "$B_TIP" 2>>"$errf" || rc=$?
  else GATE_KIND=no-gate; echo "land: $PN has no landing gate (no gate-full@$PN); none run" >>"$errf"; fi
  cat "$errf" >&2
  [ "$rc" -eq 0 ] || LAST_RED=$(grep -E '^(REFUSED|error):' "$errf" | tail -n 1 | sed 's/^[A-Za-z]*: //')
  rm -f -- "$errf"
  [ "$rc" -eq 0 ]
}

# The lanes in CHAIN land in one move: the trunk fast-forwards over the whole stack. One trunk-landings.tsv row per lane.
land_group() {
  local top=${B_CUR[${CHAIN[${#CHAIN[@]}-1]}]} i
  # The trunk lock is held only to move the trunk. Returns 1, moving nothing, when the trunk is no longer where the stack was gated.
  lock "$STATE/.trunk-$PN.lock"; tip_ok
  [ "$(rev "refs/heads/$TRUNK")" = "$B_TIP" ] || { unlock "$STATE/.trunk-$PN.lock"; return 1; }
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: land a batch of ${#CHAIN[@]}" "refs/heads/$TRUNK" "$top" "$B_TIP" || refuse "$TRUNK changed while landing the batch"
  put "$STATE/trunk-tip-$PN" "$top"
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
# returned. Prints `landed <id> ...` or `returned <id>: <reason>` for every lane. Exit 0 once every lane has an outcome.
cmd_land_batch() {
  local a id i n max proj0='' errf g flag top half res moved rounds=0 l
  local -a exp todo stack members first rest remaining
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
  lock "$STATE/.trunk-$PN.lock"; tip_ok; B_TIP=$(rev "refs/heads/$TRUNK"); unlock "$STATE/.trunk-$PN.lock"
  B_BASE0=$B_TIP; GATE_KIND=full; GATE_FIGURES=; top=$B_TIP; todo=()
  for ((i = 0; i < n; i++)); do
    META=${B_META[$i]}; id=${B_ID[$i]}; errf=$(mktemp)
    # shellcheck disable=SC2030 # the admission subshell starts with no locks and no work directory of its own
    if ( LOCKS=''; WORK=''; lane_admit "$id" "$top" "${exp[$i]}" 0 && printf '%s\t%s\t%s\t%s\n' "$LANE_HEAD" "$LANE_CAND" "$LANE_BRANCH" "$LANE_LANDED" > "$errf.res" ) 2>"$errf"; then
      IFS=$'\t' read -r "B_HEAD[i]" "B_CUR[i]" "B_BRANCH[i]" res < "$errf.res"
      if [ -n "$res" ]; then B_WHY[i]="already landed $id at ${B_CUR[$i]}; not live"; else B_C0[i]=${B_HEAD[$i]}; top=${B_CUR[$i]}; todo+=("$i"); fi
    else
      B_WHY[i]=$(grep -E '^(REFUSED|error):' "$errf" | tail -n 1); B_WHY[i]=${B_WHY[$i]:-"REFUSED: admission failed for $id"}
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
    if [ "$flag" = 1 ] && [ -z "$CHAIN_CHANGED" ]; then :; elif batch_gate "$top" "${#CHAIN[@]}"; then if land_group; then continue; fi; moved=1; break; fi
    if [ "${#CHAIN[@]}" -eq 1 ]; then
      B_WHY[CHAIN[0]]="REFUSED: this lane is the red in its batch: $LAST_RED"; continue
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
    for i in "${remaining[@]}"; do B_WHY[i]="REFUSED: the trunk kept moving while its batch was gated; it lands on the next try"; done
    break
  fi
  todo=("${remaining[@]}"); B_TIP=$(rev "refs/heads/$TRUNK"); B_BASE0=$B_TIP
  echo "note: $TRUNK moved while the stack was gated; judging the ${#todo[@]} lanes still waiting on ${B_TIP:0:12}" >&2
  done
  for ((i = 0; i < n; i++)); do
    [ -n "${B_WHY[$i]:-}" ] || continue
    case ${B_WHY[$i]} in "already landed"*) echo "${B_WHY[$i]}" ;; *) echo "returned ${B_ID[$i]}: ${B_WHY[$i]}" ;; esac
  done
}

# Manual and automatic callers share admission before either can wait on the project lock.
# Exit 75 is in progress, 74 a bounded transient read failure, 1 a final refusal.
# Context changes admit a new attempt; every attempt keeps its own output and gate logs.
cmd_land() {
  local id=${1:-} meta proj branch cand mem context key previous count=0 kind reason attempt rc=0 proof_home account run_lock held_by
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
  mem=$DATA/jg-trunk-landing; mkdir -p "$mem"
  # No runtime status, clocks or attempt output belong to the declared context.
  context=$({
    printf '%s\n' "$proj" "$cand" "$proof_home" "$account" "$PATH" \
      "${JG_BEADS_TEST_BD:-}" "${JG_BEADS_TEST_DOLT:-}" "${GOCACHE:-}" "${GOMODCACHE:-}"
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
  previous=$(cat "$key.state" 2>/dev/null || true)
  read -r kind count reason <<<"${previous:-new 0}"
  case $kind in
    final) printf '%s\n' "$reason"; return 1 ;;
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
  [ "$rc" -eq 0 ] || printf '%s\n' "$reason"
  kind=final
  if [ "$rc" -eq 0 ]; then kind=landed; reason="landed $id at $cand; not live"
  elif grep -qE "^(REFUSED|error):.*(away mode|linked to a decision| is red|still held|the trunk kept moving|proof inputs are incomplete)" "$attempt/landing.log"; then kind="wait"
  elif ! grep -q "^REFUSED: gate '" "$attempt/landing.log" &&
    grep -qE '^(jg-captain-hold: )?backlog show [A-Za-z0-9._-]+ exceeded its [0-9]+s backlog read bound$' "$attempt/landing.log"; then
    count=$((count + 1)); [ "$count" -ge 3 ] || { kind=retry; rc=74; }
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
  put "$STATE/trunk-tip-$PN" "$new"
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

# The whole suite at a landed commit, after the landing (the landing check starts it for each landing). Green moves the pin;
# a script that fails there and passes on the commit's parent charges that one commit, which is reverted; a red nobody
# can charge to one commit stops landings until a fixes-red commit lands.
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
  local sha tip rc=0 parent green why from culprit='' gate
  open_project "${1-}"
  # The tip is a ref read, which is atomic, so reading it never waits for a landing; the trunk lock is taken only for a short write.
  tip=$(rev "refs/heads/$TRUNK") || refuse "trunk branch $TRUNK is missing in $PROJ"
  sha=$tip; [ -z "${2-}" ] || sha=$(rev "$2") || die "'${2-}' does not resolve in $PROJ"
  git -C "$PROJ" merge-base --is-ancestor "$sha" "$tip" || refuse "${sha:0:12} is not on $TRUNK"
  verify_slot "$sha" || { echo "verify: ${sha:0:12} is superseded by a newer verify, so it does not run; a green result there moves the pin over it too"; return 0; }
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  # A commit strictly under the pin was covered by a newer green; the pin's own commit is verified again when asked.
  if [ -n "$green" ] && [ "$sha" != "$green" ] && git -C "$PROJ" merge-base --is-ancestor "$sha" "$green"; then echo "verify: ${sha:0:12} is already under the green pin ${green:0:12}"; return 0; fi
  parent=$(rev "$sha^" || true)
  # The top of a batch is judged against the trunk before the batch (its row says where that was), so one run covers the whole stack.
  from=$(awk -F'\t' -v c="$sha" '$3 == c && $6 ~ /^batch-from=/ { f = substr($6, 12) } END { print f }' "$DATA/trunk-landings.tsv" 2>/dev/null || true)
  if [ -n "$from" ] && git -C "$PROJ" merge-base --is-ancestor "$from" "$sha"; then parent=$from; else from=; fi
  if ! gate=$(jg_trunk_gate gate-verify "$PN" "$PROJ" "$sha"); then
    # No gate for this project (not Juggernaut, and neither gate-verify@$PN nor gate-full@$PN set): nothing can fail, so nothing goes red.
    echo "verify: no verify gate for $PN (no gate-verify@$PN or gate-full@$PN); nothing run, nothing marked red" >&2
  elif [ -n "$parent" ]; then full_gate "$sha" "$gate" "$parent" || rc=$?
  else run_gate "$sha" "$gate" full || rc=$?; fi
  case $rc in
    0)
      # A flaky pass keeps the pin. A failure the commit's own parent has in the same way is a red the commit did not add (the gate
      # reported it once as the tip's red), so the pin moves: the green pin is the last commit that added no failure.
      [ "${GATE_KIND:-full}" != full-rerun ] || { echo "verify: ${sha:0:12} passed only with a flaky failure set aside; the green pin stays" >&2; return 0; }
      lock "$STATE/.trunk-$PN.lock"; tip_ok
      green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
      if [ -z "$green" ] || git -C "$PROJ" merge-base --is-ancestor "$green" "$sha"; then put "$STATE/trunk-green-$PN" "$sha"; fi
      if [ -e "$STATE/trunk-red-$PN" ] && git -C "$PROJ" merge-base --is-ancestor "$(cat "$STATE/trunk-red-$PN")" "$sha"; then rm -f -- "$STATE/trunk-red-$PN"; fi
      unlock "$STATE/.trunk-$PN.lock"
      echo "trunk green at ${sha:0:12}$([ "${GATE_KIND:-}" != full-tip-red ] || echo ", with the failures its parent already had set aside")" ;;
    2)
      why="the whole suite fails on it where its parent ${parent:0:12} passes"
      [ -z "$from" ] || culprit=$(batch_culprit "$from" "$sha" "$gate")
      if [ -n "$culprit" ] && [ "$culprit" != "$sha" ]; then
        why="the whole suite fails on it where the trunk before its batch ${from:0:12} passes"
        if revert_commit "$culprit" "$why"; then exit 1; fi
      elif revert_commit "$sha" "$why"; then exit 1; fi
      lock "$STATE/.trunk-$PN.lock"; put "$STATE/trunk-red-$PN" "$sha"; unlock "$STATE/.trunk-$PN.lock"
      jg_wake_append check "trunk-red-$PN-${sha:0:12}" "$TRUNK is red at ${sha:0:12}: $why, and it could not be reverted by itself; landings stop except a fixes-red commit" >/dev/null 2>&1 || :
      echo "trunk is RED at ${sha:0:12}; it could not be reverted by itself; landings stop except a fixes-red commit" >&2; exit 1 ;;
    *)
      lock "$STATE/.trunk-$PN.lock"; put "$STATE/trunk-red-$PN" "$sha"; unlock "$STATE/.trunk-$PN.lock"
      echo "trunk is RED at ${sha:0:12}; landings stop except a fixes-red commit" >&2; exit 1 ;;
  esac
}

# Move the home to <sha> through the project's live hook and record it. Exit 3 when the home did not move.
go_live() {  # <sha> <tip>   LIVE_FLEET=1 (cmd_live) moves every home; a pin-back moves this one
  local sha=$1 hook status=landed-not-live here there why hook_out hook_rc reason
  hook="$CONFIG/live-hook.$PN"
  if [ ! -x "$hook" ]; then
    here=$(git -C "$JG_ROOT" remote get-url origin 2>/dev/null || echo a); there=$(git -C "$PROJ" remote get-url origin 2>/dev/null || echo b)
    [ "$here" != "$there" ] || hook="$SCRIPT_DIR/jg-trunk-live-home.sh"
    [ "$here" != "$there" ] || [ -z "${LIVE_FLEET:-}" ] || hook=fleet
  fi
  if [ "$hook" = fleet ]; then
    if why=$(fleet_move "$sha" "$2" 2>&1); then status=live; else
      printf '%s\n' "$why"; row trunk-live.tsv "$PN" "$sha" "$(date +%s)" "hook-failed:$(printf '%s' "$why" | tail -n 1 | cut -c1-200)"
      echo "error: the fleet move failed for ${sha:0:12}; see the rows in trunk-live.tsv" >&2; exit 3
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

waiver_rule() { awk -v p="$PN" '$1 == p { r = $2 } END { print r }' "$CONFIG/trunk-live-waiver" 2>/dev/null || true; }

# The batched live step, run on every tick of the landing check for a project with a go-live waiver. It moves every home to the
# green pin once the trunk has been quiet (no landing for live-quiet-minutes) or the oldest landing that is not live yet is
# live-cap-minutes old, whichever comes first, so landings never wait on a go-live and a busy trunk still goes live hourly.
# Prints one `autolive: ...` line last; exit 0 for live, waiting or held, 3 when the move failed.
cmd_autolive() {
  local green tip why out rc now last quiet cap newest oldest wait_s
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never runs the live step"
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok; tip=$(rev "refs/heads/$TRUNK")
  LIVE_WAIVER=$(waiver_rule)
  [ -n "$LIVE_WAIVER" ] || { echo "autolive: not live: it needs the captain's word (no go-live waiver for $PN)"; return 0; }
  green=$(cat "$STATE/trunk-green-$PN" 2>/dev/null || true)
  if [ -e "$STATE/trunk-red-$PN" ]; then why="the trunk is red at $(cut -c1-12 "$STATE/trunk-red-$PN")"
  elif [ -z "$green" ]; then echo "autolive: waiting: no fully green trunk commit yet"; return 0
  elif awk -F'\t' -v p="$PN" -v g="$green" '$1 == p && $2 == g && $4 ~ /^live/ { f = 1 } END { exit !f }' "$DATA/trunk-live.tsv" 2>/dev/null; then
    echo "autolive: already live at ${green:0:12}"; return 0
  fi
  if [ -n "${why:-}" ]; then
    # one held row per reason, not one per tick
    [ "$(awk -F'\t' -v p="$PN" '$1 == p { r = $4 } END { print r }' "$DATA/trunk-live.tsv" 2>/dev/null || true)" = "held:$why" ] \
      || row trunk-live.tsv "$PN" "$green" "$(date +%s)" "held:$(printf '%s' "$why" | tr '\t' ' ')"
    echo "autolive: NOT live, held: $why; every home stays on the last green commit"; return 0
  fi
  now=$(date +%s); quiet=$(( $(pol live-quiet-minutes) * 60 )); cap=$(( $(pol live-cap-minutes) * 60 ))
  last=$(awk -F'\t' -v p="$PN" '$1 == p && $4 ~ /^live/ && $3 > m { m = $3 } END { print m + 0 }' "$DATA/trunk-live.tsv" 2>/dev/null || echo 0)
  read -r newest oldest <<< "$(awk -F'\t' -v p="$PN" -v l="$last" '$2 == p && $4 >= l { if (!n || $4 > n) n = $4; if (!o || $4 < o) o = $4 } END { print n + 0, o + 0 }' "$DATA/trunk-landings.tsv" 2>/dev/null || echo "0 0")"
  [ "${newest:-0}" -gt 0 ] || { echo "autolive: waiting: nothing has landed since the last go-live"; return 0; }
  if [ $(( now - newest )) -lt "$quiet" ] && [ $(( now - oldest )) -lt "$cap" ]; then
    wait_s=$(( quiet - (now - newest) )); [ $(( cap - (now - oldest) )) -ge "$wait_s" ] || wait_s=$(( cap - (now - oldest) ))
    echo "autolive: waiting: live in about $(( (wait_s + 59) / 60 )) min (quiet $(( quiet / 60 )) min, cap $(( cap / 60 )) min)"; return 0
  fi
  LIVE_FLEET=1; out=$(go_live "$green" "$tip" 2>&1) && rc=0 || rc=$?
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
  local rule=${3-} others
  [ -z "${JG_TASK_ID:-}" ] || refuse "a worker never writes a go-live waiver"
  [ "${2-}" = --rule ] && [ -n "$rule" ] || refuse "a go-live waiver names the owner rule that grants it: jg-trunk.sh waiver <project-dir> --rule <owner-rule-id>"
  case $rule in owner-rule-[A-Za-z0-9]*) ;; *) refuse "'$rule' is not an owner rule id (owner-rule-<id>)" ;; esac
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"
  mkdir -p "$CONFIG"
  others=$(grep -v "^$PN " "$CONFIG/trunk-live-waiver" 2>/dev/null || true)
  put "$CONFIG/trunk-live-waiver" "${others:+$others$'\n'}$PN $rule $(date +%s) until=stable"
  echo "go-live waiver recorded for $PN under $rule; delete its line in config/trunk-live-waiver to restore the word"
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
  if [ "$kind" = live ]; then sha=$(cat "$STATE/trunk-green-$PN"); else sha=$(rev "refs/heads/$TRUNK"); fi
  put "$STATE/trunk-word-$kind-$PN" "$(printf '%s\t%s\t%s' "$sha" "$(date +%s)" "$quote")"
  row trunk-words.tsv "$PN" "$kind" "$sha" "$(date +%s)" "$quote"
  echo "word recorded: $kind ${sha:0:12} in $PN"
}

# The newest earlier commit that went live and was not red; the last release when none did.
last_green_before() {  # <red sha>
  local c
  while IFS= read -r c; do
    [ "$c" != "$1" ] || continue
    grep -q "^$PN	$c	[0-9]*	red$" "$DATA/trunk-ci.tsv" 2>/dev/null && continue
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
      if [ -e "$STATE/trunk-red-$PN" ] && [ "$sha" != "$(cat "$STATE/trunk-red-$PN")" ] \
        && git -C "$PROJ" merge-base --is-ancestor "$(cat "$STATE/trunk-red-$PN")" "$sha"; then rm -f -- "$STATE/trunk-red-$PN"; fi
      echo "ci green at ${sha:0:12}" ;;
    red)
      row trunk-ci.tsv "$PN" "$sha" "$(date +%s)" red
      back=$(last_green_before "$sha")
      put "$STATE/trunk-red-$PN" "$sha"; put "$STATE/trunk-green-$PN" "$back"
      echo "ci RED at ${sha:0:12}; pinning the home back to ${back:0:12}; landings stop except a fixes-red commit" >&2
      LIVE_FLEET=1; go_live "$back" "$tip" ;;
    *) die "usage: jg-trunk.sh ci <project-dir> <sha> green|red" ;;
  esac
}

# The release PR of the last release, and whether it has merged. The trunk stays untouched until it has.
last_release_url() { awk -F'\t' -v p="$PN" '$1 == p { u = $6 } END { print u }' "$DATA/trunk-releases.tsv" 2>/dev/null || true; }
pr_state() {  # <url>: open|merged|closed|unknown
  local st
  jg_pr_url_parse "$1" && [ "$JG_PR_PROVIDER" = github ] || { printf 'unknown\n'; return; }
  st=$( (cd "$PROJ" && gh-axi pr view "$JG_PR_NUMBER" --repo "$JG_PR_PATH") | awk '$1 == "state:" { print tolower($2); exit }')
  printf '%s\n' "${st:-unknown}"
}

# Once the release PR has merged, the NEXT trunk version is cut from the default branch and the project moves onto
# it: <trunk>-v2, -v3, ... The old trunk is left exactly as it was. Returns 1, changing nothing, while the PR is not merged.
rollover_if_merged() {
  local url ver new base default
  url=$(last_release_url); [ -n "$url" ] || return 1
  [ "$(cat "$STATE/trunk-rolled-$PN" 2>/dev/null)" != "$url" ] || return 1
  [ "$(pr_state "$url")" = merged ] || return 1
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  git -C "$PROJ" fetch -q origin "+refs/heads/$default:refs/remotes/origin/$default" || die "cannot fetch origin/$default to cut the next trunk"
  base=$(rev "refs/remotes/origin/$default") || die "origin/$default is not a commit"
  ver=$(( $(cat "$STATE/trunk-version-$PN" 2>/dev/null || echo 1) + 1 )); new="$(pol trunk-branch)-v$ver"
  rev "refs/heads/$new" >/dev/null && die "$new already exists in $PROJ; the next trunk is never overwritten"
  JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref -m "trunk: version $ver after $url" "refs/heads/$new" "$base" ""
  put "$STATE/trunk-tip-$PN" "$base"; put "$STATE/trunk-green-$PN" "$base"; put "$STATE/trunk-released-$PN" "$base"
  put "$STATE/trunk-branch-$PN" "$new"; put "$STATE/trunk-version-$PN" "$ver"; put "$STATE/trunk-rolled-$PN" "$url"
  rm -f -- "$STATE/trunk-red-$PN"
  row trunk-versions.tsv "$PN" "$ver" "$new" "$base" "$(date +%s)"
  echo "release merged: the project is now on $new (version $ver) cut from $default at ${base:0:12}"
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
  rollover_if_merged || refuse "no merged release to roll over from; $TRUNK stays as it is until its release PR lands"
}

cmd_release() {
  local tip base n default body url prev
  open_project "${1-}"; lock "$STATE/.trunk-$PN.lock"; tip_ok
  rollover_if_merged || true
  [ ! -e "$STATE/trunk-red-$PN" ] || refuse "$TRUNK is red; fix it before a release"
  tip=$(rev "refs/heads/$TRUNK")
  [ "$(cat "$STATE/trunk-green-$PN")" = "$tip" ] || refuse "$TRUNK tip ${tip:0:12} has not passed the full suite; run verify first"
  base=$(cat "$STATE/trunk-released-$PN"); n=$(git -C "$PROJ" rev-list --count "$base..$tip")
  [ "$n" -gt 0 ] || refuse "nothing to release: $TRUNK has no commits since the last release"
  need_word release "$tip"
  default=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true); default=${default:-main}
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$TRUNK" "$tip" "$TRUNK" "$base" | (cd "$PROJ" && "$SCRIPT_DIR/../core/owner-guard/owner-guard" pre-push) || refuse "owner-guard refused the batch"
  git -C "$PROJ" push -q origin "$tip:refs/heads/$TRUNK" || die "push of $TRUNK failed (never forced)"
  # The release PR is the trunk itself going into the default branch: no release branch, one PR.
  # While the last release PR is still open, the push above already carried the new commits into it.
  prev=$(last_release_url)
  if [ -n "$prev" ] && [ "$(pr_state "$prev")" = open ]; then
    url=$prev
  else
    body=$(mktemp); WORK=$body
    { echo "Release batch from the local $TRUNK: $n commits, one per ticket."; echo
      git -C "$PROJ" log --reverse --format='- %h %s' "$base..$tip"; } > "$body"
    url=$(cd "$PROJ" && gh-axi pr create --base "$default" --head "$TRUNK" --title "Release: $n tickets from the local $TRUNK" --body-file "$body") || die "$TRUNK is pushed but the release PR was not opened; run release again"
  fi
  put "$STATE/trunk-released-$PN" "$tip"; spend_word release
  row trunk-releases.tsv "$PN" "$TRUNK" "$tip" "$n" "$(date +%s)" "$url"
  echo "released $n commits from $TRUNK: $url"
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
  verify) shift; cmd_verify "$@" ;;
  proof) shift; cmd_proof "$@" ;;
  word) shift; cmd_word "$@" ;;
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
