#!/usr/bin/env bash
# jg-test-run.sh - single owner of Juggernaut's behavior-test runner, lane
# composition for portable CI shards, local --jobs for proven-concurrent work,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   jg-test-run.sh --all
#   jg-test-run.sh --family <name>
#   jg-test-run.sh --changed [--base <git-ref>]
#   jg-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   jg-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   jg-test-run.sh --proven-isolated
#   jg-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Local trunk required set (eight shards run side by side, each warned at the CI bound):
#   jg-test-run.sh --required-shards <base-ref> <output-dir>
# Writes one timing JSON per shard and required.json via --aggregate-json. Every shard runs every script it selected;
# a failed script refuses, and a shard over its wall-clock budget is a JG_TEST_OVERRUN warning, never a red.
# Inspection (no execution):
#   jg-test-run.sh --list --all
#   jg-test-run.sh --list --family <name>
#   jg-test-run.sh --list --lane portable-parallel-1
#   jg-test-run.sh --list-scheduled --family <name>
#   jg-test-run.sh --list-scheduled --lane portable-parallel-1
#   jg-test-run.sh --list-families
#   jg-test-run.sh --list-concurrent-safe-families
#   jg-test-run.sh --concurrent-safe-family-jobs-max <name>
#   jg-test-run.sh --list-lanes
#   jg-test-run.sh --check-coverage
#   jg-test-run.sh --show-limits
#
# Aggregation (no suite execution):
#   jg-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run. Each
#                   script record carries its family, expected gate-skip class,
#                   exit, duration, whether it gate-skipped, and the reason it
#                   gave (empty when it ran), so a lane can say which harness or
#                   tool this host could not exercise.
#   --list          print selected script paths (one per line) and exit 0
#   --list-scheduled
#                   print selected paths longest-hint-first and exit 0.
#                   Only --lane portable-parallel-1 or portable-parallel-2 uses
#                   parallel hints, falling back to serial weights if missing.
#                   Every other selection uses serial weights alone.
#                   Equal weights are ordered by path under LC_ALL=C.
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --max-weight-ms <ms>
#                   drop scripts whose recorded serial duration hint is over <ms>
#                   after selection, and name each one on stderr. The pull request
#                   fast set uses it so a slow suite runs in the post-merge lane
#                   instead of holding the merge.
#   --hosted-timings <file>
#                   interim hosted-job rule: drop a script that ended at the time bound
#                   (exit 124) in any of its last five hosted runs, or that has no hosted
#                   time, and name each one on stderr. The file is tab separated, one
#                   hosted run per line, oldest first: <script> <exit> <duration_ms>;
#                   '#' lines are comments. The script still runs on our host, in the
#                   proof and in the line's verify. Remove with the hosted shell test job.
#   --hosted        drop the scripts tests/hosted-needs.tsv lists when a tool they need is not on this
#                   PATH, and name each one on stderr with the missing tool. The hosted CI job passes it;
#                   without it the selection is unchanged, so the same scripts still run on our host.
#                   Interim, until the hosted shell test job is removed.
#   --shard <k>of<n>
#                   keep only shard k of n of the selection, after the exclusions and
#                   the weight cap, so one pull request selection can run on n runners
#                   at once. Scripts are packed longest-hint-first onto the lightest
#                   shard (ties take the lowest index), so the n shards are disjoint,
#                   together are the whole selection, and every runner computes the same
#                   split. A shard that gets nothing runs nothing and passes.
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Plain --changed and a plain list of script paths use
#                   min(4, cpus) workers when multiple selected scripts are
#                   admissible; --lane, --family, and --all stay serial unless
#                   asked for concurrency explicitly.
#                   N>1 is allowed only when every selected script is proven
#                   safe to run concurrently: individually in the proven-isolated
#                   set (bin/jg-test-isolation-proof.sh --list), or in a family
#                   carrying a recorded concurrent proof
#                   (list_concurrent_safe_families below). Overall cap is 8;
#                   family proofs may impose a lower cap. Individually proven
#                   scripts share one phase; scripts admitted only by a family
#                   proof run in a separate phase for each family. Concurrent
#                   phases use serial weights, longest-hint-first. Unproven stateful
#                   scripts run serially after all concurrent phases. Default is
#                   1 (serial) except for plain --changed and a plain list of
#                   script paths, which use the bounded automatic scheduler.
#   --per-script-timeout-secs N
#                   advise on a script that runs longer than N seconds (default:
#                   script_timeout_seconds from the limits file, 1800, so every
#                   run bounds every script; an explicit 0 disables): a JG_TEST_SLOW line, and the script
#                   keeps its own result while it keeps writing output. A script
#                   whose output stops for a whole N seconds is hung and ends as
#                   exit 124: its process group and every descendant still
#                   carrying its mark are killed, its private temp folder is
#                   removed, and a JG_TEST_TIMEOUT line names it. --changed applies a per-test bound automatically,
#                   max(120s, 4 x the test's CI hint), by the same rule: a slow
#                   script that passes stays green. --max-wall-ms is checked
#                   after the run and so cannot catch a hang on its own.
#                   External interruption cleanup is outside this runner's
#                   guarantee; configured per-script bounds remain authoritative.
#   --gate          (with --changed, also skips and logs the scripts in tests/gate-quarantine.tsv)
#                   the pull-request gate contract, which bin/jg-local-suite.sh
#                   passes: enforce the per-test speed limits and apply the
#                   configured whole-run gate budget unless --max-wall-ms names
#                   one. A test over its speed limit is reported by name with its
#                   measured time and is neither failed nor killed for it; the
#                   whole-run budget is the gate's bound.
#   --enforce-test-speed
#                   accepted so the nightly suite's command line stays valid; a
#                   speed-limit breach is reported in every mode (see below).
#   --show-limits   print the effective e2e_seconds, unit_seconds,
#                   gate_wall_seconds, script_timeout_seconds and machine_runs_max from the config file
#                   and exit without running anything.
#   --max-wall-ms N fail the run when its measured invocation wall clock exceeds
#                   N milliseconds, including an empty selection, and stop
#                   starting scripts once the budget is spent so the overshoot
#                   stays under one per-script bound. It cannot interrupt a
#                   script already running; those are bounded by the per-script
#                   bound above. Pathological output sinks that block
#                   finalization are explicitly out of scope.
#   --wall-warn-ms N
#                   the wall clock as a warning, never a red: every selected
#                   script runs, and a run past N milliseconds prints one
#                   JG_TEST_OVERRUN line with the host load, and still passes
#                   when no script failed. It takes the place of the gate's
#                   whole-run budget and cannot be given with --max-wall-ms.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   JG_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   JG_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   JG_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   JG_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   JG_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#   JG_TEST_BUDGET max_wall_ms=<n> duration_ms=<n>   (only with --max-wall-ms)
#   JG_TEST_OVERRUN budget_ms=<n> duration_ms=<n> load=<1-min load> cpus=<n> selection=<selection>
#                                                    (only with --wall-warn-ms, and only past it)
#
# Machine sharing:
#   A run that executes scripts (the --required-shards gate counts once) waits
#   for one of machine_runs_max run slots on this machine before it starts, and
#   every script it starts shares the caller's Go build cache, so a test that
#   moves HOME does not compile Go again. Queue time is not charged to
#   --max-wall-ms. bin/jg-test-host-lib.sh owns both contracts.
#
# Placement refusal:
#   A task worker is assigned an isolated worktree, and that placement is
#   checked only when its task starts. When JG_TASK_ID marks such a worker and
#   this runner resolves to the repository's PRIMARY checkout, every executing
#   mode refuses before selecting a suite: the suite creates and switches
#   branches, and the primary is the checkout every linked worktree resolves
#   against. Inspection modes execute nothing and stay available, and a run with
#   no JG_TASK_ID set is unchanged.
#
# Exit status is non-zero if any selected script exits non-zero, a configured
# --fail-on-gate-skip token appears, the measured duration exceeds
# --max-wall-ms, timing-artifact finalization fails, or a concurrent worker
# violates its isolation check. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate; each one
# is logged with its reason and recorded in the timing artifact.
#
# Per-test speed limits:
#   e2e_seconds, unit_seconds and gate_wall_seconds live in
#   defaults/test-speed-limits, overridable per home by
#   config/test-speed-limits, and --show-limits prints them. A script's class
#   comes from its name: *-e2e.test.sh is end to end, every other script is a
#   unit or policy test. A script over its limit (an e2e script: e2e_seconds; a
#   unit script: max(unit_seconds, 2 x its CI hint)) is reported by name with the
#   milliseconds it measured and the limit. The report never fails the run and
#   never kills the script: the same 60 s end-to-end limit killed real Herdr
#   scripts that ran 60.04 s on a loaded runner and hid what they had still to
#   prove. A hung script is bounded by --per-script-timeout-secs, the --changed
#   ceiling, the gate budget and the job timeout.
#
# expected_gate_skip classes name why a family is allowed to skip: herdr (the
# pinned real-Herdr lane), optional-binary (a backend whose binary is optional),
# live-capability (a live-harness guard governed by jg_live_gate, which records
# unavailable tools and explicit policy skips; see tests/lib.sh), or none.
#
# Every selected script runs isolated from the host's global and system Git
# configuration, including one that sources no test helper of its own;
# tests/git-config-helpers.sh owns that contract and its limits.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/jg-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set, packed from the measured hints
# in portable_parallel_weight_hints (see docs/jg-test-portable-shards.md).
# --check-coverage reports parallel_max_ms (the larger lane hint sum),
# parallel_imbalance_ms (the absolute difference between the sums), and
# parallel_unhinted (the number of members missing a parallel hint).
# These sums exclude unhinted members and are estimates, not measured job wall
# times. Missing parallel hints are reported without failing this guard.
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --check-coverage also reports serial_max_ms (largest packed hint sum, including
# default weights) and serial_budget_ms (the 20-minute packing target). A split above
# that target, or too many unhinted serial scripts, prints a warning and the line
# "JG_TEST_COVERAGE advise ..." (same fields as "ok") and exits 0: a time estimate
# never refuses a landing or a CI run; a script no shard runs still does. Neither figure is an execution timeout or proof of
# observed headroom: refresh growing files from CI measurements.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all. The one
# place it is deliberately narrow is a bin/ path with no curated family: a test
# that names it is selected as that SCRIPT, because the reference is per-script
# evidence. Consumer bin/ scripts still resolve through the curated map, so
# recorded family-level coupling still expands to the whole family.
# tests/lib.sh, tests/fixtures.sh, tests/*-helpers.sh and tests/*-fixture.sh are
# shared files that map to the suites naming them; a fixture under
# tests/fixtures/<dir>/ is mapped by that directory instead. Curated family arms
# above those also name individual tests/ files explicitly.
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
set -eu

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

RUN_STARTED_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_STARTED_MS=$(now_ms)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

MODE=
LIST_ONLY=0
LIST_SCHEDULED=0
SHOW_LIMITS=0
GATE_MODE=0
LIST_FAMILIES=0
LIST_CONCURRENT_SAFE_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
MAX_WEIGHT_MS=
HOSTED_TIMINGS=
HOSTED=0
SHARD=
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_EXPLICIT=0
JOBS_MAX=8
MAX_WALL_MS=
WARN_WALL_MS=
PER_SCRIPT_TIMEOUT_SECS=
PER_SCRIPT_EXPLICIT=0
TEST_SPEED_SCRIPT_TIMEOUT_SECONDS=1800
# Per-test speed limits and the gate's whole-run budget, read from
# defaults/test-speed-limits and overridden by JG_HOME/config/test-speed-limits.
# A test over its limit is reported naming its measured time; it is never a
# failure or a kill bound (see "Per-test speed limits" in the header).
TEST_SPEED_E2E_SECONDS=60
TEST_SPEED_UNIT_SECONDS=5
TEST_SPEED_GATE_SECONDS=600
# How many runs may execute tests on this machine at once (machine_runs_max; 0 is one per 16 cpus, at least one).
TEST_MACHINE_RUNS_MAX=0
# Hard per-test ceiling on the automatic --changed path: max(120s, 4 x the
# test's measured hint), so a wedged script ends as a bounded failure naming it
# within minutes, not at a job cancel (a 1500s flat bound let tests/jg-mail hang
# 20 minutes). It is a guard, not a speed control.
CHANGED_CEILING=0
CHANGED_CEILING_FLOOR_SECS=120

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
PORTABLE_SERIAL_SHARDS=12

# Conservative balance hint for a portable-serial script with no measurement.
# Rounded above the current CI mean, including the capability-skipped scripts.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=45000

# Packing target, not an execution timeout: leave at least ten minutes of the
# normal CI tier for setup and runtime variance. --check-coverage refuses a
# modeled serial shard above this target; refresh hints or rebalance instead.
PORTABLE_SERIAL_MAX_WEIGHT_MS=1200000

# Largest share of the serial lane allowed to run on the default weight above.
# Hints are what keep the shards balanced, so once too much of the lane is
# unmeasured the balance is guesswork and one shard can reach its CI job cap
# while another sits idle. The coverage guard refuses past this share, which
# leaves room for newly added tests while making a stale hint table fail loudly
# instead of silently. docs/jg-test-portable-shards.md owns the refresh.
PORTABLE_SERIAL_MAX_UNHINTED_PERCENT=15

# A test's class comes from its own name, which is what the shipped config file
# documents: anything ending -e2e.test.sh is an end-to-end test, every other
# script is a unit or policy test.
test_speed_class_for() {  # <basename> -> e2e|unit
  case $1 in *-e2e.test.sh) printf 'e2e\n' ;; *) printf 'unit\n' ;; esac
}

