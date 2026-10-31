#!/usr/bin/env bash
# jg-host-wiring.sh - wire this machine's host protections and fleet checks for one Juggernaut home.
#
# One entry point for every host-side wiring step the core owns: the guards (kill, read, delete,
# owner, supervisor), the checks a watcher arms, the account pool and quota routes, the merge
# automations, and the services. Each step is a wiring fragment at core/<name>/wiring.sh, run here in
# a working order with the argument shape it documents; a step that also has a teardown runs its
# core/<name>/unwiring.sh. There is no per-feature installer any more and nothing to install
# separately: this script, run by the core's own install or by hand, is the whole catalog.
#
# Usage:
#   jg-host-wiring.sh [--dry-run] [--home <jg-home>] [--unwire] [--list]
#   jg-host-wiring.sh [--dry-run] <jg-home>          (the home may be the positional argument)
#
# <jg-home> is the fleet home with bin/, config/ and state/ in it; JG_HOME names it instead.
# --dry-run reaches every fragment that supports it and prints, without running, the two that do not.
# --unwire runs each step's teardown instead, in reverse order; a step with no teardown is named.
# --list prints "<name><TAB><kind>" per step in run order and writes nothing.
# A rerun is a rerun of each fragment's idempotent wiring and exits 0 when it lands the same wiring;
# one failed step does not stop the rest, and every failed step is named before a nonzero exit.
#
# Exit status: 0 when every step wired, 1 when a step failed, 2 on a usage error.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

dry=0 unwire=0 list=0 home=${JG_HOME:-}
while [ "$#" -gt 0 ]; do
  case $1 in
    --home) home=${2:?--home needs a directory}; shift ;;
    --dry-run) dry=1 ;;
    --unwire) unwire=1 ;;
    --list) list=1 ;;
    -h | --help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) printf 'jg-host-wiring: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)
      if [ -n "$home" ] && [ "$home" != "$1" ]; then
        printf 'jg-host-wiring: one home per run (got %s and %s)\n' "$home" "$1" >&2
        exit 2
      fi
      home=$1
      ;;
  esac
  shift
done

# name:kind, in a working order: route-change reads pipeline-quota-failover's wrapper, guards precede
# anything that chains to them, and the account pool precedes the checks that read it.
#   plain       wiring.sh [--dry-run]
#   home        wiring.sh [--dry-run] <jg-home>
#   env         JG_HOME=<jg-home> wiring.sh [--dry-run]
#   all         wiring.sh [--dry-run] --all <jg-home>   (the home and every active local squad-lead home it lists)
#   home-nodry, all-nodry   the same without --dry-run support: printed, not run, under --dry-run
#   verify      wiring.sh <jg-home> is that feature's wiring check, not a wiring step: its incomplete
#               report is printed and never fails this run
plan=(
  kill-guard:plain
  read-guard:plain
  delete-guard:home
  host-memory:plain
  pipeline-literal-delete:plain
  pipeline-quota-failover:plain
  route-change:plain
  account-pool:verify
  claude-accounts:home-nodry
  quota-axi-pool:plain
  git-identity:home
  repo-guard:plain
  fleet-flow:plain
  fleet-pulse:home
  fleet-stall:env
  key-in-env-check:env
  zai-quota-check:env
  nm-drain:home
  merge-on-green:home
  quota-failover:all
  limit-prompt-move:all-nodry
  model-gate:env
  owner-guard:home
  owner-rules:home
  pane-titles:home
  backlog-lock-reclaim:home
  parked-homes:verify
  sentinel:home
  supervisor-guard:home
  task-priority:plain
  tickets-sync:env
  lookout-adapter:plain
)

if [ "$list" = 1 ]; then
  for entry in "${plan[@]}"; do printf '%s\t%s\n' "${entry%%:*}" "${entry##*:}"; done
  exit 0
fi

if [ -z "$home" ]; then
  printf 'jg-host-wiring: name the home: jg-host-wiring.sh [--dry-run] <jg-home> (or set JG_HOME)\n' >&2
  exit 2
fi
if [ ! -d "$home" ]; then
  printf 'jg-host-wiring: no such home directory: %s\n' "$home" >&2
  exit 2
