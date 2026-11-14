#!/usr/bin/env bash
# jg-session-start.sh - one command for the whole session start.
#
# Collapses AGENTS.md sections 3 (bootstrap) and 5 (recovery) into ONE script
# producing ONE ordered digest, so a session starts in one or two turns
# instead of the six-plus separate reads the old docs required: run
# jg-bootstrap.sh, then separately read data/projects.md, data/squad_leads.md,
# data/captain.md, data/captain-shared.md, data/learnings.md, data/owner-rules.md,
# then run jg-lock.sh, jg-wake-drain.sh, then read data/backlog.md, every state/*.meta,
# and every state/*.status.
# Every one of those reads is UNCONDITIONAL at every session start, so they
# belong in a script, not in N agent turns.
#
# COMPOSITION, NOT DUPLICATION: this script calls jg-lock.sh, jg-bootstrap.sh,
# jg-wake-drain.sh, and jg-startup-network.sh as real subprocesses and prints
# their real output. It never re-implements their logic; all
# sequencing/formatting logic added here stays local to this file. Those four
# scripts remain fully working
# standalone with unchanged default behavior - other flows (jg-bootstrap.sh
# install <tools> after consent, /resupply, the afk daemon, existing
# tests) still call them directly. The one seam this script needed -
# bootstrap running its detect-only diagnostics without its six mutating
# sweeps - is an opt-in JG_BOOTSTRAP_DETECT_ONLY=1 flag on jg-bootstrap.sh
# itself (default unset/0 = unchanged behavior), not a fork.
#
# ORDERING, and why LOCK now runs before BOOTSTRAP (the old AGENTS.md order
# was bootstrap-then-lock):
#
#   1. lock          - acquire the per-home session lock FIRST, before any
#                       mutating step runs.
#   1b. home role    - the resolved juggernaut-repository role line
#                      (bin/jg-role.sh report), purely local, no network.
#   2. bootstrap      - home-local stale Herdr projection cleanup runs only
#                       when this session actually holds the lock. Detect-only
#                       diagnostics always run. Bootstrap's six MUTATING sweeps
#                       (same-home backlog reconciliation,
#                       squad_lead convergence, squad_lead liveness, pending remote
#                       handoff retry, X-mode artifact writes, fleet sync) also run only when
#                       locked; the four network sweeps run in the deferred
#                       stage rather than this synchronous bootstrap section.
#   3. wake-drain     - presents durable wakes and advances recovery handling
#                       state, so it only runs when locked. The local bounded
#                       inactive-outcome startup scan runs in the deferred worker.
#                       First, on every harness and away posture, it seeds the
#                       outcome store's display tail copy when that is absent
#                       (bin/jg-branch-outcome.sh seed-tail).
#   4. supervision-instructions - the one emitted operating block for the
#                       detected primary harness.
#   5. read-once contract - the do-not-re-read contract covering every source
#                       represented by the two digests below.
#   6. fleet digest   - a compact data/backlog.md identity/metadata listing,
#                       one row per state/*.meta with its last status line,
#                       the away posture (state/.afk-contract and the legacy
#                       state/.afk daemon flag), and a cheap per-task
#                       endpoint-liveness read, each bounded and crash-
#                       isolated so one task's read can never abort the
#                       digest: read-only, always runs. The per-task reads
#                       run serially, so with a wedged backend the stage's
#                       ceiling is tasks x the per-read bound
#                       (JG_SESSION_START_ENDPOINT_TIMEOUT, default 10s) and
#                       can itself reach the digest's runtime bound.
#   7. network checks - the result of the deferred network stage started back at
#                       step 1, harvested WITHOUT waiting for it.
#   8. context digest - data/projects.md, data/squad_leads.md, data/captain.md,
#                       data/captain-shared.md, data/learnings.md,
#                       data/owner-rules.md: read-only,
#                       always safe, always runs.
#   9. closing reminder - prints the context-specific watcher next step; this
#                       script points back to the emitted harness supervision
#                       block and deliberately never arms the watcher itself.
#
# Those ten names are also the runtime-bound stage list below, so a truncated
# startup can name exactly which of them never ran - and the parent banners
# EVERY nonzero child exit, not only the bound: a child that dies or is killed
# mid-stage must never truncate the digest silently.
#
# NO NETWORK ON THE BLOCKING PATH. This digest runs on a session-open hook that
# blocks session initialization, so anything it waits for is time the captain
# waits before the first turn - and every external-network call it used to make
# was individually unbounded. One unreachable remote squad_lead could burn the
# entire JG_SESSION_START_TIMEOUT and truncate the digest, so a slow network
# could cost the work queue itself.
# So no step between here and the last line below makes an external-network
# call. The five that did - `gh auth status`, squad_lead liveness, squad_lead
# convergence, pending remote handoff delivery, and the fleet-sync fetch - are
# started as one detached bounded worker right after the lock (step 1) and
# harvested at step 7 without ever blocking on it. The bounded inactive-outcome
# startup scan joins that worker because its local current-state reads can also
# be slow. bin/jg-startup-network.sh owns that stage and its safety argument;
# bin/jg-bootstrap.sh and bin/jg-inactive-reconcile.sh remain the owners of the
# work itself and still run it.
# The digest is therefore composed from bounded local reads and local
# subprocesses only, while slow network or inactive-state reconciliation delays
# a reported check rather than startup.
# What this deliberately trades: on a slow network the digest prints "IN
# PROGRESS" and names exactly which checks are not yet confirmed, instead of
# waiting for them. It never reports an unconfirmed check as passed.
#
# CONTRACT CARRIER: bin/jg-contract-carrier.sh owns how the primary gets the supervisor contract from a file
# of its own. A locked start calls its `ensure`; when its `check` does not print `file` (or `ensure` wrote the
# file at this very start), the digest prints the contract itself, at the start and in the re-emit after a
# compaction, outside the digest budget.
#
# ORDERING, and why FLEET STATE now runs before CONTEXT: this digest is
# delivered through a harness that truncates an oversized payload from the TAIL,
# and it has really been truncated in practice - a 70KB digest arrived as lines
# 1-435 of 578, cutting off eight lines before the live-task inventory. What a
# truncated tail drops must therefore be the CHEAPEST thing to lose. Curated
# memory is stable session to session, is already governed by a captain-set
# budget (config/startup-memory-budget), and is recoverable with one targeted
# read; live fleet identity - which tasks exist, their windows, worktrees,
# backends, and endpoint liveness - changes every session and is exactly what
# recovery depends on. So fleet state goes first and the memory files absorb the
# truncation. The read-once contract moves ahead of both for the same reason: a
# contract that only arrives after the payload it governs is the first thing a
# truncated digest loses, and it carries the truncation caveat that keeps it
# honest when a stage below it never ran.
# The LOCK/BOOTSTRAP/WAKE-QUEUE safety preamble keeps its order: it establishes
# mutation authority and this turn's work queue before anything else is read.
#
# On a Pi primary, the supervision-block step also checks whether Pi's two
# tracked primary extensions are loaded and prints a PI_WATCH_EXTENSION
# reminder line when one is missing.
#
# Why lock first: the old documented order (bootstrap, THEN lock) let a
# SECOND concurrent session run bootstrap's mutating sweeps - converging
# squad_lead homes, retrying pending handoff outboxes and receiver wakes, writing
# X-mode artifacts, and fetching or fast-forwarding every project clone - before
# ever discovering another session already holds the lock. Two sessions racing
# those sweeps is exactly the hazard the lock exists to prevent, so locking first closes the
# hole outright: only the session that actually wins the lock ever touches
# shared mutable state.
#
# The tradeoff this ordering accepts: a refused (read-only) session must not
# go dark. So on refusal, bootstrap still runs (in JG_BOOTSTRAP_DETECT_ONLY=1
# mode) for its local read-only detect lines - missing tools, the worktree-tangle
# check, the harness override, crew-dispatch validation, the quota-axi
# tool check, and the Beads store health - none of
# which mutate shared state
# and all of which are safe to compute without verified lock ownership.
# It deliberately skips the network-only GitHub-auth probe because a read-only
# session has no dispatch, spawn, steer, or merge action for that verdict to gate.
# Only projection cleanup, the six bootstrap mutating sweeps, and wake-queue
# presentation are skipped.
# The context and fleet-state digests
# below are always read-only, so they run unconditionally in both modes.
#
# DIGEST SIZE: the whole digest is capped at JG_DIGEST_CAP bytes (defaults/token-caps
# `digest-cap`, 40000), so a fresh session starts with most of its context free: a Squad
# Lead home once started at 85 percent of its context on a 300 KB digest. bin/jg-digest-cap-lib.sh
# owns the byte budget. The lock result, the wake queue and its WAKE_ACK_REQUIRED line,
# the supervision block and the network checks are counted but never cut: they carry an
# action. Every other section prints at most min(its own cap, what the digest has left),
# newest and most urgent first, and a cut ends in a "[cut: K of N <items> shown; all of
# them: <command>]" line (or the file's own "[cut at ..." line with the sed range), so
# information moves behind a pointer and nothing is deleted. The last line reports the
# bytes printed against the cap.
# BACKLOG DIGEST: the startup listing is a RECOVERY input, not a reporting surface, so it
# carries what this turn can act on and nothing else.
#   - `done` rows are never listed (bin/jg-bearings-snapshot.sh and /debrief own history).
#   - In-flight, held, blocked and ready rows share JG_SESSION_START_BACKLOG_CAP bytes
#     (`backlog-cap`). Rows the captain owes an answer on come first among the held rows,
#     then by priority, then newest; a group's cut ends in its total row count and the
#     bin/jg-backlog.sh command that lists every row.
# CURATED MEMORY: captain-shared.md and learnings.md print their opening lines up to the
# memory-file cap and the other context files up to the context-file cap
# (JG_SESSION_START_CONTEXT_FILE_CAP sets all of them for one run), then a cut line with the
# line range, the byte count and the exact sed command. Learnings add an index of their
# headings, newest first, and a long owner-rules file prints as an index of every rule's
# title with the line range that holds the rule; a file within its cap prints whole.
# The backlog groups come from the Beads store (`list` for the compact identity
# fields plus blocked_by, hold_kind and hold_reason, never body; the groups are
# the store's own filters `--state in_flight`, `--state held`,
# `--state queued --blocked`, and `ready`), so this script never reimplements
# task state; the groups can overlap, because an in-flight item that is also held
# appears under both. A failed read prints its reason.
# Full bodies are targeted follow-up only: `bin/jg-backlog.sh show <id> --full`.
#
# LANE ROWS: one row per work lane, most urgent first (dead endpoint, then waiting on a
# decision, blocked or failed, then newest status), within JG_SESSION_START_LANES_CAP bytes.
# JG_SESSION_START_STATUS_TAIL (default 1) sets how many status lines a row carries and
# bin/jg-line-cap-lib.sh bounds each at 160 characters. Both bounds are safe because the
# lane's full record stays in state/<id>.meta and state/<id>.status, and AGENTS.md section 8
# treats a status line as a wake EVENT rather than current state - bin/jg-crew-state.sh owns
# current state.
#
# RUNTIME BOUND: the digest is now executed through a native session-open
# adapter (see bin/jg-sessionstart-run.sh), which blocks either hook-driven
# session initialization or Pi's first provider preflight while it runs, so an
# unbounded digest is no longer merely slow - it can strand a whole session or
# first turn behind one hung subprocess. Every remaining step is local, but
# local is not the same as bounded: tool version probes and the backlog
# listing are unbounded subprocesses, while each per-task endpoint read runs
# in its own crash-isolated child under JG_SESSION_START_ENDPOINT_TIMEOUT
# (default 10s). So the whole digest still runs as ONE bounded child of this
# script (JG_SESSION_START_TIMEOUT, default 120s). The deferred network stage
# deliberately sits OUTSIDE that bound,
# in its own process group under its own aggregate deadline, so a truncated
# digest neither waits for it nor orphans it unbounded. The
# child writes the digest straight to this script's stdout, so everything it
# emitted before the child stopped is already delivered; the parent then prints
# a loud STARTUP TRUNCATED banner on ANY nonzero child exit - the runtime bound
# or an unexpected child death, named with its exit status - naming the stage
# that did not finish and the sections that were therefore never emitted, and
# still exits 0. The child
# records its progress in JG_SESSION_START_STAGE_FILE, which is also the flag
# that tells a child it is the child - the parent never recurses.
# Hosts without timeout, gtimeout, or perl use the shared pure-Bash watchdog, so
# the digest never runs without the same hard bound and process-group cleanup.
#
# Usage: jg-session-start.sh [--reemit] [--source <source>]
#   Prints the full ordered digest to stdout and always exits 0: this is a
#   reporting command, not a gate. A lock refusal is reported as a loud
#   banner inline, never a silent failure or a non-zero exit that would make
#   an agent skip the rest of the digest.
#
#   --reemit  This process ALREADY took the helm at its own startup and has
#             only lost its context (a /clear or a compaction). Skip the
#             mutating sweeps that startup already reconciled - the stale Herdr
#             projection cleanup and bootstrap's six mutating sweeps (fleet
#             sync, same-home backlog reconciliation, squad_lead convergence and
#             liveness, pending remote handoff retry, X-mode
#             artifact writes) - and
#             re-emit the rest. Wake-queue presentation is NOT skipped: queued
#             records are this turn's work queue, they arrived after startup,
#             and a session that owns the lock is exactly the session that must
#             handle and acknowledge them. Lock acquisition still runs, because
#             ownership must be re-verified rather than assumed: jg-lock.sh
#             already treats a lock owned through shared ancestry or a trusted
#             same-session Claude id as its own, so the re-emit proceeds, while
#             a lock another live session took meanwhile still produces the
#             ordinary read-only path.
#
#   --source  The native session-open source, supplied only by
#             jg-sessionstart-run.sh. A genuine `startup` that owns the active
#             session lock records AGENTS.md's SHA-256 baseline only after the
#             digest completion record is published, keyed to that lock's
#             harness pid. No resume, clear, reset, compact, or other rebuild
#             creates or replaces it. Pi and pi-signed compaction are the only
#             supported stale-cache rebuild pair: a missing baseline, a baseline
#             for another harness pid, or a changed hash causes the complete
#             current AGENTS.md to print before the bulky digest. The baseline
#             remains immutable so every later drifted compaction refreshes
#             again, while an equal baseline emits no instruction refresh.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
COMPLETION_FILE="$STATE/.session-start-complete"
AGENTS_BASELINE_FILE="$STATE/.session-start-agents-baseline"

