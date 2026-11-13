#!/usr/bin/env bash
# jg-test-isolation-proof.sh - bounded concurrent isolation proofs for portable
# behavior-test candidates and selected runner families.
#
# This is the single owner of the proven portable candidate set, the reusable
# concurrent proof run, and its isolation checks. Production portable CI shards,
# bounded local jg-test-run.sh --jobs admission, and family worker caps are owned
# by bin/jg-test-run.sh (docs/jg-test-portable-shards.md).
#
# It does NOT compose production CI shard membership; jg-test-run.sh owns that
# partition. The default portable pool excludes real Herdr, real default-server
# tmux, watcher lock races, AFK, live harnesses, and GUI backends. A named family
# pool instead runs that family's exact membership and inherits its prerequisites.
#
# Usage:
#   jg-test-isolation-proof.sh [--pool <name>] [--jobs N] [--json path] [--list]
#   jg-test-isolation-proof.sh --list-exclusions
#   jg-test-isolation-proof.sh -h | --help
#
# Options:
#   --pool NAME  candidate pool: "portable" (default, this harness's own curated
#                set) or a bin/jg-test-run.sh family name, to prove a stateful
#                family that stays serial on CI but may earn bounded local
#                concurrency. bin/jg-test-run.sh's list_concurrent_safe_families
#                records which families passed.
#   --jobs N     max concurrent workers (default: 4; min 1)
#   --json path  write a pool-scoped machine-readable proof artifact after the
#                run; jg_test_run_jobs_enabled is true only for a successful
#                concurrent run within that pool's recorded admission cap
#   --list       print the proven candidate paths (one per line) and exit 0
#   --list-exclusions
#                print basename + reason for scripts deliberately kept serial
#                relative to the scout-proposed parallel pool, then exit 0
#   -h, --help   print this header
#
# Isolation contract for each concurrent worker:
#   - distinct mode-0700 temporary root under a proof-owned parent
#   - TMPDIR/TMP point only at that root so mktemp/jg_test_tmproot stay private
#   - ambient JG_HOME / JG_*_OVERRIDE cleared so no shared home is reused
#   - no global git config mutation (snapshot before/after)
#   - no production sharding and no retry-until-green
#
# Markers (stdout):
#   JG_ISOLATION_BEGIN <iso8601> concurrency=<n> candidates=<n>
#   JG_ISOLATION_CANDIDATE_BEGIN <iso8601> <script> worker=<i>
#   JG_ISOLATION_CANDIDATE_END <iso8601> <script> exit=<code> duration_ms=<n> worker=<i>
#   JG_ISOLATION_SUMMARY total=<n> failed=<n> concurrency=<n> duration_ms=<n>
#
# Exit status is the aggregate of candidate exits: non-zero if any candidate
# fails, gate-skips (first meaningful line matching ^skip:), if isolation checks
# fail, or if the candidate set is empty. A gate skip names the pool, candidate,
# and missing prerequisite and cannot admit concurrency. A script that fails
# only under concurrency must be removed from the candidate set and investigated;
# this harness never retries a failure into green.
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

JOBS=4
JSON_PATH=
LIST_ONLY=0
LIST_EXCLUSIONS=0
POOL=portable

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'jg-test-isolation-proof: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'jg-test-isolation-proof: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