# A unit test's own bound is max(unit_seconds, 2 x its measured hint), so the
# floor serves quick tests and a known-slow test gets headroom over what CI
# measured for it; a test with no hint gets the floor. A test over its own bound
# is still reported, so a new slow test is still caught. Class e2e keeps one limit.
script_hint_ms() {  # <basename> -> measured ms, empty when none
  local ms
  ms=$(portable_parallel_weight_hints | awk -v want="tests/$1" '$1 == want { print $2; exit }')
  [ -n "$ms" ] || ms=$(portable_serial_weight_hints | awk -v want="tests/$1" '$1 == want { print $2; exit }')
  printf '%s\n' "$ms"
}

test_speed_limit_for() {  # <class> [<basename>] -> whole seconds, 0 when unset
  local floor hint bound
  case $1 in
    e2e) printf '%s\n' "${TEST_SPEED_E2E_SECONDS:-60}"; return 0 ;;
  esac
  floor=${TEST_SPEED_UNIT_SECONDS:-5}
  hint=
  [ -n "${2:-}" ] && hint=$(script_hint_ms "$2")
  case $hint in ''|*[!0-9]*) printf '%s\n' "$floor"; return 0 ;; esac
  bound=$(( (2 * hint + 999) / 1000 ))
  [ "$floor" -gt 0 ] && [ "$bound" -lt "$floor" ] && bound=$floor
  printf '%s\n' "$bound"
}

# The hard bound applied to one script, in seconds, 0 when unbounded. The speed
# limits are reports, not bounds; only the --changed ceiling and a caller's
# --per-script-timeout-secs bound a script, and the tighter one wins.
script_speed_bound_secs() {  # <script> -> seconds
  local bound=0
  if [ "$CHANGED_CEILING" -eq 1 ]; then
    # Hard ceiling on the Changed path: max(floor, 4 x the test's hint), so a
    # hung test ends in a bounded, named failure within minutes, not at job cancel.
    local hint ceil
    hint=$(script_hint_ms "$(basename "$1")")
    case $hint in ''|*[!0-9]*) hint=0 ;; esac
    ceil=$(( 4 * hint / 1000 ))
    [ "$ceil" -lt "$CHANGED_CEILING_FLOOR_SECS" ] && ceil=$CHANGED_CEILING_FLOOR_SECS
    if [ "$bound" -eq 0 ] || [ "$ceil" -lt "$bound" ]; then bound=$ceil; fi
  fi
  if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] &&
    { [ "$bound" -eq 0 ] || [ "$PER_SCRIPT_TIMEOUT_SECS" -lt "$bound" ]; }; then
    bound=$PER_SCRIPT_TIMEOUT_SECS
  fi
  printf '%s\n' "$bound"
}

# Read the limits once. A home's config file wins over the shipped default, so a
# captain can loosen one limit without editing tracked material.
load_test_speed_limits() {
  local f v
  for f in "${TEST_SPEED_LIMITS_FILE:-}" "${JG_HOME:-}/config/test-speed-limits" \
           "$ROOT/defaults/test-speed-limits"; do
    [ -n "$f" ] && [ -r "$f" ] || continue
    v=$(sed -n 's/^e2e_seconds=//p' "$f" | tail -n 1)
    case $v in ''|*[!0-9]*) ;; *) TEST_SPEED_E2E_SECONDS=$v ;; esac
    v=$(sed -n 's/^unit_seconds=//p' "$f" | tail -n 1)
    case $v in ''|*[!0-9]*) ;; *) TEST_SPEED_UNIT_SECONDS=$v ;; esac
    v=$(sed -n 's/^gate_wall_seconds=//p' "$f" | tail -n 1)
    case $v in ''|*[!0-9]*) ;; *) TEST_SPEED_GATE_SECONDS=$v ;; esac
    v=$(sed -n 's/^script_timeout_seconds=//p' "$f" | tail -n 1)
    case $v in ''|*[!0-9]*) ;; *) TEST_SPEED_SCRIPT_TIMEOUT_SECONDS=$v ;; esac
    v=$(sed -n 's/^machine_runs_max=//p' "$f" | tail -n 1)
    case $v in ''|*[!0-9]*) ;; *) TEST_MACHINE_RUNS_MAX=$v ;; esac
    return 0
  done
  return 0
}

# Shipped defaults, overridden by the home's config file; see
# defaults/test-speed-limits.
load_test_speed_limits

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'jg-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'jg-test-run: %s\n' "$*" >&2
}

# shellcheck source=bin/jg-test-host-lib.sh
. "$ROOT/bin/jg-test-host-lib.sh"

# The effective machine_runs_max (see bin/jg-test-host-lib.sh "Run slots").
machine_runs_max() {
  local n=$TEST_MACHINE_RUNS_MAX
  [ "$n" -gt 0 ] || n=$(( $(cpu_count) / 16 ))
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# --wall-warn-ms: a run past the wall clock was slowed by the machine, not failed by a test, so it is one warning
# with the host load beside it (the record a gate keeps of machine load) and never changes the exit status.
wall_overrun_warn() {  # <duration-ms>
  local load cpus
  [ -n "$WARN_WALL_MS" ] && [ "$1" -gt "$WARN_WALL_MS" ] || return 0
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || load=
  cpus=$(nproc 2>/dev/null) || cpus=
  log "warning: ran ${1}ms, over its ${WARN_WALL_MS}ms wall-clock budget, at host load ${load:-unknown} on ${cpus:-unknown} cpus: every selected script ran, so a red comes only from a failed script"
  printf 'JG_TEST_OVERRUN budget_ms=%s duration_ms=%s load=%s cpus=%s selection=%s\n' \
    "$WARN_WALL_MS" "$1" "${load:-unknown}" "${cpus:-unknown}" "$SELECTION_DESC"
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Enforce the placement refusal described in this script's header.
#
# The primary checkout is the working tree whose own git dir IS the repository's
# common git dir; every linked worktree has a git dir under it instead. That is
# the same predicate bin/jg-spawn.sh uses to keep a launch out of the primary,
# and unlike comparing top-level paths it still holds when the primary is
# reached through a different path. When git resolves neither directory - a
# non-repository fixture, a detached copy - nothing proves this is the primary,
# so the run proceeds.
refuse_primary_checkout_for_task() {
  local task_id git_dir common_dir top
  task_id=${JG_TASK_ID:-}
  [ -n "$task_id" ] || return 0
  git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
    && git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=
  common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    && common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 0
  [ "$git_dir" = "$common_dir" ] || return 0
  top=$(cd "$ROOT" && pwd -P)
  die "refusing to run in the repository primary checkout $top while JG_TASK_ID=$task_id is set; run from the assigned task worktree instead"
}

cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  case "$n" in
    ''|*[!0-9]*) n=1 ;;
  esac
  [ "$n" -ge 1 ] || n=1
  printf '%s\n' "$n"
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
#
# `standalone` is the residual family: scripts that belong to no subsystem
# family above but each own their own surface. Its membership is enumerated
# rather than inherited from the `*)` catch-all precisely because the catch-all
# also swallows every test nobody has classified yet. Keeping the two separate
# is what lets `standalone` carry a concurrent proof while a brand-new test
# lands in `unclassified` and stays serial until someone proves it.
family_for_basename() {
  case "$1" in
    jg-brief.test.sh|jg-crew-state.test.sh|\
    jg-prior-art-gate.test.sh|jg-recon-gate.test.sh|jg-recon-depth.test.sh|jg-loss-claim-check.test.sh|\
    jg-captain-hold-lifecycle.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    jg-turnend-guard.test.sh|jg-wake-daemon-lifecycle-e2e.test.sh|\
    jg-mail.test.sh|jg-watcher-lock.test.sh|jg-watch-handoff.test.sh|\
    jg-watch-inventory.test.sh|\
    jg-wake-next.test.sh|jg-pi-wake-replay.test.sh|\
    jg-wake-core.test.sh|jg-wake-router.test.sh|\
    jg-state-bus-parity.test.sh|jg-lease-live.test.sh|jg-reply-bus-parity.test.sh|\
    jg-reply-engine.test.sh|jg-pending-reply-turn-end.test.sh|\
    jg-metrics-shadow-parity.test.sh|\
    jg-bus-service.test.sh|\
    jg-wake-queue-live.test.sh|jg-wake-engine.test.sh|jg-wake-watcher.test.sh|jg-delivery-record.test.sh|\
    jg-bus-account-isolation.test.sh|\
    jg-escalation-workflows.test.sh|jg-bus-leaf-parity.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    jg-afk-inject-herdr-e2e.test.sh|jg-backend-herdr-presentation-e2e.test.sh|\
    jg-backend-herdr-prune-safety-e2e.test.sh|jg-backend-herdr-respawn-idem-e2e.test.sh|\
    jg-herdr-session-cleanup-e2e.test.sh|jg-backend-herdr-smoke.test.sh|\
    jg-backend-herdr-workspace-per-home-e2e.test.sh|jg-sentinel-restart-resume.test.sh|\
    jg-sentinel-herdr-restart-live-e2e.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    jg-on.test.sh|jg-remote-reply.test.sh|\
    jg-remote-squad-lead-lifecycle-e2e.test.sh|jg-squad-lead-lifecycle-e2e.test.sh)
      printf '%s\n' squad_lead
      ;;
    jg-axi-link.test.sh|jg-bootstrap.test.sh|jg-fleet-sync.test.sh|jg-gate-refuse.test.sh|\
    jg-session-start.test.sh|jg-tangle-guard.test.sh|jg-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    jg-claude-stop-autoarm-live-e2e.test.sh|jg-claude-midturn-arm-live-e2e.test.sh|\
    jg-composer-matrix-live-e2e.test.sh|jg-control-pi-live-e2e.test.sh|jg-codex-continuity-live-e2e.test.sh|\
    jg-codex-hook-layer-live-e2e.test.sh|jg-grok-continuity-live-e2e.test.sh|\
    jg-cursor-primary-live-e2e.test.sh|jg-harness-adapter-instructions-live-e2e.test.sh|\
    jg-devin-signals-live-e2e.test.sh|\
    jg-muse-signals-live-e2e.test.sh|jg-rovo-signals-live-e2e.test.sh|\
    jg-agy-signals-live-e2e.test.sh|jg-launch-prompt-signals-live-e2e.test.sh|\
    jg-pi-seeded-home-trust-live-e2e.test.sh|jg-herdr-version-floor-live-e2e.test.sh|\
    jg-worker-account-live-e2e.test.sh|jg-opencode-primary-live-e2e.test.sh|\
    jg-pi-branch-live-e2e.test.sh|jg-pi-primary-live-e2e.test.sh|\
    jg-omp-primary-live-e2e.test.sh|jg-pr-state-live-e2e.test.sh|\
    jg-sessionstart-hook-live-e2e.test.sh|jg-supervision-host-live-e2e.test.sh|\
    jg-quota-array-dispatch-live-e2e.test.sh|jg-send-inbox-doorbell-live-e2e.test.sh|\
    jg-prompt-gate-live-e2e.test.sh|jg-backend-hc-live-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    jg-backend-tmux-smoke.test.sh|jg-control.test.sh|jg-send-inbox.test.sh|\
    jg-doorbell-missing-record.test.sh|jg-nudge-residue.test.sh|\
    jg-spawn-dispatch-profile.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    jg-pr-merge.test.sh|jg-local-suite-tree.test.sh|jg-merge-on-green.test.sh|\
    jg-teardown.test.sh|jg-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    jg-afk-inject-e2e.test.sh|jg-supervision-host.test.sh)
      printf '%s\n' afk
      ;;
    jg-procevent.test.sh|jg-public-followup.test.sh|\
    jg-wake-drain-open-decisions-cursor.test.sh)
      printf '%s\n' standalone
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' live-capability ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
squad_lead
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
standalone
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
}