REEMIT=0
SESSION_SOURCE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reemit)
      REEMIT=1
      shift
      ;;
    --source)
      SESSION_SOURCE=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --source=*)
      SESSION_SOURCE=${1#--source=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$SCRIPT_DIR/jg-session-start.sh" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'jg-session-start: unknown argument: %s\n' "$1" >&2
      printf 'usage: jg-session-start.sh [--reemit] [--source <source>]\n' >&2
      exit 2
      ;;
  esac
done

# --- 0. runtime bound ---------------------------------------------------------
# The ordered stage list is the contract behind the truncation banner: the child
# names the stage it is entering, and the parent reports every stage at or after
# that one as never emitted. Keep it in the exact order the digest prints.
SESSION_START_STAGES='lock role bootstrap wake-queue supervision-instructions read-once fleet-state network-checks context next-step'

stage() {  # <stage-name>: breadcrumb for the parent's truncation banner
  [ -n "${JG_SESSION_START_STAGE_FILE:-}" ] || return 0
  printf '%s\n' "$1" > "$JG_SESSION_START_STAGE_FILE" 2>/dev/null || true
}

# shellcheck source=bin/jg-timeout-lib.sh
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-session-lock-lib.sh
. "$SCRIPT_DIR/jg-session-lock-lib.sh"

if [ -z "${JG_SESSION_START_STAGE_FILE:-}" ]; then
  SESSION_START_BUDGET=${JG_SESSION_START_TIMEOUT:-120}
  # A non-positive or non-numeric budget is not a budget (`timeout 0` disables
  # the deadline outright), so an unusable value falls back to the default
  # rather than silently removing the bound.
  case "$SESSION_START_BUDGET" in ''|*[!0-9]*) SESSION_START_BUDGET=120 ;; esac
  [ "$SESSION_START_BUDGET" -gt 0 ] 2>/dev/null || SESSION_START_BUDGET=120
  SESSION_START_STAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/jg-session-start-stage.XXXXXX" 2>/dev/null) || SESSION_START_STAGE_FILE=
  if [ -z "$SESSION_START_STAGE_FILE" ]; then
    # Without a breadcrumb the bound still holds; only the banner's precision
    # is lost, so the child still runs bounded.
    SESSION_START_STAGE_FILE=/dev/null
  fi
  if [ "$REEMIT" -eq 1 ]; then
    if [ -n "$SESSION_SOURCE" ]; then
      jg_run_timed "$SESSION_START_BUDGET" \
        env JG_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/jg-session-start.sh" --reemit --source "$SESSION_SOURCE"
    else
      jg_run_timed "$SESSION_START_BUDGET" \
        env JG_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
        "$SCRIPT_DIR/jg-session-start.sh" --reemit
    fi
  elif [ -n "$SESSION_SOURCE" ]; then
    jg_run_timed "$SESSION_START_BUDGET" \
      env JG_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/jg-session-start.sh" --source "$SESSION_SOURCE"
  else
    jg_run_timed "$SESSION_START_BUDGET" \
      env JG_SESSION_START_STAGE_FILE="$SESSION_START_STAGE_FILE" \
      "$SCRIPT_DIR/jg-session-start.sh"
  fi
  SESSION_START_RC=$?
  # ANY nonzero child exit is a truncation: the banner contract promises that
  # a stage that cannot print is named. Exit 124 is the bound firing; any
  # other status means the child died or was killed mid-stage, which truncates
  # silently when unbanned - the parent must banner it, never exit 0 around it.
  if [ "$SESSION_START_RC" -ne 0 ]; then
    SESSION_START_LAST_STAGE=$(cat "$SESSION_START_STAGE_FILE" 2>/dev/null) || SESSION_START_LAST_STAGE=
    [ -n "$SESSION_START_LAST_STAGE" ] || SESSION_START_LAST_STAGE=unknown
    SESSION_START_PENDING=$(
      printf '%s\n' "$SESSION_START_STAGES" | tr ' ' '\n' |
        awk -v from="$SESSION_START_LAST_STAGE" '$0 == from {seen = 1} seen' | tr '\n' ' '
    )
    [ -n "${SESSION_START_PENDING# }" ] || SESSION_START_PENDING='(unknown - the digest may be incomplete anywhere)'
    BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
    printf '\n%s\n' "$BAR"
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  STARTUP TRUNCATED - SESSION START HIT ITS %ss RUNTIME BOUND\n' "$SESSION_START_BUDGET"
    else
      printf '●  STARTUP TRUNCATED - SESSION START DIED UNEXPECTEDLY (exit %s, not its runtime bound)\n' "$SESSION_START_RC"
    fi
    printf '●  It stopped during the "%s" stage, so everything above is COMPLETE\n' "$SESSION_START_LAST_STAGE"
    printf '●  only up to that point.\n'
    printf '●  RECONCILE these stages before acting on anything they would have shown:\n'
    printf '●    %s\n' "${SESSION_START_PENDING% }"
    printf '●  Rerun bin/jg-session-start.sh now to finish taking the helm. If it truncates\n'
    if [ "$SESSION_START_RC" -eq 124 ]; then
      printf '●  again, raise JG_SESSION_START_TIMEOUT and report the slow stage - a stage that\n'
      printf '●  cannot finish inside the bound is a fleet problem, not a reporting detail.\n'
    else
      printf '●  again, report the exit status and the stage - raising the runtime bound\n'
      printf '●  cannot help a digest that died, and a stage that dies is a fleet problem.\n'
    fi
    printf '%s\n' "$BAR"
  fi
  rm -f "$SESSION_START_STAGE_FILE" 2>/dev/null || true
  exit 0
