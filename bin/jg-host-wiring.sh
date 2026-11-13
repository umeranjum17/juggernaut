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
#   jg-host-wiring.sh [--dry-run] [--home <jg-home>] [--unwire] [--list] [--changed]
#   jg-host-wiring.sh [--dry-run] <jg-home>          (the home may be the positional argument)
#
# <jg-home> is the fleet home with bin/, config/ and state/ in it; JG_HOME names it instead.
# --dry-run reaches every fragment that supports it and prints, without running, the two that do not.
# --unwire runs each step's teardown instead, in reverse order; a step with no teardown is named.
# --list prints "<name><TAB><kind>" per step in run order and writes nothing.
# --changed runs only the steps whose sources changed since that step last wired this home (the live move runs this).
# A rerun is a rerun of each fragment's idempotent wiring and exits 0 when it lands the same wiring;
# one failed step does not stop the rest, and every failed step is named before a nonzero exit, on the
# last line as ", failed: <step> ...".
#
# Each step that wires records the commit of this checkout it wired from in <jg-home>/state/host-wiring.tsv
# ("<step><TAB><commit><TAB><epoch>"); a failed step, a dry run and a step whose sources hold uncommitted edits
# record nothing, and --unwire drops the record. A step's sources are its own core/<name>/ directory, this
# script, and the files it copies or builds from another directory (step_sources). Under --changed a step
# runs when it has no record, its recorded commit is unknown here, or a source differs between that commit and
# this checkout's working tree; a home whose sources did not change since its last wiring runs no step.
#
# A Squad Lead home (marked by jg_compat_marker) never wires the machine-wide units: sentinel (jg-sentinel),
# host-memory (jg-heavy-adopt timer) and lookout-adapter (the one dashboard). They are single per-machine
# units, so the last lead home to run this would take them from Main; per-home steps still run, and --unwire
# skips the same steps. Wake engine, wake watcher and router are not wired here.
#
# A throw-away home (a test's, under a temp root) wires nothing, dry runs and --unwire included, when HOME or an
# XDG config or data dir is this account's own: every step writes there (bin/jg-lab-home-lib.sh owns the rule).
#
# Exit status: 0 when every step wired, 1 when a step failed, 2 on a usage error or a refused throw-away home.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

dry=0 unwire=0 list=0 changed_only=0 home=${JG_HOME:-}
while [ "$#" -gt 0 ]; do
  case $1 in
    --home) home=${2:?--home needs a directory}; shift ;;
    --dry-run) dry=1 ;;
    --changed) changed_only=1 ;;
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
  claude-model-guard:plain
  delete-guard:home
  host-memory:plain
  pipeline-literal-delete:plain
  pipeline-quota-failover:plain
  route-change:plain
  account-pool:home
  claude-accounts:home-nodry
  quota-axi-pool:plain
  git-identity:home
  repo-guard:plain
  fleet-flow:plain
  fleet-pulse:home
  fleet-stall:env
  fleet-report:env
  key-in-env-check:env
  zai-quota-check:env
  nm-drain:home
  merge-on-green:home
  merge-card:home
  goal-loop:home
  critical-stall:home
  stall-action:home
  lead-sweep:home
  pr-pager:home
  auto-dispatch:home
  trunk-latency:home
  status-latency:home
  tmp-reaper:home
  landing-card:home
  machines:view
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
  undelivered-alert:home
)

# The sources one step installs from: its own directory, this script (the plan and argument shapes), and every file
# its wiring copies or builds from outside its own directory. A wiring that takes a new outside source names it here.
step_sources() {  # <name>
  printf '%s\n' "core/$1" bin/jg-host-wiring.sh
  case $1 in
    delete-guard | repo-guard) printf '%s\n' core/guard-host ;;
    owner-guard | owner-rules) printf '%s\n' core/lib/merge-gate-lib.sh ;;
    limit-prompt-move) printf '%s\n' core/parked-homes/bin/jg-parked-homes-lib.sh core/account-pool/bin/jg-account-pool-lib.sh ;;
    quota-failover) printf '%s\n' core/parked-homes/bin/jg-parked-homes-lib.sh core/account-pool/bin/jg-account-pool-lib.sh \
      core/account-pool/bin/jg-pool-claude-env.sh ;;
  esac
}

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
# shellcheck source=bin/jg-lab-home-lib.sh
. "$here/bin/jg-lab-home-lib.sh"
jg_lab_home_guard "$home" jg-host-wiring "${HOME:-}" "${XDG_CONFIG_HOME:-${HOME:-}/.config}" \
  "${XDG_DATA_HOME:-${HOME:-}/.local/share}" || exit 2