# Exact proven-isolated candidate set (same paths as
# bin/jg-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/jg-brief.test.sh
tests/jg-captain-hold-lifecycle.test.sh
tests/jg-crew-state.test.sh
tests/jg-pr-merge.test.sh
tests/jg-x-mode.test.sh
EOF
}

# Per-script serial CI duration hints, one "<path> <ms>" per line, used to
# pack only the two portable parallel lanes. Measurement provenance and the
# refresh procedure are owned by docs/jg-test-portable-shards.md.
portable_parallel_weight_hints() {
  cat <<'EOF'
tests/jg-brief.test.sh 10594
tests/jg-browser-sweep.test.sh 2000
tests/jg-captain-hold-lifecycle.test.sh 343658
tests/jg-crew-state.test.sh 82058
tests/jg-pr-merge.test.sh 300199
tests/jg-x-mode.test.sh 29896
EOF
}

# Sum the hints above for the scripts read on stdin, and report how many of
# them had no hint at all, as "<summed_ms> <unhinted_count>".
portable_parallel_lane_weight() {
  awk '
    NR == FNR { if (NF) { hint[$1] = $2 } ; next }
    NF {
      if ($1 in hint) { total += hint[$1] } else { unhinted++ }
    }
    END { printf "%d %d\n", total + 0, unhinted + 0 }
  ' <(portable_parallel_weight_hints) -
}

# Portable parallel shard 1: LPT balance of the proven-isolated set over the
# hints above. Stored order agrees with this lane's --list-scheduled output.
# tests/jg-pi-primary-types.test.sh runs the production-consumer typecheck here;
# its own header owns temporary dependency provisioning.
list_portable_parallel_1() {
  cat <<'EOF'
tests/jg-pr-merge.test.sh
tests/jg-x-mode.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/jg-captain-hold-lifecycle.test.sh
tests/jg-crew-state.test.sh
tests/jg-brief.test.sh
EOF
}

# Families whose scripts are proven safe to run concurrently WITH EACH OTHER
# under the bounded local scheduler. Deliberately separate from the
# proven-isolated set, which must stay exactly equal to the portable CI shard
# union (see the coverage guard); these families keep their serial CI lane and
# only gain concurrency for a local run.
#
# Membership is empirical, never assumed:
# `bin/jg-test-isolation-proof.sh --pool <family> --jobs 4` is the owner of the
# proof, and docs/jg-test-isolation-proof.md records the dated result.
list_concurrent_safe_families() {
  cat <<'EOF'
watcher-wake-lock
pure-contract-unit
pr-forge
squad_lead
session-bootstrap
standalone
EOF
}

family_is_concurrent_safe() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_concurrent_safe_families)
  return 1
}

concurrent_safe_family_jobs_max() {
  case "$1" in
    watcher-wake-lock|pure-contract-unit|pr-forge) printf '4\n' ;;
    squad_lead|session-bootstrap|standalone) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}

# A script may run under --jobs when it is individually proven isolated or is
# an exact repository member of a family carrying a recorded concurrent proof.
script_allows_concurrency() {
  local s=$1 family repo_script
  is_proven_isolated_script "$s" && return 0
  family=$(family_for_basename "$(basename "$s")")
  family_is_concurrent_safe "$family" || return 1
  while IFS= read -r repo_script; do
    [ "$repo_script" = "$s" ] && return 0
  done < <(all_repo_tests)
  return 1
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# squad_lead lifecycle, bootstrap, the live-harness-optin family, GUI-backend,
# and other unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifacts recorded in docs/jg-test-portable-shards.md. Each value is the
# slowest successful sample in the referenced complete/partial CI runs, with
# the version-specific host and native-Windows exceptions documented there.
# These are balance hints only: the shard
# partition stays complete and disjoint whatever they say, so a stale hint costs
# balance rather than coverage. That doc owns the refresh procedure.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/board-link.test.sh 1700
tests/jg-afk-inject-e2e.test.sh 42474
tests/jg-agents-md-floor.test.sh 542
tests/jg-agy-signals-live-e2e.test.sh 125
tests/jg-backend-tmux-smoke.test.sh 520
tests/jg-beads-migrate.test.sh 1700
tests/jg-beads-native-followup.test.sh 150000
tests/jg-beads-native-n5.test.sh 140000
tests/jg-behavior-determinism.test.sh 172000
tests/jg-board-answers.test.sh 6382
tests/jg-board-answers-latency.test.sh 90000
tests/jg-board-asks.test.sh 643
tests/jg-board-gate.test.sh 40000
tests/jg-bus-gateway.test.sh 46155
tests/jg-bus-leaf-parity.test.sh 10999
tests/jg-bus.test.sh 86
tests/jg-axi-link.test.sh 900
tests/jg-bootstrap.test.sh 129297
tests/jg-browser-reaper.test.sh 2004
tests/jg-stray-nats-reap.test.sh 2265
tests/jg-calm-home-links.test.sh 690
tests/jg-chat-answer-card.test.sh 2129
tests/jg-ci-required.test.sh 595
tests/jg-ci-scope.test.sh 1353
tests/jg-claude-stop-autoarm-live-e2e.test.sh 169
tests/jg-claude-midturn-arm-live-e2e.test.sh 140
tests/jg-clause.test.sh 4074
tests/jg-codex-continuity-live-e2e.test.sh 260
tests/jg-codex-hook-layer-live-e2e.test.sh 225
tests/jg-comms-feed.test.sh 1014
tests/jg-compat-old-records.test.sh 1127
tests/jg-composer-matrix-live-e2e.test.sh 244
tests/jg-composer-self-repair.test.sh 51000
tests/jg-control.test.sh 94076
tests/jg-cursor-primary-live-e2e.test.sh 384
tests/jg-deprecated-paths-check.test.sh 3000
tests/jg-ports-check.test.sh 9010
tests/jg-decisions-reconcile.test.sh 55000
tests/jg-design-gate-first-draft.test.sh 1650
tests/jg-design-gate.test.sh 812
tests/jg-devin-signals-live-e2e.test.sh 174
tests/jg-doorbell-missing-record.test.sh 4529
tests/jg-escalation-chain.test.sh 245000
tests/jg-escalation-chain-backlog.test.sh 410000
tests/jg-escalation-chain-signals.test.sh 450000
tests/jg-escalation-chain-actions.test.sh 305000
tests/jg-escalation-workflows.test.sh 3200
tests/jg-fast-evals.test.sh 1136
tests/jg-fleet-heartbeat.test.sh 3664
tests/jg-fleet-sync.test.sh 41550
tests/jg-flow.test.sh 936
tests/jg-gate-refuse.test.sh 16669
tests/jg-goal-loop-journey.test.sh 144000
tests/jg-grok-continuity-live-e2e.test.sh 157
tests/jg-harness-adapter-instructions-live-e2e.test.sh 199
tests/jg-harness-quirks.test.sh 644
tests/jg-herdr-lead-label.test.sh 368
tests/jg-tool-models.test.sh 4000
tests/jg-classify-go.test.sh 520
tests/jg-herdr-go.test.sh 1222
tests/jg-guard-host.test.sh 6431
tests/jg-herdr-names.test.sh 2803
tests/jg-herdr-version-floor-live-e2e.test.sh 249
tests/jg-hometag-lead-label.test.sh 506
tests/jg-retired-catalog-check.test.sh 309
tests/jg-host-wiring.test.sh 1330
tests/jg-inbox.test.sh 12752
tests/jg-launch-prompt-signals-live-e2e.test.sh 194
tests/jg-lint-partitions.test.sh 7835
tests/jg-local-suite-tree.test.sh 706
tests/jg-merge-on-green.test.sh 900
tests/jg-lint-root-memory.test.sh 4969
tests/jg-context-bound.test.sh 72
tests/jg-mail.test.sh 15199
tests/jg-machine-shadow.test.sh 5000
tests/jg-merge-gate-lib.test.sh 608
tests/jg-merge-gate-policy.test.sh 30967
tests/jg-metrics-shadow-parity.test.sh 210
tests/jg-machine-task.test.sh 1800
tests/jg-machine-call.test.sh 55000
tests/jg-machine-call-b.test.sh 38000
tests/jg-machine-call-c.test.sh 53000
tests/jg-muse-signals-live-e2e.test.sh 180
tests/jg-omp-primary-live-e2e.test.sh 290
tests/jg-on.test.sh 20997
tests/jg-opencode-primary-live-e2e.test.sh 341
tests/jg-overwatch-kpi.test.sh 2289
tests/jg-owner-correction.test.sh 2003
tests/jg-owner-rules.test.sh 4200
tests/jg-pending-reply-turn-end.test.sh 3000
tests/jg-pi-branch-live-e2e.test.sh 201
tests/jg-pi-primary-live-e2e.test.sh 394
tests/jg-pi-seeded-home-trust-live-e2e.test.sh 102
tests/jg-pi-wake-replay.test.sh 2977
tests/jg-post-merge-ci-main.test.sh 357
tests/jg-pr-state-live-e2e.test.sh 242
tests/jg-pr-state.test.sh 458
tests/jg-pr-wait.test.sh 362
tests/jg-pre-push.test.sh 17156
tests/jg-progress-claim.test.sh 2500
tests/jg-procevent.test.sh 233712
tests/jg-project-mode.test.sh 462
tests/jg-prompt-gate-live-e2e.test.sh 249
tests/jg-prompt-gate.test.sh 101581
tests/jg-proof-attach.test.sh 980
tests/jg-public-followup.test.sh 260000
tests/jg-quota-array-dispatch-live-e2e.test.sh 284
tests/jg-release-readiness.test.sh 11877
tests/jg-release-tag.test.sh 1500
tests/jg-remote-reply.test.sh 243818
tests/jg-remote-squad-lead-lifecycle-e2e.test.sh 680926
tests/jg-reply-bus-parity.test.sh 253
tests/jg-reply-engine.test.sh 1203
tests/jg-rovo-signals-live-e2e.test.sh 389
tests/jg-self-repo-role.test.sh 18448
tests/jg-send-dormant-lead.test.sh 4831
tests/jg-send-inbox-doorbell-live-e2e.test.sh 264
tests/jg-send-inbox.test.sh 53586
tests/jg-session-start.test.sh 748000
tests/jg-sessionstart-hook-live-e2e.test.sh 157
tests/jg-ship-local.test.sh 786
tests/jg-spawn-clone-identity.test.sh 20000
tests/jg-spawn-core.test.sh 1238
tests/jg-spawn-dispatch-profile.test.sh 938199
tests/jg-squad-lead-dormant.test.sh 2392
tests/jg-squad-lead-restart-idle.test.sh 14389
tests/jg-state-bus-parity.test.sh 279
tests/jg-lease-live.test.sh 183
tests/jg-bus-service.test.sh 616
tests/jg-wake-queue-live.test.sh 19169
tests/jg-wake-watcher.test.sh 41813
tests/jg-wake-engine.test.sh 65412
tests/jg-delivery-record.test.sh 200
tests/jg-bus-account-isolation.test.sh 63398
tests/jg-squad-lead-lifecycle-e2e.test.sh 14484
tests/jg-supervision-host-live-e2e.test.sh 223
tests/jg-supervision-host.test.sh 1062710
tests/jg-status-digest.test.sh 1334
tests/jg-stack-owner.test.sh 635
tests/jg-bus-health.test.sh 5000
tests/jg-bus-health-extra.test.sh 4000
tests/jg-tangle-guard.test.sh 58000
tests/jg-teardown-core.test.sh 4222
tests/jg-teardown.test.sh 902000
tests/jg-test-run.test.sh 33000
tests/jg-ticket-writeback.test.sh 83
tests/jg-tmp-sweep.test.sh 5192
tests/jg-tokens-retro.test.sh 615
tests/jg-trunk.test.sh 45000
tests/jg-trunk-live.test.sh 44000
tests/jg-trunk-gate.test.sh 35000
tests/jg-trunk-queue.test.sh 31000
tests/jg-trunk-retry.test.sh 20000
tests/jg-trunk-publish.test.sh 19000
tests/jg-trunk-golive-guard.test.sh 30000
tests/jg-trunk-verify.test.sh 15000
tests/jg-trunk-spawn.test.sh 49000
tests/jg-spawn-load-admission.test.sh 45000
tests/jg-spawn-same-file.test.sh 45000
tests/jg-trunk-scope.test.sh 8000
tests/jg-worker-rules.test.sh 3633
tests/jg-turnend-guard.test.sh 97000
tests/jg-update.test.sh 17444
tests/jg-wake-daemon-lifecycle-e2e.test.sh 15568
tests/jg-wake-core.test.sh 4900
tests/jg-wake-router.test.sh 1211
tests/jg-wake-route.test.sh 24386
tests/jg-wake-drain-open-decisions-cursor.test.sh 148819
tests/jg-wake-next.test.sh 4801
tests/jg-planned-wait.test.sh 83716
tests/jg-watch-inventory.test.sh 5002
tests/jg-watch-handoff.test.sh 52298
tests/jg-watcher-lock.test.sh 210766
tests/jg-watch-silent-exit.test.sh 5000
tests/jg-watch-silence-prune.test.sh 5000
tests/jg-lock-pi-session-id.test.sh 1000
tests/jg-worker-account-live-e2e.test.sh 192
tests/juggernaut-axi-serve.test.sh 1466
tests/juggernaut-axi.test.sh 29551
tests/migration-card.test.sh 2469
tests/migration-card-live.test.sh 83
tests/merge-card-title.test.sh 1312
tests/merge-gate-one-entry.test.sh 7202
tests/jg-bus-machine-service.test.sh 88
tests/jg-captain-card-two-layers.test.sh 2200
tests/jg-card-rules.test.sh 3900
tests/jg-chat-store.test.sh 7108
tests/jg-dispatch-resolve-codex-routing.test.sh 645
tests/jg-dispatch-resolve-tiers.test.sh 938
tests/jg-done-checks.test.sh 7083
tests/jg-fleet-autosync.test.sh 6509
tests/jg-fleet-rules.test.sh 470
tests/jg-git-hooks-refresh.test.sh 300
tests/jg-install-herdr-retry.test.sh 361
tests/jg-installed-drift.test.sh 434
tests/jg-launch-env-strip.test.sh 462
tests/jg-lavish-guard.test.sh 476
tests/jg-lavish-session-check.test.sh 529
tests/jg-licence-check.test.sh 333
tests/jg-path-guard.test.sh 536
tests/jg-live-claim.test.sh 919
tests/jg-loss-claim-check.test.sh 400
tests/jg-prior-art-gate.test.sh 652
tests/jg-recon-depth.test.sh 330
tests/jg-recon-gate.test.sh 1500
tests/jg-running-products.test.sh 514
tests/jg-stack.test.sh 53387
tests/jg-turnend-guard-no-false-blocks.test.sh 465
tests/jg-version-branch-sync.test.sh 94207
tests/jg-wake-batching.test.sh 52062
tests/jg-watch-beacon.test.sh 45490
tests/jg-whats-left.test.sh 3479
tests/jg-captain-approval.test.sh 113000
tests/jg-pending-decision-blocks-work.test.sh 294000
tests/jg-triage.test.sh 2061
tests/jg-nudge-residue.test.sh 6000
tests/jg-wake-schedule.test.sh 78000
tests/jg-critical-path-spawn.test.sh 57000
tests/jg-release-smoke.test.sh 84562
tests/jg-beads-native-n3.test.sh 44000
tests/jg-beads-native-n8.test.sh 43000
tests/jg-public-followup-b.test.sh 500000
tests/jg-public-followup-c.test.sh 500000
tests/board-link-send.test.sh 784
tests/jg-afk-telegram.test.sh 912
tests/jg-away-reach.test.sh 1097
tests/jg-beads-native-hold.test.sh 19584
tests/jg-beads-native-n4.test.sh 1500
tests/jg-beads-native-n6.test.sh 22346
tests/jg-beads-native-whole.test.sh 9455
tests/jg-beads.test.sh 42005
tests/jg-browser-sweep.test.sh 2500
tests/jg-captain-say-chat.test.sh 138
tests/jg-ci-rerun.test.sh 10104
tests/jg-control-pi-live-e2e.test.sh 1500
tests/jg-critical-path.test.sh 5305
tests/jg-evidence.test.sh 1178
tests/jg-goal.test.sh 1500
tests/jg-held-card-no-fleet-freeze.test.sh 2000
tests/jg-home-guard.test.sh 3000
tests/jg-machine-enforce.test.sh 2500
tests/jg-machine-inbox.test.sh 3500
tests/jg-machine-index.test.sh 1500
tests/jg-machine-landing.test.sh 3000
tests/jg-machine-status.test.sh 4000
tests/jg-machine.test.sh 2000
tests/jg-merge-alert.test.sh 1726
tests/jg-proof-gate.test.sh 502
tests/jg-rejected-state-check-once.test.sh 26500
tests/jg-sentinel-inbox-ring.test.sh 19000
tests/jg-ticket-link-guard.test.sh 1152
tests/jg-trunk-live-home.test.sh 2500
tests/jg-unit-claim.test.sh 7478
tests/jg-update-local-base.test.sh 4000
tests/jg-voice.test.sh 6554
tests/jg-watch-arm-handling-delivered.test.sh 959
tests/jg-learnings.test.sh 43017
tests/jg-brief-lint.test.sh 1000
EOF
}

