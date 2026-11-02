#!/usr/bin/env bash
# Reap remote job workers whose code root no longer exists.
#
# Usage: jg-remote-job-reap-orphans.sh [--dry-run]
#   --dry-run reports what would be reaped and signals nothing.
#
# A remote job worker (bin/jg-remote-job-worker.sh) is launched from a specific
# Juggernaut code root: the account's own checkout under the LaunchAgent, a
# remote squad_lead's checkout, a no-mistakes gate worktree, a pooled task
# worktree, or a test fixture root. When that root is pruned while the worker is
# running, the worker is reparented to init and, on older builds, keeps polling
# and logging indefinitely. Current workers stop themselves once their root is
# gone (bin/jg-remote-job-worker.sh); this sweep is the belt-and-suspenders pass
# that clears workers already orphaned that way, including ones started before
# self-termination shipped.
#
# The reap condition is exactly jg_remote_job_root_is_live failing for the root
# named in the worker's own command line. That is deliberately the whole test:
# a worker whose root is gone can never claim, validate, or execute another job,
# and no healthy worker can present a missing root. The account's healthy
# LaunchAgent worker, a live remote squad_lead's worker, and any worker whose
# checkout still exists are therefore never candidates, with no dependence on
# log paths, process age, or which home is sweeping.
#
# Only this user's processes are inspected, and this process, its own process
# group, and any ancestor are never signalled. Each candidate is stopped through
# the shared jg_remote_job_stop_worker_tree, so the whole worker tree goes at
# once (TERM first, KILL only for a survivor) and a group whose leader is not
# itself a worker is stopped as a single process instead.
#
# Prints one line per reaped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run, so a
# caller can sweep without risking its own outcome.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/jg-remote-job-lib.sh
. "$SCRIPT_DIR/jg-remote-job-lib.sh"

DRY_RUN=0
REAP_SUFFIX=/bin/jg-remote-job-worker.sh

reap_die() { printf 'jg-remote-job-reap-orphans: %s\n' "$1" >&2; exit 2; }

reap_usage() {
  cat <<'TXT'
Usage: jg-remote-job-reap-orphans.sh [--dry-run]

Stop every remote job worker whose Juggernaut code root has been pruned. A
worker whose root still exists - the account's LaunchAgent worker, a live
remote squad_lead's worker - is never a candidate. --dry-run reports the
candidates and signals nothing. Read this script's header for the full rule.
TXT
}

# The code root a worker command line was launched from, echoed only when the
# command is unambiguously a worker invocation: an absolute script path ending
# in the worker suffix, optionally preceded by the interpreter ps reports as
# "/bin/bash <script>", with at most the --serve argument after it.
reap_worker_root() { # <command>
  local command=$1 path prefix leading
  case "$command" in
    *"$REAP_SUFFIX --serve") path=${command%" --serve"} ;;
    *"$REAP_SUFFIX") path=$command ;;
    *) return 1 ;;
  esac
  prefix=${path%"$REAP_SUFFIX"}
  case "$prefix" in /*) ;; *) return 1 ;; esac
  leading=${prefix%% *}
  # Drop the leading token only when it really is the interpreter binary, so a
  # code root that itself contains a space is read whole rather than split.
  if [ "$leading" != "$prefix" ] && [ -f "$leading" ] && [ -x "$leading" ]; then
    prefix=${prefix#"$leading" }
  fi
  case "$prefix" in /*) ;; *) return 1 ;; esac
  printf '%s\n' "$prefix"
}

reap_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

reap_orphans() {
  local uid scan pid command live root own_pgid pgid
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) reap_die "cannot resolve the current uid" ;; esac
  scan=$(ps -u "$uid" -o pid=,command= 2>/dev/null) ||
    reap_die "cannot scan this account's processes for remote job workers"
  own_pgid=$(jg_remote_job_process_pgid "$$" 2>/dev/null || true)
  # ps pads the pid column to the widest pid on the host, so the fields are read
  # with default word splitting rather than by fixed offsets or a single space.
  while read -r pid command; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$command" ] || continue
    root=$(reap_worker_root "$command") || continue
    jg_remote_job_root_is_live "$root" && continue
    [ "$pid" != "$$" ] || continue
    reap_is_self_or_ancestor "$pid" && continue
    if [ -n "$own_pgid" ]; then
      pgid=$(jg_remote_job_process_pgid "$pid" 2>/dev/null || true)
      [ "$pgid" != "$own_pgid" ] || continue
    fi
    # Re-read the command from the live process so a recycled pid cannot be
    # signalled on the strength of a stale scan line.
    live=$(jg_remote_job_process_command "$pid" 2>/dev/null || true)
    read -r live <<< "$live"
    [ "$live" = "$command" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'would reap abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
      continue
    fi
    if jg_remote_job_stop_worker_tree "$pid"; then
      printf 'reaped abandoned remote job worker %s (pruned code root %s)\n' "$pid" "$root"
    else
      printf 'warning: abandoned remote job worker %s survived reaping (pruned code root %s)\n' "$pid" "$root" >&2
    fi
  done <<EOF
$scan
EOF
}

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1; [ "$#" -eq 1 ] || reap_die "unexpected arguments" ;;
  -h|--help) reap_usage; exit 0 ;;
  *) reap_die "unexpected argument: $1" ;;
esac

reap_orphans