fi

PRIMARY_HARNESS=$("$SCRIPT_DIR/jg-harness.sh" 2>/dev/null || printf unknown)

# shellcheck source=bin/jg-backend.sh
. "$SCRIPT_DIR/jg-backend.sh"
# shellcheck source=bin/jg-backlog-lib.sh
. "$SCRIPT_DIR/jg-backlog-lib.sh"
# shellcheck source=bin/jg-public-followup-lib.sh
. "$SCRIPT_DIR/jg-public-followup-lib.sh"
# shellcheck source=bin/jg-trace-context-lib.sh
. "$SCRIPT_DIR/jg-trace-context-lib.sh"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-line-cap-lib.sh
. "$SCRIPT_DIR/jg-line-cap-lib.sh"
# shellcheck source=bin/jg-digest-cap-lib.sh
. "$SCRIPT_DIR/jg-digest-cap-lib.sh"


# The digest size bounds are token caps: defaults/token-caps owns each value and
# its reason, config/token-caps overrides it for one home, and the matching
# JG_SESSION_START_* variable overrides both for one run.
# token_cap <name> <built-in>: the last `<name> <positive integer>` line of the
# home's file, else the shared default, else the built-in; a malformed value is
# skipped, so a bad line can never zero a cap.
token_cap() {
  local name=$1 builtin=$2 file val
  for file in "$CONFIG/token-caps" "$SCRIPT_DIR/../defaults/token-caps"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    val=$(awk -v n="$name" '$1 == n && $2 ~ /^[0-9]+$/ && $2 > 0 { v = $2 } END { if (v != "") print v }' "$file" 2>/dev/null)
    [ -z "$val" ] || { printf '%s\n' "$val"; return 0; }
  done
  printf '%s\n' "$builtin"
}
# cap_value <name> <built-in> [override-var-value]: a positive integer cap, the run override first.
cap_value() {
  local name=$1 builtin=$2 over=${3:-} val
  val=${over:-$(token_cap "$name" "$builtin")}
  case "$val" in ''|*[!0-9]*|0) val=$builtin ;; esac
  printf '%s\n' "$val"
}
STATUS_TAIL=${JG_SESSION_START_STATUS_TAIL:-$(token_cap status-tail 1)}
case "$STATUS_TAIL" in ''|*[!0-9]*) STATUS_TAIL=1 ;; esac
LANES_TIMEOUT=${JG_SESSION_START_LANES_TIMEOUT:-30}
case "$LANES_TIMEOUT" in ''|*[!0-9]*) LANES_TIMEOUT=30 ;; esac
[ "$LANES_TIMEOUT" -gt 0 ] 2>/dev/null || LANES_TIMEOUT=30
# One per-task endpoint read may never outlive this bound: a hung backend CLI
# becomes that task's endpoint: error line instead of the digest's whole
# runtime budget.
ENDPOINT_TIMEOUT=${JG_SESSION_START_ENDPOINT_TIMEOUT:-10}
case "$ENDPOINT_TIMEOUT" in ''|*[!0-9]*) ENDPOINT_TIMEOUT=10 ;; esac
[ "$ENDPOINT_TIMEOUT" -gt 0 ] 2>/dev/null || ENDPOINT_TIMEOUT=10
# THE DIGEST BYTE CAP. A fresh session starts under a fifth of its context: the
# whole digest prints at most DIGEST_CAP bytes (defaults/token-caps `digest-cap`,
# 40000, about 10000 tokens), and bin/jg-digest-cap-lib.sh counts every byte against
# it. The safety preamble (lock, wake queue, supervision block, network checks)
# is never cut; every other section has a byte cap of its own and prints only what
# is left of the whole when it runs. A cut section ends with its total count and the
# one command that prints all of it, and it lists the newest and most urgent first.
# The caps below cut only what the digest PRINTS: nothing is deleted from disk.
DIGEST_CAP=$(cap_value digest-cap 40000 "${JG_DIGEST_CAP:-}")
DIGEST_RESERVE=$(cap_value digest-reserve 2500 "${JG_DIGEST_RESERVE:-}")
BACKLOG_CAP=$(cap_value backlog-cap 5000 "${JG_SESSION_START_BACKLOG_CAP:-}")
LANES_CAP=$(cap_value lanes-cap 6000 "${JG_SESSION_START_LANES_CAP:-}")
ORPHAN_CAP=$(cap_value orphan-cap 600 "${JG_SESSION_START_ORPHAN_CAP:-}")
COMMITMENTS_CAP=$(cap_value commitments-cap 2500 "${JG_SESSION_START_COMMITMENTS_CAP:-}")
INDEX_CAP=$(cap_value index-cap 1500 "${JG_SESSION_START_INDEX_CAP:-}")
OWNER_RULES_CAP=$(cap_value owner-rules-cap 2500 "${JG_SESSION_START_OWNER_RULES_CAP:-}")
# Per-file caps for the curated files. The run override sets all of them, as it
# always has.
CONTEXT_FILE_CAP=$(cap_value context-file-cap 1500 "${JG_SESSION_START_CONTEXT_FILE_CAP:-}")
MEMORY_FILE_CAP=$(cap_value memory-file-cap 1200 "${JG_SESSION_START_CONTEXT_FILE_CAP:-}")
BACKLOG_FIELDS=blocked_by,hold_kind,hold_reason,priority,created
jg_digest_budget_init "$DIGEST_CAP" "$DIGEST_RESERVE"
trap jg_digest_budget_close EXIT

RULE='================'
SUBRULE='----------------'