# The portable-serial scripts with no measured hint, one per line. These fall
# back to PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, so they are balanced on a guess
# rather than on evidence; the coverage guard bounds how many there may be.
portable_serial_unhinted() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-test-unhinted.XXXXXX") || return 1
  portable_serial_weight_hints | awk 'NF { print $1 }' | LC_ALL=C sort -u >"$tmp/hinted"
  list_portable_serial | LC_ALL=C sort -u >"$tmp/serial"
  comm -23 "$tmp/serial" "$tmp/hinted"
  rm -rf "$tmp"
}

# Sum serial weights for paths on stdin, including the unmeasured default.
portable_serial_lane_weight() {
  awk -v fallback="$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS" '
    NR == FNR { if (NF) { hint[$1] = $2 }; next }
    NF { total += ($1 in hint) ? hint[$1] : fallback }
    END { printf "%d\n", total + 0 }
  ' <(portable_serial_weight_hints) -
}

portable_parallel_weight_for() {
  local want=$1 ms
  ms=$(portable_parallel_weight_hints | awk -v want="$want" '$1 == want { print $2; exit }')
  if [ -n "$ms" ]; then
    printf '%s\n' "$ms"
    return 0
  fi
  portable_serial_weight_for "$want"
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Deterministic: candidates are ordered by hint descending then path, and ties
# between equally loaded bins always take the lowest bin index.
portable_serial_assignments() {
  local ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done < <(
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      printf '%s\t%s\n' "$(portable_serial_weight_for "$script")" "$script"
    done < <(list_portable_serial) | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
  )
}

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard unhinted serial_total serial_ms serial_max_ms=0
  local p1_ms p1_unhinted p2_ms p2_unhinted parallel_max_ms parallel_imbalance_ms
  local verdict=ok
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" >>"$tmp/serial_shards_raw"
    serial_ms=$(printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | portable_serial_lane_weight)
    [ "$serial_ms" -le "$serial_max_ms" ] || serial_max_ms=$serial_ms
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Hint drift and a modeled shard over its target are advice, never a refusal:
  # the hints are estimates, and refusing a landing or a CI run for an estimate
  # stopped work that no script had failed. Only a script no shard runs, or a
  # partition that disagrees with its owners, refuses.
  portable_serial_unhinted >"$tmp/unhinted"
  unhinted=$(wc -l <"$tmp/unhinted" | tr -d ' ')
  serial_total=$(wc -l <"$tmp/serial" | tr -d ' ')
  if [ "$serial_total" -gt 0 ] &&
    [ "$((unhinted * 100))" -gt "$((serial_total * PORTABLE_SERIAL_MAX_UNHINTED_PERCENT))" ]; then
    log "coverage advice: $unhinted of $serial_total portable serial scripts have no measured duration hint (advised max ${PORTABLE_SERIAL_MAX_UNHINTED_PERCENT}%); the shards are balanced on a guess"
    log "refresh the hints from a green run's timing artifacts: docs/jg-test-portable-shards.md"
    cat "$tmp/unhinted" >&2
    verdict=advise
  fi

  if [ "$serial_max_ms" -gt "$PORTABLE_SERIAL_MAX_WEIGHT_MS" ]; then
    log "coverage advice: largest portable serial shard packs ${serial_max_ms}ms above the ${PORTABLE_SERIAL_MAX_WEIGHT_MS}ms target"
    log "refresh CI hints and rebalance or add shards; do not raise the job timeout: docs/jg-test-portable-shards.md"
    verdict=advise
  fi

  if [ -x "$ROOT/bin/jg-test-isolation-proof.sh" ]; then
    "$ROOT/bin/jg-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/jg-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # Keep these estimates derived from the membership and hint owners; see the
  # header for the distinction between packed weights and measured job time.
  read -r p1_ms p1_unhinted <<<"$(list_portable_parallel_1 | portable_parallel_lane_weight)"
  read -r p2_ms p2_unhinted <<<"$(list_portable_parallel_2 | portable_parallel_lane_weight)"
  parallel_max_ms=$p1_ms
  [ "$p2_ms" -le "$parallel_max_ms" ] || parallel_max_ms=$p2_ms
  parallel_imbalance_ms=$((p1_ms - p2_ms))
  [ "$parallel_imbalance_ms" -ge 0 ] || parallel_imbalance_ms=$((-parallel_imbalance_ms))

  printf 'JG_TEST_COVERAGE %s total=%s parallel=%s parallel_max_ms=%s parallel_imbalance_ms=%s parallel_unhinted=%s serial=%s serial_shards=%s serial_unhinted=%s serial_max_ms=%s serial_budget_ms=%s herdr=%s\n' \
    "$verdict" \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$parallel_max_ms" \
    "$parallel_imbalance_ms" \
    "$((p1_unhinted + p2_unhinted))" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$unhinted" \
    "$serial_max_ms" \
    "$PORTABLE_SERIAL_MAX_WEIGHT_MS" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
failed_lanes = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    failed_lanes += bool(summary.get("exit", summary.get("failed", 0)))
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
        "failed_lanes": failed_lanes,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"JG_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {  # <needle>...
  local s needle
  local found=0
  local -a needles=()
  for needle in "$@"; do needles+=(-e "$needle"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "${needles[@]}" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Tests that name <needle>, selected as individual scripts rather than widened
# to each referencing test's whole family. A direct reference is per-script
# evidence, so it selects per script: one real-Herdr E2E sourcing a shared
# helper must not drag in every other script of that expensive family.
scripts_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      printf '__script__:%s\n' "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# bin/ scripts other than <needle> itself that name <needle>.
bin_consumers_of() {
  local needle=$1 b
  for b in bin/*.sh bin/backends/*.sh; do
    [ -f "$b" ] || continue
    [ "$(basename "$b")" = "$needle" ] || ! grep -Fq "$needle" "$b" || printf '%s\n' "$b"
  done
}

# An unmapped bin/ path has no curated family of its own. Its blast radius is
# the tests that name it, and the tests that name a library that names it - a
# library is how a script is sourced into the others, so a test of the library
# runs the changed code. Both resolve per script, never to a whole family: the
# scripts that call a caller of the file are not evidence about the file, and
# widening to them selected 97 to 100 scripts for the 18 that name a shared file.
# A family a maintainer recorded for a file is still given by its case row below.
families_for_unmapped_bin() {
  local path=$1 needle consumer out found=0
  needle=$(basename "$path")
  if out=$(scripts_for_test_reference "$needle"); then
    printf '%s\n' "$out"
    found=1
  fi
  while IFS= read -r consumer; do
    [ -n "$consumer" ] || continue
    case "$consumer" in
      *-lib.sh) ;;
      *) continue ;;
    esac
    if out=$(scripts_for_test_reference "$(basename "$consumer")"); then
      printf '%s\n' "$out"
      found=1
    fi
  done < <(bin_consumers_of "$needle")
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/captures/stuck-live/*)
      # These captured terminal states are read by the signals cases.
      printf '%s\n' __script__:jg-escalation-chain-signals.test.sh
      ;;
    tests/jg-supervision-host.test.sh)
      # The late half sources the same fixture and test definitions.
      printf '%s\n' __script__:jg-supervision-host.test.sh
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/jg-test-run.sh)
      # Deliberately the WHOLE family, not just the two contract tests. This
      # runner executes every pure-contract-unit script, so a change to it is
      # only proven by running them: its own contract test passing says the
      # runner's logic is right, not that the suite it drives still runs.
      printf '%s\n' pure-contract-unit
      # Only this script wraps each suite in run_script_bounded's fixture Git
      # isolation, and only a standalone-family script proves it.
      ;;
    bin/jg-test-isolation-proof.sh)
      # Same reason as the runner above: the proof drives every
      # pure-contract-unit script. It runs each candidate directly, never
      # through run_script_bounded, so it cannot regress fixture Git isolation.
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/jg-herdr-lab.sh|tests/herdr-test-safety.sh|tests/herdr-client-pair-fixture.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    tests/journeys/fleet-autopilot/*)
      # The fleet-autopilot journey (run.sh, lab.sh, homes.sh, lanes.sh and its faults) is no suite of its own: its proof
      # is the sealed done-done run of run.sh. It drives the Herdr lab helper, so a change to it re-runs the
      # real-Herdr family, the same family the lab helper selects.
      printf '%s\n' real-herdr-gated
      ;;
    bin/jg-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/hc*|bin/jg-hc-lab.sh)
      # The Herdr Core adapter and its lab helper are proven by the one hc
      # journey, which drives both against a real core.
      printf '%s\n' __script__:jg-backend-hc-live-e2e.test.sh
      ;;
    bin/jg-backend.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      printf '%s\n' __script__:jg-backend-hc-live-e2e.test.sh
      ;;
    bin/jg-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/jg-agent-process-lib.sh)
      # The shared harness-process classifier feeds both the tmux and Herdr
      # liveness verdicts, so a change to it is proven by both backends' suites.
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      printf '%s\n' pure-contract-unit
      ;;
    bin/jg-watch*|bin/jg-wake*|bin/jg-escalation-workflows.sh|\
    bin/jg-inactive-reconcile.sh|bin/jg-classify-lib.sh|bin/jg-daemon*|\
    bin/jg-turnend-guard*|bin/jg-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/jg-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/jg-supervision-host.sh|bin/jg-supervision-engine-lib.sh|\
    bin/jg-branch-report.sh|bin/jg-branch-dispatch.mjs)
      # The supervision host and its parts: its own suite and live guard, plus
      # the Claude Stop hook that runs it.
      printf '%s\n' afk
      printf '%s\n' live-harness-optin
      ;;
    bin/jg-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/jg-learnings.py)
      printf '%s\n' __script__:jg-learnings.test.sh
      ;;
    bin/jg-startup-memory-budget.sh|bin/jg-startup-memory-budget-lib.sh)
      printf '%s\n' squad_lead
      printf '%s\n' session-bootstrap
      ;;
    bin/jg-squad-lead*|bin/jg-remote*|bin/jg-on.sh|bin/jg-home-seed.sh|\
    bin/jg-backlog-handoff.sh|bin/jg-backlog-receive.sh|bin/jg-procevent-remote-reply.sh|\
    bin/jg-config-inherit-lib.sh|bin/jg-config-push.sh|bin/jg-shared*|\
    bin/jg-stow-cascade.sh)
      printf '%s\n' squad_lead
      ;;
    bin/jg-required-checks.sh|bin/jg-delivery-tick.sh)
      printf '%s\n' "__script__:jg-stops.test.sh"
      ;;
    bin/jg-session-start.sh|bin/jg-fleet-sync.sh|\
    bin/jg-sessionstart-nudge.sh|bin/jg-startup-network.sh|bin/jg-tangle*|bin/jg-update.sh|\
    bin/jg-gate-refuse*|bin/jg-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/jg-bootstrap.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:jg-brief.test.sh"
      ;;
    defaults/brief-lint-rules.tsv)
      printf '%s\n' "__script__:jg-brief-lint.test.sh"
      ;;
    install.sh|defaults/*|toolchain.versions|bin/jg-pin-lib.sh)
      # The one entry command, the defaults it writes, and the pin table every
      # install path reads. The table and its reader also set the floors
      # bin/jg-bootstrap.sh enforces, so the bootstrap family comes too.
      printf '%s\n' session-bootstrap
      ;;
    bin/jg-axi-link.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' "__script__:jg-axi-link.test.sh"
      ;;
    bin/jg-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      ;;
    bin/jg-toon-lib.sh)
      # The TOON renderer sourced by juggernaut-axi and jg-bearings-snapshot.sh.
      printf '%s\n' "__script__:juggernaut-axi.test.sh"
      printf '%s\n' "__script__:juggernaut-axi-serve.test.sh"
      ;;
    bin/jg-procevent-quota.sh)
      ;;
    bin/jg-quota-choose.sh)
      ;;
    bin/jg-dispatch-resolve.sh)
      ;;
    bin/jg-env-lib.sh)
      # The one .env accessor, sourced by bin/jg-x-lib.sh (Relay token) and
      # bin/jg-dispatch-resolve.sh (TYPESAFE_API_KEY).
      printf '%s\n' pr-forge
      ;;
    .pi/extensions/jg-branch-supervision.ts|.pi/extensions/lib/jg-async-exec.ts|\
    .pi/extensions/lib/jg-branch-dispatch.ts|.pi/extensions/lib/jg-native-contract.ts)
      # The portable suites that actually load these files, named one by one.
      # Left unmapped, a Pi extension library resolves through the reference
      # scan, which widens to each referencing suite's WHOLE family - and
      # these suites sit in four different families, so that pulls in dozens
      # of suites with nothing to do with Pi.
      printf '%s\n' __script__:jg-supervision-host.test.sh
      # Whether an arriving outcome still lets the captain type is a fact only
      # a real Pi TUI can answer, so the live guards are selected too.
      printf '%s\n' live-harness-optin
      ;;
    .pi/extensions/lib/jg-operational-input.ts)
      # The same rule for the operational-input library, whose reach is wider:
      # every Pi extension that classifies or encodes operational text.
      printf '%s\n' __script__:jg-turnend-guard.test.sh
      printf '%s\n' live-harness-optin
      ;;
    .claude/mods/juggernaut-calm/*|.pi/extensions/lib/jg-calm-working-ship.ts|\
    .pi/extensions/lib/jg-calm-working-ship-sprite.ts)
      # The Claude Code Calm mod and the sprite core it shares with the Pi Calm
      # extension: the portable Node checks, the Pi suites that draw the shared
      # sprite, the Pi typecheck, and the Claude-dependent guards.
      printf '%s\n' live-harness-optin
      ;;
    bin/jg-sessionstart-run.sh|.claude/settings.json|.codex/hooks.json|\
    .pi/extensions/jg-primary-turnend-guard.ts)
      # The run tier's two harness-supplied facts (source vocabulary and
      # context-reset stdout injection) only show up against a real harness.
      printf '%s\n' session-bootstrap
      printf '%s\n' live-harness-optin
      ;;
    bin/jg-extension.mjs|bin/jg-extension.sh|docs/examples/process-event-extension/*)
      ;;
    bin/jg-procevent.sh|bin/jg-procevent-lib.sh|bin/jg-procevent-extension-capture.pl)
      printf '%s\n' __script__:jg-procevent.test.sh
      printf '%s\n' __script__:jg-remote-reply.test.sh
      ;;
    bin/jg-timeout-lib.sh)
      # The shared hard bound: session start's runtime bound, the fleet/bearings
      # snapshots, the vendor auth probe, the stow cascade's per-home step, and
      # the wedge detector's worktree write probe all depend on it.
      printf '%s\n' session-bootstrap
      printf '%s\n' pure-contract-unit
      printf '%s\n' squad_lead
      printf '%s\n' watcher-wake-lock
      ;;
    bin/jg-pr-*|bin/jg-merge-on-green.sh|bin/jg-merge-local.sh|bin/jg-teardown.sh|bin/jg-review-diff.sh|\
    bin/jg-x-*|bin/jg-check*|bin/jg-pipeline-spend.sh)
      printf '%s\n' pr-forge
      ;;
    bin/jg-nm-run-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/jg-crew-state.sh (pure-contract-unit) and bin/jg-teardown.sh's
      # pre-teardown run abort (pr-forge).
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/jg-control-lib.sh|bin/jg-control-primary-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' session-bootstrap
      ;;
    bin/jg-composer-lib.sh)
      # The shared shape catalogue is vendor-rendered signal; a change to it
      # re-selects the live guard (jg-composer-matrix-live-e2e) alongside the
      # portable families.
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    bin/jg-spawn.sh|bin/jg-send.sh|bin/jg-harness.sh|\
    bin/jg-peek.sh|bin/jg-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/jg-fleet-homes-lib.sh)
      # The registry reader that bin/jg-update.sh (the fleet move) and bin/jg-trunk-live-lag.sh source. No test names it,
      # and neither caller is a library the named-script rule follows, so the one test that drives the move and the lag
      # report against real homes (T1d reads the registry from a lead home) owns it, as the one script that runs its code.
      printf '%s\n' "__script__:jg-update-local-base.test.sh"
      ;;
    bin/jg-task-inbox-lib.sh)
      # The steering-inbox record/doorbell/ladder owner: jg-send's data plane
      # (backend-dispatch), the watcher's re-ring check (watcher-wake-lock),
      # and the live doorbell guard against real harnesses.
      printf '%s\n' backend-dispatch
      printf '%s\n' watcher-wake-lock
      printf '%s\n' live-harness-optin
      ;;
    bin/jg-bearings-snapshot.sh|bin/jg-fleet-snapshot.sh|bin/jg-fleet-view.sh|bin/jg-contributions.sh|bin/jg-contributions.jq|\
    bin/jg-home-summary-refresh.sh|bin/jg-whats-left.sh|bin/jg-owner-asks.sh|bin/jg-triage.sh|\
    bin/jg-hold-reason-lib.sh|bin/jg-landed-lib.sh)
      # The last two are sourced only by the snapshot scripts above, which no
      # suite drives, so they have no test owner either.
      ;;
    .done-done-receipts/*.json|BACKLOG.md)
      # A sealed done-done receipt is run evidence, and BACKLOG.md is the Beads
      # card index: neither is code a suite reads.
      ;;
    bin/jg-install-herdr.sh|bin/jg-install-treehouse.sh|bin/jg-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/jg-lint.sh|bin/jg-lint-workflows.sh|bin/jg-install-shellcheck.sh|\
    bin/jg-install-actionlint.sh|\
    bin/jg-committed-binary-check.sh|bin/jg-ports-check.sh|bin/jg-brief.sh|bin/jg-prior-art-gate.sh|bin/jg-recon-gate.sh|bin/jg-recon-depth.sh|bin/jg-loss-claim-check.sh|bin/jg-ensure-agents-md.sh|bin/jg-crew-state.sh|\
    bin/jg-captain-hold.sh|bin/jg-decision-hold.sh|bin/jg-supervision*|bin/jg-transition-lib.sh|\
    bin/jg-tmux-lib.sh|bin/jg-marker-lib.sh|bin/jg-operational-input.sh|bin/jg-backlog-lib.sh|\
    bin/jg-vendor-auth-probe.sh|\
    bin/jg-primary-scope-lib.sh|bin/jg-project-mode.sh|bin/jg-forge-detect.sh|bin/jg-promote.sh|\
    bin/jg-ff-lib.sh|bin/jg-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/harness-adapters/SKILL.md|.agents/skills/harness-adapters/references/*)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/done-done-verify-suites/SKILL.md|.agents/skills/done-done-verify-suites/suites/*)
      # One suite per file is the layout its own test checks; a suite file is
      # documentation no other suite reads, so it selects that test alone.
      printf '%s\n' "__script__:jg-verify-suites-layout.test.sh"
      ;;
    .agents/skills/task-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' "__script__:jg-agents-md-floor.test.sh"
      ;;
    .agents/skills/*/SKILL.md|.agents/skills/done-done-verify-suites/features/*.md)
      # The verify skill's feature map is documentation the skill indexes, so it
      # selects the same contract family as the skill itself.
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.github/workflows/behavior.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/jg-test-portable-shards.md|docs/jg-test-isolation-proof.md|\
    docs/jg-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.gitattributes|.done-done.yaml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/git-config-helpers.sh)
      # The reference scan is not transitive, so match the two helpers that
      # source this one as well: most suites inherit it only through them.
      families_for_test_reference git-config-helpers.sh lib.sh herdr-test-safety.sh \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/gate-quarantine.tsv|tests/hosted-needs.tsv)
      # The gate's quarantine list is read by the runner's own suite.
      scripts_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/jg-trunk-fixture.sh|tests/jg-machine-call-fixture.sh)
      # Each is shared by the parts of one split suite, which are unclassified:
      # the family-wide arm below would widen it to every unclassified script.
      scripts_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/lib.sh|tests/*-helpers.sh|tests/fixtures.sh|tests/*-fixture.sh)
      # Shared top-level test files, selected by the suites that name them.
      # Must stay below the tests/fixtures/*/* arm: a case glob's * spans /, so
      # tests/*-fixture.sh would otherwise swallow a nested
      # tests/fixtures/<dir>/<name>-fixture.sh and scan for its basename
      # instead of the fixture directory its readers actually name.
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_unmapped_bin "$path" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    policy/gate/*)
      # The merge gate's rules and their data: the test that drives them through the real gate scripts.
      printf '%s\n' "__script__:jg-merge-gate-policy.test.sh"
      ;;
    journeys/*)
      # A done-done journey is owned by the test that names it: a direct
      # reference is per-script evidence, so select that script, not its family.
      # A journey with no test but a `.done-done.yaml` entry is owned by its
      # sealed done-done run, which is the proof; an unregistered one stays
      # unmapped. A deleted journey selects only a test that still names it,
      # the rule the retired-path case below applies.
      if [ -e "$path" ]; then
        scripts_for_test_reference "$path" \
          || families_for_test_reference "$path" \
          || { grep -qF "command: bash $path" "$ROOT/.done-done.yaml" 2>/dev/null; } \
          || printf '%s\n' "__unmapped__:$path"
      else
        scripts_for_test_reference "$path" || families_for_test_reference "$path" || true
      fi
      ;;
    core/*.sh)
      # A core script has no curated row. The tests that name it run, per script,
      # so a lane's own proof covers the file it changed; a script no test names
      # selects nothing here. The core feature's own suites are the core-* tier entries of .done-done.yaml, run
      # by done-done on the host, and a red post-merge run
      # files a fix-forward item (bin/jg-post-merge-ci.sh).
      scripts_for_test_reference "$(basename "$path")" || true
      ;;
    core/*)
      # Other core files (docs, data, Go sources) are run as core-* entries of .done-done.yaml, not on
      # the push; the fast set does not wait for them.
      ;;
    *)
      if [ -e "$path" ]; then
        families_for_test_reference "$path" \
          || printf '%s\n' "__unmapped__:$path"
      else
        # A retired source path with no remaining test consumer cannot select
        # a runnable suite. Known source paths above retain their mappings,
        # and a still-referenced removal is found by the same reference scan.
        families_for_test_reference "$path" || true
      fi
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the reason a gate skip gave, i.e. the first meaningful output line with
# its leading "skip:" removed. Tabs and stray whitespace are folded so the
# reason stays one field of the tab-separated record the JSON artifact is built
# from. Callers only use this once detect_gate_skip has already said yes.
gate_skip_reason() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  first=${first#skip:}
  printf '%s\n' "$first" | tr '\t' ' ' | sed -e 's/^ *//' -e 's/ *$//'
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]+"${EXCLUDE_FAMILIES[@]}"}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

# apply_quarantine drops the scripts tests/gate-quarantine.tsv lists from a gate's changed-files selection and logs each one with
# its reason, so a hung or flaky script can never hold a landing. Only --changed --gate is affected: a script named on the command
# line, --all and the other modes still run it.
apply_quarantine() {
  local s why
  local -a kept=()
  [ "$GATE_MODE" -eq 1 ] && [ "$MODE" = changed ] || return 0
  [ -f "$ROOT/tests/gate-quarantine.tsv" ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    why=$(awk -F'\t' -v s="$s" '$1 == s { print $2; exit }' "$ROOT/tests/gate-quarantine.tsv")
    if [ -n "$why" ]; then
      printf 'JG_TEST_QUARANTINED %s reason=%s\n' "$s" "$why"
    else
      kept+=("$s")
    fi
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

# apply_hosted drops, on --hosted, each script tests/hosted-needs.tsv (script<TAB>tool) lists while its tool is not on PATH, and
# names it with the tool. The scripts still run on our host: in a change's proof and in the line's verify.
apply_hosted() {
  local s tool
  local -a kept=()
  [ "$HOSTED" -eq 1 ] || return 0
  [ -f "$ROOT/tests/hosted-needs.tsv" ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    tool=$(awk -F'\t' -v s="$s" '$1 == s && $2 !~ /^#/ { print $2 }' "$ROOT/tests/hosted-needs.tsv" \
      | while IFS= read -r t; do command -v "$t" >/dev/null 2>&1 || { printf '%s\n' "$t"; break; }; done)
    if [ -n "$tool" ]; then
      log "not run on the hosted runner (needs $tool, which it lacks): $s"
    else
      kept+=("$s")
    fi
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

apply_max_weight() {
  local s ms
  local -a kept=()
  [ -n "$MAX_WEIGHT_MS" ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    ms=$(portable_parallel_weight_for "$s")
    if [ "$ms" -gt "$MAX_WEIGHT_MS" ]; then
      log "deferred to the post-merge lane (${ms}ms hint is over ${MAX_WEIGHT_MS}ms): $s"
    else
      kept+=("$s")
    fi
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

# apply_hosted_timings drops, from the hosted selection, the scripts the hosted
# runner cannot finish: one that ended at the time bound (exit 124) in any of its
# last five runs in the timing file, or one with no run in it at all.
apply_hosted_timings() {
  local s why
  local -a kept=()
  [ -n "$HOSTED_TIMINGS" ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    why=$(awk -F'\t' -v s="$s" '
      $0 ~ /^#/ || NF < 2 { next }
      $1 == s { n++; code[n] = $2 }
      END {
        if (n == 0) { print "no hosted time"; exit }
        for (i = (n > 5 ? n - 4 : 1); i <= n; i++)
          if (code[i] == 124) { print "ended at the time bound in its last five hosted runs"; exit }
      }' "$HOSTED_TIMINGS")
    if [ -n "$why" ]; then
      log "not run on the hosted runner ($why): $s"
    else
      kept+=("$s")
    fi
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

# apply_shard keeps shard k of n of the selection (--shard <k>of<n>): the
# scripts are packed longest-hint-first onto the lightest of n bins, a tie taking
# the lowest bin, and this shard keeps its bin. The packing depends only on the
# selection and the hints, so every runner of a matrix computes the same split.
apply_shard() {
  local index count s ms i best best_load
  local -a kept=() loads=()
  [ -n "$SHARD" ] || return 0
  index=${SHARD%%of*}
  count=${SHARD#*of}
  i=1
  while [ "$i" -le "$count" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms s; do
    [ -n "$s" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$count" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    [ "$best" -ne "$index" ] || kept+=("$s")
  done < <(
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2
  )
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" "${12:-0}" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file, gate_exit = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate, reason = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
            "gate_skip_reason": reason,
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
        "exit": int(gate_exit),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

if [ "${1:-}" = --required-shards ]; then
  [ "$#" -eq 3 ] || die "--required-shards needs <base-ref> <output-dir>"
  required_base=$2 required_dir=$3 required_rc=0
  mkdir -p "$required_dir" || die "cannot create required-set output directory"
  # The gate takes one machine run slot for all eight shards, and builds the Go cores once into the shared Go build
  # cache before they start (bin/jg-test-host-lib.sh); the shards inherit both and take no slot of their own.
  jg_test_host_admit "$(machine_runs_max)"
  trap jg_test_host_release EXIT
  jg_test_host_pin_go_cache
  jg_test_host_warm_go_cache "$ROOT"
  # The eight shards are disjoint, so they run side by side: each one in its own temp and tmux directory
  # (a short path under /tmp, because a tmux socket path is length-limited), its output kept in its own file and
  # printed in shard order afterwards so the log reads exactly as the sequential run's did. JG_REQUIRED_SHARD_PARALLEL
  # caps how many run at once (default: every shard, at most one per cpu); 1 gives the old one-after-another run.
  required_cpus=$(nproc 2>/dev/null || echo 1)
  required_par=${JG_REQUIRED_SHARD_PARALLEL:-8}
  case $required_par in ''|*[!0-9]*|0) required_par=1 ;; esac
  [ "$required_par" -le "$required_cpus" ] || required_par=$required_cpus
  # Each shard's wall clock is a warning at JG_REQUIRED_SHARD_WALL_MS (default 600000 ms, the CI bound), never a red:
  # a shard runs every script it selected, and only a failed script, or a timing file it could not write, fails it.
  # A shard past the bound was slowed by the machine (trunk-v3 at 20eb94ae6054: all eight shards ran 601 to 651 s at
  # host load 60 with no failed test, and the budget had cut each one short, so about half their scripts never ran).
  # Its JG_TEST_OVERRUN line names the time and the host load; the trunk gate records it in its machine-load ledger.
  required_wall_ms=${JG_REQUIRED_SHARD_WALL_MS:-600000}
  case $required_wall_ms in ''|*[!0-9]*|0) die "JG_REQUIRED_SHARD_WALL_MS must be a positive number of milliseconds" ;; esac
  required_scratch=$(mktemp -d "${TMPDIR:-/tmp}/jg-shards.XXXXXX") || die "cannot create the shard scratch directory"
  required_pids=()
  # shellcheck disable=SC2317,SC2329  # runs from the trap
  required_stop() { local p; for p in "${required_pids[@]+"${required_pids[@]}"}"; do kill "$p" 2>/dev/null || :; done; rm -rf -- "$required_scratch"; }
  trap 'required_stop; exit 130' INT TERM

  # A shard that stops before it writes its result (it died at selection, was killed, or ran out of time) still leaves a
  # failed one that names the shard and the cause, so the aggregate reads a verdict and never a missing file; a shard past
  # its budget that could not say so itself is named in the log in its place. Trunk tip 52dd4fd44: eight shards died at
  # selection on an unmapped bin/ file and the log said only "aggregate input not found".
  required_missing_result() {  # <k> <scratch path of the shard, without extension>
    local k=$1 base=$2 rc ms cause load cpus
    rc=$(cat "$base.rc" 2>/dev/null) || rc=
    ms=$(cat "$base.ms" 2>/dev/null) || ms=0
    cause=$(grep -v '^[[:space:]]*$' "$base.out" 2>/dev/null | tail -n 1)
    log "shard ${k}of8 stopped with ${rc:+exit }${rc:-no exit status} before it wrote its result (${ms}ms): ${cause:-no output}"
    python3 - "$required_dir/shard-$k.json" "${k}of8" "${rc:-1}" "$ms" "$cause" <<'PY' || log "shard ${k}of8: cannot write its failed result"
import json, sys
out, shard, rc, ms, cause = sys.argv[1:]
doc = {"run_id": "shard-" + shard, "selection": "shard=" + shard, "scripts": [], "error": cause,
       "summary": {"total": 0, "failed": 0, "skipped_gate": 0, "duration_ms": int(ms), "exit": int(rc) or 1}}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    if [ "$ms" -gt "$required_wall_ms" ] && ! grep -q '^JG_TEST_OVERRUN ' "$base.out" 2>/dev/null; then
      load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || load=
      cpus=$(nproc 2>/dev/null) || cpus=
      printf 'JG_TEST_OVERRUN budget_ms=%s duration_ms=%s load=%s cpus=%s selection=shard=%sof8\n' \
        "$required_wall_ms" "$ms" "${load:-unknown}" "${cpus:-unknown}" "$k"
    fi
  }

  # Run the shards <k>... side by side, each writing shard-<k>.json, and print their output in shard order.
  # Sets REQUIRED_RED to the shards that failed.
  required_run() {  # <k>...
    local k i=0 running=0 work
    required_pids=(); REQUIRED_RED=()
    for k in "$@"; do
      work=$required_scratch/$k
      mkdir -p "$work"
      (
        shard_rc=0 shard_start=$(now_ms)
        TMPDIR="$work" TMUX_TMPDIR="$work" \
          bash "$ROOT/bin/jg-test-run.sh" --changed --base "$required_base" --exclude-family real-herdr-gated \
          --max-weight-ms 60000 --shard "${k}of8" --gate --wall-warn-ms "$required_wall_ms" \
          --json "$required_dir/shard-$k.json" || shard_rc=$?
        echo $(($(now_ms) - shard_start)) > "$work.ms"
        echo "$shard_rc" > "$work.rc"
      ) > "$work.out" 2>&1 &
      required_pids+=($!)
      running=$((running + 1))
      if [ "$running" -ge "$required_par" ]; then
        wait -n || :
        running=$((running - 1))
      fi
    done
    for k in "$@"; do
      wait "${required_pids[i]}" 2>/dev/null || :
      i=$((i + 1))
      cat "$required_scratch/$k.out"
      [ "$(cat "$required_scratch/$k.rc" 2>/dev/null)" = 0 ] || REQUIRED_RED+=("$k")
      [ -s "$required_dir/shard-$k.json" ] || required_missing_result "$k" "$required_scratch/$k"
    done
  }

  required_run 1 2 3 4 5 6 7 8
  [ "${#REQUIRED_RED[@]}" -eq 0 ] || required_rc=1
  trap - INT TERM
  rm -rf -- "$required_scratch"
  bash "$ROOT/bin/jg-test-run.sh" --aggregate-json "$required_dir/required.json" "$required_dir"/shard-{1..8}.json || required_rc=1
  exit "$required_rc"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      JOBS_EXPLICIT=1
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      JOBS_EXPLICIT=1
      shift
      ;;
    --max-wall-ms)
      [ "$#" -gt 1 ] || die "--max-wall-ms requires a positive integer"
      MAX_WALL_MS=$2
      shift 2
      ;;
    --max-wall-ms=*)
      MAX_WALL_MS=${1#--max-wall-ms=}
      shift
      ;;
    --wall-warn-ms)
      [ "$#" -gt 1 ] || die "--wall-warn-ms requires a positive integer"
      WARN_WALL_MS=$2
      shift 2
      ;;
    --wall-warn-ms=*)
      WARN_WALL_MS=${1#--wall-warn-ms=}
      shift
      ;;
    --per-script-timeout-secs)
      [ "$#" -gt 1 ] || die "--per-script-timeout-secs requires a whole number of seconds"
      PER_SCRIPT_TIMEOUT_SECS=$2
      PER_SCRIPT_EXPLICIT=1
      shift 2
      ;;
    --per-script-timeout-secs=*)
      PER_SCRIPT_TIMEOUT_SECS=${1#--per-script-timeout-secs=}
      PER_SCRIPT_EXPLICIT=1
      shift
      ;;
    --enforce-test-speed)
      # Accepted so the nightly suite's command line stays valid: a speed-limit
      # breach is reported in every mode and never fails or kills a test.
      shift
      ;;
    --gate)
      # The pull-request gate contract: enforce the per-test limits, and apply the
      # configured whole-run budget unless the caller named one with --max-wall-ms.
      GATE_MODE=1
      shift
      ;;
    --show-limits)
      SHOW_LIMITS=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-scheduled)
      LIST_SCHEDULED=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-concurrent-safe-families)
      LIST_CONCURRENT_SAFE_FAMILIES=1
      shift
      ;;
    --concurrent-safe-family-jobs-max)
      [ "$#" -gt 1 ] || die "--concurrent-safe-family-jobs-max requires a family name"
      concurrent_safe_family_jobs_max "$2"
      exit 0
      ;;
    --concurrent-safe-family-jobs-max=*)
      concurrent_safe_family_jobs_max "${1#--concurrent-safe-family-jobs-max=}"
      exit 0
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --hosted)
      HOSTED=1
      shift
      ;;
    --max-weight-ms)
      [ "$#" -gt 1 ] || die "--max-weight-ms requires a number"
      case "$2" in ''|*[!0-9]*) die "--max-weight-ms requires a number" ;; esac
      MAX_WEIGHT_MS=$2
      shift 2
      ;;
    --hosted-timings)
      [ "$#" -gt 1 ] || die "--hosted-timings requires a file"
      [ -f "$2" ] || die "--hosted-timings file not found: $2"
      HOSTED_TIMINGS=$2
      shift 2
      ;;
    --shard)
      [ "$#" -gt 1 ] || die "--shard requires <k>of<n>"
      case "$2" in
        [1-9]of[1-9]|[1-9]of[1-9][0-9]|[1-9][0-9]of[1-9][0-9]) ;;
        *) die "--shard requires <k>of<n>, for example 2of3 (got '$2')" ;;
      esac
      [ "${2%%of*}" -le "${2#*of}" ] || die "--shard index is outside 1..${2#*of}: $2"
      SHARD=$2
      shift 2
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$SHOW_LIMITS" -eq 1 ]; then
  printf 'e2e_seconds=%s\n' "$TEST_SPEED_E2E_SECONDS"
  printf 'unit_seconds=%s\n' "$TEST_SPEED_UNIT_SECONDS"
  printf 'gate_wall_seconds=%s\n' "$TEST_SPEED_GATE_SECONDS"
  printf 'script_timeout_seconds=%s\n' "$TEST_SPEED_SCRIPT_TIMEOUT_SECONDS"
  printf 'machine_runs_max=%s\n' "$(machine_runs_max)"
  exit 0
