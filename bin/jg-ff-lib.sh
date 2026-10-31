# shellcheck shell=bash
# Shared fast-forward machinery for juggernaut self-sync.
# Usage: . bin/jg-ff-lib.sh   (after JG_ROOT and JG_HOME are set)
#
# This is the one implementation of "advance a juggernaut checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /resupply (bin/jg-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD squad_lead sync (bin/jg-spawn.sh on launch, bin/jg-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# A REMOTE squad_lead home follows that same primary commit. Its host cannot read
# this object store, so bin/jg-spawn.sh and bin/jg-bootstrap.sh hand the commit to
# bin/jg-remote-squad-lead-control.sh, which imports it on that host and then runs
# THIS ff_target with it as the base, so the guards below stay the only copy of the
# ancestry rules.
#
# A linked-worktree squad_lead home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A local standalone clone moves through that path
# only when it already has the target; otherwise it is skipped until the origin
# path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# squad_lead's backlog, projects, or in-flight work. For the same reason,
# untracked output inside those dirs (and the retired board tool's .lavish/)
# never makes a home dirty: only tracked, staged, or genuinely stray untracked
# files do, and a skip names each of them.
# The seeded .jg-squad-lead-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# A clean squad_lead divergence is reconciled only when a three-way tree proof
# shows that its complete local result is already present in the target, as
# happens after an upstream squash merge. Every other divergence stays put and
# records an inspectable state/.squad-lead-update-reconcile/<id>.pending marker
# in the supervising home until a later successful convergence clears it.
# Locally leased homes start at a detached HEAD on the default branch, so their
# fast-forward advances HEAD only and never moves the shared default branch or
# any other worktree's checkout. A standalone remote home may instead advance
# its checked-out default branch under the same guard.
# A fast-forward can fail forever on the target's OWN index.lock left behind by
# a killed git process ("Unable to create ...index.lock: File exists"). That one
# failure gets a single recovery attempt: the lock is removed only when
# jg-lock-lib.sh proves it stale (no live holder, mtime age past the threshold)
# and the fast-forward is retried once; an unproven lock keeps today's skip.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.jg-squad-lead-home}"
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-squad-lead-registry-lib.sh"
# shellcheck source=bin/jg-lock-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jg-lock-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every squad_lead follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="squad_lead $name directory must resolve inside the squad_lead home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="squad_lead $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="squad_lead $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="squad_lead $name directory must resolve inside the squad_lead home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="squad_lead $name directory cannot be inside the active juggernaut home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="squad_lead $name directory cannot be inside the juggernaut repo"
      return 1
    fi
  done
}

validate_squad_lead_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$JG_HOME") || {
    VALIDATION_ERROR="active juggernaut home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$JG_ROOT") || {
    VALIDATION_ERROR="juggernaut repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="squad_lead home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="squad_lead home cannot be the active juggernaut home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="squad_lead home cannot be the juggernaut repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="squad_lead home cannot be inside the active juggernaut home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="squad_lead home cannot be inside the juggernaut repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="squad_lead home cannot be an ancestor of the active juggernaut home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="squad_lead home cannot be an ancestor of the juggernaut repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$(jg_compat_marker "$abs_home")" ]; then
    VALIDATION_ERROR="squad_lead marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$(jg_compat_marker "$abs_home")" ]; then
    VALIDATION_ERROR="not a seeded squad_lead home"
    return 1
  fi
  marker_id=$(cat "$(jg_compat_marker "$abs_home")" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for squad_lead ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a juggernaut home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a juggernaut home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md imports via @AGENTS.md), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

# Translate one remote home sync leg's failure into an operator-actionable
# reason. The remote leg refuses a command shape it does not recognize with this
# status, which on this leg can only mean that host's Juggernaut copy predates the
# parent-targeted sync it was just asked for; every other failure already carries
# its own diagnostic.
REMOTE_SYNC_UNSUPPORTED_STATUS=2
remote_sync_failure_reason() { # <exit-status> <output>
  if [ "$1" = "$REMOTE_SYNC_UNSUPPORTED_STATUS" ]; then
    printf '%s\n' "the Juggernaut copy on that host is too old to sync to this primary's commit; run /resupply"
    return 0
  fi
  first_line "$2"
}