section() {
  printf '\n%s\n%s\n%s\n' "$RULE" "$1" "$RULE"
  jg_digest_account $((${#RULE} * 2 + $(jg_digest_bytes "$1") + 4))
}
subsection() {
  printf '\n%s\n%s\n' "$1" "$SUBRULE"
  jg_digest_account $((${#SUBRULE} + $(jg_digest_bytes "$1") + 3))
}

# print_file_or_absent <path> <label>: full contents under a labeled
# subsection, or an explicit ABSENT marker. Absence is semantically
# meaningful for every one of these files (captain.md absent = juggernaut
# repo built-in defaults, projects.md absent = rebuild from clones, etc. -
# AGENTS.md section 3) and must never be confused with an empty-but-present
# file, so the two cases print differently.
print_file_or_absent() {
  local path=$1 label=$2
  subsection "$label"
  if [ -f "$path" ]; then
    if [ -s "$path" ]; then
      cat "$path" | jg_digest_say
    else
      printf '(present, empty)\n' | jg_digest_say
    fi
  else
    printf 'ABSENT\n' | jg_digest_say
  fi
}

# print_heading_index <path> <heading-regex> <noun> <intro>: every heading of a
# knowledge file once, newest (last in the file) first, each with the line range of
# its complete body, until INDEX_CAP bytes are spent. A cut ends in the heading
# count and the command that lists them all.
print_heading_index() {
  local path=$1 pattern=$2 noun=$3 intro=$4 budget
  budget=$(jg_digest_avail "$INDEX_CAP")
  printf '\n%s\n' "$intro" | jg_digest_say
  awk -v pat="$pattern" '
    $0 ~ pat {
      if (name != "") rows[++n] = sprintf("  lines %d-%d: %s", first, NR - 1, substr(name, 1, 300))
      first = NR; name = $0
    }
    END {
      if (name != "") rows[++n] = sprintf("  lines %d-%d: %s", first, NR, substr(name, 1, 300))
      for (i = n; i >= 1; i--) print rows[i]
    }
  ' "$path" | jg_digest_clip "$budget" "$noun" "grep -n '$pattern' $path"
}

# print_file_capped <path> <label> [cap]: print_file_or_absent for the long curated
# files. A file over its cap (or over what the whole digest has left) prints its first
# lines, then ONE cut line: the line range and byte count not printed, and the sed
# command that prints them.
print_file_capped() {
  local path=$1 label=$2 own=${3:-$CONTEXT_FILE_CAP} cap size keep lines left marker_reserve=330
  cap=$(jg_digest_avail "$own")
  if [ ! -s "$path" ] || [ "$(wc -c < "$path")" -le "$cap" ]; then
    print_file_or_absent "$path" "$label"
    return 0
  fi
  size=$(wc -c < "$path")
  subsection "$label"
  # The cut line is paid for out of what the whole digest has left, not out of the
  # file's own cap, so a configured cap of N prints N bytes of the file.
  left=$(jg_digest_avail 1000000000)
  left=$((left > marker_reserve ? left - marker_reserve : 0))
  cap=$(( cap < left ? cap : left ))
  keep=$(head -c "$cap" "$path" | wc -l)
  lines=$(wc -l < "$path")
  [ "$keep" -eq 0 ] || head -n "$keep" "$path" | jg_digest_say
  printf '[cut at %s bytes: lines %s-%s (%s bytes in all) are not printed; read them with sed -n %s,%sp %s]\n' \
    "$cap" "$((keep + 1))" "$lines" "$size" "$((keep + 1))" "$lines" "$path" | jg_digest_say
}

# The learnings file: its opening lines, then an index of every heading.
print_learnings() {
  local path=$1 label=$2
  print_file_capped "$path" "$label" "$MEMORY_FILE_CAP"
  [ -s "$path" ] || return 0
  print_heading_index "$path" '^#' headings \
    "Learning index (newest first; full bodies: sed -n '<first>,<last>p' $path):"
}

# The owner rules: whole while they are short, else an index of every rule's title,
# newest first, with the line range that holds the rule's words, scope and enforcement.
print_owner_rules() {
  local path=$1 label=$2 cap size
  cap=$(jg_digest_avail "$OWNER_RULES_CAP")
  if [ ! -s "$path" ] || [ "$(wc -c < "$path")" -le "$cap" ]; then
    print_file_or_absent "$path" "$label"
    return 0
  fi
  size=$(wc -c < "$path")
  subsection "$label"
  print_heading_index "$path" '^## ' rules \
    "$(grep -c '^## ' "$path") owner rules, $size bytes; every rule stays whole in the file (newest first; a rule's words, scope and enforcement: sed -n '<first>,<last>p' $path):"
}

print_backlog_pointer() {
  printf 'Full task bodies remain available on demand: bin/jg-backlog.sh show <id> --full.\n' | jg_digest_say
}

# The store closes every listing with its own help block. This section composes
# four listings, so keeping them would repeat the same pointers four times, once
# per group, each carrying this home's full backlog path. The section prints one
# equivalent pointer of its own (print_backlog_pointer), so the per-group help
# blocks stop at their `help[` header instead.
strip_help_block() {
  awk '/^help\[/ { exit } { print }'
}

backlog_rows() {  # <list|ready> [flags...]
  jg_backlog_beads_read "$CONFIG" "$@"
}

# print_backlog_group <title> <listing> <budget> <command> <order>
# One group of the compact listing. The store's own header lines (its count and
# table header) print as written; its rows print most urgent first until <budget>
# bytes are spent, and a cut ends in the group's total row count and <command>,
# which lists every row. <order> is `held` (rows the captain owes an answer on
# first, then priority, then newest), `urgent` (priority, then newest) or `store`
# (the store's own order, which for `ready` is dispatch priority already).
print_backlog_group() {
  local title=$1 listing=$2 budget=$3 command=$4 order=$5 body headbytes line
  printf '\n%s\n' "$title" | jg_digest_say
  body=$(printf '%s\n' "$listing" | strip_help_block)
  headbytes=$(printf '%s\n' "$body" | grep -v '^  ' | wc -c | tr -d '[:space:]')
  printf '%s\n' "$body" | grep -v '^  ' | jg_digest_say
  budget=$((budget > headbytes ? budget - headbytes : 0))
  # A row is cut at ROW_CAP characters, and no more rows are read than the budget could print.
  printf '%s\n' "$body" | grep '^  ' | if [ "$order" = store ]; then cat; else
    awk -v order="$order" '{
      n = split($0, f, ",")
      pr = f[n - 1]; cr = f[n]
      if (pr !~ /^[0-9]$/) pr = 9
      if (cr !~ /^[0-9][0-9-]*$/) cr = "0000-00-00"
      lead = (order == "held" && $0 ~ /,captain,/) ? 0 : 1
      printf "%d\t%d\t%s\t%s\n", lead, pr, cr, $0
    }' | sort -s -t "$(printf '\t')" -k1,1n -k2,2n -k3,3r | cut -f4-
  fi | while IFS= read -r line; do
    jg_cap_line_var "$line" 230
    printf '%s\n' "$JG_LINE_CAP_LINE"
  done | jg_digest_clip "$budget" rows "$command"
}

# The four reads of the compact listing share one store read: the first fills the snapshot file and the rest reuse it.
print_backlog_rows_compact() {
  local snap_dir rc=0
  snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/jg-backlog-snap.XXXXXX") || snap_dir=
  JG_BACKLOG_SNAPSHOT=${snap_dir:+$snap_dir/rows} print_backlog_rows_compact_reads || rc=$?
  [ -z "$snap_dir" ] || rm -rf -- "$snap_dir"
  return "$rc"
}

print_backlog_rows_compact_reads() {
  local in_flight held blocked ready err budget spent before weight_left=100 w group
  if ! in_flight=$(backlog_rows list --state in_flight --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$in_flight
  elif ! held=$(backlog_rows list --state held --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$held
  elif ! blocked=$(backlog_rows list --state queued --blocked --fields "$BACKLOG_FIELDS" 2>&1); then
    err=$blocked
  elif ! ready=$(backlog_rows ready 2>&1); then
    err=$ready
  else
    printf 'compact backlog listing (beads; done rows omitted; task bodies omitted; each group lists its most urgent, then newest rows within %s bytes and ends in its total and the command that lists them all)\n' \
      "$BACKLOG_CAP" | jg_digest_say
    budget=$(jg_digest_avail "$BACKLOG_CAP")
    # Each group takes its share of what is left, so a short group leaves its bytes to the next.
    for group in "35 in_flight" "30 held" "10 blocked" "25 ready"; do
      w=${group%% *}
      before=$(jg_digest_used)
      case "${group#* }" in
        in_flight) print_backlog_group "in flight:" "$in_flight" $((budget * w / weight_left)) 'bin/jg-backlog.sh list --state in_flight' urgent ;;
        held) print_backlog_group "held (captain- or time-gated; an in-flight item that is also held appears in both groups; captain-owed first):" "$held" $((budget * w / weight_left)) 'bin/jg-backlog.sh list --state held (the rows the captain owes an answer on: juggernaut-axi holds --kind captain)' held ;;
        blocked) print_backlog_group "blocked queued:" "$blocked" $((budget * w / weight_left)) 'bin/jg-backlog.sh list --state queued --blocked' urgent ;;
        ready) print_backlog_group "ready queued (dispatchable now):" "$ready" $((budget * w / weight_left)) 'bin/jg-backlog.sh ready' store ;;
      esac
      spent=$(($(jg_digest_used) - before))
      budget=$((budget > spent ? budget - spent : 0))
      weight_left=$((weight_left - w))
    done
    return 0
  fi
  printf 'beads compact listing failed:\n%s\n' "$err" | jg_digest_say
  return 0
}

print_backlog_compact() {
  subsection "backlog (Beads store)"
  print_backlog_rows_compact
  print_backlog_pointer
}

# lane_status_text <status-file>: the last STATUS_TAIL status lines on one line, each
# capped (bin/jg-line-cap-lib.sh): a worker writes its own status lines, so their length
# is unbounded (one observed line ran 865 characters). The lede carries the state word
# and the key; the full log path reaches the rest.
lane_status_text() {
  local status=$1 line text=
  while IFS= read -r line || [ -n "$line" ]; do
    jg_cap_line_var "$line" 160
    text="${text:+$text || }$JG_LINE_CAP_LINE"
  done < <(tail -n "$STATUS_TAIL" "$status")
  printf '%s\n' "$text"
}

# jg_session_start_endpoint_read <backend> <target> [expected-label]: ONE
# bounded, crash-isolated endpoint-liveness read. The read runs in its own
# bash under jg_run_timed's bound instead of in this digest process, because
# a per-task backend liveness read that dies mid-read would otherwise take
# every later stage with it. Isolation turns any death, hang, or nonzero
# surprise in one task's read into that task's own endpoint line - never a
# silently missing rest of digest. The inner bash re-sources jg-backend.sh
# per read; that cost is a few milliseconds per task and buys the isolation.
jg_session_start_endpoint_read() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 label=${3:-}
  # shellcheck disable=SC2016  # Positional parameters expand inside the child bash, not here.
  jg_run_timed "$ENDPOINT_TIMEOUT" bash -c '
    . "$1"
    jg_backend_target_exists "$2" "$3" "$4"
  ' _ "$SCRIPT_DIR/jg-backend.sh" "$backend" "$target" "$label"
}

hash_file_sha256() {
  local file=$1 digest
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file" 2>/dev/null | awk '
      length($1) == 64 && $1 !~ /[^[:xdigit:]]/ { print "sha256:" $1; found=1; exit }
      END { if (!found) exit 1 }
    ') && [ -n "$digest" ] && { printf '%s\n' "$digest"; return 0; }
  fi
  return 1
}

# The baseline describes instructions this true session started with, not the
# most recently emitted instructions. It is intentionally immutable for this
# lock owner: every later stale-context rebuild needs the current file again.
write_agents_baseline() {  # <lock-pid> <agents-hash>
  local lock_pid=$1 agents_hash=$2 tmp
  [ -n "$lock_pid" ] && [ -n "$agents_hash" ] || return 1
  tmp=$(mktemp "$STATE/.session-start-agents-baseline.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$lock_pid" "$agents_hash" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$AGENTS_BASELINE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

agents_baseline_drifted() {  # <rebuilding-session-pid>
  local lock_pid=$1 baseline_pid baseline_hash current_hash
  [ -f "$AGENTS_BASELINE_FILE" ] && [ ! -L "$AGENTS_BASELINE_FILE" ] || return 0
  baseline_pid=$(sed -n '1p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  baseline_hash=$(sed -n '2p' "$AGENTS_BASELINE_FILE" 2>/dev/null || true)
  current_hash=$(hash_file_sha256 "$JG_ROOT/AGENTS.md" 2>/dev/null || true)
  [ -n "$current_hash" ] || return 0
  [ "$baseline_pid" = "$lock_pid" ] && [ "$baseline_hash" = "$current_hash" ] && return 1
  return 0
}

# Only run-tier source pairs with both a stale native instruction cache and a
# working Juggernaut delivery path arrive here. Claude fresh-reads on reset, and
# Codex has no tracked interactive reset delivery path.
agents_refresh_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  case "$PRIMARY_HARNESS:$SESSION_SOURCE" in
    pi:compact|pi-signed:compact) ;;
    *) return 1 ;;
  esac
  agents_baseline_drifted "$lock_pid"
}

print_agents_refresh_if_required() {  # <rebuilding-session-pid>
  local lock_pid=$1
  agents_refresh_required "$lock_pid" || return 0
  section "CURRENT AGENTS.md - INSTRUCTION REFRESH"
  {
    if [ -f "$JG_ROOT/AGENTS.md" ]; then
      cat <<'EOF'
The complete on-disk AGENTS.md below supersedes the instruction copy this session
started with. Apply it as the current Juggernaut instruction contract.

EOF
      cat "$JG_ROOT/AGENTS.md"
    else
      printf 'The original AGENTS.md baseline no longer matches, but the current file is absent.\n'
    fi
  } | jg_digest_say
}

AGENTS_START_HASH=
if [ "$REEMIT" -eq 0 ] && [ "$SESSION_SOURCE" = startup ]; then
  AGENTS_START_HASH=$(hash_file_sha256 "$JG_ROOT/AGENTS.md" 2>/dev/null || true)
fi

if [ "$REEMIT" -eq 1 ]; then
  section "SESSION START (CONTEXT RE-EMIT) - $JG_HOME"
  printf 'This session already took the helm at its own startup and has only lost its\n'
  printf 'context. Lock ownership is re-verified and the durable records below are\n'
  printf 'reprinted, but the sweeps startup already reconciled - project clone refresh,\n'
  printf 'squad_lead convergence and liveness, pending remote handoff\n'
  printf 'retry, X-mode artifact writes, and stale Herdr child cleanup - are NOT repeated.\n'
  printf 'Queued wakes ARE still drained: they arrived after startup and are this turn work.\n'
else
  section "SESSION START - $JG_HOME"
fi
# --- 1. lock -----------------------------------------------------------
stage lock
subsection "LOCK"
LOCK_OUT=$("$SCRIPT_DIR/jg-lock.sh" 2>&1)
LOCK_RC=$?
printf '%s\n' "$LOCK_OUT" | jg_digest_say
READ_ONLY=0
if [ "$LOCK_RC" -ne 0 ]; then
  READ_ONLY=1
  BAR='●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s\n' "$BAR"
    printf '●  READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED\n'
    printf '●  %s\n' "$LOCK_OUT"
    printf '●  Skipping every mutating step: stale Herdr child cleanup,\n'
    printf '●  squad_lead convergence, squad_lead liveness, pending remote handoff retry,\n'
    printf '●  X-mode artifacts, fleet sync, and wake-queue drain. Detect-only bootstrap\n'
    printf '●  diagnostics and the rest of this read-only-safe digest still ran below.\n'
    printf '●  Operate read-only until this resolves - do not spawn, steer, merge, or\n'
    printf '●  otherwise mutate fleet state from this session.\n'
    printf '%s\n' "$BAR"
  } | jg_digest_say
fi
REBUILDING_SESSION_PID=$(jg_harness_ancestry_pid 2>/dev/null || true)
print_agents_refresh_if_required "$REBUILDING_SESSION_PID"

# The supervisor contract has a carrier of its own (bin/jg-contract-carrier.sh). Only a locked session
# may write it. When the carrier's proof is not `file`, or `ensure` wrote the file just now (this session
# did not load it), the digest holds the contract itself, at the start and in the re-emit after a
# compaction. The refresh above already printed it for a pi compaction, so it is not printed twice.
# The contract is printed outside the digest budget: it must not crowd out the state sections.
CARRIER="$SCRIPT_DIR/jg-contract-carrier.sh"
CARRIER_WROTE=0
if [ "$READ_ONLY" -eq 0 ]; then
  CARRIER_OUT=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" "$CARRIER" ensure "$PRIMARY_HARNESS" 2>&1)
  [ "$?" -ne 3 ] || CARRIER_WROTE=1
  [ -z "$CARRIER_OUT" ] || printf '%s\n' "$CARRIER_OUT" | jg_digest_say
fi
CARRIER_PROOF=$(JG_HOME="$JG_HOME" JG_ROOT_OVERRIDE="$JG_ROOT" "$CARRIER" check "$PRIMARY_HARNESS" 2>/dev/null || true)
if { [ "$CARRIER_PROOF" != file ] || [ "$CARRIER_WROTE" -eq 1 ]; } && ! agents_refresh_required "$REBUILDING_SESSION_PID"; then
  CONTRACT_REL=$(JG_ROOT_OVERRIDE="$JG_ROOT" "$CARRIER" contract 2>/dev/null || printf 'AGENTS.md')
  if [ "$CARRIER_WROTE" -eq 1 ]; then CARRIER_NOTE='carrier file written at this start'; else CARRIER_NOTE="carrier proof: ${CARRIER_PROOF:-none}"; fi
  section "SUPERVISOR CONTRACT - $CONTRACT_REL ($CARRIER_NOTE)"
  if [ -f "$JG_ROOT/$CONTRACT_REL" ]; then
    cat "$JG_ROOT/$CONTRACT_REL"
  else
    printf 'The supervisor contract file %s is absent.\n' "$CONTRACT_REL"
  fi
fi

# --- 1b. home role -------------------------------------------------------
# This home's juggernaut-repository role: user/operator unless an explicit
# local or receipt-proven inherited grant says otherwise (bin/jg-role-lib.sh).
# Purely local resolution - no network, no gh call.
stage role
subsection "HOME ROLE"
{
  JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/jg-role.sh" report 2>/dev/null \
    || printf 'jg-role: unknown (bin/jg-role.sh report failed)\n'
} | jg_digest_say

if [ "$READ_ONLY" -eq 0 ]; then
  if [ "$REEMIT" -eq 0 ]; then
    rm -f "$COMPLETION_FILE" 2>/dev/null || true
  fi
  jg_trace_context_session_start "$CONFIG" "$STATE/.trace-context-effective"
  # A full locked start publishes this home's current structured summary.
  # Publication is side-band and best-effort, so it can never change the
  # session-start result. A context re-emit is not another session start.
  if [ "$REEMIT" -eq 0 ]; then
    "$SCRIPT_DIR/jg-home-summary-refresh.sh" --best-effort || true
  fi
  # The machine's four long-running services belong to Main, and bin/jg-unit-claim.sh
  # owns why: one that serves another home sends every stuck-worker, blocked-pane
  # and stopped-service alert there instead of here, and nothing else notices. The
  # claim runs on the home's own copy before the digest reads that state, and says
  # nothing when they already serve here. It reads JG_HOME's own units, so a state
  # override (a test) never reaches it.
  if [ "$REEMIT" -eq 0 ] && [ "$STATE" = "$JG_HOME/state" ]; then
    "$SCRIPT_DIR/jg-unit-claim.sh" claim || true
  fi
  # Every network call and the potentially slow inactive-outcome startup scan
  # are launched HERE, detached and bounded, so they run concurrently with the
  # whole digest below instead of in front of it. Step 7 harvests whatever has
  # finished, without ever waiting.
  # --reemit passes --locked 0 for the same reason it runs bootstrap detect-only:
  # this process already ran the mutating sweeps at its own startup, so only the
  # read-only GitHub-auth probe is owed. A read-only session starts nothing at
  # all: it holds no mutation authority for the sweeps, and it must not spawn,
  # steer, or merge anyway, so it has no action left for an auth verdict to gate.
  NETWORK_STAGE_LOCKED=1
  [ "$REEMIT" -eq 0 ] || NETWORK_STAGE_LOCKED=0
  "$SCRIPT_DIR/jg-startup-network.sh" start \
    --locked "$NETWORK_STAGE_LOCKED" --harvest-pid $$ >/dev/null 2>&1 || true
  # A full locked start resumes this home's own lanes that an agent-runtime
  # restart left idle or dead (bin/jg-sentinel.sh owns the rules). Detached in
  # its own process group for the same reasons as the network stage above. It
  # reads JG_HOME's own state/, so a state override (a test) never reaches it.
  if [ "$REEMIT" -eq 0 ] && [ "$STATE" = "$JG_HOME/state" ]; then
    (set -m; JG_HOME="$JG_HOME" nohup "$SCRIPT_DIR/jg-sentinel.sh" reconcile >/dev/null 2>&1 </dev/null &) || true
  fi
fi

# --- 2. bootstrap --------------------------------------------------------
# JG_BOOTSTRAP_NETWORK=skip on every path: bootstrap's own network half is what
# the deferred stage above is running right now, and running it twice would both
# re-block this digest and race the worker's sweeps against themselves.
stage bootstrap
subsection "BOOTSTRAP"
if [ "$READ_ONLY" -eq 1 ]; then
  BOOT_OUT=$(JG_BOOTSTRAP_DETECT_ONLY=1 JG_BOOTSTRAP_NETWORK=skip \
    "$SCRIPT_DIR/jg-bootstrap.sh" 2>&1)
elif [ "$REEMIT" -eq 1 ]; then
  BOOT_OUT=$(JG_BOOTSTRAP_DETECT_ONLY=1 JG_BOOTSTRAP_LOCKED=1 JG_BOOTSTRAP_NETWORK=skip \
    "$SCRIPT_DIR/jg-bootstrap.sh" 2>&1)
else
  BOOT_OUT=$(
    "$SCRIPT_DIR/jg-herdr-session-cleanup.sh" 2>&1 || true
    JG_BOOTSTRAP_NETWORK=skip \
      "$SCRIPT_DIR/jg-bootstrap.sh" 2>&1
  )
fi
if [ "$READ_ONLY" -eq 1 ] || [ "$REEMIT" -eq 1 ]; then
  required_out=$(bash "$SCRIPT_DIR/jg-required-checks.sh" "$JG_HOME" --detect-only 2>&1)
else
  required_out=$(bash "$SCRIPT_DIR/jg-required-checks.sh" "$JG_HOME" 2>&1)
fi
[ -z "$required_out" ] || BOOT_OUT="${BOOT_OUT}${BOOT_OUT:+$'\n'}$required_out"
if [ -n "$BOOT_OUT" ]; then
  printf '%s\n' "$BOOT_OUT" | jg_digest_say
else
  printf '(silent - all good)\n' | jg_digest_say
fi

# --- 3. wake-drain ---------------------------------------------------------
# The inactive-outcome startup scan runs in the deferred worker launched above,
# where its potentially slow current-state reads cannot block this digest. It
# publishes findings through the same durable queue drained here; the watcher's
# separate 900-second cadence remains unchanged.
# Presented records are this turn's first work queue and remain durable until
# post-handling acknowledgement. The drain's separate OPEN DECISIONS section
# remains actionable even when that queue is empty (AGENTS.md sections 3 and 8).
# The drain also runs jg-guard.sh internally on the locked path, so the
# tangle/watcher-liveness alarms land right here too, ahead of the bulk digest
# below. The read-only path never touches the queue because it lacks mutation
# authority, and another session may be actively handling it. It still runs
# jg-guard.sh directly with non-mutating advisory text, so the same alarms
# surface without repair commands.
stage wake-queue
subsection "WAKE QUEUE"
if [ "$READ_ONLY" -eq 1 ]; then
  QLEN=0
  [ -s "$STATE/.wake-queue" ] && QLEN=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || printf '0')
  printf 'skipped (read-only session) - %s record(s) remain queued because this session lacks verified fleet-lock ownership.\n' "$QLEN" | jg_digest_say
  GUARD_OUT=$(JG_GUARD_READ_ONLY=1 "$SCRIPT_DIR/jg-guard.sh" 2>&1)
  [ -z "$GUARD_OUT" ] || printf '%s\n' "$GUARD_OUT" | jg_digest_say