fi

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_CONCURRENT_SAFE_FAMILIES" -eq 1 ]; then
  list_concurrent_safe_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  # LC_ALL=C for this call only: the guard writes byte-ordered lists and compares them
  # with comm, whose collation is the ambient locale's, so the two must agree here and
  # nowhere else - the locale must never leak into a suite, where a test that counts
  # characters instead of bytes would start failing.
  LC_ALL=C run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

if [ -n "$MAX_WALL_MS" ]; then
  case "$MAX_WALL_MS" in
    ''|*[!0-9]*) die "--max-wall-ms requires a positive integer" ;;
  esac
  [ "$MAX_WALL_MS" -gt 0 ] || die "--max-wall-ms requires a positive integer"
fi
if [ -n "$WARN_WALL_MS" ]; then
  case "$WARN_WALL_MS" in
    ''|*[!0-9]*) die "--wall-warn-ms requires a positive integer" ;;
  esac
  [ "$WARN_WALL_MS" -gt 0 ] || die "--wall-warn-ms requires a positive integer"
  [ -z "$MAX_WALL_MS" ] || die "--wall-warn-ms and --max-wall-ms cannot be given together"
fi

# Every run bounds every script: a caller that names no bound gets the configured
# script_timeout_seconds, so no caller (the landing gate's --all and its rerun
# included) can leave a hung script holding the run. Only an explicit 0 disables.
[ "$PER_SCRIPT_EXPLICIT" -eq 1 ] || PER_SCRIPT_TIMEOUT_SECS=$TEST_SPEED_SCRIPT_TIMEOUT_SECONDS
case "$PER_SCRIPT_TIMEOUT_SECS" in
  ''|*[!0-9]*) die "--per-script-timeout-secs requires a whole number of seconds (0 disables)" ;;