# Translate a remote inheritance push's combined output into an operator-
# actionable reason. The push prints one "unchanged: <item>" line per item that
# already matched before failing on the item that stopped it, so the plain
# first line usually names an unrelated unchanged item rather than the error;
# prefer the push's own "error: ..." line and fall back to the first line only
# when it emitted none (an interrupted or unrecognized-shape failure).
remote_inherit_failure_reason() { # <output>
  local err
  err=$(printf '%s\n' "$1" | grep -m1 '^error:') || true
  if [ -n "$err" ]; then
    first_line "$err"
  else
    first_line "$1"
  fi
}

# Untracked output the rules own, so it never makes a home dirty. A
# tracked-files fast-forward cannot disturb these paths, and each one belongs to
# the running home rather than to the tracked surface being advanced: the
# backlog and records (data/, state/, config/), project clones (projects/),
# validation scratch (.no-mistakes/), and the retired board tool's .lavish/.
OPERATIONAL_UNTRACKED_DIRS="data state config projects .no-mistakes .lavish"

# Print the paths that make a checkout dirty, one per line, in
# `git status --porcelain` order. Empty output means clean.
# Counted: tracked changes and staged changes, plus a genuinely untracked file
# anywhere outside the operational dirs (a stray source file still refuses).
# Never counted: a gitignored path, which `git status --porcelain` already omits,
# and an untracked path inside OPERATIONAL_UNTRACKED_DIRS.
dirty_paths() { # <dir> [ignore_seed_marker]
  local dir=$1 ignore_seed_marker=${2:-no} entry path first
  git -C "$dir" status --porcelain 2>/dev/null | while IFS= read -r entry; do
    case "$entry" in
      '?? '*)
        path=${entry#\?\? }
        if [ "$ignore_seed_marker" = yes ] && [ "$path" = "$SUB_HOME_MARKER" ]; then
          continue
        fi
        first=${path%%/*}
        case " $OPERATIONAL_UNTRACKED_DIRS " in
          *" $first "*) continue ;;
        esac
        ;;
    esac
    printf '%s\n' "${entry:3}"
  done
}

squad_lead_update_reconcile_marker_path() { # <state> <id>
  local state=$1 id=$2
  case "$id" in *[!A-Za-z0-9._-]*|'') return 1 ;; esac
  printf '%s/.squad-lead-update-reconcile/%s.pending\n' "$state" "$id"
}

squad_lead_update_reconcile_record() { # <state> <id> <local-commit> <target-commit> <target>
  local state=$1 id=$2 local_commit=$3 target_commit=$4 target=$5 marker parent tmp
  case "$target" in *$'\n'*|*$'\r'*) return 1 ;; esac
  if [ -e "$state" ] || [ -L "$state" ]; then
    state=$(resolved_existing_dir "$state") || return 1
  else
    mkdir -p "$state" || return 1
    state=$(resolved_existing_dir "$state") || return 1
  fi
  marker=$(squad_lead_update_reconcile_marker_path "$state" "$id") || return 1
  parent=${marker%/*}
  if [ -e "$parent" ] || [ -L "$parent" ]; then
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  else
    mkdir -p "$parent" || return 1
  fi
  [ ! -L "$marker" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.squad-lead-update-reconcile.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'schema=jg-squad-lead-update-reconcile.v1\n'
    printf 'id=%s\n' "$id"
    printf 'status=diverged\n'
    printf 'local_commit=%s\n' "$local_commit"
    printf 'target_commit=%s\n' "$target_commit"
    printf 'target=%s\n' "$target"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$marker"
}

squad_lead_update_reconcile_clear() { # <state> <id>
  local state=$1 marker
  [ -e "$state" ] || [ -L "$state" ] || return 0
  state=$(resolved_existing_dir "$state") || return 1
  marker=$(squad_lead_update_reconcile_marker_path "$state" "$2") || return 1
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ ! -L "$marker" ] || return 1
  rm -f -- "$marker"
}

# Prove that merging LOCAL into TARGET from their real merge base adds no tree
# change to TARGET. A temporary index performs the three-way comparison without
# touching the worktree or writing a merge commit. Conflicts or any remaining
# content difference are not redundant and therefore stay diverged.
divergence_is_redundant() { # <dir> <local-commit> <target-commit>
  local dir=$1 local_commit=$2 target_commit=$3 ancestor scratch index result=1
  ancestor=$(git -C "$dir" merge-base "$local_commit" "$target_commit" 2>/dev/null) || return 1
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/jg-ff-redundant.XXXXXX" 2>/dev/null) || return 1
  index="$scratch/index"
  if GIT_INDEX_FILE="$index" git -C "$dir" read-tree -m \
      "$ancestor" "$target_commit" "$local_commit" 2>/dev/null \
    && ! GIT_INDEX_FILE="$index" git -C "$dir" ls-files -u | grep -q . \
    && GIT_INDEX_FILE="$index" git -C "$dir" diff --cached --quiet "$target_commit" --; then
    result=0
  fi
  rm -rf -- "$scratch"
  return "$result"
}

# List this home's LIVE squad_lead direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/squad_leads.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_squad_lead_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    jg_compat_meta_is_squad_lead "$meta" || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(squad_lead_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# Minimum mtime age before a blocked index.lock may be judged stale and removed.
# Read at call time - this is a sourced library serving many sweeps in one shell -
# and an invalid or missing value falls back to 30s.
ff_stale_index_lock_age_secs() {
  local age=${JG_FF_STALE_INDEX_LOCK_AGE_SECS:-30}
  case "$age" in ''|*[!0-9]*) age=30 ;; esac
  printf '%s\n' "$age"
}

# Extract the index.lock path from a git "Unable to create '<path>': File
# exists" failure, or return 1. Only an index.lock path matches, so any other
# File exists failure (a branch ref lock, packed-refs.lock) never does.
ff_index_lock_error_path() {
  local match
  match=$(printf '%s\n' "$1" | grep -m1 -Eo "Unable to create ['\"][^'\"]*/index\\.lock['\"]") || return 1
  match=${match#Unable to create }
  match=${match%\'}
  match=${match%\"}
  match=${match#\'}
  match=${match#\"}
  printf '%s\n' "$match"
}

# Absolute path to $dir's index.lock, or return 1 when it cannot be resolved.
ff_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(resolved_existing_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# One recovery attempt for a fast-forward that failed on the target's OWN
# index.lock "File exists" signature: remove the lock only when jg-lock-lib.sh's
# jg_lock_is_provably_stale proves it dead (still present, no live holder, mtime
# age past the threshold), so the caller can retry the fast-forward once.
# The proof takes NO companion directory here: the live home itself is always
# held open as cwd by its running squad lead, so a companion check on the home
# could never pass, while a live git keeps its own index.lock open for the whole
# operation - so the lock-file holder plus mtime age is a complete proof.
# Any other failure, a lock path that is not the target's own index.lock, or a
# lock that cannot be proven stale returns non-zero and today's skip stands.
# Diagnostics print to stderr via jg_lock_log, which the session-start bootstrap
# digest merges with stdout, so both outcomes surface.
ff_maybe_clear_stale_index_lock() { # <dir> <label> <merge-output>
  local dir=$1 label=$2 output=$3 err_lock lock age
  age=$(ff_stale_index_lock_age_secs)
  err_lock=$(ff_index_lock_error_path "$output") || return 1
  lock=$(ff_index_lock_path "$dir") || return 1
  [ "$err_lock" = "$lock" ] || return 1
  [ -e "$lock" ] || return 1
  if jg_lock_is_provably_stale "$lock" "" "$age"; then
    if ! rm -f -- "$lock"; then
      jg_lock_log "failed to remove provably-stale git lock $lock for $label; leaving it in place"
      return 1
    fi
    jg_lock_log "removed provably-stale git lock $lock (age >= ${age}s, no live holder) for $label; retrying fast-forward once"
    return 0
  fi
  jg_lock_log "fast-forward for $label blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place"
  return 1
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /resupply
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD squad_lead sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: never force/merge/stash; skip a dirty or
# wrong-branch target and leave its work untouched. An optional squad_lead id
# enables the content-equivalent divergence proof and durable marker described
# in this file's header.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  local squad_lead_id=${6:-} reconciliation_state=${7:-}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out path dirty
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  dirty=$(dirty_paths "$dir" "$ignore_seed_marker")
  if [ -n "$dirty" ]; then
    echo "$label: skipped: dirty working tree"
    # Name every path, one per line, so a skip stays diagnosable without
    # reading this source.
    printf '%s\n' "$dirty" | while IFS= read -r path; do
      echo "  dirty path: $path"
    done
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    [ -z "$reconciliation_state" ] || squad_lead_update_reconcile_clear "$reconciliation_state" "$squad_lead_id" || true
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    if [ -n "$squad_lead_id" ] && [ -n "$reconciliation_state" ] \
      && divergence_is_redundant "$dir" "$local_rev" "$base_rev"; then
      instr=$(changed_instr "$dir" "$base")
      before=$(git -C "$dir" rev-parse --short HEAD)
      if git -C "$dir" reset --keep "$base" >/dev/null 2>&1; then
        after=$(git -C "$dir" rev-parse --short HEAD)
        FF_STATUS="updated"
        FF_INSTR="$instr"
        squad_lead_update_reconcile_clear "$reconciliation_state" "$squad_lead_id" || true
        if [ -n "$instr" ]; then
          echo "$label: reconciled redundant divergence $before..$after (instructions changed: $instr)"
        else
          echo "$label: reconciled redundant divergence $before..$after"
        fi
        return 0
      fi
      echo "$label: skipped: redundant divergence could not be reconciled with reset --keep"
      return 0
    fi
    if [ -n "$squad_lead_id" ] && [ -n "$reconciliation_state" ]; then
      local marker
      if marker=$(squad_lead_update_reconcile_record "$reconciliation_state" "$squad_lead_id" "$local_rev" "$base_rev" "$base"); then
        echo "$label: skipped: diverged from $base; reconciliation required (record: $marker)"
      else
        echo "$label: skipped: diverged from $base; reconciliation required, but its durable record could not be written"
      fi
    else
      echo "$label: skipped: diverged from $base"
    fi
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    # A killed git process can orphan the target's index.lock, after which every
    # fast-forward fails forever on "Unable to create ...index.lock: File exists".
    # Recover once: clear the lock only when provably stale (jg-lock-lib.sh) and
    # retry the fast-forward a single time; any other failure, or an unproven
    # lock, keeps today's skip.
    if ! ff_maybe_clear_stale_index_lock "$dir" "$label" "$out" \
      || ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
      echo "$label: skipped: fast-forward failed: $(first_line "$out")"
      return 0
    fi
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  [ -z "$reconciliation_state" ] || squad_lead_update_reconcile_clear "$reconciliation_state" "$squad_lead_id" || true
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one squad_lead home, accumulating its stable
# jg-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# juggernaut repo itself (JG_ROOT) is never processed as its own squad_lead, and
# each resolved home is processed at most once.
#
# Two optional caller hooks fire from here, each at most once per resolved home:
#   jg_ff_after_instruction_update <id> <home> <window> <instr>
#     the nudge-shaped hook: only for an advance that changed the instruction
#     surface, and only under nudge_requires_instr=yes.
#   jg_ff_after_squad_lead_settled <id> <home> <window> <status> <instr>
#     the settled-state hook: for every home this sweep left AT the base with a
#     live window, whether it advanced (status=updated) or was already there
#     (status=current). A home that was SKIPPED is never settled, so a dirty,
#     diverged, offline, or unsafe home never reaches this hook and nothing here
#     forces, stashes, or discards its work. /resupply uses this hook to
#     reach every live mate that is genuinely on the new bytes, including the
#     ones that needed no advance to get there.
# An undefined hook is simply not called.
process_squad_lead() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real jg_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  jg_root_real=$(resolve_path "$JG_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$jg_root_real" ] || return 0
  if ! validate_squad_lead_home "$id" "$home"; then
    echo "squad_lead $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "squad_lead $id" "$base_mode" yes yes "$id" "${JG_STATE_OVERRIDE:-$JG_HOME/state}"
  if [ -n "$window" ] && { [ "$FF_STATUS" = "updated" ] || [ "$FF_STATUS" = "current" ]; } \
    && type jg_ff_after_squad_lead_settled >/dev/null 2>&1; then
    jg_ff_after_squad_lead_settled "$id" "$home_real" "$window" "$FF_STATUS" "$FF_INSTR"
  fi
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS jg-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type jg_ff_after_instruction_update >/dev/null 2>&1; then
      jg_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE squad_lead direct reports - state/<id>.meta files with
# kind=squad_lead - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_squad_lead. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_squad_lead_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$JG_HOME/data/squad_leads.md} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
    process_squad_lead "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done < <(live_squad_lead_meta_records "$state" "$registry")
}