# Serial exclusions relative to the scout-proposed parallel pool (pure units,
# fake backends, private git fixtures, stubbed network). Reasons are audit
# evidence; do not re-add a basename without clearing its reason.
exclusion_reason() {
  case "$1" in
    jg-backend-tmux-smoke.test.sh)
      printf '%s\n' 'real tmux on a private socket; keep exclusive of default-server contention class'
      ;;
    jg-spawn-dispatch-profile.test.sh)
      printf '%s\n' 'real isolated git worktrees plus spawn settle loops; gray zone until dedicated proof'
      ;;
    jg-teardown.test.sh)
      printf '%s\n' 'landed-work + lock-race teardown matrix; keep serial with forge/git stress peers'
      ;;
    jg-turnend-guard.test.sh|jg-wake-daemon-lifecycle-e2e.test.sh|\
    jg-watcher-lock.test.sh)
      printf '%s\n' 'watcher/wake/lock family; intentional process locks and daemon races'
      ;;
    jg-afk-inject-e2e.test.sh|jg-afk-inject-herdr-e2e.test.sh)
      printf '%s\n' 'AFK lifecycle / inject path; exclusive daemon and pane control'
      ;;
    jg-codex-continuity-live-e2e.test.sh|jg-grok-continuity-live-e2e.test.sh|\
    jg-opencode-primary-live-e2e.test.sh|jg-pi-primary-live-e2e.test.sh|\
    jg-quota-array-dispatch-live-e2e.test.sh)
      printf '%s\n' 'live harness opt-in; never default parallel CI'
      ;;
    jg-backend-herdr-presentation-e2e.test.sh|jg-backend-herdr-prune-safety-e2e.test.sh|\
    jg-backend-herdr-respawn-idem-e2e.test.sh|jg-backend-herdr-smoke.test.sh|\
    jg-backend-herdr-workspace-per-home-e2e.test.sh|jg-herdr-session-cleanup-e2e.test.sh)
      printf '%s\n' 'real Herdr-gated; Herdr lane is a later phase'
      ;;
    *)
      return 1
      ;;
  esac
}

# Exact candidate set from the archived concurrent proof. Adding or removing a
# path requires a new audit and proof archive.
list_parallel_candidates() {
  cat <<'EOF'
tests/jg-pr-merge.test.sh
tests/jg-x-mode.test.sh
EOF
}

list_exclusions_for_report() {
  local base reason
  # Stable report of known serial reasons for the scout-proposed pool classes.
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if reason=$(exclusion_reason "$base"); then
      printf '%s\t%s\n' "$base" "$reason"
    fi
  done <<'EOF'
jg-backend-tmux-smoke.test.sh
jg-spawn-dispatch-profile.test.sh
jg-teardown.test.sh
jg-watcher-lock.test.sh
jg-afk-inject-e2e.test.sh
jg-backend-herdr-smoke.test.sh
jg-pi-primary-live-e2e.test.sh
jg-quota-array-dispatch-live-e2e.test.sh
EOF
}

dir_mode() {
  local path=$1
  if /usr/bin/stat -f %Lp "$path" >/dev/null 2>&1; then
    /usr/bin/stat -f %Lp "$path"
  else
    stat -c %a "$path"
  fi
}

global_git_snapshot() {
  # Empty string when no global config is present or git cannot read it.
  git config --global --list 2>/dev/null | LC_ALL=C sort || true
}

detect_gate_skip() {
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) printf '%s\n' "$first" ;;
    *) return 1 ;;
  esac
}

write_json_artifact() {
  local out=$1 started=$2 finished=$3 run_id=$4 total=$5 failed=$6 concurrency=$7 duration=$8 records=$9 pool=${10} jobs_enabled=${11}
  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$concurrency" "$duration" "$records" "$pool" "$jobs_enabled" <<'PY'
import json, sys
out, started, finished, run_id, total, failed, concurrency, duration, records_path, pool, jobs_enabled = sys.argv[1:12]
scripts = []
with open(records_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, exit_s, dur_s, worker = line.split("\t")
        scripts.append({
            "path": path,
            "exit": int(exit_s),
            "duration_ms": int(dur_s),
            "worker": int(worker),
        })
scripts.sort(key=lambda s: s["path"])
doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "kind": "isolation-proof",
    "pool": pool,
    "concurrency": int(concurrency),
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "production_sharding_enabled": False,
    "jg_test_run_jobs_enabled": jobs_enabled == "1",
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
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
    --pool)
      [ "$#" -gt 1 ] || die "--pool requires a name (portable, or a family name)"
      POOL=$2
      shift 2
      ;;
    --pool=*)
      POOL=${1#--pool=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-exclusions)
      LIST_EXCLUSIONS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1 (this harness owns its candidate set)"
      ;;
  esac
done

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

if [ "$LIST_EXCLUSIONS" -eq 1 ]; then
  list_exclusions_for_report
  exit 0
fi

# The portable pool is this harness's own curated set. A family pool proves a
# stateful family that stays serial on CI but may earn bounded local
# concurrency; bin/jg-test-run.sh's list_concurrent_safe_families records which
# families passed. Membership stays empirical: a family that fails here is not
# admitted, and this harness never retries a failure into green.
pool_candidates() {
  case "$POOL:$LIST_ONLY" in
    portable:1)
      list_parallel_candidates
      ;;
    portable:0)
      "$ROOT/bin/jg-test-run.sh" --list-scheduled --proven-isolated
      ;;
    *:1)
      "$ROOT/bin/jg-test-run.sh" --list --family "$POOL" \
        || die "--pool $POOL is not a known family (see bin/jg-test-run.sh --list-families)"
      ;;
    *)
      "$ROOT/bin/jg-test-run.sh" --list-scheduled --family "$POOL" \
        || die "--pool $POOL is not a known family (see bin/jg-test-run.sh --list-families)"
      ;;
  esac
}