else
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-branch-outcome.sh" seed-tail >/dev/null 2>&1 || true
  # Pi supervision-branch recovery, locked path only: clear leases whose
  # supervising session died, and surface outcomes the branch stored durably
  # that never reached main (docs/pi-supervision-branch.md). Gated to the
  # pi/pi-signed primary so a non-Pi home runs neither step - homes on any
  # other harness stay entirely untouched (captain-decided criterion).
  if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
    JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-lease.sh" sweep 2>/dev/null || true
    BRANCH_REPLAY_OUT=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/jg-branch-outcome.sh" startup-replay 2>&1) || BRANCH_REPLAY_OUT=
    if [ -n "$BRANCH_REPLAY_OUT" ]; then
      printf '%s\n' "$BRANCH_REPLAY_OUT" | jg_digest_say
    fi
  fi
  DRAIN_OUT=$("$SCRIPT_DIR/jg-wake-drain.sh" 2>&1)
  if [ -n "$DRAIN_OUT" ]; then
    printf '%s\n' "$DRAIN_OUT" | jg_digest_say
  else
    printf '(no queued wakes)\n' | jg_digest_say
  fi
fi

# --- 4. supervision operating instructions ----------------------------------
stage supervision-instructions
AFK_PRESENT=0
[ -e "$STATE/.afk" ] && AFK_PRESENT=1
AFK_MODE=$(jg_afk_mode "$STATE")
X_MODE_PRESENT=0
[ -f "$CONFIG/x-mode.env" ] && X_MODE_PRESENT=1