esac

# --gate owns the whole-run budget unless the caller named one or asked for the
# wall clock as a warning, so the gate's 10-minute bound lives in one config
# file rather than at every call site.
if [ "$GATE_MODE" -eq 1 ] && [ -z "$MAX_WALL_MS" ] && [ -z "$WARN_WALL_MS" ] && [ "$TEST_SPEED_GATE_SECONDS" -gt 0 ]; then
  MAX_WALL_MS=$((TEST_SPEED_GATE_SECONDS * 1000))
fi

# Refuse before any suite is selected or run. The inspection modes execute
# nothing: --show-limits, --list-families, --list-concurrent-safe-families,
# --list-lanes, --check-coverage, --concurrent-safe-family-jobs-max and
# --aggregate-json have already exited above, and --list/--list-scheduled print
# their selection and exit below. An unset MODE still falls through to the usage
# error, so a caller who named no selection mode is told that rather than this.
if [ -n "${MODE:-}" ] && [ "$LIST_ONLY" -eq 0 ] && [ "$LIST_SCHEDULED" -eq 0 ]; then
  refuse_primary_checkout_for_task
fi

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
apply_quarantine
apply_hosted
apply_max_weight
apply_hosted_timings
apply_shard
if [ -n "$SHARD" ]; then
  SELECTION_DESC="${SELECTION_DESC};shard=$SHARD"
