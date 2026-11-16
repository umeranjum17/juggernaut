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
#   jg-host-wiring.sh [--dry-run] [--home <jg-home>] [--unwire] [--list] [--changed] [--drift]
#   jg-host-wiring.sh [--dry-run] <jg-home>          (the home may be the positional argument)
#
# <jg-home> is the fleet home with bin/, config/ and state/ in it; JG_HOME names it instead.
# --dry-run reaches every fragment that supports it and prints, without running, the two that do not.
# --unwire runs each step's teardown instead, in reverse order; a step with no teardown is named.
# --list prints "<name><TAB><kind>" per step in run order and writes nothing.
# --changed runs only the steps whose sources changed since that step last wired this home, plus every step whose installed
# copy differs from its source or is gone (the live move runs this, so In use means the copies that run equal the repo's).
# --drift prints "<step><TAB><installed copy><TAB>differs|missing<TAB><source>" per drifted copy and writes nothing.
# A rerun is a rerun of each fragment's idempotent wiring and exits 0 when it lands the same wiring;
# one failed step does not stop the rest, and every failed step is named before a nonzero exit, on the
# last line as ", failed: <step> ...".
#
# Each step that wires records the commit of this checkout it wired from in <jg-home>/state/host-wiring.tsv
# ("<step><TAB><commit><TAB><epoch>"); a failed step, a dry run and a step whose sources hold uncommitted edits
# record nothing, and --unwire drops the record. A step's sources are its own core/<name>/ directory, this
# script, and the files it copies or builds from another directory (step_sources). Under --changed a step
# runs when it has no record, its recorded commit is unknown here, a source differs between that commit and this
# checkout's working tree, or an installed copy it owns (step_copies) differs from its source or is gone; a home
# whose sources did not change since its last wiring and whose installed copies all match runs no step.
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

dry=0 unwire=0 list=0 changed_only=0 drift=0 home=${JG_HOME:-}
while [ "$#" -gt 0 ]; do
  case $1 in
    --home) home=${2:?--home needs a directory}; shift ;;
    --dry-run) dry=1 ;;
    --changed) changed_only=1 ;;
    --unwire) unwire=1 ;;
    --list) list=1 ;;
    --drift) drift=1 ;;
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
  merge-on-green:home
  merge-card:home
  goal-loop:home
  critical-stall:home
  stall-action:home
  lead-sweep:home
  installed-drift:home
  tool-update-check:home
  pane-sweep:home
  pr-pager:home
  auto-dispatch:home
  trunk-latency:home
  green-pin-stale:home
  trunk-ci:home
  recon-ready:home
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
  tickets-sync:env
  lookout-adapter:plain
  undelivered-alert:home
  lock-lease:home
  wake-rollup:home
)

# The sources one step installs from: its own directory, this script (the plan and argument shapes), and every file
# its wiring copies or builds from outside its own directory. A wiring that takes a new outside source names it here.
step_sources() {  # <name>
  printf '%s\n' "core/$1" bin/jg-host-wiring.sh
  case $1 in
    installed-drift) printf '%s\n' bin/jg-installed-drift.sh ;;
    tool-update-check) printf '%s\n' bin/jg-tool-update-check.sh ;;
    delete-guard | repo-guard) printf '%s\n' core/guard-host ;;
    owner-guard | owner-rules) printf '%s\n' core/lib/merge-gate-lib.sh ;;
    limit-prompt-move) printf '%s\n' core/parked-homes/bin/jg-parked-homes-lib.sh core/account-pool/bin/jg-account-pool-lib.sh ;;
    quota-failover) printf '%s\n' core/parked-homes/bin/jg-parked-homes-lib.sh core/account-pool/bin/jg-account-pool-lib.sh \
      core/account-pool/bin/jg-pool-claude-env.sh ;;
  esac
}