if [ "$PRIMARY_HARNESS" = pi ] || [ "$PRIMARY_HARNESS" = pi-signed ]; then
  PI_EXT="$JG_ROOT/.pi/extensions/jg-primary-pi-watch.ts"
  PI_TURNEND_EXT="$JG_ROOT/.pi/extensions/jg-primary-turnend-guard.ts"
  PI_WATCH_MARKER="$STATE/.pi-watch-extension-loaded"
  PI_TURNEND_MARKER="$STATE/.pi-turnend-extension-loaded"
  PI_LOCK="$STATE/.lock"
  PI_RESTART_COMMAND=$PRIMARY_HARNESS
  [ "$PRIMARY_HARNESS" != pi ] || PI_RESTART_COMMAND='plain pi'
  PI_WATCH_VERSION=$(jg_pi_extension_version "$PI_EXT" || printf '')
  PI_TURNEND_VERSION=$(jg_pi_extension_version "$PI_TURNEND_EXT" || printf '')
  if ! jg_pi_extension_loaded "$PI_WATCH_MARKER" "$PI_WATCH_VERSION" "$PI_LOCK" active \
    || ! jg_pi_extension_loaded "$PI_TURNEND_MARKER" "$PI_TURNEND_VERSION" "$PI_LOCK"; then
    printf 'PI_WATCH_EXTENSION: not loaded - approve Pi project trust once per clone, then restart %s so %s and %s auto-load for turn-end guard and background wake coverage; use -e %s -e %s only if project hooks are not trusted\n' "$PI_RESTART_COMMAND" "$PI_TURNEND_EXT" "$PI_EXT" "$PI_TURNEND_EXT" "$PI_EXT" | jg_digest_say
  fi
fi
# omp (Oh My Pi) has no project-trust gate: it auto-discovers <cwd>/.omp/extensions
# with no dialog, so the only ways both tracked primary extensions fail to load
# are a session started outside this home, an extension disabled in the omp
# config, or a build older than the tracked file. The markers carry the loaded
# build plus the loading pid, exactly as the Pi ones do (bin/jg-wake-lib.sh).
if [ "$PRIMARY_HARNESS" = omp ]; then
  OMP_EXT="$JG_ROOT/.omp/extensions/jg-primary-omp-watch.ts"
  OMP_TURNEND_EXT="$JG_ROOT/.omp/extensions/jg-primary-turnend-guard.ts"
  OMP_WATCH_MARKER="$STATE/.omp-watch-extension-loaded"
  OMP_TURNEND_MARKER="$STATE/.omp-turnend-extension-loaded"
  OMP_LOCK="$STATE/.lock"
  OMP_WATCH_VERSION=$(jg_pi_extension_version "$OMP_EXT" || printf '')
  OMP_TURNEND_VERSION=$(jg_pi_extension_version "$OMP_TURNEND_EXT" || printf '')
  if ! jg_pi_extension_loaded "$OMP_WATCH_MARKER" "$OMP_WATCH_VERSION" "$OMP_LOCK" \
    || ! jg_pi_extension_loaded "$OMP_TURNEND_MARKER" "$OMP_TURNEND_VERSION" "$OMP_LOCK"; then
    printf 'OMP_WATCH_EXTENSION: not loaded - restart omp with this home as its working directory so %s and %s auto-load from .omp/extensions/ for turn-end guard and background wake coverage; pass -e %s -e %s only when omp must start from another directory, never together with auto-discovery (omp loads a file named both ways twice)\n' "$OMP_TURNEND_EXT" "$OMP_EXT" "$OMP_TURNEND_EXT" "$OMP_EXT" | jg_digest_say
  fi