fi
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$LIST_ONLY" -eq 1 ] || [ "$LIST_SCHEDULED" -eq 1 ]; then
  if [ "$LIST_SCHEDULED" -eq 1 ]; then
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      case "$MODE:$LANE" in
        lane:portable-parallel-1|lane:portable-parallel-2)
          printf '%s\t%s\n' "$(portable_parallel_weight_for "$s")" "$s"
          ;;
        *)
          printf '%s\t%s\n' "$(portable_serial_weight_for "$s")" "$s"
          ;;
      esac
    done | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f2-
  else
    for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
      printf '%s\n' "$s"
    done
  fi
  exit 0
fi

# An empty selection is a clean result, not a no-op that falls through. Exiting
# here also keeps every array expansion below off the empty-array path: under
# `set -u`, bash 3.2 (the stock macOS shell) treats "${arr[@]}" on an empty
# array as an unbound-variable error, while bash 4.4+ makes it a harmless no-op.
# A contributor on stock macOS who changes only documentation must still get
# total=0 and exit 0 rather than a crash.
if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  empty_finished_ms=$(now_ms)
  empty_duration=$((empty_finished_ms - RUN_STARTED_MS))
  [ "$empty_duration" -ge 0 ] || empty_duration=0
  empty_rc=0
  printf 'JG_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=%s\n' "$empty_duration"
  # The budget covers the whole invocation, so a selection phase that outran it
  # still fails - reporting zero work is not the same as reporting no time.
  if [ -n "$MAX_WALL_MS" ]; then
    printf 'JG_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$empty_duration"
    if [ "$empty_duration" -gt "$MAX_WALL_MS" ]; then
      log "wall-clock budget exceeded: ${empty_duration}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
      empty_rc=1
    fi
  fi
  wall_overrun_warn "$empty_duration"
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    empty_finished_iso=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$RUN_STARTED_ISO" "$empty_finished_iso" \
      "jg-test-run-${RUN_STARTED_MS}-$$" 0 0 0 "$empty_duration" \
      "$SELECTION_DESC" "$empty_rec" "$empty_fam" "$empty_rc"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit "$empty_rc"
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# Plain --changed and a plain list of script paths both use the bounded
# representative-suite scheduler; numeric --jobs retains the strict all-script
# admission rule below. Naming scripts is how a local verification round asks
# for exactly those subjects, so it gets bounded concurrency rather than a
# serial chain of separate runs.
# The curated selections stay untouched: --lane composes CI shards whose serial
# lane must stay strictly serial, --family is what the required Herdr lane runs,
# and --all is a deliberate complete regression.
AUTO_CONCURRENCY=0
if { [ "$MODE" = changed ] || [ "$MODE" = scripts ]; } && [ "$JOBS_EXPLICIT" -eq 0 ]; then
  if [ "$MODE" = changed ] && [ "${#SCRIPTS[@]}" -gt 0 ] && [ "$PER_SCRIPT_EXPLICIT" -eq 0 ]; then
    CHANGED_CEILING=1
  fi
  auto_admissible=0
  for s in "${SCRIPTS[@]}"; do
    script_allows_concurrency "$s" && auto_admissible=$((auto_admissible + 1))
  done
  if [ "$auto_admissible" -gt 1 ]; then
    JOBS=$(cpu_count)
    [ "$JOBS" -le 4 ] || JOBS=4
    [ "$JOBS" -ge 1 ] || JOBS=1
    [ "$JOBS" -eq 1 ] || AUTO_CONCURRENCY=1
  fi
fi
if [ "$JOBS" -gt 1 ] || [ "$MODE" = changed ] || [ "$MODE" = scripts ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

# An explicit --jobs names a concurrency for exactly the selection given, so an
# unproven script in it is a refusal rather than something to schedule around.
if [ "$JOBS" -gt 1 ] && [ "$AUTO_CONCURRENCY" -eq 0 ]; then
  # A single heavy suite can occupy a whole serial shard. Its family may have
  # a separate concurrency proof, but that never changes this lane's contract.
  if [ "$MODE" = lane ]; then
    case "$LANE" in
      portable-serial|portable-serial-*) die "--jobs $JOBS refused: portable serial lanes stay serial; use --jobs 1" ;;
    esac
  fi
  for s in "${SCRIPTS[@]}"; do
    if ! script_allows_concurrency "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/jg-test-isolation-proof.sh --list) and its family has no recorded concurrent proof. Unproven stateful scripts stay serial."
    fi
    if ! is_proven_isolated_script "$s"; then
      family=$(family_for_basename "$(basename "$s")")
      family_jobs_max=$(concurrent_safe_family_jobs_max "$family")
      [ "$JOBS" -le "$family_jobs_max" ] \
        || die "--jobs $JOBS refused: family $family is proven only up to $family_jobs_max concurrent workers"
    fi
  done
fi

# Split the run into proven concurrent phases and an unproven remainder.
# Individually proven scripts share one phase. Scripts admitted only by a family
# proof get a separate phase per family, because that proof establishes safety
# only among members of that family. The serial remainder runs after every
# concurrent phase, never beside another test.
CONCURRENT_SCRIPTS=()
SERIAL_TAIL_SCRIPTS=()
CONCURRENT_PHASE_BREAK=__jg_test_concurrent_phase_break__
if [ "$JOBS" -gt 1 ]; then
  SCHEDULE_TMP=$(mktemp "${TMPDIR:-/tmp}/jg-test-sched.XXXXXX")
  : >"$SCHEDULE_TMP"
  for s in "${SCRIPTS[@]}"; do
    if script_allows_concurrency "$s"; then
      if is_proven_isolated_script "$s"; then
        phase=0
      else
        family=$(family_for_basename "$(basename "$s")")
        phase=1
        while IFS= read -r admitted_family; do
          [ "$family" = "$admitted_family" ] && break
          phase=$((phase + 1))
        done < <(list_concurrent_safe_families)
      fi
      # Longest first within each isolation phase: workers are handed scripts
      # in order, so starting the longest last strands it at the tail.
      printf '%s\t%s\t%s\n' "$phase" "$(portable_serial_weight_for "$s")" "$s" >>"$SCHEDULE_TMP"
    else
      SERIAL_TAIL_SCRIPTS+=("$s")
    fi
  done
  previous_phase=
  while IFS=$'\t' read -r phase _weight s; do
    [ -n "$s" ] || continue
    if [ -n "$previous_phase" ] && [ "$phase" != "$previous_phase" ]; then
      CONCURRENT_SCRIPTS+=("$CONCURRENT_PHASE_BREAK")
    fi
    CONCURRENT_SCRIPTS+=("$s")
    previous_phase=$phase
  done < <(LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2nr -k3,3 "$SCHEDULE_TMP")
  rm -f "$SCHEDULE_TMP"