# The byte-copies one step installs on this host, as "<source in this checkout><TAB><installed path>" lines: the files an
# installed copy must equal. Only plain copies belong here. A generated file (a shim, a hook wrapper, a unit), a seeded
# file the owner edits (repo-guard's allow-list) and a copy the wiring installs only where the host already holds the
# thing it hooks into (claude-model-guard) are left out. A wiring that installs a new copy names it here, or --changed
# cannot see that copy drift; tests/jg-host-wiring.test.sh fails when an installed file equal to a repo file is unnamed.
step_copies() {  # <name>
  local data=${XDG_DATA_HOME:-${HOME:-}/.local/share} c=core/$1
  into() {  # <installed dir> <source dir> <file>...: each file of the source dir, installed under the same name
    local to=$1 from=$2 f
    shift 2
    for f in "$@"; do printf '%s\t%s\n' "$from/$f" "$to/$f"; done
  }
  case $1 in
    kill-guard | read-guard) into "$data/jg-$1" "$c" guard.mjs ;;
    delete-guard) into "$data/jg-delete-guard" "$c" check.sh guard.mjs ;;
    host-memory) into "$data/jg-host-memory" "$c/bin" jg-mem-gate.sh jg-heavy-adopt.sh ;;
    pipeline-literal-delete) into "$data/jg-pipeline-literal-delete" "$c" context.mjs rule.txt ;;
    pipeline-quota-failover) into "${HOME:-}/.local/share/jg-pipeline-quota-failover" "$c" pi-quota-failover ;;
    route-change) into "$data/jg-route-change" "$c" route-change ;;
    account-pool) into "$data/jg-account-pool" "$c/bin" jg-route-probe jg-route-chain-lib.sh ;;
    quota-axi-pool) into "$data/jg-quota-axi-pool" "$c/bin" quota-axi-pool ;;
    git-identity) into "$data/jg-git-identity" "$c" git-identity ;;
    repo-guard) into "$data/jg-repo-guard" "$c" run-guard ;;
    fleet-flow) into "$data/jg-fleet-flow" "$c/bin" jg-flow-check.sh ;;
    fleet-stall) into "$data/jg-fleet-stall" "$c" fleet-stall-check ;;
    key-in-env-check) into "$data/jg-key-in-env-check" "$c" key-in-env-check ;;
    merge-on-green)
      into "$data/jg-merge-on-green" "$c" merge-on-green.sh checks-lint.sh jg-checks-lint.sh stale-pr-alarm.sh \
        merge-ready-batch.sh red-ci-ticket.sh backlog-shipped-reconcile.sh .done-done.yaml ;;
    goal-loop) into "$data/jg-goal-loop" "$c" goal-loop.sh proof-run.sh ;;
    critical-stall) into "$data/jg-critical-stall" "$c" critical-stall.sh ;;
    stall-action) into "$data/jg-stall-action" "$c" relaunch.sh stall-action.sh ;;
    lead-sweep) into "$data/jg-lead-sweep" "$c" lead-sweep.sh ;;
    pane-sweep) into "$data/jg-pane-sweep" "$c" sweep.sh ;;
    pr-pager) into "$data/jg-pr-pager" "$c" pager.sh ;;
    auto-dispatch) into "$data/jg-auto-dispatch" "$c" dispatch.sh ;;
    trunk-latency | status-latency) into "$data/jg-$1" "$c" latency.sh ;;
    green-pin-stale) into "$data/jg-green-pin-stale" "$c" stale.sh ;;
    trunk-ci) into "$data/jg-trunk-ci" "$c" ci-result.sh ;;
    recon-ready) into "$data/jg-recon-ready" "$c" ready.sh ;;
    landing-card) into "$data/jg-landing-card" "$c" landing-card.sh ;;
    wake-rollup) into "$data/jg-wake-rollup" "$c" rollup.sh ;;
    undelivered-alert) into "$data/jg-undelivered-alert" "$c" undelivered-alert.sh ;;
    lock-lease) into "$data/jg-lock-lease" "$c" lock-lease.check.sh ;;
    backlog-lock-reclaim) into "$data/jg-backlog-lock-reclaim" "$c" backlog-lock-reclaim.check.sh ;;
    quota-failover)
      into "$data/jg-quota-failover/account-pool/bin" core/account-pool/bin jg-account-pool-lib.sh jg-pool-claude-env.sh
      into "$data/jg-quota-failover/parked-homes/bin" core/parked-homes/bin jg-parked-homes-lib.sh
      into "$data/jg-quota-failover/quota-failover" "$c" check.sh jg-probe-folder-lib.sh quota-failover ;;
    limit-prompt-move)
      into "$data/jg-limit-prompt-move/account-pool/bin" core/account-pool/bin jg-account-pool-lib.sh
      into "$data/jg-limit-prompt-move/parked-homes/bin" core/parked-homes/bin jg-parked-homes-lib.sh
      into "$data/jg-limit-prompt-move/limit-prompt-move" "$c" check.sh limit-prompt-move ;;
    model-gate) into "$data/jg-model-gate" "$c/bin" jg-model-gate ;;
    owner-guard) into "$data/jg-owner-guard-scan" "$c" scan-check ;;
    pane-titles) into "$data/jg-pane-titles" "$c" launch-env-hook ;;
    sentinel) into "$data/jg-sentinel/bin" "$c/bin" jg-sentinel.sh ;;
    supervisor-guard)
      into "$data/jg-supervisor-guard" "$c/bin" jg-supervisor-work-pretool-check.sh jg-supervisor-work-decide.mjs \
        jg-supervisor-work-command-policy.mjs ;;
    tickets-sync)
      into "$data/jg-tickets-sync/tickets-sync" "$c" sync.py ticket.py identity.py lane.py hierarchy.py \
        task_rows.py cleanup.py legacy.py reconcile.py release.py drop.py tidy.py
      local icon
      for icon in "$here/$c"/icons/*; do
        [ -f "$icon" ] || continue
        into "$data/jg-tickets-sync/tickets-sync/icons" "$c/icons" "${icon##*/}"
      done ;;
  esac
}

# The installed copies of one step that are gone or differ from their source: "<installed><TAB>missing|differs<TAB><source>".
copy_drift() {  # <name>
  local src dst
  while IFS=$'\t' read -r src dst; do
    [ -f "$here/$src" ] || continue
    if [ ! -e "$dst" ]; then printf '%s\tmissing\t%s\n' "$dst" "$here/$src"
    elif ! cmp -s -- "$here/$src" "$dst"; then printf '%s\tdiffers\t%s\n' "$dst" "$here/$src"
    fi
  done < <(step_copies "$1")
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

if [ "$drift" = 1 ]; then
  for entry in "${plan[@]}"; do
    name=${entry%%:*}
    if [ "$lead_home" = 1 ] && [ "${machine_wide#*" $name "}" != "$machine_wide" ]; then continue; fi
    while IFS=$'\t' read -r copy state source; do
      printf '%s\t%s\t%s\t%s\n' "$name" "$copy" "$state" "$source"
    done < <(copy_drift "$name")
  done
  exit 0
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
  touches "${diff_of[$rec]}${dirty:+$'\n'$dirty}" "$2" && return 0
  [ -n "$(copy_drift "$2")" ]  # a copy edited or deleted since the step wired is drift whatever git says
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