fi
home=$(cd "$home" && pwd -P)
export JG_HOME=$home

steps=("${plan[@]}")
[ "$unwire" = 0 ] || { steps=(); for ((i = ${#plan[@]} - 1; i >= 0; i--)); do steps+=("${plan[i]}"); done; }

failed='' wired=0 skipped=''
for entry in "${steps[@]}"; do
  name=${entry%%:*}
  kind=${entry##*:}
  file=wiring.sh
  [ "$unwire" = 0 ] || file=unwiring.sh
  script=$here/core/$name/$file
  if [ ! -f "$script" ]; then
    if [ "$unwire" = 1 ]; then
      [ -f "$here/core/$name/wiring.sh" ] || { printf 'jg-host-wiring: %s has no wiring at %s\n' "$name" "$here/core/$name" >&2; failed="$failed $name"; continue; }
      skipped="$skipped $name"
      continue
    fi
    printf 'jg-host-wiring: %s has no %s at %s\n' "$name" "$file" "$script" >&2
    failed="$failed $name"
    continue
  fi
  args=()
  dryable=1
  case $kind in
    plain) ;;
    home) args=("$home") ;;
    env) ;;
    all) args=(--all "$home") ;;
    home-nodry) args=("$home") dryable=0 ;;
    all-nodry) args=(--all "$home") dryable=0 ;;
    verify) args=("$home") ;;
    *) printf 'jg-host-wiring: %s has an unknown kind %s\n' "$name" "$kind" >&2; failed="$failed $name"; continue ;;
  esac
  # A wiring check reports the home's state; an incomplete home is information, not a failed step.
  if [ "$kind" = verify ] && [ "$unwire" = 0 ]; then
    printf '\n== %s: bash core/%s/%s %s\n' "$name" "$name" "$file" "$home"
    bash "$script" "$home" || printf 'jg-host-wiring: %s wiring incomplete (see the lines above; it changes nothing)\n' "$name"
    continue
  fi
  [ "$dry" = 0 ] || args=(--dry-run "${args[@]}")
  printf '\n== %s: bash core/%s/%s%s\n' "$name" "$name" "$file" "${args[*]:+ ${args[*]}}"
  if [ "$dry" = 1 ] && [ "$dryable" = 0 ]; then
    printf 'would-run core/%s/%s%s (this step has no --dry-run of its own)\n' "$name" "$file" "${args[*]:+ ${args[*]//--dry-run/}}"
    continue
  fi
  if ! bash "$script" "${args[@]}"; then
    printf 'jg-host-wiring: %s failed\n' "$name" >&2
    failed="$failed $name"
    continue
  fi
  wired=$((wired + 1))
done

# owner-guard is wired twice: its own fragment and the daily owner-details scan.
if [ "$unwire" = 0 ]; then
  scan=$here/core/owner-guard/install-scan.sh
  if [ -f "$scan" ]; then
    printf '\n== owner-guard scan: bash core/owner-guard/install-scan.sh%s\n' "$([ "$dry" = 0 ] || printf ' --dry-run')"
    if [ "$dry" = 1 ]; then
      bash "$scan" --dry-run "$home" || { printf 'jg-host-wiring: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; }
    else
      bash "$scan" "$home" || { printf 'jg-host-wiring: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; }
    fi
  fi
fi

printf '\n== steps with no teardown of their own:'
missing=0
for entry in "${plan[@]}"; do
  name=${entry%%:*}
  [ -f "$here/core/$name/wiring.sh" ] && [ ! -f "$here/core/$name/unwiring.sh" ] || continue
  printf ' %s' "$name"
  missing=$((missing + 1))
done
printf '\n   %s; each core/<name>/README.md owns how its own host wiring is removed.\n' "$missing"

printf '\njg-host-wiring: %s steps wired' "$wired"
[ -z "$skipped" ] || printf ', no teardown:%s' "$skipped"
if [ -z "$failed" ] || [ "$failed" = ' ' ]; then printf '.\n'; exit 0; fi
printf ', failed:%s\n' "$failed" >&2
exit 1