fi

if [ "$PER_SCRIPT_TIMEOUT_SECS" -gt 0 ] || [ "$CHANGED_CEILING" -eq 1 ]; then
  [ -r "$ROOT/bin/jg-timeout-lib.sh" ] || die "bounded-run helper not found: bin/jg-timeout-lib.sh"
  # shellcheck source=bin/jg-timeout-lib.sh
  . "$ROOT/bin/jg-timeout-lib.sh"
fi

# A run that executes scripts holds a machine run slot until it exits, and every script it starts shares one Go
# build cache (bin/jg-test-host-lib.sh). Time spent waiting for the slot is the machine's, so it is taken off the
# run's own wall clock.
jg_test_host_admit "$(machine_runs_max)"
RUN_STARTED_MS=$((RUN_STARTED_MS + JG_TEST_HOST_WAITED_MS))
jg_test_host_pin_go_cache

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()
declare -a WORKER_SCRIPTS=()

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_run() {
  rm -rf "$RUN_TMP"
  jg_test_host_release
}

trap cleanup_run EXIT

# Build the status classifier once for the whole run. Its launcher builds on first use into the
# calling home's state directory, and every test makes a fresh state directory, so without this
# each watcher test would pay a cold Go build inside its own timing window. A run that sets
# JG_CLASSIFY_BIN itself, or has no Go toolchain, keeps the launcher's own behaviour.
if [ -z "${JG_CLASSIFY_BIN:-}" ] && command -v "${JG_CLASSIFY_GO:-go}" >/dev/null 2>&1; then
  if JG_CLASSIFY_BIN="$RUN_TMP/classify/jg-classify" "$ROOT/bin/jg-classify.sh" is-terminal x >/dev/null 2>&1 \
    || [ -x "$RUN_TMP/classify/jg-classify" ]; then
    export JG_CLASSIFY_BIN="$RUN_TMP/classify/jg-classify"
  fi
fi

RUN_ID="jg-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {  # <script> <rc> <duration> <out> <end_iso> <stream>
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5 stream=${6:-0}
  local base family expected gate_skip gate_reason fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  # Per-class speed limit, reported only. The measured time goes in the message
  # so the next reader sees how far over it is rather than only that it was over.
  local speed_limit speed_class speed_ms
  speed_class=$(test_speed_class_for "$base")
  speed_limit=$(test_speed_limit_for "$speed_class" "$base")
  speed_ms=$((speed_limit * 1000))
  if [ "$speed_limit" -gt 0 ] && [ "$duration" -gt "$speed_ms" ]; then
    # A warning in every mode and for every class, never a failure or a kill.
    log "speed over limit, reported only: $script took ${duration}ms, over its ${speed_ms}ms $speed_class limit"
  fi

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  gate_reason=
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    gate_reason=$(gate_skip_reason "$out")
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
    # A capability skip is the runner's only record of what this host could not
    # exercise, so name it rather than leaving a silent green.
    log "gate skip: $script: ${gate_reason:-<no reason given>}"
  fi

  printf 'JG_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" "$gate_reason" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

# Kill every process still carrying <mark> in its environment, after the bound has
# stopped the script's process group. A descendant that moved into a process group of
# its own (setsid) is outside that signal; it still inherits the script's environment,
# so /proc finds it. Hosts without /proc keep the group kill alone.
reap_marked_processes() {  # <mark>
  local mark=$1 pid
  [ -n "$mark" ] && [ -d /proc/self ] || return 0
  while read -r pid; do
    [ "$pid" != "$$" ] && [ "$pid" != "$BASHPID" ] && kill -KILL "$pid" 2>/dev/null || :
  done < <(grep -al "JG_TEST_SCRIPT_MARK=$mark" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3)
}

# Run <script>, capturing output to <out>. <stream> 1 also echoes it live.
# <id> only has to be unique within this run. The script runs under the bound
# script_speed_bound_secs names, and a script that outruns it is terminated and
# advised (JG_TEST_SLOW) and never stopped while it keeps writing output; a script
# whose output stops for a whole bound is hung and ends as exit 124, so a hang is
# still a bounded failure while a slow, passing script stays green.
run_script_bounded() {  # <script> <out> <stream> <id>
  local script=$1 out=$2 stream=$3 id=$4
  # Declaring the variables local first keeps the helper's export scoped to this
  # call and its child script, so the runner's own environment is left as the
  # caller had it.
  local GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM
  # shellcheck source=tests/git-config-helpers.sh
  . "$ROOT/tests/git-config-helpers.sh" || return
  local rc bound scratch mark scratch_root=${TMPDIR:-/tmp}
  local TMPDIR JG_TEST_SCRIPT_MARK
  TMPDIR=$scratch_root
  : "$id"
  bound=$(script_speed_bound_secs "$script")
  # A bounded script gets a private temp folder and an environment mark, so a
  # timeout can remove what the killed script never cleaned up and find the
  # descendants that left its process group.
  scratch=
  mark=
  if [ "$bound" -gt 0 ]; then
    scratch=$(mktemp -d "$scratch_root/jg-script.XXXXXX") || return
    mark="jg-script-mark-$$-$(now_ms)-$RANDOM"
    export TMPDIR="$scratch" JG_TEST_SCRIPT_MARK="$mark"
  fi
  # ONE owner of what a behavior script inherits, for the serial and the
  # concurrent path alike: a script must see the same environment in CI and
  # under a live home. A squad_lead launch prefixes every process it starts
  # with the whole home-override set (bin/jg-spawn.sh), so an unsanitized
  # runner runs a fixture against the live home - a fixture teardown then
  # compares that ambient live parent with its own durable parent record,
  # finds them disagreeing, and refuses cleanup that had to succeed. The same
  # launch names the live home's JG_SUPERVISION_MODEL, which a fixture home
  # does not have: inherited, it makes the inbox readiness verdict judge a
  # fixture by the live home's model instead of reporting it unknown.
  unset JG_HOME JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_ROOT_OVERRIDE \
    JG_PROJECTS_OVERRIDE JG_CONFIG_OVERRIDE JG_BACKEND \
    JG_PUBLIC_FOLLOWUP_PRIMARY_HOME JG_SUPERVISION_MODEL 2>/dev/null || true
  # A script never records its fixture homes in a real machine's bus registry: the
  # owner home's state/bus/homes must stay byte for byte as Main left it, so each script
  # names a registry file of its own under this run's temp tree.
  local JG_BUS_HOMES
  JG_BUS_HOMES="$RUN_TMP/bus-homes.$$"
  export JG_BUS_HOMES
  set +e
  local marker="$out.bound"
  if [ "$bound" -gt 0 ]; then
    # Expansion is intentionally deferred to the child bash passed to -c.
    # shellcheck disable=SC2016
    if [ "$stream" -eq 1 ]; then
      jg_run_advised "$bound" "$out" "$marker" bash -c \
        'bash "$1" 2>&1 | tee "$2"; exit "${PIPESTATUS[0]}"' _ "$script" "$out"
    else
      jg_run_advised "$bound" "$out" "$marker" bash -c \
        'exec bash "$1" >"$2" 2>&1' _ "$script" "$out"
    fi
    rc=$?
  elif [ "$stream" -eq 1 ]; then
    bash "$script" 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
  else
    bash "$script" >"$out" 2>&1
    rc=$?
  fi
  # The bound advises: a script that outran it and still finished keeps its own
  # result, and only a script whose output stopped growing for a whole bound is
  # ended as hung (exit 124). The line names which of the two it was.
  local verdict=
  [ "$bound" -gt 0 ] && verdict=$(cat "$marker" 2>/dev/null)
  rm -f -- "$marker"
  if [ "$verdict" = hung ] && [ "$rc" -eq 124 ]; then
    printf 'not ok - %s exceeded the per-script bound of %ss with no output for %ss and was terminated as hung\n' \
      "$script" "$bound" "$bound" >>"$out"
    reap_marked_processes "$mark"
    [ "$stream" -eq 1 ] && tail -1 "$out"
    printf 'JG_TEST_TIMEOUT script=%s bound_secs=%s\n' "$script" "$bound"
    printf 'JG_TEST_TIMEOUT script=%s bound_secs=%s\n' "$script" "$bound" >&2
  elif [ "$verdict" = slow ]; then
    printf 'JG_TEST_SLOW %s ran past the per-script bound of %ss and was not stopped: it kept writing output (advice only, exit %s; shards that run side by side slow each other)\n' \
      "$script" "$bound" "$rc" >>"$out"
    [ "$stream" -eq 1 ] && tail -1 "$out"
  fi
  [ -z "$scratch" ] || rm -rf -- "$scratch"
  return "$rc"
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'JG_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  run_script_bounded "$script" "$out" 1 "s$TOTAL"
  rc=$?
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso" 1
}

# A wall budget is a bound on the whole invocation, so work the budget can no
# longer cover is refused instead of started: the run stops, names the first
# script it did not reach, and fails. Only MAX_WALL_MS enables this. A single
# script's own bound is script_speed_bound_secs, so the overshoot is one bound
# at most, never an unbounded tail.
wall_budget_spent() {  # <next-script> -> 0 when the run must stop here
  local next=$1 elapsed
  [ -n "$MAX_WALL_MS" ] || return 1
  elapsed=$(( $(now_ms) - RUN_STARTED_MS ))
  [ "$elapsed" -ge "$MAX_WALL_MS" ] || return 1
  log "wall budget spent: ${elapsed}ms of ${MAX_WALL_MS}ms before $next; that script and the rest were not run"
  printf 'not ok - %s was not run: the wall budget of %sms was already spent at %sms\n' \
    "$next" "$MAX_WALL_MS" "$elapsed"
  AGG_RC=1
  return 0
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    wall_budget_spent "$script" && break
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for admitted scripts. Each worker gets a
  # private mode-0700 TMPDIR so mktemp roots cannot collide. Native Windows
  # Bash layers report synthetic POSIX modes, so retain chmod there but enforce
  # its observed mode only where the host reports real POSIX permissions.
  # Retries are never used as a green strategy.
  worker_n=0
  active_workers=0

  worker_root_mode_is_enforceable() {
    case "$(uname -s)" in
      MINGW*|MSYS*) return 1 ;;
      *) return 0 ;;
    esac
  }

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    set +e
    wait "$pid"
    set -e
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    if worker_root_mode_is_enforceable; then
      mode=$(stat -c %a "$work" 2>/dev/null || /usr/bin/stat -f %Lp "$work" 2>/dev/null || echo unknown)
      case "$mode" in
        700|0700) ;;
        *)
          log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
          rc=1
          ;;
      esac
    fi
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso" 0
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${CONCURRENT_SCRIPTS[@]+"${CONCURRENT_SCRIPTS[@]}"}"; do
    if [ "$script" = "$CONCURRENT_PHASE_BREAK" ]; then
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      continue
    fi
    if wall_budget_spent "$script"; then
      # Everything already running still finishes and is recorded; no new work
      # starts, and the tail below stays unstarted for the same reason.
      while [ "$active_workers" -gt 0 ]; do
        wait_one_completed_job_worker
      done
      break
    fi
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'JG_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      trap - EXIT HUP INT TERM
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      set +e
      run_script_bounded "$script" "$work/output" 0 "w$worker_n"
      rc=$?
      set -e
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    worker_pid=$!
    WORKER_PIDS[worker_n]=$worker_pid
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
  # Unproven remainder, after every concurrent worker has finished.
  for script in "${SERIAL_TAIL_SCRIPTS[@]+"${SERIAL_TAIL_SCRIPTS[@]}"}"; do
    wall_budget_spent "$script" && break
    run_one_serial "$script"
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'JG_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'JG_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'JG_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$MAX_WALL_MS" ] && [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then AGG_RC=1; fi
if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  set +e
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV" "$AGG_RC"
  json_rc=$?
  set -e
  if [ "$json_rc" -eq 0 ]; then
    log "wrote timing artifact: $JSON_PATH"
  else
    log "timing artifact finalization failed: $JSON_PATH"
    AGG_RC=1
  fi
fi

if [ -n "$MAX_WALL_MS" ]; then
  printf 'JG_TEST_BUDGET max_wall_ms=%s duration_ms=%s\n' "$MAX_WALL_MS" "$RUN_DURATION"
  if [ "$RUN_DURATION" -gt "$MAX_WALL_MS" ]; then
    log "wall-clock budget exceeded: ${RUN_DURATION}ms > ${MAX_WALL_MS}ms for $SELECTION_DESC"
    AGG_RC=1
  fi
fi
wall_overrun_warn "$RUN_DURATION"

exit "$AGG_RC"