fi
"$SCRIPT_DIR/jg-supervision-instructions.sh" \
  --harness "$PRIMARY_HARNESS" \
  --read-only "$READ_ONLY" \
  --afk "$AFK_PRESENT" \
  --afk-mode "$AFK_MODE" \
  --x-mode "$X_MODE_PRESENT" | jg_digest_say

# --- 5. read-once contract -------------------------------------------------
# Ahead of the two digests it governs, not after them: a truncated tail is
# exactly what drops a closing reminder, and this contract is what stops the
# next turn from re-reading everything the digest just printed. Because it now
# arrives BEFORE its subject, it also names the one condition that voids it -
# a stage that never ran, which the truncation banner names by stage.
stage read-once
section "READ-ONCE CONTRACT"
cat <<EOF | jg_digest_say
This digest holds at most $DIGEST_CAP bytes, so a fresh session starts with most of its
context free. The lock, the wake queue, the supervision block and the network checks are
never cut. Every other section is cut to a byte cap of its own, with the newest and most
urgent items first, and each cut ends in a "[cut: ..." line (or an "(N more ..." line) that
gives the section's total count and the one command that prints all of it. A cut moves
information behind a pointer; nothing is deleted.
Below: one row per work lane (state/<id>.meta and state/<id>.status hold its full record),
a compact data/backlog.md listing, data/projects.md, data/squad_leads.md, data/captain.md,
data/captain-shared.md, data/learnings.md, and data/owner-rules.md.
Do NOT re-read any of them after reading this digest, and do NOT bulk-read
data/backlog.md or state/*.status: re-reading everything defeats the entire
point of this command.

Go to a source directly only when:
  - this digest flagged it ABSENT (then rebuild or create it per AGENTS.md),
  - its contents looked unparseable or corrupt,
  - a section ended in a "[cut: ..." or "(N more ..." line and this turn needs the rest (the line names
    the command or line range that prints it),
  - an individual full status log is needed for older wake-event history, or a
    status line was capped and its tail matters (the lane listing names the log),
  - a full task body is needed (bin/jg-backlog.sh show <id> --full),
  - the NETWORK CHECKS section reported its checks still IN PROGRESS and this
    turn needs their verdict (bin/jg-startup-network.sh report),
  - or a STARTUP TRUNCATED banner named the stage that would have printed it, in
    which case that stage's sources were never emitted and must be reconciled.
EOF

# --- 6. fleet-state digest ---------------------------------------------
# Before CONTEXT: see this file's ORDERING note. Live fleet identity is what a
# truncated tail must never take.
stage fleet-state
section "FLEET STATE"
print_backlog_compact

subsection "Work under way (state/*.meta)"
# One row per lane, most urgent first, within LANES_CAP bytes: a lane whose endpoint is dead or
# unreadable, then one whose last status line is waiting on a decision or blocked or failed, then
# the rest, newest status first; finished lanes (the fleet snapshot already calls them finished)
# come last, one `juggernaut-axi lanes` row each. The full record of a lane stays in its
# state/<id>.meta and state/<id>.status, and bin/jg-crew-state.sh owns its current state.
LANE_ROWS=$(mktemp "${TMPDIR:-/tmp}/jg-lane-rows.XXXXXX" 2>/dev/null) || LANE_ROWS=
FOLDED_LANES=" "
lanes_out=$(jg_run_timed "$LANES_TIMEOUT" "$SCRIPT_DIR/juggernaut-axi" lanes --limit 100 2>/dev/null) || lanes_out=
folded_rows=$(printf '%s\n' "$lanes_out" | awk -F, '
  /^[^ ]/ { inrows = 0 }
  /^lanes\[[0-9]+\]\{/ { inrows = 1; next }
  inrows && /^  [^ ]/ && ($3 == "done" || ($3 == "unknown" && ($4 == "done" || $4 == "resolved"))) { print }')
if [ -n "$folded_rows" ]; then
  while IFS= read -r row; do
    row=${row#  }
    FOLDED_LANES="$FOLDED_LANES${row%%,*} "
    printf '9\t0\tfinished: %s\n' "$row" >> "${LANE_ROWS:-/dev/null}"
  done <<< "$folded_rows"
fi
META_FOUND=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  META_FOUND=1
  case "$FOLDED_LANES" in *" $id "*) continue ;; esac
  window=$(jg_meta_get "$meta" window)
  target=$(jg_backend_target_of_meta "$meta")
  rank=2
  if [ -n "$window" ]; then
    backend=$(jg_backend_of_meta "$meta")
    endpoint_rc=0
    jg_session_start_endpoint_read "$backend" "${target:-$window}" "jg-$id" || endpoint_rc=$?
    # Only the timeout owner's own statuses mean the read itself failed: 124 is
    # the bound firing and >=128 is a signal death. Every other nonzero status
    # is the probe's own verdict that the endpoint is gone.
    if [ "$endpoint_rc" -eq 0 ]; then
      endpoint="alive (backend=$backend window=$window)"
    elif [ "$endpoint_rc" -eq 124 ] || [ "$endpoint_rc" -ge 128 ]; then
      endpoint="error (backend=$backend window=$window - the endpoint read died or hit its ${ENDPOINT_TIMEOUT}s bound; the digest continued past it)"
      rank=0
    else
      endpoint="dead (backend=$backend window=$window)"
      rank=0
    fi
  else
    endpoint='unknown (no window recorded)'
  fi
  status="$STATE/$id.status"
  stamp=0
  if [ -f "$status" ]; then
    text=$(lane_status_text "$status")
    stamp=$(jg_path_mtime "$status" || printf 0)
    case "${text%% *}" in needs-decision|blocked|failed) [ "$rank" -gt 1 ] && rank=1 ;; esac
  else
    text='(no status file yet)'
  fi
  printf '%s\t%s\t%s %s | endpoint: %s | %s\n' "$rank" "$stamp" "$id" "$(jg_meta_get "$meta" kind)" "$endpoint" "$text" >> "${LANE_ROWS:-/dev/null}"
done
if [ "$META_FOUND" -eq 0 ]; then
  printf '(none)\n' | jg_digest_say
else
  budget=$(jg_digest_avail "$LANES_CAP")
  printf 'one row per lane, most urgent first (dead endpoint, then waiting on a decision or blocked, then newest status), each with its last status line capped at 160 characters; a lane'"'"'s full record: state/<id>.meta and state/<id>.status; its current state: bin/jg-crew-state.sh <id>\n' | jg_digest_say
  sort -s -t "$(printf '\t')" -k1,1n -k2,2nr "$LANE_ROWS" | cut -f3- \
    | jg_digest_clip $((budget > 260 ? budget - 260 : 0)) lanes 'juggernaut-axi lanes'
fi
[ -z "$LANE_ROWS" ] || rm -f -- "$LANE_ROWS"

subsection "Orphan status logs (state/*.status without matching .meta)"
ORPHAN_ROWS=$(mktemp "${TMPDIR:-/tmp}/jg-orphan-rows.XXXXXX" 2>/dev/null) || ORPHAN_ROWS=
for status in "$STATE"/*.status; do
  [ -f "$status" ] || continue
  id=$(basename "$status" .status)
  [ -f "$STATE/$id.meta" ] && continue
  printf '%s\t%s\n' "$(jg_path_mtime "$status" || printf 0)" "$id | $(lane_status_text "$status")" >> "${ORPHAN_ROWS:-/dev/null}"
done
if [ -s "${ORPHAN_ROWS:-/dev/null}" ]; then
  sort -s -t "$(printf '\t')" -k1,1nr "$ORPHAN_ROWS" | cut -f2- \
    | jg_digest_clip "$(jg_digest_avail "$ORPHAN_CAP")" 'orphan logs' "ls -t $STATE/*.status"
else
  printf '(none)\n' | jg_digest_say
fi
[ -z "$ORPHAN_ROWS" ] || rm -f -- "$ORPHAN_ROWS"

subsection "Home drift (the code copies that run here)"
# bin/jg-fleet-autosync.sh owns the count and the guard; this line only reports it.
{ "$SCRIPT_DIR/jg-fleet-autosync.sh" digest 2>/dev/null || printf 'unavailable\n'; } | jg_digest_say

subsection "AFK"
# The away posture is the record (bin/jg-afk-contract.sh); the legacy flag
# still marks a running daemon on the harnesses that launch one.
# A quiet record (bin/jg-afk-contract.sh mode) is a present captain: it holds
# nothing for a return.
{
  if [ -f "$STATE/.afk-contract" ]; then
    if [ "$("$SCRIPT_DIR/jg-afk-contract.sh" mode 2>/dev/null)" = quiet ]; then
      printf 'present - quiet mode recorded at %s (the captain is present and nothing is held for a return: requested actions proceed under ordinary attended authority; only an explicit /radio-silence off exits it)' \
        "$("$SCRIPT_DIR/jg-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
    else
      printf 'present - away posture recorded at %s (hold-for-return only; bin/jg-afk-contract.sh readback for the mandate)' \
        "$("$SCRIPT_DIR/jg-afk-contract.sh" field entered 2>/dev/null || printf unknown)"
    fi
    if [ -e "$STATE/.afk" ]; then
      if [ "$AFK_MODE" = quiet ]; then
        printf '; the quiet daemon owns the watcher.\n'
      else
        printf '; the away daemon owns the watcher.\n'
      fi
    else
      printf '; no daemon runs, the ordinary supervision session continues.\n'
    fi
  elif [ -e "$STATE/.afk" ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf 'present - quiet-mode supervision is active; the daemon owns the watcher, only an explicit /radio-silence off exits it (legacy flag with no posture record).\n'
    else
      printf 'present - away-mode supervision is active; the daemon owns the watcher (legacy flag with no posture record).\n'
    fi
  else
    printf 'absent\n'
  fi
} | jg_digest_say

# Public commitments made through the myjuggernaut relay. A promise to reply in a
# public thread must survive compaction and restart, so it is surfaced from disk
# here rather than from conversation memory. jg-public-followup-lib.sh owns both
# gates: a home that never opted into the relay runs one [ -f ] test, prints no
# subsection, and never reaches jg-public-followup.sh.
if jg_pf_relay_active "$JG_HOME" \
  && { jg_pf_has_registrations "$STATE" || jg_pf_has_events "$STATE"; }; then
  PUBLIC_FOLLOWUP=$("$SCRIPT_DIR/jg-public-followup.sh" pending 2>/dev/null) || PUBLIC_FOLLOWUP=
  if [ -n "$PUBLIC_FOLLOWUP" ]; then
    subsection "Public commitments"
    printf '%s\n' "$PUBLIC_FOLLOWUP" | jg_digest_clip "$(jg_digest_avail "$COMMITMENTS_CAP")" 'public loops' "$JG_ROOT/bin/jg-public-followup.sh pending"
    {
      printf '\nEach line is a public loop this home still holds: a reply still owed, or an open loop with nothing owed.\n'
      printf 'Reconcile terminal results with %s/bin/jg-public-followup.sh consume, then deliver a ready one with\n' "$JG_ROOT"
      printf '%s/bin/jg-public-followup.sh deliver <id>. Hand a delivered loop on with rechain, or close it with\n' "$JG_ROOT"
      printf '%s/bin/jg-public-followup.sh retire <id> --reason "...". Load relay-respond for the procedure.\n' "$JG_ROOT"
    } | jg_digest_say
  fi
fi

# --- 7. network checks ------------------------------------------------------
# Deliberately here and not later: these lines are actionable (a stuck clone, a
# squad_lead that could not be relaunched, broken GitHub auth), and the section
# after this one is the curated memory a truncated tail is meant to take first.
# Deliberately here and not earlier: this is the last point in the digest, so the
# worker started at step 1 has had the whole composition above to finish in. It
# is a NON-BLOCKING read either way - whatever the worker has published by now is
# printed, and whatever it has not is named as not yet confirmed.
stage network-checks
section "NETWORK CHECKS"
if [ "$READ_ONLY" -eq 1 ]; then
  {
    printf 'skipped (read-only session) - GitHub authentication, project clone refresh,\n'
    printf 'squad_lead liveness and convergence, and pending handoff delivery were not run.\n'
    printf 'They need the fleet lock, and this session must not spawn, steer, or merge, so it\n'
    printf 'has no action they would gate. The session holding the lock runs them.\n'
  } | jg_digest_say
else
  { "$SCRIPT_DIR/jg-startup-network.sh" harvest --pid $$ 2>&1 || true; } | jg_digest_say
fi

# --- 8. context digest -----------------------------------------------------
# Last of the bulk sections deliberately: curated memory is stable session to
# session, already governed by config/startup-memory-budget, and recoverable
# with one targeted read, so it is the cheapest thing for a truncated tail to
# take (see this file's ORDERING note).
stage context
section "CONTEXT"
print_file_capped "$DATA/projects.md" "data/projects.md"
print_file_capped "$(jg_compat_pick "$DATA/squad_leads.md")" "data/squad_leads.md"
print_file_capped "$DATA/captain.md" "data/captain.md"
print_file_capped "$DATA/captain-shared.md" "data/captain-shared.md (shared, main-authoritative, read-only in squad_lead homes)" "$MEMORY_FILE_CAP"
print_learnings "$DATA/learnings.md" "data/learnings.md"
print_owner_rules "$DATA/owner-rules.md" "data/owner-rules.md (the shared owner rules every session reads; bin/jg-owner-rules.sh writes it)"
bypass_digest=$(JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="$CONFIG" JG_STATE_OVERRIDE="$STATE" bash "$SCRIPT_DIR/jg-proof-bypass.sh" digest 2>/dev/null) || bypass_digest=''
if [ -n "$bypass_digest" ]; then subsection "proof bypass (config/proof-bypass; bin/jg-proof-bypass.sh)"; printf '%s\n' "$bypass_digest" | jg_digest_say; fi
# The role's personality file adds tone only; the voice rules stay in captain-voice.md (bin/jg-voice.py).
if voice_persona=$(JG_HOME="$JG_HOME" JG_CONFIG_OVERRIDE="$CONFIG" python3 "$SCRIPT_DIR/jg-voice.py" persona 2>/dev/null) && [ -n "$voice_persona" ]; then
  subsection "captain voice personality (config/captain-voice-<role>.md; tone only, the rules are in captain-voice.md)"
  printf '%s\n' "$voice_persona" | jg_digest_clip "$(jg_digest_avail 600)" lines 'bin/jg-voice.py persona'
fi

# --- 9. closing reminder -----------------------------------------------
stage next-step
section "NEXT STEP"
{
if [ "$READ_ONLY" -eq 1 ]; then
  cat <<'EOF'
This session did not acquire the fleet lock. Stay read-only: do not arm,
drain, spawn, steer, merge, or repair fleet state from here. Only a session
with verified fleet-lock ownership may perform mutable follow-up.

EOF
elif [ "$AFK_PRESENT" -eq 1 ] && [ "$AFK_MODE" = quiet ]; then
  cat <<'EOF'
Quiet mode is active. Follow the supervision operating instructions block
above: load /radio-silence and ensure the daemon is running, because the daemon owns
watcher supervision. Ordinary captain chat does not exit it; only an
explicit /radio-silence off does.

EOF
elif [ "$AFK_PRESENT" -eq 1 ]; then
  cat <<'EOF'
Away mode is active. Follow the supervision operating instructions block above:
load /watchover and ensure the daemon is running, because the daemon owns watcher
supervision.

EOF
elif [ -f "$CONFIG/x-mode.env" ]; then
  cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
X mode is active, so the emitted block's cadence instruction applies.
This script never starts supervision itself.

EOF
else
cat <<EOF
Follow the supervision operating instructions block above for harness '$PRIMARY_HARNESS'.
This script never starts supervision itself.

EOF
fi
cat <<'EOF'
The digest above is complete for this session start. The READ-ONCE CONTRACT
section near the top of it governs what may still be read from disk.
EOF
} | jg_digest_say
printf 'DIGEST SIZE: %s of %s bytes (the digest cap; defaults/token-caps digest-cap)\n' "$(jg_digest_used)" "$DIGEST_CAP"

if [ "$READ_ONLY" -eq 0 ] && [ "$REEMIT" -eq 0 ]; then
  COMPLETION_RECORDED=0
  COMPLETION_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$COMPLETION_PID" in
    ''|*[!0-9]*) COMPLETION_PID= ;;
  esac
  COMPLETION_TMP=$(mktemp "$STATE/.session-start-complete.XXXXXX" 2>/dev/null || true)
  if [ -n "$COMPLETION_PID" ] && [ -n "$COMPLETION_TMP" ] \
    && printf '%s\n' "$COMPLETION_PID" > "$COMPLETION_TMP" 2>/dev/null \
    && mv -f "$COMPLETION_TMP" "$COMPLETION_FILE" 2>/dev/null; then
    COMPLETION_RECORDED=1
  else
    [ -z "$COMPLETION_TMP" ] || rm -f "$COMPLETION_TMP" 2>/dev/null || true
    printf '\nSESSION_START_COMPLETION: not recorded - the next clear or compact will run a full startup.\n'
  fi
  if [ "$SESSION_SOURCE" = startup ] && [ "$COMPLETION_RECORDED" -eq 1 ] && [ -n "$AGENTS_START_HASH" ]; then
    if ! write_agents_baseline "$COMPLETION_PID" "$AGENTS_START_HASH"; then
      printf '\nSESSION_START_AGENTS_BASELINE: not recorded - a later supported rebuild will re-emit AGENTS.md.\n'
    fi
  fi
fi

exit 0