set +e
candidate_output=$(pool_candidates)
pool_rc=$?
set -e
[ "$pool_rc" -eq 0 ] || exit "$pool_rc"

CANDIDATES=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  CANDIDATES+=("$s")
done < <(printf '%s\n' "$candidate_output" | awk '!seen[$0]++')

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

[ "${#CANDIDATES[@]}" -gt 0 ] || die "candidate set is empty; refusing isolation proof"

for s in "${CANDIDATES[@]}"; do
  [ -f "$s" ] || die "candidate not found: $s"
done

PROOF_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jg-isolation-proof.XXXXXX")
chmod 0700 "$PROOF_ROOT" || die "could not chmod 0700 proof root $PROOF_ROOT"
RECORDS="$PROOF_ROOT/records.tsv"
: >"$RECORDS"
trap 'rm -rf "$PROOF_ROOT"' EXIT

GIT_BEFORE=$(global_git_snapshot)
RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="jg-isolation-${RUN_STARTED_MS}-$$"
TOTAL=${#CANDIDATES[@]}
FAILED=0
AGG_RC=0

printf 'JG_ISOLATION_BEGIN %s concurrency=%s candidates=%s\n' \
  "$RUN_STARTED_ISO" "$JOBS" "$TOTAL"

# Worker state arrays parallel to CANDIDATES indices (1-based worker labels).
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()
ACTIVE_WORKERS=0

wait_one_slot() {
  local slot=$1 pid idx work rc duration script mode gate_skip
  pid=${WORKER_PIDS[$slot]}
  idx=${WORKER_IDX[$slot]}
  unset 'WORKER_PIDS[slot]'
  unset 'WORKER_IDX[slot]'
  ACTIVE_WORKERS=$((ACTIVE_WORKERS - 1))
  set +e
  wait "$pid"
  set -e
  work="$PROOF_ROOT/w$idx"
  script=${CANDIDATES[$((idx - 1))]}
  rc=$(cat "$work/out/exit" 2>/dev/null || echo 1)
  duration=$(cat "$work/out/duration_ms" 2>/dev/null || echo 0)
  if [ "$rc" -eq 0 ] && gate_skip=$(detect_gate_skip "$work/out/output"); then
    rc=1
    log "pool $POOL candidate gate-skipped without proving concurrency: $script: $gate_skip"
  fi
  printf 'JG_ISOLATION_CANDIDATE_END %s %s exit=%s duration_ms=%s worker=%s\n' \
    "$(now_iso)" "$script" "$rc" "$duration" "$idx"
  printf '%s\t%s\t%s\t%s\n' "$script" "$rc" "$duration" "$idx" >>"$RECORDS"
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    AGG_RC=1
    log "candidate failed: $script exit=$rc"
    if [ -s "$work/out/output" ]; then
      log "--- output ($script) ---"
      tail -n 40 "$work/out/output" >&2 || true
    fi
  fi
  # Isolation: worker root must remain mode 0700 and under the proof parent.
  mode=$(dir_mode "$work")
  case "$mode" in
    700|0700) ;;
    *)
      log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
      AGG_RC=1
      FAILED=$((FAILED + 1))
      ;;
  esac
  case "$work" in
    "$PROOF_ROOT"/*) ;;
    *)
      log "isolation failure: worker root escaped proof parent: $work"
      AGG_RC=1
      ;;
  esac
}

worker_pid_is_running() {
  local want=$1 running inventory="$PROOF_ROOT/running-pids"
  jobs -r -p >"$inventory"
  while IFS= read -r running; do
    [ "$running" = "$want" ] && return 0
  done <"$inventory"
  return 1
}

wait_one_completed_slot() {
  local slot work
  while :; do
    for slot in "${!WORKER_PIDS[@]}"; do
      work="$PROOF_ROOT/w${WORKER_IDX[$slot]}"
      if [ -f "$work/out/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
        wait_one_slot "$slot"
        return
      fi
    done
    sleep 0.01
  done
}

idx=0
for script in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  work="$PROOF_ROOT/w$idx"
  # Create then chmod: mkdir -m can still be umask-adjusted on some platforms.
  mkdir -p "$work/tmp" "$work/out"
  chmod 0700 "$work" "$work/tmp" "$work/out" \
    || die "could not chmod 0700 worker roots under $work"
  mode=$(dir_mode "$work")
  case "$mode" in
    700|0700) ;;
    *) die "failed to create mode-0700 worker root at $work (mode=$mode)" ;;
  esac
  mode=$(dir_mode "$work/tmp")
  case "$mode" in
    700|0700) ;;
    *) die "failed to create mode-0700 TMPDIR at $work/tmp (mode=$mode)" ;;
  esac

  printf 'JG_ISOLATION_CANDIDATE_BEGIN %s %s worker=%s\n' \
    "$(now_iso)" "$script" "$idx"

  (
    set +e
    export TMPDIR="$work/tmp"
    export TMP="$work/tmp"
    # Clear ambient fleet overrides so candidates cannot share a live home.
    unset JG_HOME JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_ROOT_OVERRIDE \
      JG_PROJECTS_OVERRIDE JG_CONFIG_OVERRIDE JG_BACKEND 2>/dev/null || true
    cd "$ROOT" || exit 1
    begin_ms=$(now_ms)
    bash "$script" >"$work/out/output" 2>&1
    rc=$?
    end_ms=$(now_ms)
    duration=$((end_ms - begin_ms))
    if [ "$duration" -lt 0 ]; then
      duration=0
    fi
    printf '%s\n' "$rc" >"$work/out/exit"
    printf '%s\n' "$duration" >"$work/out/duration_ms"
    exit 0
  ) &
  WORKER_PIDS[idx]=$!
  WORKER_IDX[idx]=$idx
  ACTIVE_WORKERS=$((ACTIVE_WORKERS + 1))

  # Bound concurrency.
  while [ "$ACTIVE_WORKERS" -ge "$JOBS" ]; do
    wait_one_completed_slot
  done
done

while [ "$ACTIVE_WORKERS" -gt 0 ]; do
  wait_one_completed_slot
done

GIT_AFTER=$(global_git_snapshot)
if [ "$GIT_BEFORE" != "$GIT_AFTER" ]; then
  log "isolation failure: git config --global changed during the concurrent proof"
  log "--- before ---"
  printf '%s\n' "$GIT_BEFORE" >&2
  log "--- after ---"
  printf '%s\n' "$GIT_AFTER" >&2
  AGG_RC=1
  FAILED=$((FAILED + 1))
fi

# Cross-process artifact check: no candidate may leave debris outside the
# proof-owned TMPDIR tree. Workers only receive TMPDIR under PROOF_ROOT, so any
# residual path under PROOF_ROOT is expected and cleaned by trap. Refuse if a
# worker wrote a fixed global path we know about from audit (none remain after
# the arm-pretool stderr path uses TMPDIR).
if find "$PROOF_ROOT" -type f -name 'jg-arm-pretool-check-claude-stderr.*' 2>/dev/null | grep -q .; then
  : # allowed only under proof roots; nothing to do
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'JG_ISOLATION_SUMMARY total=%s failed=%s concurrency=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION"

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Stable record order for the artifact.
  sort -t$'\t' -k1,1 "$RECORDS" -o "$RECORDS"
  jobs_enabled=0
  jobs_max=0
  if "$ROOT/bin/jg-test-run.sh" --list-concurrent-safe-families | grep -Fxq "$POOL"; then
    jobs_max=$("$ROOT/bin/jg-test-run.sh" --concurrent-safe-family-jobs-max "$POOL")
  fi
  if [ "$AGG_RC" -eq 0 ] && [ "$JOBS" -gt 1 ] && [ "$JOBS" -le "$jobs_max" ]; then
    jobs_enabled=1
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION" "$RECORDS" "$POOL" "$jobs_enabled"
  log "wrote isolation proof artifact: $JSON_PATH"
fi

exit "$AGG_RC"