# Source the repo marker helper; a copy with no compat file beside it uses the same marker spelling.
if [ -r "$here/bin/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$here/bin/jg-compat.sh"
else
  jg_compat_marker() { printf '%s\n' "${1-}/.jg-squad-lead-home"; }
fi
machine_wide=' sentinel host-memory lookout-adapter '
lead_home=0
[ ! -e "$(jg_compat_marker "$home")" ] || lead_home=1
if [ "$lead_home" = 1 ]; then
  printf 'jg-host-wiring: %s is a Squad Lead home; skipping the machine-wide units:%s (Main owns them)\n' "$home" "${machine_wide% }"
fi

if [ "$changed_only" = 1 ] && [ "$unwire" = 1 ]; then
  printf 'jg-host-wiring: --changed wires; it does not combine with --unwire\n' >&2
  exit 2
fi

# The record of the commit each step last wired from (see the header). An unreadable commit or tree leaves head empty,
# so --changed runs every step and nothing is recorded.
record=$home/state/host-wiring.tsv
head=$(git -C "$here" rev-parse --verify -q HEAD 2>/dev/null) || head=''
dirty=''
[ -z "$head" ] || dirty=$(git -C "$here" diff --name-only HEAD -- 2>/dev/null) || head=''
declare -A wired_at=() wired_when=() diff_of=()
if [ -r "$record" ]; then
  while IFS=$'\t' read -r key commit when; do
    [ -n "$key" ] && [ -n "$commit" ] || continue
    wired_at[$key]=$commit wired_when[$key]=$when
  done < "$record"
fi

touches() {  # <paths, one per line> <name>: 0 when a path is one of the step's sources or lies under one
  local p s
  [ -n "$1" ] || return 1
  while IFS= read -r s; do
    while IFS= read -r p; do
      case $p in "$s" | "$s"/*) return 0 ;; esac
    done <<< "$1"
  done < <(step_sources "$2")
  return 1
}

due() {  # <record key> <name>: 0 when the step must run under --changed
  local rec=${wired_at[$1]:-} d
  [ -n "$head" ] && [ -n "$rec" ] || return 0
  if [ -z "${diff_of[$rec]+set}" ]; then
    d=$(git -C "$here" diff --name-only "$rec" "$head" -- 2>/dev/null) || return 0
    diff_of[$rec]=$d
  fi
  touches "${diff_of[$rec]}${dirty:+$'\n'$dirty}" "$2"
}

mark() {  # <record key> <name>: the step wired from this checkout's commit; uncommitted source bytes record nothing
  [ "$dry" = 0 ] && [ -n "$head" ] || return 0
  if touches "$dirty" "$2"; then unset 'wired_at[$1]' 'wired_when[$1]'; return 0; fi
  wired_at[$1]=$head wired_when[$1]=$(date +%s)
}

steps=("${plan[@]}")
[ "$unwire" = 0 ] || { steps=(); for ((i = ${#plan[@]} - 1; i >= 0; i--)); do steps+=("${plan[i]}"); done; }

failed='' wired=0 skipped='' current=0
for entry in "${steps[@]}"; do
  name=${entry%%:*}
  kind=${entry##*:}
  file=wiring.sh
  [ "$kind" != view ] || file=view.sh
  [ "$unwire" = 0 ] || file=unwiring.sh
  script=$here/core/$name/$file
  if [ "$lead_home" = 1 ] && [ "${machine_wide#*" $name "}" != "$machine_wide" ]; then continue; fi
  if [ "$changed_only" = 1 ] && ! due "$name" "$name"; then current=$((current + 1)); continue; fi
  if [ ! -f "$script" ]; then
    if [ "$unwire" = 1 ]; then
      [ -f "$here/core/$name/wiring.sh" ] || { [ "$kind" = view ] && [ -f "$here/core/$name/view.sh" ]; } || { printf 'jg-host-wiring: %s has no wiring at %s\n' "$name" "$here/core/$name" >&2; failed="$failed $name"; continue; }
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
    home | view) args=("$home") ;;
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
    mark "$name" "$name"
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
  [ "$unwire" = 1 ] || mark "$name" "$name"
done

# owner-guard is wired twice: its own fragment and the daily owner-details scan.
if [ "$unwire" = 0 ]; then
  scan=$here/core/owner-guard/install-scan.sh
  if [ "$changed_only" = 1 ] && ! due owner-guard-scan owner-guard; then
    current=$((current + 1))
  elif [ -f "$scan" ]; then
    printf '\n== owner-guard scan: bash core/owner-guard/install-scan.sh%s\n' "$([ "$dry" = 0 ] || printf ' --dry-run')"
    if [ "$dry" = 1 ]; then
      bash "$scan" --dry-run "$home" || { printf 'jg-host-wiring: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; }
    else
      if bash "$scan" "$home"; then mark owner-guard-scan owner-guard
      else printf 'jg-host-wiring: owner-guard scan failed\n' >&2; failed="$failed owner-guard-scan"; fi
    fi
  fi
fi

# The record is this run's result: a teardown drops it, so the next --changed run wires every step again.
if [ "$dry" = 0 ] && [ -d "$home/state" ]; then
  if [ "$unwire" = 1 ]; then
    rm -f -- "$record"
  elif [ -n "$head" ] && tmp=$(mktemp "$record.XXXXXX"); then
    for key in "${!wired_at[@]}"; do printf '%s\t%s\t%s\n' "$key" "${wired_at[$key]}" "${wired_when[$key]:-}"; done | LC_ALL=C sort > "$tmp"
    mv -f -- "$tmp" "$record" || rm -f -- "$tmp"
  fi
fi

if [ "$changed_only" = 0 ]; then
  printf '\n== steps with no teardown of their own:'
  missing=0
  for entry in "${plan[@]}"; do
    name=${entry%%:*}
    [ -f "$here/core/$name/wiring.sh" ] && [ ! -f "$here/core/$name/unwiring.sh" ] || continue
    printf ' %s' "$name"
    missing=$((missing + 1))
  done
  printf '\n   %s; each core/<name>/README.md owns how its own host wiring is removed.\n' "$missing"
fi

printf '\njg-host-wiring: %s steps wired' "$wired"
[ "$changed_only" = 0 ] || printf ', %s unchanged since their last wiring at this home' "$current"
[ -z "$skipped" ] || printf ', no teardown:%s' "$skipped"
if [ -z "$failed" ] || [ "$failed" = ' ' ]; then printf '.\n'; exit 0; fi
printf ', failed:%s\n' "$failed" >&2
exit 1
