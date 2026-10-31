#!/usr/bin/env bash
# Juggernaut watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-on-positive-evidence: a wake
# is absorbed only when the crew shows it is still working through an actively
# running no-mistakes step or a backend busy signal. A home that opts in with
# config/turnend-churn-absorb lets a bare turn-end also use bounded pane churn
# since the previous poll. Every other no-verb wake surfaces, so a crew
# that finishes (or stops and waits) is never silently swallowed. A declared wait,
# either a paused: external wait or a verified captain-held transfer, is the
# separate idle absorb case and re-surfaces only on its long bounded cadence,
# although its initial no-verb status signal still surfaces in normal mode.
# That cadence is hours long and condition-aware: a paused: line naming
# `until <UTC ISO 8601>` is rechecked when that time passes, but a declared time
# beyond JG_PAUSE_RESURFACE_SECS cannot extend the ordinary recheck cadence, and
# while an away record (state/.afk-contract, never quiet mode's) exists an
# item held for the captain is never rechecked at all, in either posture.
# jg-watch-progress-lib.sh owns the independent activity proof.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          span has a captain-relevant event OR a no-verb signal lacks
#                          positive execution evidence, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          juggernaut hands it to a no-mistakes validation. A declared
#                          external-wait pause or verified captain-held transfer is
#                          absorbed instead with its own long re-surface cadence,
#                          never as a wedge, and that recheck reason names which
#                          human the wait is on. An idle `paused:` lane whose
#                          authoritative run is parked at a gate nobody was told
#                          about wakes once per run state, naming that state
#                          (declared_wait_contradiction). Only when neither absorb class
#                          applies does the log's latest recognized status event decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A busy verdict without progress
#                          past the wedge threshold surfaces, with an "escalation N"
#                          count in the reason; at JG_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Active validation steps are rechecked at the
#                          threshold rather than called stale for a frozen terminal.
#                          A pane about to escalate
#                          that can account for its quiet - a `paused:` external
#                          wait or a verified `captain-held` transfer its worker
#                          declared, or, where config/wedge-defer-parked-gate
#                          arms it, a validation gate of its own awaiting a
#                          supervisor decision nobody has answered yet - is
#                          deferred to that same long recheck cadence instead
#                          (wedge_wait_evidence), and a pane whose own task
#                          worktree was written during the quiet window is
#                          deferred rather than escalated (wedge_defer_writing),
#                          because files appearing there are liveness the pane and
#                          the run step cannot show; that deferral still
#                          re-surfaces once per PAUSE_RESURFACE_SECS, and a pane
#                          that writes nothing keeps the unchanged schedule.
#                          A pane whose recorded endpoint holds no agent at all is
#                          not a wedge and is reported ONCE instead of escalating
#                          on that cadence forever (wedge_dead_record); only the
#                          two recovery-grade verdicts license it, and every other
#                          verdict escalates unchanged.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS without observed progress
#                          (busy_turn_over_age owns the activity sources).
#                          Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence; under daemon-backed afk an
#                          external wait is instead handed to the daemon as this
#                          plain reason once per declaration, while captain-held
#                          work stays silent until return
#                          (busy_turn_bound_check owns that split);
#                          every other pane goes through the same wedge timer,
#                          the dead-record probe above included, and surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker for a live
#                          agent, for human inspection only - never an automatic
#                          interrupt, signal, or restart of the worker or its
#                          tool process.
#   stale: <window> (unread juggernaut instruction: ...)
#                          the steering-inbox ladder spent its delivery-attempt
#                          budget on an idle pane without an acknowledgement, or
#                          the pane read busy through the busy-deferral bound. The
#                          busy form is a report only: the message stays owed and
#                          its doorbell rings on the first non-busy poll, so it
#                          needs no interrupt
#   stale: <window> (permission prompt: <prompt>; path <path>; not answered: <why>)
#                          a worker or squad_lead pane shows a permission or trust
#                          prompt that bin/jg-prompt-gate-lib.sh did not approve
#                          or reject; reported once per prompt, at first sight,
#                          then escalated by the wait-timers chain (prompt_gate_check)
#   stale: <window> (pane vanished, state pruned: no task record owns it and
#   the backend confirms it is gone)
#                          a vanished pane's orphaned per-pane markers were
#                          pruned after one authoritative absence verdict; the
#                          key is recorded in state/.pruned-panes (bounded to
#                          the last 1024 keys) before this notice, so a re-created
#                          sidecar is pruned silently: one notice, never a new
#                          escalation series
#   stale: <window> (steering-inbox ladder bookkeeping unwritable: ...)
#   stale: <window> (steering-inbox busy bookkeeping unwritable: ...)
#                          steering-inbox recovery; bin/jg-task-inbox-lib.sh owns
#                          delivery-attempt, busy-deferral, and unavailable-endpoint policy
#   check: <script>: <out> authenticated check output, always actionable
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: process-event source stranded: <keys>
#                          a registered process-to-event source has a claim
#                          reconcile will not displace and nothing collecting
#                          for it (bin/jg-procevent.sh reconcile queues it
#                          once per stranded claim generation); the queued
#                          payload names what clears it
#   check: process-event source failed to start: <keys>
#                          a registered process-to-event source was launched by
#                          reconcile and did not prove it took the claim within
#                          the confirm window, so nothing is confirmed to be
#                          collecting for it and every cycle will relaunch it
#                          (bin/jg-procevent.sh reconcile queues it once per
#                          failure episode, and a later cycle that finds the
#                          source owned closes that episode); the queued
#                          payload names what to check. These three kinds are
#                          joined with `;` when more than one surfaces in a cycle
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
#   check: ready work waiting with free lane slots: (<open>/<target> open): <ids> - dispatch them now, P0 first, up to project capacity
#   check: ready work waiting with no worker working: <ids> - dispatch them now, P0 first, up to project capacity
#                          a primary or squad_lead home's base-cadence scan found dispatchable
#                          queued work (jg-tasks-axi.sh ready) while the home sits
#                          below its lane floor: with config/lane-target naming a
#                          positive integer, fewer open lanes than that target;
#                          otherwise (no usable target, or at least that many
#                          open lanes), none of its workers is provably working.
#                          Re-raised while the condition holds, once per
#                          new ready set and then every READY_WORK_RESURFACE_SECS;
#                          intake uses HEARTBEAT's base interval, never its backoff
#   check: ready backlog stalled: <ids> waits with free lanes|no worker working (<open>/<target> open) and nothing started for <n>s - dispatch them now, P0 first, up to project capacity, or hold each with why it waits; Main was told id=<key>
#                          the wait-timers chain's stalled-backlog backstop: a
#                          squad_lead home's ready, startable work sat on a free
#                          lane (or with no worker provably working) with no lane
#                          started for JG_READY_STALL_SECS, so the lead is woken
#                          again and Main gets the same report, both re-fired
#                          every JG_PROMPT_REALERT_SECS while it holds, and Main
#                          posts a board card if it is still open
#                          (ready_backlog_stall_state owns the condition;
#                          addons/wait-timers/README.md owns the rungs)
#   check: ask-default safe default applied while the captain was unreachable: <ids> ...
#                          the juggernaut-addons ask-default add-on, when installed,
#                          applied the recorded safe default of each named ask
#                          (ask_default_tick owns the hook; the add-on owns the
#                          decision and its applied.log record)
# Local queue reminder semantics, including decision-signal normalization:
# docs/watcher-continuity.md, "Durable queue and turn-end backstop".
#   check: inactive-outcome bounded poll-loop reconciliation found a suspicious
#                          inactive terminal outcome that still lacks its durable
#                          upstream receipt
#   check: squad_lead wake-loop stalled: mate=<id> row=<seq> idle=<seconds>s
#                          an actionable row in an endpoint-recorded local
#                          squad_lead home's durable wake queue did not advance
#                          between observations for JG_SQUAD_LEAD_WAKE_STALL_SECS
#                          while the mate was not in an active turn (a busy mate
#                          is exempt only until the queue has been frozen for
#                          BUSY_TURN_MAX_SECS); declared external-wait pause
#                          rows do not feed this escalation; a mate whose
#                          semantic busy class is exactly idle, whose agent is
#                          alive, and whose composer is not pending is rung
#                          once so its own home can drain, and the parent
#                          notification is withheld until that same row stays
#                          frozen for another stall interval; unknown or
#                          ring-unsafe panes keep the parent alarm; empty
#                          inbox and a fresh child beacon are not idle proof;
#                          the foreign queue itself stays read-only, and one
#                          parent notification covers each no-progress episode
#   check: squad_lead <id> auto-relaunched after <cause> (<where>)
#                          the liveness tick probed a registered squad_lead's
#                          recorded endpoint, got the recovery-grade `dead` or
#                          `missing` verdict, and relaunched it through the
#                          same guarded jg-spawn.sh --squad-lead path the
#                          session-start sweep uses; one wake per relaunch, and
#                          state/.squad-lead-relaunch-<id> keeps the durable
#                          per-mate count (bin/jg-squad-lead-liveness-lib.sh)
#   check: squad_lead <id> auto-relaunch failed after <cause>: <detail>
#                          the same verdict authorized recovery but the
#                          relaunch itself failed; the attempt is ledgered and
#                          counts toward the bound below
#   check: squad_lead <id> auto-relaunch paused after <n> attempts in <s>s; ...
#                          a mate that kept dying exceeded its bounded relaunch
#                          budget and is parked until a probe reads it live
#                          again (JG_SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS and
#                          JG_SQUAD_LEAD_LIVENESS_WINDOW_SECS)
#   check: host memory ALERT: <summary>; largest: <owner> <size>, ...; <action>
#                          durable sampler wake; docs/configuration.md "Host
#                          memory guard" owns admission and alert behavior;
#                          the host-memory add-on owns sampler lifecycle
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock. A live holder whose beacon is stale
# past the grace (JG_WATCHER_STALE_GRACE, default max(300, JG_POLL+60)) is
# refused with "lock held by live pid ... but heartbeat is stale"; one stale past
# the hard bound JG_WATCHER_STALL_BOUND (default 3x that grace) is instead
# evicted with TERM after its recorded identity is re-verified, and this arm
# starts in its place, printing "watcher: replaced stalled pid <N> (...)". A
# holder that survives the five-second TERM grace is re-verified as the same
# stalled lock holder before KILL; an unproved or surviving holder keeps the
# refusal and the nonzero exit. The replacement safeguards, including recorded
# child retirement and missing-beacon handling, are owned by
# docs/turnend-guard.md "Guard grace and the poll cadence".
# Once per poll the watcher also checks that its home (when it existed at
# start), its state directory, and its own bin directory still exist; when one
# is gone it logs "watcher: exiting - <what> no longer exists: <path>" to stderr
# and exits 1, so a watcher whose temporary home or disposable checkout was
# deleted stops itself instead of running on as an orphan. That check is scoped
# to this process alone and never signals another watcher.
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
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
mkdir -p "$STATE"
# A home that never existed (a state-only test fixture) is not a home that
# disappeared, so the per-poll home-gone exit below applies only when it did.
WATCH_HOME_EXISTED=0
[ ! -d "$JG_HOME" ] || WATCH_HOME_EXISTED=1

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime needlessly spends per-root CI lint memory while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/jg-push-transition-lib.sh"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"
# Only for the arm-time check on JG_PROCEVENT_LAUNCH_CONFIRM_SECONDS below;
# the per-cycle reconcile itself runs as a separate process.
# shellcheck source=bin/jg-procevent-lib.sh
. "$SCRIPT_DIR/jg-procevent-lib.sh"
# Single owner of durable merge-outcome publication, shared with
# bin/jg-pr-merge.sh so self and poll origins use the same role-routed outcome.
# The watcher still owns immediate delivery of its actionable poll result and
# poll retirement.
# This library is a canonical lint root in its own right, and it reaches the
# wake queue, PR identity, and squad_lead parent libraries. Keep it an analysis
# boundary here for the same reason as the transition and inbox owners above and
# below: following its graph from this large runtime needlessly spends per-root
# CI lint memory while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/jg-merge-outcome-lib.sh"
# The durable merge-authority owner is shared with bin/jg-pr-merge.sh. The
# watcher consumes only its identity-bound record after a poll observes landing.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/jg-merge-authority-lib.sh"
# shellcheck source=bin/jg-x-lib.sh
. "$SCRIPT_DIR/jg-x-lib.sh"
# shellcheck source=bin/jg-check-lib.sh
. "$SCRIPT_DIR/jg-check-lib.sh"
# Parent-owned squad_lead missed-report guards: durable pending-reply
# expectations created by jg-send on marked squad_lead requests. The tick is
# cheap when no records exist and never scrapes squad_lead conversation.
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"
# shellcheck source=bin/jg-busy-lib.sh
. "$SCRIPT_DIR/jg-busy-lib.sh"
# shellcheck source=bin/jg-prompt-gate-lib.sh
. "$SCRIPT_DIR/jg-prompt-gate-lib.sh"
# shellcheck source=bin/jg-watch-progress-lib.sh
. "$SCRIPT_DIR/jg-watch-progress-lib.sh"
# shellcheck source=bin/jg-stuck-gate-lib.sh
. "$SCRIPT_DIR/jg-stuck-gate-lib.sh"
# shellcheck source=bin/jg-supervision-lib.sh
. "$SCRIPT_DIR/jg-supervision-lib.sh"
# shellcheck source=bin/jg-project-capacity-lib.sh
. "$SCRIPT_DIR/jg-project-capacity-lib.sh"
# Stale test-browser reaper and machine load alarm: on by default, no add-on to
# install, and it stops only a browser in a fleet temp or scratch profile root whose
# owning worker is gone and whose age is past the limit.
# shellcheck source=bin/jg-reaper-lib.sh
. "$SCRIPT_DIR/jg-reaper-lib.sh"
# Where this checkout's add-ons live (in-repo addons/ first, then the pre-fold clone).
# shellcheck source=bin/jg-addons-dir-lib.sh
. "$SCRIPT_DIR/jg-addons-dir-lib.sh"
# Optional alerts add-on: defines jg_model_outage_tick.
_jg_alerts_lib=$(jg_addon_path "$JG_HOME" alerts/bin/jg-model-outage-lib.sh)
# shellcheck source=/dev/null
[ ! -r "$_jg_alerts_lib" ] || . "$_jg_alerts_lib"
# Parked-home reader (juggernaut-addons/parked-homes): the shared predicate
# every parked-home guard in the watcher calls. The shim answers not parked
# when the add-on is absent (stock behavior).
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$SCRIPT_DIR/jg-parked-homes-lib.sh"
# shellcheck source=bin/jg-composer-lib.sh
. "$SCRIPT_DIR/jg-composer-lib.sh"
# Steering-inbox loss detection: bin/jg-task-inbox-lib.sh owns the record,
# doorbell, re-ring ladder, and unavailable-endpoint contracts; this watcher
# supplies their live endpoint and busy checks plus wake emission
# (inbox_steer_check below).
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"
# The away-posture record (state/.afk-contract) is the posture in both the
# attended and the afk session; bin/jg-afk-contract.sh owns its schema and its
# away-or-quiet reading, which is all this watcher reads (away_record_present
# below).
# shellcheck source=bin/jg-afk-contract.sh
. "$SCRIPT_DIR/jg-afk-contract.sh"
# Persistent-squad-lead endpoint liveness: the shared probe/relaunch library is
# the same one bin/jg-bootstrap.sh's session-start sweep drives, so ordinary
# supervision recovers a positively dead or missing mate through the identical
# guarded path. The watcher contributes only the cadence, the relaunch bound,
# and wake emission (squad_lead_liveness_tick below).
_jg_wait_timers_lib=$(jg_addon_path "$JG_HOME" wait-timers/bin/jg-wait-timers-lib.sh)
# shellcheck source=/dev/null # Analyzed separately as a canonical lint root.
. "$SCRIPT_DIR/jg-squad-lead-liveness-lib.sh"
# Dormant-lead record reader: this tick skips a lead bin/jg-squad-lead-dormant.sh stopped.
# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"
# shellcheck source=/dev/null # Canonical lint root with its own parent-channel graph.
[ ! -r "$_jg_wait_timers_lib" ] || . "$_jg_wait_timers_lib"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/jg-watch.sh"
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
# On Darwin, call /usr/bin/stat rather than PATH-resolved stat so GNU coreutils
# cannot shadow the BSD `-f` syntax.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi
# bin/jg-classify-lib.sh owns status reported-state signatures and presentation
# markers, while bin/jg-wake-lib.sh owns their wake-facing routing, the legacy
# turn-ended signature, annotation staleness checks, and guarded bookkeeping writes.

POLL=${JG_POLL:-15}                   # seconds between cycles
PROMPT_REALERT=${JG_PROMPT_REALERT_SECS:-600}  # a prompt still up is re-acted on this often
# Beacon publication and scan timing are owned by docs/turnend-guard.md
# "Guard grace and the poll cadence".
# jg_poll_derived_grace (bin/jg-wake-lib.sh, already sourced
# transitively above) is the single owner of the max(300, poll+60)
# derivation - see docs/turnend-guard.md "Guard grace and the poll cadence".
# This recomputes the library default above now that the real configured
# POLL is known.
WATCHER_STALE_GRACE=${JG_WATCHER_STALE_GRACE:-${JG_GUARD_GRACE:-$(jg_poll_derived_grace "$POLL")}}
# Hard bound on a live holder's beacon age. Under it a re-arm refuses and asks
# for inspection (the grace above); at or past it the re-arm evicts the holder
# instead, because a watcher whose beacon has stalled that long is not polling
# and nothing else would ever replace it (evict_stalled_holder below).
# jg_watcher_stall_bound (bin/jg-wake-lib.sh) owns the derivation, shared with
# the arm that follows this watcher.
WATCHER_STALL_BOUND=$(jg_watcher_stall_bound "$POLL")
HEARTBEAT=${JG_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${JG_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${JG_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps and ask-default decide ticks
CHECK_TIMEOUT=${JG_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
HOME_SUMMARY_INTERVAL=${JG_HOME_SUMMARY_INTERVAL:-300}
case "$HOME_SUMMARY_INTERVAL" in
  ''|*[!0-9]*|0) HOME_SUMMARY_INTERVAL=300 ;;
esac
SIGNAL_GRACE=${JG_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
CLEANUP_LOCK_BOUND=${JG_WATCHER_CLEANUP_LOCK_BOUND:-2}  # seconds EXIT cleanup may
                                      # wait on the downtime-marker lock; a live
                                      # foreign holder must not strand a TERM'd
                                      # watcher inside its own trap
case "$CLEANUP_LOCK_BOUND" in
  ''|*[!0-9]*) CLEANUP_LOCK_BOUND=2 ;;
  *) CLEANUP_LOCK_BOUND=$((10#$CLEANUP_LOCK_BOUND)) ;;
esac
[ "$CLEANUP_LOCK_BOUND" -gt 0 ] || CLEANUP_LOCK_BOUND=2
TURNEND_CHURN_ABSORB_SECS=${JG_TURNEND_CHURN_ABSORB_SECS:-900}  # longest a task's
                                      # bare turn-ends may be deferred on pane-churn
                                      # evidence alone (signal_turnend_panes_churned)
# Busy state is decided by the semantic contract in bin/jg-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only).
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake juggernaut's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-on-positive-evidence. The shared proof is an actively
# running no-mistakes step or a busy pane via crew_is_provably_working over
# jg-crew-state.sh; where config/turnend-churn-absorb opts in, a bare turn-end alone
# may also use bounded pane churn since the previous poll.
# Every other crew that stopped its turn is SURFACED, so a finish reported
# only through interactive pane menus (no done: status) is never swallowed. An
# ACTIONABLE wake (a captain-relevant signal, a no-verb signal without either
# eligible proof, any check, a stale pane whose crew is not provably working, a
# provably-working stale past the threshold, or anything unknown) is written to
# the durable queue and exits. That wakes the LLM through the background-task
# completion. The same classifier
# (jg-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages. The progress add-on still checks positive
# validation execution evidence before surfacing a stale pane.
STALE_ESCALATE_SECS=${JG_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go without observed activity (the
# marker-selection contract is in busy_turn_over_age below). Once this bound
# is crossed, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. Set generously above
# any legitimate interval without observable progress, including silent long
# tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${JG_BUSY_TURN_MAX_SECS:-3600}
# A local squad_lead's foreign queue is checked on every poll, but only after this
# bounded interval with no drain progress can it produce a parent notification.
# A healthy mate drains its queue between turns, not inside one, so this default
# sits above a real turn; it is only the backstop behind the active-turn gate in
# squad_lead_wake_stall_tick, never a substitute for it.
SQUAD_LEAD_WAKE_STALL_SECS=${JG_SQUAD_LEAD_WAKE_STALL_SECS:-}
case "$SQUAD_LEAD_WAKE_STALL_SECS" in ''|*[!0-9]*|0) SQUAD_LEAD_WAKE_STALL_SECS=180 ;; esac
# SquadLead ENDPOINT liveness (distinct from the wake-loop stall observation
# above): on this cadence the watcher probes each registered mate's recorded
# endpoint through jg-squad-lead-liveness-lib.sh and relaunches only on the
# same recovery-grade `dead` or `missing` verdicts the session-start sweep
# uses. The cadence survives watcher restarts via a state marker's mtime, so a
# relaunch wake cannot restart the probe into a tight loop.
SQUAD_LEAD_LIVENESS_SECS=${JG_SQUAD_LEAD_LIVENESS_SECS:-}
case "$SQUAD_LEAD_LIVENESS_SECS" in ''|*[!0-9]*|0) SQUAD_LEAD_LIVENESS_SECS=60 ;; esac
# Per-relaunch wall-clock bound, so a wedged spawn cannot stall the poll.
SQUAD_LEAD_LIVENESS_TIMEOUT=${JG_SQUAD_LEAD_LIVENESS_TIMEOUT:-}
case "$SQUAD_LEAD_LIVENESS_TIMEOUT" in ''|*[!0-9]*|0) SQUAD_LEAD_LIVENESS_TIMEOUT=120 ;; esac
# Relaunch bound: at most this many automatic attempts per window per mate,
# counted from the durable attempt ledger the shared library appends to. A mate
# that keeps dying past the bound wakes once and is parked until a probe reads
# it alive again, so a flapping endpoint cannot relaunch forever unseen.
SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS=${JG_SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS:-}
case "$SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS" in ''|*[!0-9]*|0) SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS=3 ;; esac
SQUAD_LEAD_LIVENESS_WINDOW_SECS=${JG_SQUAD_LEAD_LIVENESS_WINDOW_SECS:-}
case "$SQUAD_LEAD_LIVENESS_WINDOW_SECS" in ''|*[!0-9]*|0) SQUAD_LEAD_LIVENESS_WINDOW_SECS=3600 ;; esac
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent surfaces on first sight
# and is then held to that same cadence; a squad_lead earns the cadence on its
# declaration alone, because its endpoint liveness is deliberately never read
# (pause_state_class owns that split).
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten wait cannot rot
# invisibly - except an item held for the captain while the away-posture record
# exists, which is never rechecked (away_record_present below).
PAUSE_RESURFACE_SECS=${JG_PAUSE_RESURFACE_SECS:-$JG_PAUSE_RESURFACE_SECS_DEFAULT}
# A squad_lead home below its lane floor with ready work re-raises the same
# condition on this cadence instead of going silent after one wake: the lead
# either starts the work or records why it waits, and that answer must not need a
# fresh incident to be repeated.
READY_WORK_RESURFACE_SECS=${JG_READY_WORK_RESURFACE_SECS:-1800}
case "$READY_WORK_RESURFACE_SECS" in ''|*[!0-9]*|0) READY_WORK_RESURFACE_SECS=1800 ;; esac
# A declared wait that names WHEN it clears (`paused: ... until <UTC ISO 8601>`,
# status_paused_until in jg-classify-lib.sh) is condition-aware: it is not
# rechecked before that time, and it is rechecked once as soon as that time
# passes even when the flat cadence has not elapsed, then held to the cadence.
# Consecutive event-path failures (jg_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${JG_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (jg_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# away_record_present: 0 while an away record exists (the captain is away, in
# either supervision shape); quiet mode's record is a present captain, so it
# reads 1 (jg_afk_contract_away_present). "The away-posture record exists"
# below means this. While it exists an item held for the captain is never
# rechecked: there is nobody to answer it, the return brief lists it, and a
# recheck would only churn (the 2026-09-07 away-window audit counted hourly
# rechecks of captain-held items as pure noise). Declared external waits keep
# their condition-aware cadence in both postures.
away_record_present() { jg_afk_contract_away_present "$STATE"; }

# captain_held_silenced <status-line>: 0 when the line declares a captain-held
# transfer and an away record exists, so every stale path absorbs the pane
# silently instead of rechecking it.
captain_held_silenced() {  # <status-line>
  status_is_captain_held "$1" && away_record_present
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/jg-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is passed
# into the contract's harness-scoped rendered-text checks: the Grok/Rovo/AGY
# busy fallbacks and the launch-prompt backstop that keeps a launch pinned at
# its jg-spawn seed from reading as provably working.
# window_stuck_busy: 0 when a busy verdict must be DISTRUSTED because the
# turn behind it has visibly stopped. A hook that never fires (a Claude turn
# parked at an empty prompt with a full context, no Stop event) leaves a busy
# record nothing ever clears, and the stale backbone would trust it for the
# whole BUSY_TURN_MAX_SECS bound. All three must hold at once: the record's
# own last-event age already passed STALE_ESCALATE_SECS, the pane shows none
# of its harness's registered busy chrome, and the composer is proven empty.
# Any live chrome, any unproven composer, any fresh record, and any harness
# with no registered spinner signature keep the busy verdict: a stale video
# frame still carries its Working line, a mid-redraw pane never proves empty,
# and absence of a signature the repo never recorded proves nothing either.
# The safe direction is to surface: a false positive becomes one stale alert
# for inspection, never an automatic interrupt, signal, or restart.
window_stuck_busy() {  # <window> <task> <tail40>
  local w=$1 task=$2 tail40=$3 rec ts age harness backend label cstate
  [ -n "$task" ] || return 1
  rec="$STATE/$task.busy-state"
  ts=$(sed -n 's/^v1 .* state=busy .* ts=\([0-9][0-9]*\)$/\1/p' "$rec" 2>/dev/null | head -n 1) || return 1
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  age=$(( $(date +%s) - ts ))
  [ "$age" -ge "$STALE_ESCALATE_SECS" ] || return 1
  harness=$(window_harness "$w")
  if printf '%s' "$tail40" | jg_busy_lines_match "$harness"; then
    return 1
  fi
  jg_busy_harness_has_signature "$harness" || return 1
  backend=$(window_backend "$w")
  label=$(window_label "$w")
  cstate=$(jg_backend_composer_state "$backend" "$w" "$label" 2>/dev/null || true)
  [ "$cstate" = empty ] || return 1
  return 0
}

window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(jg_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(jg_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ] || return 1
  window_stuck_busy "$w" "$task" "$tail40" && return 1
  return 0
}

window_kind() {
  local w=$1 meta kind
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(jg_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'jg-%s' "$task"
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*, .waiting-*, .truth-*, .activity-*, .tracked-), and live homes
# hold those markers on disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

# Emit the one deferral report for <record> and mark it reported. Both
# deferral reasons (a turn still running, a composer holding other text) use
# this single wake, and neither one ends delivery.
inbox_steer_defer_report() {  # <window> <task> <record> <kind> <sentence>
  local w=$1 task=$2 rec=$3 reason
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    jg_task_inbox_due_action "$STATE" "$task" >/dev/null || true
    return 0
  fi
  reason="stale: $w (unread juggernaut instruction: $rec stays unhandled - $5; no doorbell was typed, and it lands as soon as that clears, so no interrupt is needed unless the worker is wedged)"
  jg_wake_append stale "$w" "$reason" || exit 1
  if ! jg_task_inbox_record_deferral_reported "$STATE" "$task" "$rec" "$4"; then
    echo "error: stale wake was queued for $task but its deferral report marker could not be written" >&2
    exit 1
  fi
  wake "$reason"
}

inbox_steer_escalate_unavailable() {  # <window> <task> <record>
  local w=$1 task=$2 rec=$3 reason
  reason="stale: $w (unread juggernaut instruction: $rec is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)"
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    jg_task_inbox_due_action "$STATE" "$task" >/dev/null || true
    return 0
  fi
  jg_wake_append stale "$w" "$reason" || exit 1
  if ! jg_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
    echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
    exit 1
  fi
  wake "$reason"
}

# Steering-inbox loss detection, one cheap check per recorded window per poll.
# bin/jg-task-inbox-lib.sh owns delivery, busy-deferral, retry, and escalation policy.
# Endpoint and busy checks precede delivery so recovery never types into a busy,
# dead, or missing worker; the ring helper protects pending composer text.
# Normal retries keep the watcher blocking rather than waking juggernaut.
# Runs for squad_leads too: their pane-staleness exemption is about quiet panes
# being healthy, while an unacknowledged instruction can still be a stuck steer.
inbox_steer_check() {  # <window> <task>
  local w=$1 task=$2 action verb rec count tail40 reason='' ring_rc backend agent_state decision
  # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
  # doorbell ring, re-ring or unread-instruction escalation. No-op without
  # the add-on checkout.
  jg_parked_skip_meta "$STATE/$task.meta" "$task" wake-doorbell && return 0
  action=$(jg_task_inbox_due_action "$STATE" "$task") || return 0
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  if [ "$verb" = retry ] && [ -n "$(status_own_open_decisions "$STATE/$task.status")" ]; then
    return 0
  fi
  rec=${action#* }
  count=
  case "$verb" in
    escalate)
      count=${rec##* }
      rec=${rec% *}
      ;;
  esac
  backend=$(window_backend "$w")
  agent_state=$(jg_backend_agent_state "$backend" "$w" 2>/dev/null || true)
  case "$agent_state" in
    dead|missing)
      if [ "$verb" = retry ]; then
        jg_task_inbox_clear_retry "$STATE" "$task" "$rec" || true
      else
        inbox_steer_escalate_unavailable "$w" "$task" "$rec"
      fi
      return 0
      ;;
  esac
  watcher_capture "$backend" "$w" 40 "$(window_label "$w")" || WATCHER_CAPTURE=
  tail40=$WATCHER_CAPTURE
  if window_is_busy "$w" "$tail40"; then
    [ "$verb" != retry ] || return 0
    # The turn really is still running, so nothing may be typed at it. The
    # deferral only defers: it reports the unread instruction once and keeps the
    # message owed, so the ordinary ladder below rings the doorbell on the first
    # non-busy poll once the turn ends - no interrupt, no relaunch.
    decision=$(jg_task_inbox_defer "$STATE" "$task" "$rec")
    case "$decision" in
      quiet) return 0 ;;
      escalate)
        reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be written while $rec stays unhandled; inspect the inbox directory)"
        verb=escalate
        ;;
      *)
        inbox_steer_defer_report "$w" "$task" "$rec" busy \
          "stuck-busy after ${decision#report } consecutive busy-deferred due doorbells, with the pane reading busy for a turn still running"
        return 0
        ;;
    esac
  elif [ "$verb" != retry ] && ! jg_task_inbox_clear_busy "$STATE" "$task"; then
    reason="stale: $w (steering-inbox busy bookkeeping unwritable: ${rec%/*}/.busy-state cannot be reset after a non-busy check; inspect the inbox directory)"
    verb=escalate
  fi
  case "$verb" in
    ring)
      ring_rc=0
      jg_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")" || ring_rc=$?
      if [ "$ring_rc" -eq 3 ]; then
        inbox_steer_escalate_unavailable "$w" "$task" "$rec"
        return 0
      fi
      if [ "$ring_rc" -eq 1 ]; then
        # The composer provably holds other text, so the Enter was withheld on
        # purpose. That is a deferral, not a spent attempt: the record stays
        # owed and the one-keypress fix is reported at once instead of the
        # delivery budget being spent toward a silent give-up.
        if jg_task_inbox_deferral_reported "$STATE" "$task" "$rec" held; then
          triage_log "steer-inbox delivery held: $task ${rec##*/} (already reported)"
          return 0
        fi
        triage_log "steer-inbox delivery held: $task ${rec##*/}${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
        inbox_steer_defer_report "$w" "$task" "$rec" held \
          "the worker's composer holds other pending text, so submitting the doorbell could submit that text - submit it with 'jg-send.sh $task --key Enter' or clear the composer"
        return 0
      fi
      if ! jg_task_inbox_record_ring "$STATE" "$task" "$rec"; then
        if [ ! -f "$rec" ]; then
          jg_task_inbox_due_action "$STATE" "$task" >/dev/null || true
          return 0
        fi
        if [ -d "${rec%/*}" ]; then
          reason="stale: $w (steering-inbox ladder bookkeeping unwritable: ${rec%/*}/.ring-state cannot be written while $rec stays unhandled; the doorbell cannot advance toward escalation - inspect the inbox directory)"
          jg_wake_append stale "$w" "$reason" || exit 1
          wake "$reason"
        fi
      fi
      triage_log "steer-inbox delivery attempt: $task ${rec##*/} result=$ring_rc${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
      ;;
    retry)
      ring_rc=0
      jg_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")" || ring_rc=$?
      if ! jg_task_inbox_clear_retry "$STATE" "$task" "$rec" && [ -f "$rec" ]; then
        reason="stale: $w (steering-inbox retry mark unremovable: ${rec%/*}/.retry-ring cannot be removed, so $rec would ring on every poll - inspect the inbox directory)"
        jg_wake_append stale "$w" "$reason" || exit 1
        wake "$reason"
      fi
      triage_log "steer-inbox retry ring: $task ${rec##*/} result=$ring_rc${JG_TASK_INBOX_RING_REASON:+ reason=$JG_TASK_INBOX_RING_REASON}"
      ;;
    escalate)
      reason=${reason:-"stale: $w (unread juggernaut instruction: $rec still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"}
      if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
        jg_task_inbox_due_action "$STATE" "$task" >/dev/null || true
        return 0
      fi
      jg_wake_append stale "$w" "$reason" || exit 1
      if ! jg_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        exit 1
      fi
      wake "$reason"
      ;;
  esac
}

# 0 (benign/absorb) if EVERY task in a no-verb "signal:" wake has positive work
# evidence; 1 otherwise. Each task may satisfy the authoritative working proof,
# or an eligible bare turn-end may use the opt-in pane-churn proof below.
#
# OFF unless the home creates config/turnend-churn-absorb. The first two proofs
# read a verdict the harness itself vouches for; this one infers execution from
# rendered bytes, which is weaker, so widening the absorb is a home's choice to
# make rather than a default every fleet inherits. With the flag absent this
# delegates to the unchanged all-tasks authoritative proof.
#
# It exists because the first two are unreachable for a harness whose semantic
# busy state has no verified source: bin/jg-crew-state.sh can only answer unknown
# for such an adapter, crew_is_provably_working is therefore never satisfiable,
# and every worker turn boundary surfaced a wake with nothing to act on - the cost
# scaling with the number of workers in flight. Pane churn needs no harness
# cooperation, so it restores the absorb branch for those adapters without
# fabricating a busy verdict any adapter has not earned.
#
# The evidence is the one the pane-staleness backbone below already trusts for
# liveness: this compares a fresh capture against the .hash- marker that backbone
# recorded on the previous poll, which is why the derivation lives here with the
# marker format rather than in the shared classifier. Absorbing here DEFERS a wake
# rather than swallowing it, and the deferral is BOUNDED: a task's turn-ends may
# ride churn evidence for at most JG_TURNEND_CHURN_ABSORB_SECS, tracked per window
# in .churn-since-, after which the wake surfaces and the window restarts. The
# bound is what keeps churn from muting supervision outright. A pane that renders
# continuously - a clock, a spinner, a shell heartbeat, a harness that leaves a
# background renderer alive after its agent yields - never presents the two
# identical consecutive hashes the staleness backbone needs either, so without the
# bound a worker that had genuinely stopped behind such a renderer would be
# deferred here forever with no fallback path left to surface it. Churn and
# staleness read the same pane, so neither can be the other's only backstop.
# Within the bound, an ordinary crew that stops renders nothing more, its pane
# hash stops moving, and the staleness backbone surfaces it within a couple of
# polls; any captain-relevant status verb still surfaces immediately through
# signal_files_actionable. That is why this widens the proof instead of
# bounding the wake rate, which would have suppressed genuinely stopped workers.
#
# Every negative outcome returns 1, so absence of evidence surfaces exactly as
# before: any batch that references a squad_lead, an unresolvable task, a task
# with no uniquely attributable recorded endpoint, no previous hash to compare
# against (nothing has been polled yet), a capture that fails or comes back empty,
# an exhausted deferral bound, and of course an unchanged pane. Any .status file
# also returns 1: an authored append is content the
# supervisor may need to read, so only the mechanical turn-end marker gets the
# fallback.
#
# NOT a pure read: one bounded pane capture per referenced task that lacks
# authoritative proof. Once EVERY task passes, each churn-proven pane's prior
# .stale- classification and wedge-escalation count are cleared because churn
# begins a new quiet interval; retaining either would make the new interval
# inherit the prior one. Reached only for a non-afk, no-captain-verb signal, so
# it never runs on the ordinary per-wake path.
signal_turnend_panes_churned() {  # <file> ...
  [ -e "$CONFIG/turnend-churn-absorb" ] || return 1
  local f base task meta kind w key backend label terminal prev now since now_s absorb_secs marker age
  local rec_task task_index i j count hash_file hash_bytes created
  local max_absorb_secs=9223372036854775807
  local -a signal_tasks=() signal_statuses=() snapshot_tasks=() snapshot_kinds=()
  local -a snapshot_windows=() snapshot_keys=() snapshot_backends=() snapshot_labels=()
  local -a signal_indexes=() churn_indexes=() churned_keys=() missing_keys=() created_keys=()
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     return 1 ;;
      *.turn-ended) task=${base%.turn-ended}; kind=turn-ended ;;
      *)            return 1 ;;
    esac
    [ -n "$task" ] || return 1
    task_index=-1
    for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
      [ "${signal_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    if [ "$task_index" -lt 0 ]; then
      signal_tasks+=("$task")
      [ "$kind" = status ] && signal_statuses+=(1) || signal_statuses+=(0)
    elif [ "$kind" = status ]; then
      signal_statuses[task_index]=1
    fi
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    rec_task=${meta##*/}
    rec_task=${rec_task%.meta}
    kind=$(jg_meta_get "$meta" kind)
    backend=$(jg_backend_of_meta "$meta")
    if [ "$backend" = orca ]; then
      terminal=$(jg_meta_get "$meta" terminal)
      w=${terminal:-$(jg_meta_get "$meta" window)}
    else
      w=$(jg_meta_get "$meta" window)
    fi
    key=
    [ -n "$w" ] && key=$(window_key "$w")
    label="jg-$rec_task"
    snapshot_tasks+=("$rec_task")
    snapshot_kinds+=("$kind")
    snapshot_windows+=("$w")
    snapshot_keys+=("$key")
    snapshot_backends+=("$backend")
    snapshot_labels+=("$label")
  done
  # These linear lookups deliberately support stock macOS Bash 3.2.57, enforced
  # by macos-stock-bash, and this repository uses no associative arrays in bin/
  # or tests/. A batch is normally one to three tasks and captures dominate its
  # cost; indexed lookup is the upgrade path if coalesced batches grow large.
  for task in "${signal_tasks[@]}"; do
    task_index=-1
    for ((i = 0; i < ${#snapshot_tasks[@]}; i++)); do
      [ "${snapshot_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    [ "$task_index" -ge 0 ] || return 1
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    [ -n "$w" ] && [ -n "$key" ] || return 1
    count=0
    for ((j = 0; j < ${#snapshot_keys[@]}; j++)); do
      [ "${snapshot_keys[$j]}" = "$key" ] && count=$((count + 1))
    done
    [ "$count" -eq 1 ] || return 1
    signal_indexes+=("$task_index")
  done
  for task_index in "${signal_indexes[@]}"; do
    [ "${snapshot_kinds[$task_index]}" != squad_lead ] || return 1
  done
  for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
    task=${signal_tasks[$i]}
    crew_is_provably_working "$task" && continue
    task_index=${signal_indexes[$i]}
    churn_indexes+=("$task_index")
  done
  [ "${#churn_indexes[@]}" -gt 0 ] || return 0
  [[ $TURNEND_CHURN_ABSORB_SECS =~ ^[1-9][0-9]*$ ]] || return 1
  if [ "${#TURNEND_CHURN_ABSORB_SECS}" -gt "${#max_absorb_secs}" ] \
    || { [ "${#TURNEND_CHURN_ABSORB_SECS}" -eq "${#max_absorb_secs}" ] \
      && [[ $TURNEND_CHURN_ABSORB_SECS -gt $max_absorb_secs ]]; }; then
    return 1
  fi
  absorb_secs=$((10#$TURNEND_CHURN_ABSORB_SECS))
  for task_index in "${churn_indexes[@]}"; do
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    backend=${snapshot_backends[$task_index]}
    label=${snapshot_labels[$task_index]}
    hash_file="$STATE/.hash-$key"
    hash_bytes=$(LC_ALL=C wc -c 2>/dev/null < "$hash_file") || return 1
    hash_bytes=${hash_bytes//[[:space:]]/}
    [ "$hash_bytes" = 32 ] || return 1
    prev=$(cat "$hash_file" 2>/dev/null) || return 1
    [[ $prev =~ ^[0-9a-f]{32}$ ]] || return 1
    watcher_capture "$backend" "$w" 40 "$label" || return 1
    now=$WATCHER_CAPTURE
    [ -n "$now" ] || return 1
    [ "$(printf '%s' "$now" | hash_pane)" != "$prev" ] || return 1
    churned_keys+=("$key")
  done
  # Enforce the deferral bound BEFORE any .stale- state is touched, so a wake that
  # surfaces here leaves the staleness backbone's own classification alone.
  now_s=$(date +%s)
  for key in "${churned_keys[@]}"; do
    marker="$STATE/.churn-since-$key"
    if [ ! -e "$marker" ]; then
      [ ! -L "$marker" ] || return 1
      missing_keys+=("$key")
      continue
    fi
    since=$(cat "$marker" 2>/dev/null) || return 1
    [[ $since =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#since}" -gt "${#now_s}" ] \
      || { [ "${#since}" -eq "${#now_s}" ] && [[ $since > $now_s ]]; }; then
      return 1
    fi
    age=$((10#$now_s - 10#$since))
    if [ "$age" -ge "$absorb_secs" ]; then
      rm -f "$marker"
      return 1
    fi
  done
  for key in "${missing_keys[@]+"${missing_keys[@]}"}"; do
    marker="$STATE/.churn-since-$key"
    if (set -C; printf '%s' "$now_s" > "$marker") 2>/dev/null; then
      created_keys+=("$key")
      continue
    fi
    for created in "${created_keys[@]+"${created_keys[@]}"}"; do
      rm -f "$STATE/.churn-since-$created"
    done
    return 1
  done
  for key in "${churned_keys[@]}"; do
    if ! rm -f "$STATE/.stale-$key" "$STATE/.wedge-escalations-$key"; then
      for created in "${created_keys[@]+"${created_keys[@]}"}"; do
        rm -f "$STATE/.churn-since-$created"
      done
      return 1
    fi
  done
  return 0
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    # A lane stopped by a verified `jg-control.sh exit` keeps its window= for
    # relaunch and teardown, but its endpoint may be dead; watching it would
    # emit stale on every arm and keep supervision from holding the lock.
    ! jg_meta_exited_on_purpose "$meta" || continue
    w=$(jg_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid ACTIONABLE row in a local squad_lead's
# foreign queue. A stale recheck that explicitly identifies itself as a declared
# external-wait pause is not evidence that the mate's wake loop is stuck: the
# pause cadence already owns that bounded visibility, and blocked waits remain
# actionable because they do not carry this declaration. This is a read-only
# observation: the receiving home owns acknowledgement and this parent never
# changes the row or the foreign queue.
squad_lead_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    function declared_external_pause(kind, payload) {
      return kind == "stale" \
        && payload ~ /^stale: .*\(paused [0-9]+s, awaiting external - declared (pause,|paused\))/
    }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ \
      && !declared_external_pause($3, $5) {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# 0 iff <task> is demonstrably inside an active turn, through the watcher's own
# busy-state knowledge: an exact busy verdict from the semantic contract, bounded
# by the same BUSY_TURN_MAX_SECS that stops a busy pane from proving liveness
# forever. A mate mid-turn has not stopped draining its queue - it simply drains
# between turns - so this gate, not the elapsed interval, is what separates a
# healthy mate from a frozen wake loop. The bound is measured on <idle>, how long
# the queue's drain position has not moved, because a mate's turns end in its own
# home and this home holds no completed-turn evidence to age them by
# (busy_turn_over_age, whose spawn-record fallback would age every mate from its
# launch). Any absence of proof (no window, a failed capture, an idle or unknown
# verdict, a queue frozen past the bound) is NOT an active turn, so a frozen
# queue still escalates.
# A mate with a supervision branch also works its queue in that branch's turns,
# which the busy record (main's turns only) never sees: the frozen row <seq>
# sitting in the branch's live grant (jg_wake_branch_grant_live) is that turn in
# progress, and the mate's main conversation cannot drain a granted row, so a
# ring there could not move it.
squad_lead_in_active_turn() {  # <window> <idle> <home> <seq>
  local w=$1 idle=$2 grant="$3/state/.branch-eligible-rows" seq=$4 tail40
  [ "$idle" -lt "$BUSY_TURN_MAX_SECS" ] || return 1
  if [ ! -L "$grant" ] && grep -Fqx -- "$seq" "$grant" 2>/dev/null \
    && jg_wake_branch_grant_live "$grant" "$3/state/.branch-eligible-owner"; then
    return 0
  fi
  [ -n "$w" ] || return 1
  watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" || return 1
  tail40=$WATCHER_CAPTURE
  window_is_busy "$w" "$tail40"
}

# Set SQUAD_LEAD_BUSY_CLASS to the first token of the semantic busy
# classification for <window>: busy, idle, unknown, or dead. Capture failure and
# a missing window are unknown, never idle. Empty inbox and a fresh watcher
# beacon are not consulted. Call it directly, never in $(...), so its pane
# capture runs in the watcher's own shell.
SQUAD_LEAD_BUSY_CLASS=
squad_lead_busy_class() {  # <window>
  local w=$1 task meta tail40 verdict
  SQUAD_LEAD_BUSY_CLASS=unknown
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -z "$w" ] || [ -z "$task" ] || [ ! -f "$meta" ]; then
    return 0
  fi
  watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" || return 0
  tail40=$WATCHER_CAPTURE
  verdict=$(jg_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  SQUAD_LEAD_BUSY_CLASS=${verdict%% *}
}

# 0 iff a child ring is authorized: exact idle, a live agent, and a composer
# that is not proven pending. Busy, unknown, dead, missing, and pending
# composer all refuse, so a Kimi or Claude pane without an exact idle
# verdict is never typed into.
squad_lead_idle_ring_safe() {  # <window>
  local w=$1 backend agent_state cstate
  [ -n "$w" ] || return 1
  squad_lead_busy_class "$w"
  [ "$SQUAD_LEAD_BUSY_CLASS" = idle ] || return 1
  backend=$(window_backend "$w")
  agent_state=$(jg_backend_agent_state "$backend" "$w" 2>/dev/null || true)
  [ "$agent_state" = alive ] || return 1
  cstate=$(jg_backend_composer_state "$backend" "$w" "$(window_label "$w")" 2>/dev/null) || cstate=unknown
  [ "$cstate" != pending ] || return 1
  return 0
}

# Write one fire-and-forget drain steer and ring the child's doorbell. The
# steer carries the same from-juggernaut fire-and-forget carrier jg-send uses
# for a squad_lead (marker, then delivery=<16-hex-id>, then the text), so the
# mate reads it as a parent request that expects no reply, never as captain
# intervention. The worker's ordinary wake-handling turn drains its own home's
# wake queue; this parent never rewrites that foreign queue. The text names the
# frozen row and the acknowledgement, because a drained row leaves the queue only
# on its WAKE_ACK_REQUIRED command, and a mate told only to drain has presented
# the row, cut that line off its output, and left the row queued. 0 iff the ring
# call returned 0.
squad_lead_ring_to_drain() {  # <task> <window> <seq>
  local task=$1 w=$2 seq=$3 rec backend delivery_id
  backend=$(window_backend "$w")
  delivery_id=$(LC_ALL=C od -An -v -tx1 -N 8 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
  case "$delivery_id" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#delivery_id}" -eq 16 ] || return 1
  rec=$(jg_task_inbox_write "$STATE" "$task" \
    "${JG_FROMFIRST_MARK}delivery=${delivery_id} Wake row $seq is still queued in this home. Run bin/jg-wake-drain.sh and read its whole output, handle what it presents, then run the exact WAKE_ACK_REQUIRED command it prints, which is what removes the row. Then resume idle supervision." \
    fire-and-forget) || return 1
  jg_task_inbox_ring "$backend" "$w" "$rec" "$(window_label "$w")"
}

# Surface one durable parent check when the foreign queue's drain position has
# not moved for the bounded interval. The progress marker records that position
# as the same epoch-sequence row identity the stall receipts use, so the timer
# restarts whenever a different row becomes the oldest actionable one - as the
# mate drains, and as a queue reprovisioned under the same task id starts its
# own generation of rows at whatever sequence it restarts, and neither is a
# continued no-progress episode; row creation time belongs to that identity but
# never to the interval. A moved position ends an alerted episode and starts a
# new observation interval, so a newly-oldest row cannot alert immediately while
# a later genuine freeze remains visible. A mate demonstrably inside an active
# turn defers its escalation, but only while this same interval is under
# BUSY_TURN_MAX_SECS, so a turn that never ends cannot hide a frozen queue.
# A mate whose busy class is exactly idle, whose agent is alive, and whose
# composer is not pending is rung once so its own home can drain, and the
# parent notification is withheld until that same row stays frozen for another
# stall interval. Unknown, busy-over-bound, and ring-unsafe panes keep the
# parent alarm. Empty inbox and a fresh child beacon are not idle proof.
# Receipts close the append-before-marker crash window without changing the
# foreign queue.
squad_lead_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SQUAD_LEAD_WAKE_STALL_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker progress_marker ring_marker progress observed_at observed_key
  local receipt receipt_dir notify_key queued idle reason episode_alerted already_rung w
  # Endpoint metadata admits this queue-loop check; squad-lead-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(jg_meta_get "$meta" kind)
    [ "$kind" = squad_lead ] || continue
    remote_host=$(jg_meta_get "$meta" remote_host)
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
    # drain ring and no wake-loop-stalled check; its stale episode markers are
    # dropped so an unpark starts clean. No-op without the add-on checkout.
    jg_parked_skip_meta "$meta" "$task" watch-wake-stall && { rm -f "$STATE/.squad-lead-wake-stall-$task" "$STATE/.squad-lead-wake-progress-$task" "$STATE/.squad-lead-wake-ring-$task" 2>/dev/null || true; continue; }
    home=$(jg_meta_get "$meta" home)
    [ -n "$home" ] || continue
    [ -f "$(jg_compat_marker "$home")" ] && [ ! -L "$(jg_compat_marker "$home")" ] || continue
    [ "$(cat "$(jg_compat_marker "$home")" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(squad_lead_oldest_queue_row "$queue")
    marker="$STATE/.squad-lead-wake-stall-$task"
    progress_marker="$STATE/.squad-lead-wake-progress-$task"
    ring_marker="$STATE/.squad-lead-wake-ring-$task"
    receipt_dir="$STATE/.squad-lead-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker" "$progress_marker" "$ring_marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    row_key="$epoch-$seq"
    episode_alerted=0
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      episode_alerted=1
    fi
    progress=$(cat "$progress_marker" 2>/dev/null || true)
    observed_at=${progress%%[[:space:]]*}
    observed_key=${progress#*[[:space:]]}
    if [ "$observed_at" = "$progress" ]; then
      observed_key=
    else
      observed_key=${observed_key%%[[:space:]]*}
    fi
    case "$observed_at" in ''|*[!0-9]*) observed_at= ;; esac
    case "$observed_key" in ''|*[!0-9-]*) observed_key= ;; esac
    if [ -z "$observed_at" ] || [ -z "$observed_key" ] \
      || [ "$now" -lt "$observed_at" ] || [ "$row_key" != "$observed_key" ]; then
      jg_wake_squad_lead_progress_marker_write "$task" "$now" "$row_key" || return 1
      [ "$episode_alerted" -eq 0 ] || rm -f "$marker" || return 1
      rm -f "$ring_marker" || return 1
      continue
    fi
    [ "$episode_alerted" -eq 0 ] || continue
    idle=$((now - observed_at))
    [ "$idle" -ge "$threshold" ] || continue
    w=$(jg_backend_target_of_meta "$meta")
    ! squad_lead_in_active_turn "$w" "$idle" "$home" "$seq" || continue
    already_rung=0
    if [ -e "$ring_marker" ] || [ -L "$ring_marker" ]; then
      [ -f "$ring_marker" ] && [ ! -L "$ring_marker" ] || return 1
      [ "$(cat "$ring_marker" 2>/dev/null || true)" = "$row_key" ] && already_rung=1
    fi
    if [ "$already_rung" -eq 0 ] && squad_lead_idle_ring_safe "$w"; then
      if squad_lead_ring_to_drain "$task" "$w" "$seq"; then
        jg_wake_squad_lead_ring_marker_write "$task" "$row_key" || return 1
        jg_wake_squad_lead_progress_marker_write "$task" "$now" "$row_key" || return 1
        continue
      fi
    fi
    receipt="$receipt_dir/$row_key"
    if [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ]; then
      jg_wake_squad_lead_stall_marker_write "$task" "$row_key" || return 1
      continue
    fi
    notify_key="squad-lead-wake-loop-$task-$row_key"
    reason="check: squad_lead wake-loop stalled: mate=$task row=$seq idle=${idle}s"
    queued=$(jg_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      jg_wake_append check "$notify_key" "$reason" || return 1
    fi
    jg_wake_squad_lead_stall_receipt_write "$task" "$row_key" || return 1
    jg_wake_squad_lead_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# The ordinary-supervision half of the squad_lead liveness guarantee, paired
# with bin/jg-bootstrap.sh's session-start sweep over the shared library in
# bin/jg-squad-lead-liveness-lib.sh (which owns the state contract, the remote
# probe rules, the kill ordering, and the guarded relaunch). On a bounded
# cadence each registered mate's recorded endpoint is probed once; only a
# recovery-grade `dead` or `missing` verdict relaunches, every relaunch
# (success or failure) becomes exactly one durable `check` wake row, and every
# other verdict lands only in the triage log. The tick finishes every mate's
# bounded recovery before it wakes once on the first outcome; the drain
# surfaces every queued row. A mate that keeps
# dying is parked after SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS ledgered attempts
# inside SQUAD_LEAD_LIVENESS_WINDOW_SECS: the bound marker wakes once, further
# probes stay silent, and a later live probe ledgers a `rearmed` row and clears
# the marker so a manually recovered mate rejoins the guarantee with a full
# budget. The per-mate liveness lock serializes this tick against a concurrent
# session-start sweep, so neither side can kill or re-probe an endpoint the
# other is mid-relaunch on.
jg_host_memory_lib=$(jg_addon_path "$JG_HOME" host-memory/bin/jg-host-memory-lib.sh)
# shellcheck disable=SC1090,SC1091 # The optional add-on source is installed outside this repository.
if [ -f "$jg_host_memory_lib" ]; then . "$jg_host_memory_lib"; fi

# Publication and acknowledgement remain the sampler and drain's jobs. A
# delivered row must not immediately close the successor before it can prove
# continuity; the own-queue backstop below re-rings an unhandled row later.
host_memory_surface_after_output() {
  local status=$1
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$HOST_MEMORY_SURFACED" > "$STATE/.host-memory-surfaced" || status=1
  fi
  jg_lock_release "$JG_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

host_memory_surface_queued() {
  local row reason
  [ -s "$JG_WAKE_QUEUE" ] || return 0
  jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK" || return 1
  row=$(awk -F '\t' '$3 == "check" && $4 == "host-memory" { row=$0 } END { if (row != "") print row }' "$JG_WAKE_QUEUE")
  HOST_MEMORY_SURFACED=$(printf '%s\n' "$row" | cut -f1,2)
  if [ -z "$row" ] || [ "$HOST_MEMORY_SURFACED" = "$(cat "$STATE/.host-memory-surfaced" 2>/dev/null)" ]; then
    jg_lock_release "$JG_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason=$(printf '%s\n' "$row" | cut -f5-)
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  JG_WAKE_POST_OUTPUT_ACTION=host_memory_surface_after_output
  wake "$reason"
}

# Re-deliver the oldest unhandled local wake on a bounded cadence, without
# adding a duplicate queue row or consuming it. This survives watcher cycles,
# excludes declared external waits, and defers rows a live branch is handling.
# The ordinary arm owner delivers the reason, never a synthetic keyboard ring.
own_queue_resurface() {
  local row epoch seq kind key reason now previous observed_at observed_key row_key idle task file
  while :; do
    row=$(squad_lead_oldest_queue_row "$JG_WAKE_QUEUE")
    if [ -z "$row" ]; then
      rm -f "$STATE/.own-wake-progress"
      return 0
    fi
    IFS=$'\t' read -r epoch seq kind key reason <<EOF
$row
EOF
    # Cleanup can race a scan's queue append. A removed log is not a new
    # signal; retain any row whose task still has a record (including links).
    case "$kind:$key" in
      signal:*.status|signal:*.turn-ended)
        file=${key##*/}; task=${file%.*}
        if [ ! -e "$STATE/$file" ] && [ ! -L "$STATE/$file" ] \
          && [ ! -e "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ] \
          && [ ! -e "$STATE/$task.status" ] && [ ! -L "$STATE/$task.status" ] \
          && [ ! -e "$STATE/$task.inbox" ] && [ ! -L "$STATE/$task.inbox" ]; then
          jg_wake_withdraw signal "$key" || return 1
          continue
        fi
        ;;
      stale:*)
        # Retire legacy prune notices too. A current owner retains its alarm.
        task=$(window_key "$key")
        if pruned_panes_seen "$task" && [ ! -e "$STATE/.tracked-$task" ] \
          && ! jg_backend_meta_for_window "$key" "$STATE" >/dev/null 2>&1; then
          jg_wake_withdraw stale "$key" || return 1
          continue
        fi
        ;;
    esac
    break
  done
  row_key="$epoch-$seq"
  jg_epoch_seconds_to now
  previous=$(cat "$STATE/.own-wake-progress" 2>/dev/null) || previous=
  observed_at=${previous%%$'\t'*}
  observed_key=${previous#*$'\t'}
  case "$observed_at" in ''|*[!0-9]*) observed_at=$now; observed_key= ;; esac
  if [ "$observed_key" != "$row_key" ] || [ "$now" -lt "$observed_at" ]; then
    printf '%s\t%s\n' "$now" "$row_key" > "$STATE/.own-wake-progress" || return 1
    return 0
  fi
  idle=$((now - observed_at))
  [ "$idle" -ge "$SQUAD_LEAD_WAKE_STALL_SECS" ] || return 0
  squad_lead_in_active_turn '' "$idle" "$JG_HOME" "$seq" && return 0
  printf '%s\t%s\n' "$now" "$row_key" > "$STATE/.own-wake-progress" || return 1
  case "$kind:$reason" in
    signal:needs-decision:*) reason="signal:${reason#needs-decision:}" ;;
  esac
  wake "$reason"
}

# lead_supervision_check: a live lead whose own watcher is not running while it
# has work under way is a dead hop, so its workers' waits would reach nobody.
# Main owns lead liveness, so the lead is steered to re-arm and the gap becomes
# a wait source (state/.wait-sources/<id>.supervision) that the wait-timers
# chain escalates like any other wait. Only the lead home's own supervision
# state is read (bin/jg-supervision-lib.sh), never a child's records. Returns 0
# on first detection only; the source clears once the lead is supervised again.
lead_supervision_check() {  # <meta> <id>
  local lead_home src="$STATE/.wait-sources/$2.supervision" text
  lead_home=$(jg_meta_get "$1" home 2>/dev/null || true)
  case "$lead_home" in /*) [ -d "$lead_home/state" ] || return 1 ;; *) return 1 ;; esac
  if ! JG_HOME="$lead_home" jg_supervision_unhealthy "$lead_home/state" "$WATCHER_STALE_GRACE"; then
    rm -f "$src"
    return 1
  fi
  [ ! -f "$src" ] || return 1
  text="supervision: squad lead $2 has work under way but its own watcher is not running"
  mkdir -p "$STATE/.wait-sources" && printf '%s\n' "$text" > "$src" || return 1
  steer_task "$2" "lead-supervision-$2-$(date +%s)" \
    "Your own supervision is not running while you have work under way, so your workers' waits reach nobody. Re-arm your supervision now and handle your queued notifications." \
    || triage_log "supervision steer to squad_lead $2 was not recorded"
  if declare -F jg_wait_timer_source_delivered >/dev/null; then
    jg_wait_timer_source_delivered "$2" "$(jg_backend_target_of_meta "$1")" "$text" || return 1
  fi
}

squad_lead_liveness_tick() {
  local tick_marker="$STATE/.squad-lead-liveness-tick"
  [ "$(age_of "$tick_marker")" -ge "$SQUAD_LEAD_LIVENESS_SECS" ] || return 0
  touch "$tick_marker" || return 1
  # Dormant rule first: settle the leads with no open work, then probe. A lead
  # stopped in this same tick is skipped as dormant by the loop below rather
  # than being relaunched straight back.
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-squad-lead-dormant.sh" sweep >/dev/null 2>&1 \
    || triage_log "squad_lead dormant sweep reported a failure; the liveness tick continues"
  local now=$(( $(date +%s) )) meta id kind
  local bound_marker attempts notify_key reason queued err first_reason='' failed=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(jg_meta_get "$meta" kind 2>/dev/null || true)
    [ "$kind" = squad_lead ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    if squad_lead_dormant "$STATE" "$id"; then
      triage_log "squad_lead $id liveness skipped: dormant with no open work (bin/jg-squad-lead-dormant.sh)"
      continue
    fi
    # Parked-home guard (juggernaut-addons/parked-homes): a parked home gets no
    # liveness probe and no auto-relaunch - one triage line names the skip.
    # No-op without the add-on checkout.
    jg_parked_skip_meta "$meta" "$id" watch-liveness && { triage_log "squad_lead $id liveness skipped: its home is parked (config/parked-homes)"; continue; }
    jg_squad_lead_liveness_lock "$id" || continue
    jg_squad_lead_liveness_probe "$meta" "$id" poll
    bound_marker="$STATE/.squad-lead-relaunch-bound-$id"
    reason='' notify_key='' err=''
    case "$JG_SM_LIVE_STATUS" in
      relaunchable)
        if [ -e "$bound_marker" ] || [ -L "$bound_marker" ]; then
          :
        elif ! attempts=$(jg_squad_lead_liveness_recent_attempts "$id" "$SQUAD_LEAD_LIVENESS_WINDOW_SECS"); then
          err="relaunch ledger is unreadable; endpoint left $JG_SM_LIVE_STATE"
        elif [ "$attempts" -ge "$SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS" ]; then
          if printf '%s\t%s\n' "$now" "$JG_SM_LIVE_STATE" > "$bound_marker"; then
            reason="check: squad_lead $id auto-relaunch paused after $SQUAD_LEAD_LIVENESS_MAX_ATTEMPTS attempts in ${SQUAD_LEAD_LIVENESS_WINDOW_SECS}s; endpoint still $JG_SM_LIVE_STATE - relaunch it manually or retire the route"
            notify_key="squad-lead-relaunch-bound-$id"
          else
            err="relaunch park marker could not be written; endpoint left $JG_SM_LIVE_STATE"
          fi
        elif jg_squad_lead_liveness_relaunch "$meta" "$id" "$SQUAD_LEAD_LIVENESS_TIMEOUT"; then
          reason="check: squad_lead $id auto-relaunched after $JG_SM_LIVE_CAUSE ($JG_SM_LIVE_WHERE)"
          notify_key="squad-lead-relaunch-$id-$now"
        elif [ "$JG_SM_LIVE_STATUS" = deferred ]; then
          triage_log "squad_lead $id liveness deferred: $JG_SM_LIVE_REASON"
        elif [ "$JG_SM_LIVE_STATUS" = skipped ]; then
          err=$JG_SM_LIVE_REASON
        else
          reason="check: squad_lead $id auto-relaunch failed after $JG_SM_LIVE_CAUSE: $(jg_sm_live_first_line "$JG_SM_LIVE_OUT")"
          notify_key="squad-lead-relaunch-failed-$id-$now"
        fi
        ;;
      alive)
        if lead_supervision_check "$meta" "$id"; then
          reason="check: squad_lead $id supervision not running while it has work under way; it was told to re-arm, and the wait escalates until it does"
          notify_key="squad-lead-supervision-$id-$now"
        fi
        if [ -e "$bound_marker" ] || [ -L "$bound_marker" ]; then
          if ! jg_squad_lead_liveness_ledger_add "$id" rearmed; then
            err="relaunch ledger is unwritable; auto-relaunch stays paused"
          elif ! rm -f "$bound_marker"; then
            err="relaunch park marker could not be cleared; auto-relaunch stays paused"
          else
            triage_log "squad_lead $id live again; auto-relaunch pause cleared"
          fi
        fi
        ;;
      skipped)
        triage_log "squad_lead $id liveness: $JG_SM_LIVE_REASON"
        ;;
    esac
    if [ -n "$reason" ]; then
      queued=$(jg_wake_queued_keys check)
      if printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1 \
        || jg_wake_append check "$notify_key" "$reason"; then
        [ -n "$first_reason" ] || first_reason=$reason
      else
        err="check wake row could not be queued: $reason"
      fi
    fi
    jg_squad_lead_liveness_unlock "$id"
    if [ -n "$err" ]; then
      echo "watcher: squad_lead $id liveness: $err" >&2
      triage_log "squad_lead $id liveness error: $err" || true
      failed=1
    fi
  done
  [ -z "$first_reason" ] || wake "$first_reason"
  [ "$failed" -eq 0 ]
}

# Consecutive wedge-escalation count for a window past JG_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
JG_WEDGE_DEMAND_INSPECT_COUNT=${JG_WEDGE_DEMAND_INSPECT_COUNT:-3}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. An optional <scope> binds that cadence to its current declaration; callers
# without a scoped declaration keep the timestamp body. Shared by the
# declared-pause absorb and the worktree-write deferral so the two cadences cannot
# drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline. An optional
# <min-age> replaces the cadence as the absorb-age gate for one call (0 lets a
# declared `until` time that has just passed re-surface at once), while the
# throttle keeps the cadence between repeats.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason> [scope] [min-age]
  local win=$1 throttle=$2 age=$3 reason=$4 scope=${5-} min_age=${6:-$PAUSE_RESURFACE_SECS}
  if [ -z "$scope" ] || [ ! -e "$throttle" ] \
    || [ "$(cat "$throttle" 2>/dev/null || true)" = "$scope" ]; then
    [ "$age" -ge "$min_age" ] || return 0
    [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fi
  jg_wake_append stale "$win" "$reason" || exit 1
  if [ -n "$scope" ]; then printf '%s' "$scope" > "$throttle"; else date +%s > "$throttle"; fi
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# jg-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# One wait record, carrying every field a recheck needs to be correct. Emitting
# them together is the point: a recheck that names the wrong human, or asks for
# an action that does not clear the lane, points the reader away from the only
# person who can end the wait, so a new kind of evidence must not be able to
# reach wedge_defer_wait without deciding all of them.
#   <kind>       what the evidence IS, as the recheck names it.
#   <subject>    WHO the wait is on, in the recheck's own words.
#   <whom>       `captain` when that subject is the captain, `supervisor` when
#                it is juggernaut itself, `external` otherwise; this is what
#                applies the away-posture rule below, which only `captain` takes.
#   <action>     the one thing that clears the lane.
#   <age-record> the file whose mtime is when this wait started, or EMPTY when
#                the wait has no written record. Empty is a real answer, not a
#                degraded one: a gate the pipeline parked was never written down
#                by the worker, so there is no honest age to publish and the
#                deferral publishes none.
# The fields are joined with US (\037) rather than TAB because TAB is an IFS
# WHITESPACE character: consecutive tabs collapse under `read`, so a record with
# an empty middle field would not fail to parse, it would SHIFT every later field
# left into another field's position. US is not IFS whitespace, so consecutive
# delimiters yield genuinely empty fields and the record either parses as written
# or fails the deferral's guard.
wait_record() {  # <kind> <subject> <whom> <action> <age-record>
  printf '%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5"
}

# The evidence that a quiet pane is a BOUNDED WAIT rather than a wedge suspect,
# read at the one moment it decides anything: when an escalation is about to
# fire. Two records answer it, and they are independent: the worker's own status
# line - a declared `paused:` external wait, or a verified `captain-held`
# transfer - and, when that line explains nothing, the crew's authoritative
# current state.
#
# The generated brief promises that declaring one buys the long recheck cadence
# instead of a wedge, and the wedge timer is reachable while that declaration
# stands: a crew that declares a wait and then has an active run or busy pane
# attributed to it is handed to the timer as provably-working, and the timer then
# escalates on elapsed idle time alone. The declaration is what the worker said
# about its OWN silence, so it outranks a liveness verdict that only says
# something is running.
#
# A declared clearing time that has ALREADY passed (`paused: ... until <t>`) is
# not evidence: the wait the worker described is over, so it no longer explains
# the silence, and the pane keeps the unchanged schedule. The records are read in
# this order rather than pooled because the routing already guarantees it is the
# right one: a pane whose last line is `paused:` or `captain-held:` reaches this
# timer only through pause_state_class answering `working`, so its crew state is
# a running step, never a parked gate.
#
# The second record is OFF unless the home creates config/wedge-defer-parked-gate,
# and that one guard is what makes an unconfigured home's behaviour identical to
# having no second record at all: it is read before the fold, so no fold or
# crew-state read is spent, no wait record exists to defer on, no recheck wording
# is reachable, and the lane keeps the unchanged escalation schedule, reason and
# demand-deep-inspection wording. Unlike the status line, which is the worker's
# own declaration about its own silence, this record is derived from a pipeline's
# gate state, so which lanes lose the ladder for it is a home's choice to make
# rather than a default every fleet inherits - the same reason
# config/turnend-churn-absorb gates its own widened absorb.
#
# The second record takes TWO signals, and needs both. The crew's authoritative
# current state must be a no-mistakes gate whose answer is owed by a HUMAN
# (crew_gate_awaits_human_decision in jg-classify-lib.sh, minted from the
# findings table's `action` column by position), AND the task's own decision fold
# must still hold an open `needs-decision` record whose key is `nm-<run>-<step>`
# for the run that verdict reports. The gate's table alone says only that the
# answer is owed by a human; the open decision bound to that run is the positive
# evidence that juggernaut was actually told about THIS gate and has not answered
# yet, which is what makes the lane's quiet a wait rather than a suspected wedge.
# An open decision under any other key - an unrelated question never closed - is
# not that evidence, and neither is a verdict that names no run. The wait is owed
# by juggernaut, not the captain: ask-user findings are routed to juggernaut, which
# decides most of them itself, and one it escalates becomes a captain-held
# transfer that the first record above already catches. So the away-posture
# silence does not apply to it: under away posture the supervision branch is the
# actor allowed to answer it, and it is rechecked on the long cadence throughout.
# The two signals come apart in both directions, and the ladder is kept in each:
#   - the decision was ANSWERED and the operator has not yet relayed it with
#     `axi respond`: the gate is still reported parked and still carries the
#     ask-user row, but `jg-send --resolve-key` wrote the closing `resolved` line
#     at answer time, so the fold is empty and what is outstanding is the
#     operator's OWN next move;
#   - the operator parked at a human-owed gate and went quiet before escalating
#     it at all: nobody was ever told, so there is no wait to defer to.
# A `blocked` record does not count: a blocker is not an unanswered gate decision
# and a different action clears it. A gate awaiting the OPERATOR's own answer is
# deliberately NOT evidence either: a operator that goes quiet before answering
# its own gate is exactly the wedge this ladder exists to catch, so those keep
# the unchanged schedule, reason and demand-deep-inspection wording.
# Nothing here weakens detection for a pane with no wait at all - their
# escalation schedule, reason and wording are untouched, and every way this
# signal can come back empty (an unreadable status file, a fold with nothing
# open, a key convention nobody followed) escalates on the unchanged schedule
# rather than losing the ladder. The status-line and fold reads are file reads;
# the crew-state read is the costly one (it may make a bounded no-mistakes call),
# so it is taken only behind a first fold read that finds some open
# `needs-decision` at all, and only in the at-threshold branch - at most once per
# window per STALE_ESCALATE_SECS, never on an ordinary poll.
wedge_wait_evidence() {  # <task> -> one wait_record on stdout
  local task=$1 last until statusf run
  [ -n "$task" ] || return 1
  statusf="$STATE/$task.status"
  last=$(status_declared_wait_line "$statusf")
  if status_is_captain_held "$last"; then
    wait_record 'captain-held' 'awaiting the captain - verified hold transfer' \
      captain 'answer the held decision or release the hold' "$statusf"
    return 0
  fi
  if status_is_paused "$last"; then
    if until=$(status_paused_until "$last"); then
      [ "$(date +%s)" -lt "$until" ] || return 1
    fi
    wait_record 'declared wait' 'awaiting external' \
      external 'confirm the wait still holds' "$statusf"
    return 0
  fi
  [ -e "$CONFIG/wedge-defer-parked-gate" ] || return 1
  if status_has_open_needs_decision "$statusf" \
    && run=$(crew_gate_awaits_human_decision "$task") \
    && status_has_open_needs_decision "$statusf" "$run"; then
    wait_record 'verified wait at a parked gate' "awaiting juggernaut's ask-user decision" \
      supervisor "decide the gate's ask-user finding and relay the decision to the operator" ''
    return 0
  fi
  return 1
}

# Defer ONE wedge escalation for a pane whose wait record explains the quiet
# (wedge_wait_evidence above). Deliberately the same shape as
# wedge_defer_writing: a DEFERRAL, not a cancellation, so the idle timer restarts
# and the next window probes the evidence again - a wait that ends is escalating
# again within one STALE_ESCALATE_SECS, which is why the worst-case detection
# time for a pane that stops waiting does not move.
# Every word of the recheck that could be wrong per kind of evidence - the human
# it names, the action it asks for, the age it publishes - is READ FROM THE
# RECORD rather than re-derived here, so this function cannot word one kind of
# wait as another.
# A wait with a written record is aged from that file, which is when the worker
# wrote the line - anchored there rather than on a per-window marker for the same
# reason handle_paused_stale is: an idle pane churns its display (a clock, a
# token counter), and a marker this deferral kept touching would let that churn
# reset the cadence. A wait with NO written record publishes no age at all: the
# quiet window is the only clock in hand and this deferral resets it on every
# pass, so a number read from it would never grow and would tell a supervisor
# that a day-old gate opened four minutes ago. The bounded re-surface still
# fires, governed by its own throttle instead of by a wait age.
# A CAPTAIN-facing wait is not rechecked at all while the away-posture record
# exists: the one human who can answer it is away, the return brief already lists
# it, and every other captain-facing path in this file absorbs it silently for
# that reason (handle_paused_stale, surface_nonterminal_stale,
# captain_call_stale_bound). That absorb arms no throttle and deliberately
# leaves the idle timer alone: a `captain` whom is minted only by the
# captain-held arm of wedge_wait_evidence, which returns before the
# wedge-defer-parked-gate flag test and therefore before any decision-fold or
# current-state read, so the only read that repeats under the away record is the
# one status-line read that predates this deferral. There is nothing costly to
# throttle there, so the recheck owed on return stays owed in full the moment the
# record is archived rather than starting a cadence nobody could act on. The
# costly parked-gate consult is owed to the supervisor instead, never silenced
# here, and its own deferral restarts the timer below.
# The escalation counter is left alone, exactly as the write deferral leaves it:
# this is not an escalation, and a later genuine one must keep the
# demand-inspection history it had already earned.
wedge_defer_wait() {  # <window> <since-file> <triage-label> <idle-age> <wait-record>
  local win=$1 since_file=$2 label=$3 age=$4 record=$5
  local kind subject whom action anchor key mtime wage min_age waited us ok
  us=$(printf '\037')
  IFS=$us read -r kind subject whom action anchor <<EOF
$record
EOF
  # Enforce the whole of the record's own contract here, which the US delimiter
  # now makes checkable: `kind`, `subject`, `whom` and `action` are each a field
  # the recheck prints and must be non-empty, `whom` is exactly one of the three
  # values the record contract names, only `anchor` may legitimately
  # be empty, and the record holds exactly four delimiters - a surplus one is
  # visible because `read` puts everything past the last field into `anchor`.
  # A record that fails any of these is refused rather than deferred: deferring
  # is what takes the ladder away, so the unparseable case must fall back to the
  # escalation the caller was about to make.
  ok=1
  case "$whom" in
    captain|supervisor|external) ;;
    *) ok=0 ;;
  esac
  case "$anchor" in
    *"$us"*) ok=0 ;;
  esac
  if [ -z "$kind" ] || [ -z "$subject" ] || [ -z "$action" ]; then ok=0; fi
  if [ "$ok" -eq 0 ]; then
    triage_log "refused a malformed wait record for $label: $win"
    return 1
  fi
  key=$(window_key "$win")
  if [ "$whom" = captain ] && away_record_present; then
    triage_log "absorbed $label ($kind, never rechecked while the away-posture record exists): $win"
    return 0
  fi
  mtime=''
  [ -n "$anchor" ] && mtime=$(stat_mtime "$anchor")
  case "$mtime" in
    ''|*[!0-9]*)
      # No readable record of when the wait started - either none exists, or the
      # status file could not be read. Age from the quiet window already in hand
      # and publish nothing: anchoring on the current time instead would
      # recompute the wait age as 0 at every threshold, and the bounded
      # re-surface could then never fire at all - the one outcome this deferral
      # must not produce.
      wage=$age; min_age=0; waited=''
      ;;
    *)
      wage=$(( $(date +%s) - mtime ))
      [ "$wage" -ge 0 ] || wage=0
      min_age=$PAUSE_RESURFACE_SECS; waited=", waiting ${wage}s"
      ;;
  esac
  clear_write_tracking "$key"
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.waiting-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s${waited} - $kind, $subject, rechecked on a long cadence not a wedge; $action)" \
    '' "$min_age"
  triage_log "absorbed $label ($kind explains the quiet, idle ${age}s): $win"
  return 0
}

# Drop a window's write-deferral chain wherever its stale bookkeeping resets, so
# the bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately.
clear_write_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key"
}

# The question the wedge timer never asked before it alarmed: is there still an
# agent here to BE wedged? A wedge is something stuck that might recover, so
# re-alarming it earns its cost; an agent that is gone never moves again, its pane
# never churns, the idle timer never resets, and the escalate path below clears its
# own timer and re-arms with nothing bounding the count.
# docs/architecture.md owns that contract and why only these two verdicts license
# it; what the code needs stated here is the rest.
#
# jg_backend_agent_state (bin/jg-backend.sh) owns the vocabulary and the
# process-level proof behind it. Every verdict short of proof - `alive`,
# `ambiguous`, `unreadable`, `unverified`, or a read that failed outright - keeps
# the unchanged escalation schedule, reason and count, so this narrows WHICH panes
# escalate and never how loudly the ones that still do.
#
# Deliberately NOT a deferral like the two above it. They restart the idle timer
# because the pane might still be working; this is terminal for as long as the
# endpoint stays gone, because there is nothing left to re-probe on a cadence and a
# repeat is exactly the noise it exists to stop. WHICH verdict fired is named for
# the same reason wedge_wait_evidence names its kind of wait: the two ask the supervisor
# for different things.
#
# The marker is owned entirely by this function and records the verdict together
# with the agent incarnation it was reported for: the task's per-incarnation busy
# gen (bin/jg-busy-lib.sh, state/<id>.busy-gen), which changes exactly when the
# agent is replaced, so a repeat is absorbed only while BOTH still match, a read
# that stops being gone still drops it, and no other reset site has to know this
# file exists. The incarnation half re-arms a relaunch: a successor's own later
# death is reported in full even when its dead display hashes identically to the
# reported one. Only when no incarnation token is readable for the task does the
# pane hash stand in as the discriminator - an unreadable token must never mean
# re-report on every threshold, so that fallback keeps today's hash-keyed absorb,
# with the residual that a record-less successor dying into a byte-identical dead
# display stays absorbed. Under one unchanged incarnation a dead pane's static
# display absorbs on every threshold either way.
# Returns 0 when it has handled the window, 1 to escalate on the unchanged path.
wedge_dead_record() {  # <window> <since-file> <triage-label> <idle-age> <pane-hash> <task>
  local win=$1 since_file=$2 label=$3 age=$4 hash=$5 task=$6 key marker agent_state detail reason gen id
  key=$(window_key "$win")
  marker="$STATE/.dead-reported-$key"
  agent_state=$(jg_backend_agent_state "$(window_backend "$win")" "$win" 2>/dev/null) || agent_state=unreadable
  case "$agent_state" in
    dead) detail='the endpoint is still there with no agent running in it' ;;
    missing) detail='the recorded endpoint is gone' ;;
    *) rm -f "$marker"; return 1 ;;
  esac
  # Re-arm the idle timer on BOTH paths below, so the backend probe above stays on
  # its once-per-STALE_ESCALATE_SECS budget instead of running on every poll.
  date +%s > "$since_file"
  id=$hash
  if gen=$(jg_busy_current_gen "$STATE" "$task"); then
    id=$gen
  fi
  if [ "$(cat "$marker" 2>/dev/null || true)" = "$agent_state $id" ]; then
    triage_log "absorbed $label (agent $agent_state, already reported once, idle ${age}s): $win"
    return 0
  fi
  reason="stale: $win (idle ${age}s, agent $agent_state - $detail, so this is not a wedge; reported once and not re-escalated while it stays that way - reconcile this record, and check for unlanded work before any cleanup)"
  # Append before the marker, for the reason stale_wait_record gives: a marker
  # written ahead of a failed append outlives it, and the next sighting would then
  # absorb the retry - the one way this bound could swallow the report outright
  # rather than deliver it once.
  jg_wake_append stale "$win" "$reason" || exit 1
  printf '%s %s' "$agent_state" "$id" > "$marker"
  clear_write_tracking "$key"
  wake "$reason"
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Shared by both places a hash
# can be absorbed this way: the plain non-terminal path, and the
# stale_is_terminal-overridden path (a captain-relevant status-log line that an
# active run/busy pane outranked).
# The wait-evidence consult (wedge_wait_evidence), the worktree write probe, and
# the dead-record probe (wedge_dead_record) run ONLY here, inside the
# at-threshold branch that is about to escalate: at most one each per window per
# STALE_ESCALATE_SECS, never on an ordinary poll. The crew-state read
# wedge_wait_evidence may take under config/wedge-defer-parked-gate keeps that
# same bound however long the wait lasts, because the deferral it feeds restarts
# the idle timer like every other deferral below; an unconfigured home never
# reaches that read at all. The wait consult runs first, because a pane that can
# account for its own quiet has nothing to prove through its worktree. The dead-record probe
# runs last of the three, so the two cheaper deferrals keep the panes they
# already own on their existing bounded cadences and only a pane that would
# otherwise alarm pays for a backend read.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task> <pane-hash>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 hash=$6 since age n reason evidence
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      # Publish the repaired timer only after its old write-deferral chain is
      # gone, so observers cannot mistake a new idle window for the old chain.
      clear_write_tracking "$(window_key "$win")"
      date +%s > "$since_file"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      jg_epoch_seconds_to age
      age=$(( age - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        # A live validation step owns the wait even when its worker's terminal
        # is frozen. Re-read at the threshold, not on every ordinary poll.
        if task_validation_active "$task"; then
          date +%s > "$since_file"
          rm -f "$escalation_file"
          triage_log "absorbed stale (active validation step): $win"
          return 0
        fi
        if evidence=$(wedge_wait_evidence "$task") &&
           wedge_defer_wait "$win" "$since_file" "$label" "$age" "$evidence"; then
          return 0
        fi
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer_writing "$win" "$since_file" "$label" "$age"
          return 0
        fi
        if wedge_dead_record "$win" "$since_file" "$label" "$age" "$hash" "$task"; then
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$JG_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        jg_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_write_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff the newest completed-turn, generation-bound
# progress, or independently observed activity marker is BUSY_TURN_MAX_SECS old.
# jg-watch-progress-lib.sh owns observation; a timer or busy footer is not proof.
# Before those markers exist, age the spawn record. Activity does not fabricate
# a completed turn or change semantic busy state.
# The caller checks busy state and routes a crossed bound through inspection.
busy_turn_over_age() {  # <task> <window-key>
  local task=$1 key=$2 f progress activity
  f="$STATE/$task.turn-ended"
  [ -e "$f" ] || f="$STATE/$task.meta"
  progress="$STATE/$task.progress"
  if [ -f "$progress" ] && [ "$progress" -nt "$f" ]; then f="$progress"; fi
  activity="$STATE/.activity-$key"
  if [ -f "$activity" ] && [ "$activity" -nt "$f" ]; then f="$activity"; fi
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. The bounded re-surface itself is the shared resurface_absorbed
# above, throttled by this window's own .paused-resurfaced-<key> marker. Advances
# the stale suppressor to <hash> and flags the key paused.
#
# The recheck distinguishes the declared dependency from a captain decision:
# the legacy external-wait wording for paused: (bin/jg-classify-lib.sh), and the
# captain themself for a verified hold. Only the captain-held verb takes the second
# wording; a caller that reached the bounded cadence off pause tracking alone, with
# no declaring verb left on the log, keeps the external-wait wording it always had.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age detail reason declaration last until now min_age
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_write_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  now=$(date +%s)
  age=$(( now - mtime ))
  last=$(status_declared_wait_line "$statusf")
  min_age=$PAUSE_RESURFACE_SECS
  declaration="declared:$(jg_wake_signal_sig "$statusf" || true)"
  if status_is_captain_held "$last"; then
    if away_record_present; then
      triage_log "absorbed stale (captain-held, never rechecked while the away-posture record exists): $win"
      return 0
    fi
    detail="captain-held, awaiting the captain"
    reason="captain-held ${age}s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold"
  elif until=$(status_paused_until "$last"); then
    if [ "$now" -lt "$until" ] && [ "$age" -lt "$PAUSE_RESURFACE_SECS" ]; then
      triage_log "absorbed stale (paused until $(( until - now ))s from now, declared time not reached): $win"
      return 0
    elif [ "$now" -lt "$until" ]; then
      detail="paused, declared time beyond recheck cadence"
      reason="paused ${age}s, awaiting external - the declared time is beyond the recheck cadence; confirm the wait still holds"
    else
      # The declared time has passed: recheck now, once per declaration, then
      # hold the cadence.
      detail="paused, declared time reached"
      reason="paused ${age}s, awaiting external - the declared clearing time has passed, rechecked on a long cadence not a wedge; confirm the wait cleared"
      declaration="$declaration:due"
      min_age=0
    fi
  else
    detail="paused, awaiting external"
    reason="paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"
  fi
  resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win ($reason)" "$declaration" "$min_age"
  triage_log "absorbed stale ($detail, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's OWN declared external wait. Prints/queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# 0 when the declared-pause cadence took the pane, 1 when the wedge timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A `paused:` declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS.
# A pane that declared nothing falls through to the shared wedge timer, which,
# in a home that armed config/wedge-defer-parked-gate, applies the same rule to
# the one wait a busy pane cannot declare: a validation gate of its own awaiting
# a supervisor decision that is still open also takes the bounded recheck rather
# than the ladder, because who owes that answer does not depend on what the pane
# is rendering, and the recheck names that supervisor and the action that clears
# it. An unconfigured home keeps the unchanged ladder there.
# Away mode remains daemon-owned and receives the undecorated wake identity for
# its own classification, which is why the declaration is read before the afk
# branch rather than after it.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5 key statusf declared
  statusf="$STATE/$task.status"
  if status_is_paused_or_captain_held "$(status_declared_wait_line "$statusf")"; then
    if afk_present; then
      # Away mode is daemon-owned, so this bound hands off the PLAIN wake identity
      # and lets the daemon classify the declaration itself - the undecorated
      # identity the rest of this function's contract promises. Running the wedge
      # timer here instead would decorate the wake as a possible wedge, and that
      # decoration overrides the daemon's own pause verdict for the pane: the
      # ladder then climbs on every re-arm, escalating a crew that declared the
      # wait itself once per JG_STALE_ESCALATE_SECS for as long as the wait lasts.
      # The one-shot is keyed on the DECLARATION (the status log's signature),
      # never on the pane hash: a busy pane's harness footer ticks on every
      # capture, so a hash-keyed one-shot would re-fire on every poll and the
      # daemon, which relaunches the watcher after each handled wake, would be
      # woken in a loop for the whole declared wait. The suppressor therefore
      # advances to the declaration rather than the hash, and the daemon is woken
      # once per distinct declaration. The wedge timer, escalation count and
      # write-deferral chain are cleared exactly as handle_paused_stale clears
      # them, so an undeclared busy phase that had already started the timer does
      # not resume its count the moment the declaration is lifted. Normal-mode
      # pause tracking stays unwritten here, exactly as the idle away-mode handoff
      # leaves it, because the daemon owns that bookkeeping.
      key=$(window_key "$win")
      rm -f "$since_file" "$escalation_file"
      clear_write_tracking "$key"
      declared="declared:$(jg_wake_signal_sig "$statusf" || true)"
      if captain_held_silenced "$(status_declared_wait_line "$statusf")"; then
        printf '%s' "$declared" > "$STATE/.stale-$key"
        triage_log "absorbed busy over-age pane (captain-held, never rechecked while the away-posture record exists): $win"
        return 0
      fi
      if [ "$(cat "$STATE/.stale-$key" 2>/dev/null || true)" != "$declared" ]; then
        jg_wake_append stale "$win" "stale: $win" || exit 1
        printf '%s' "$declared" > "$STATE/.stale-$key"
        wake "stale: $win"
      fi
      return 0
    fi
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task" "$h"
  return 1
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

# The hash-scoped half of clear_pause_tracking: the stale suppressor, its wedge
# timer and escalation count, and both deferral chains the timer can take - the
# write-deferral chain and the wait-deferral throttle. Split out so a caller
# that must keep a window's DECLARATION-scoped pause state - its .paused-* flag,
# recheck, and re-surface throttle - can still reset the per-hash half alone.
clear_stale_hash_tracking() {  # <window-key>
  local key=$1
  clear_write_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" \
    "$STATE/.waiting-resurfaced-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_stale_hash_tracking "$key"
}

# Phantom-pane prune. The per-window markers this watcher keeps (.hash-,
# .count-, .stale-*, .wedge-escalations-, and their reset bookkeeping) outlive
# the pane they describe: when a pane is closed outside its teardown, or lost
# with its whole herdr workspace, and no task record references it anymore,
# nothing evaluates the pane again - but nothing prunes the markers either, so
# any path that keeps classifying the vanished pane escalates it every
# JG_STALE_ESCALATE_SECS forever (observed live: one vanished pane reached 16+
# demand-deep-inspection escalations after its record was torn down), and a
# later pane that reuses the window key inherits dead bookkeeping such as an
# old wedge-escalation count.
#
# The .tracked-<key> sidecar (window and backend, written once beside the
# window's hash above) is the forward map that makes those markers findable
# once no record names the window. Each poll cycle, every tracked key that no
# meta references gets ONE authoritative verdict from
# jg_backend_target_absent, and only its `absent` verdict prunes: the backend
# answered a read and definitively does not have the pane. `present` keeps the
# markers (an ownerless but live pane is a reconciliation matter, not silent
# state loss), and so does `uncertain` - herdr unreachable, a read timeout, a
# backend with no implementation: only confirmed absence prunes, never an
# uncertain read, because herdr restores its whole session layout on restart
# and a pruned marker cannot tell a restored pane's fresh bookkeeping from a
# wedged one's.
#
# A window any meta references is never pruned here regardless of liveness:
# the record's fate belongs to juggernaut's record reconciliation, and its gone
# agent already has wedge_dead_record's bounded once-only report. The prune
# removes every marker the key owns, including the sidecar itself.
# state/.pruned-panes remembers confirmed absences so old queued prune notices
# can be retired even after their sidecar is gone. It is bounded by key count.
# Pruning is silent: an absent endpoint with no owner is not a task alarm.
pruned_panes_seen() {  # <key>
  [ -s "$STATE/.pruned-panes" ] && grep -qxF -- "$1" "$STATE/.pruned-panes"
}

pruned_panes_record() {  # <key>
  local ledger="$STATE/.pruned-panes" tmp="$STATE/.pruned-panes.next"
  grep -qxF -- "$1" "$ledger" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$ledger" || return 1
  tail -n 1024 "$ledger" > "$tmp" && mv "$tmp" "$ledger"
}

phantom_pane_prune() {
  local tracked key w backend verdict
  for tracked in "$STATE"/.tracked-*; do
    [ -e "$tracked" ] || continue
    key=${tracked##*/.tracked-}
    { IFS=$(printf '\t') read -r w backend; } < "$tracked" || continue
    [ -n "$w" ] && [ -n "$backend" ] || continue
    jg_backend_meta_for_window "$w" "$STATE" >/dev/null 2>&1 && continue
    [ "$(jg_backend_target_absent "$backend" "$w")" = absent ] || continue
    clear_pause_tracking "$key"
    # Withdraw before removing the sidecar, so a failed queue write is retried.
    jg_wake_withdraw stale "$w" || exit 1
    # The sidecar is removed LAST: a failed marker removal leaves it behind so
    # the next cycle retries the whole prune, while a removed sidecar with
    # markers left behind would strand the orphans unfindable.
    rm -f "$STATE/.hash-$key" "$STATE/.count-$key" "$STATE/.churn-since-$key" \
      "$STATE/.dead-reported-$key" "$STATE/.truth-read-$key" "$STATE/.truth-raised-$key" \
      "$STATE/.activity-$key" "$STATE/.activity-observed-$key" "$STATE/.activity-observed-$key.next" || continue
    rm -f "$tracked" || continue
    pruned_panes_record "$key" || true
    triage_log "pruned absent unowned pane: $w"
  done
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# After jg-crew-state has fallen back to stopped or unknown, paused classification is
# recovered only for a confidently dead ordinary crew, or for a squad_lead, whose
# endpoint liveness this function deliberately never reads.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive kind
  key=$(window_key "$win")
  last=$(status_declared_wait_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  # Read once past the declared-wait gate and reused by both liveness gates below,
  # so a mate's stale poll costs one metadata scan rather than one per gate, and the
  # far more common no-declaration path above still costs none.
  kind=$(window_kind "$win")
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$kind" != squad_lead ]; then
      agent_alive=$(jg_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$kind" != squad_lead ]; then
    agent_alive=$(jg_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  # Recover paused classification for a declared wait that authoritative crew state
  # could not name. Reaching here already proves the only two admissible cases: an
  # ordinary crew whose agent the gate above confirmed dead, so no live decision gate
  # is being silenced, or a squad_lead, whose endpoint liveness is deliberately never
  # read and so cannot supply that confirmation. Without the mate case a mate's
  # status-declared `captain-held` transfer - which has no current-state mapping
  # and so arrives as `none` - would be silenced by every caller rather than taking
  # the bounded re-surface cadence, and a forgotten declaration would rot invisibly.
  [ "$class" = none ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# The two records of one ordinary crew wait, and why its stale alarm reads both.
#
# status_is_paused_or_captain_held reads the status LINE a worker wrote, which is
# the only record when the worker itself is waiting. It is not the only record
# there is: once juggernaut hands work to the captain, the wait is written into the
# BACKLOG by bin/jg-captain-hold.sh, and the worker's last line stays whatever it
# was - routinely `done` after a PR delivery, which no line predicate can
# read as a wait. An alarm bounded only by the line therefore re-fires for the
# captain's whole thinking time, on exactly the work they already have in hand.
#
# `open` is that record's own read-only predicate and owns its semantics: exit 0
# still an open captain call, 1 not, 2 could not be established. Only a 0 bounds
# an alarm here, so an unreadable backlog, an incompatible or absent tasks-axi,
# and a row this home does not carry all keep alarming exactly as they do today -
# a wait this watcher cannot prove is not a wait.
#
# The read costs one subprocess and runs only where the watcher is about to
# alarm, so at most once per distinct stale hash per window, beside the crew-state
# read the same paths already pay. The squad_lead stale gate deliberately runs
# before this bound and admits only status-declared waits: a backlog-only hold
# whose mate still says `working:` or `done:` does not reach this read. Reaching
# it would put backlog reads into windows deliberately skipped on ordinary polls.
STALE_WAIT_DECLARATION=

# The identity a re-surface throttle is bound to: the task's whole status-log
# signature. Any new status event - a replacement wait, a fresh delivery, a
# blocker - changes it and so starts its own window instead of inheriting the
# silence of the one before it.
stale_wait_declaration() {  # <task>
  printf 'declared:%s' "$(jg_wake_signal_sig "$STATE/$1.status" || true)"
}

# The same scope for a captain call, carrying the CALL's own lifecycle identity
# beside the status signature. The status log is not enough on its own: a task
# can be answered with `--release` and held again as a genuinely different call
# without any status append, and binding the throttle to the signature alone let
# the second call inherit the first one's silence and absorbed its first sight.
# That first sight is the one alarm this bound must never swallow - a decision
# waiting on the captain that is never surfaced is invisible, where a delivery
# announced twice is merely noise.
captain_call_declaration() {  # <task> <call-identity>
  printf 'captain-hold:%s:%s' "$2" "$(jg_wake_signal_sig "$STATE/$1.status" || true)"
}

# 0 when <declaration> has already been alarmed for this window inside the
# current PAUSE_RESURFACE_SECS. A pure read: recording an alarm is the caller's,
# so the throttle is never advanced by a sighting it just absorbed.
stale_wait_throttled() {  # <window-key> <declaration>
  local throttle="$STATE/.paused-resurfaced-$1"
  [ "$(cat "$throttle" 2>/dev/null || true)" = "$2" ] \
    && [ "$(age_of "$throttle")" -lt "$PAUSE_RESURFACE_SECS" ]
}

# The same bound, for a stale window whose last line IS captain-relevant. That
# line is real and its first sight must still reach the captain, but a delivery
# they are already holding has nothing new to say on the next pane tick.
# Sets STALE_WAIT_DECLARATION to the scope this sighting is bound to, and leaves
# it EMPTY when no open captain call bounds it, so an unheld delivery, a blocker,
# and a failure alarm exactly as they do today.
# Returns 0 to absorb this sighting; 1 to alarm, after which the caller records
# the throttle through stale_wait_record once its own wake append has succeeded.
# Record a fired wake against the bounded cadence, and ONLY after that wake was
# durably appended. A marker written ahead of the append outlives a failed one:
# the watcher exits with no wake queued, and the next sighting reads the fresh
# marker and absorbs the retry, which is the single way this bound could swallow
# an alarm outright rather than delay it.
stale_wait_record() {  # <window-key>
  [ -n "$STALE_WAIT_DECLARATION" ] || return 0
  printf '%s' "$STALE_WAIT_DECLARATION" > "$STATE/.paused-resurfaced-$1"
}

# Bound a due stale alarm for an ordinary crew task held for the captain.
# Backlog-only squad_lead holds are outside this guard because the earlier gate
# preserves their no-backlog-read hot path.
# While the away-posture record exists the bound is absolute: an open captain
# call is never rechecked, whatever the throttle says, because nobody is there
# to answer it and the return brief lists it.
captain_call_stale_bound() {  # <window-key> <task>
  local key=$1 task=$2
  STALE_WAIT_DECLARATION=
  task_captain_call_open "$task" || return 1
  STALE_WAIT_DECLARATION=$(captain_call_declaration "$task" "$CAPTAIN_CALL_IDENTITY")
  away_record_present && return 0
  stale_wait_throttled "$key" "$STALE_WAIT_DECLARATION"
}

# Surface a stale pane no classifier could resolve, so juggernaut inspects it: it
# may have finished through an interactive menu that wrote no status, be waiting on
# a decision, or be wedged. pause_state_class deliberately answers `none` for a
# still-LIVE agent even under a declared wait, so a worker genuinely waiting on a
# decision is never silenced - which routes every parked-but-live worker here, on
# first sight of each distinct stale hash.
#
# So a legitimate wait bounds this path to the same once-per-PAUSE_RESURFACE_SECS
# cadence resurface_absorbed owns for the absorbed paths, throttled by this
# window's own .paused-resurfaced-<key> marker: an idle parked pane still churns
# its hash (a clock, a token counter), and each new hash re-enters this path, so
# without that bound one wait re-alarms juggernaut for its whole duration.
# The FIRST sight still wakes, keeping the inspect-an-inconclusive-state intent,
# and the throttle is read BEFORE anything is queued and advanced only by a wake
# that really fires - a throttle written by the wake it should have prevented, or
# read after that wake was already appended, bounds nothing.
# Both records of an ordinary crew wait bound it (see task_captain_call_open
# above): the status line the worker declared, and the backlog hold juggernaut
# recorded once the captain took the work in hand.
# prompt_gate_check: a pane parked on a permission or trust prompt is stuck at
# once, never left to the wedge timer, and a squad_lead's idle exemption does
# not cover it. bin/jg-prompt-gate-lib.sh owns the verdict, and rung one of the
# escalation chain is answered here: an approval or a rejection is re-proved on
# a fresh capture before its key is sent (an approval is logged first), and a
# rejected worker is steered with the reason. The same prompt still on screen
# within a minute means the answer did not take. While it stays up it is
# answered again every JG_PROMPT_REALERT_SECS (default 600).
# Any prompt left unanswered wakes this home's supervisor once, at first sight,
# and is recorded as a wait source (state/.wait-sources/<task>.prompt, touched
# on every sighting) so the wait-timers chain owns every later rung: re-alerts,
# Main, and the board card (addons/wait-timers/README.md).
# Returns 0 only after an answer was sent, so the caller skips the stale path
# for that poll; a pane left on an unanswered prompt keeps the stale path.
prompt_gate_check() {  # <window> <task> [tail40]
  local w=$1 task=$2 harness backend label key mf src meta verdict again h reason kind act
  local _r path prompt
  harness=$(window_harness "$w")
  jg_prompt_gate_harness "$harness" || return 1
  backend=$(window_backend "$w")
  label=$(window_label "$w")
  key=$(window_key "$w")
  mf="$STATE/.prompt-$key"
  src="$STATE/.wait-sources/$task.prompt"
  meta="$STATE/$task.meta"
  if [ -n "${3-}" ] && ! printf '%s' "$3" | jg_prompt_gate_verdict "$harness" "$JG_HOME" "$STATE" "$CONFIG" "$task" "$meta" | grep -q .; then
    rm -f "$mf" "$src"
    return 1
  fi
  watcher_capture "$backend" "$w" 200 "$label" || return 1
  verdict=$(printf '%s' "$WATCHER_CAPTURE" | jg_prompt_gate_verdict "$harness" "$JG_HOME" "$STATE" "$CONFIG" "$task" "$meta")
  if [ -z "$verdict" ]; then
    rm -f "$mf" "$src"
    return 1
  fi
  h=$(printf '%s' "$verdict" | hash_pane)
  IFS=$'\t' read -r kind _r path prompt <<< "$verdict"
  if [ "$(cat "$mf" 2>/dev/null)" = "wait:$h" ]; then
    if [ "$kind" = card ] || [ "$(age_of "$mf")" -lt "$PROMPT_REALERT" ]; then
      # Rewritten on every sighting: the chain honours the record only while
      # it is fresh, so a prompt on a pane that died lapses by itself.
      mkdir -p "$STATE/.wait-sources" && printf 'prompt: %s; path %s\n' "$prompt" "$path" > "$src" || exit 1
      return 1
    fi
  fi
  if [ "$kind" = approve ] || [ "$kind" = reject ]; then
    act=approval
    [ "$kind" = approve ] || act=rejection
    if [ "$(cat "$mf" 2>/dev/null)" = "$kind:$h" ] && [ "$(age_of "$mf")" -lt 60 ]; then
      _r="$_r; the $act sent under a minute ago did not take"
    else
      watcher_capture "$backend" "$w" 200 "$label" || return 1
      again=$(printf '%s' "$WATCHER_CAPTURE" | jg_prompt_gate_verdict "$harness" "$JG_HOME" "$STATE" "$CONFIG" "$task" "$meta")
      [ "$again" = "$verdict" ] || return 1
      # ponytail: the re-proof and the key are two tmux calls, so a dialog
      # replaced within that one round trip gets the key; tmux has no atomic
      # capture-and-send, and this is the shortest window it allows.
      if [ "$kind" = approve ] && ! jg_prompt_gate_log "$STATE" "$task" "$w" "$harness" "$_r" "$path" "$prompt"; then
        _r="the approval record could not be written"
      elif [ "$kind" = approve ] && jg_backend_send_key "$backend" "$w" Enter "$label" >/dev/null 2>&1; then
        printf 'approve:%s' "$h" > "$mf"
        triage_log "approved permission prompt ($_r): $w $path"
        return 0
      elif [ "$kind" = reject ] && jg_backend_send_key "$backend" "$w" Escape "$label" >/dev/null 2>&1; then
        printf 'reject:%s' "$h" > "$mf"
        triage_log "rejected permission prompt ($_r): $w $path"
        # A key typed right after Escape reads as Alt+key, so the doorbell
        # waits for the terminal to take the Escape alone.
        sleep 1
        steer_task "$task" "prompt-reject-$task-$h-$(date +%s)" \
          "Supervision rejected your permission prompt ($prompt) because $path is a $_r: .env files, ~/.config, and a home's data/ and config/ hold credentials and private records. Do not retry that access; carry on without it, or append blocked: to your status naming what you need." \
          || triage_log "rejection steer to $task was not recorded"
        return 0
      else
        _r="sending the $act key failed"
      fi
    fi
  fi
  mkdir -p "$STATE/.wait-sources" && printf 'prompt: %s; path %s\n' "$prompt" "$path" > "$src" || exit 1
  printf 'wait:%s' "$h" > "$mf"
  reason="stale: $w (permission prompt: $prompt; path $path; not answered: $_r)"
  jg_wake_append stale "$w" "$reason" || exit 1
  if declare -F jg_wait_timer_source_delivered >/dev/null; then
    jg_wait_timer_source_delivered "$task" "$w" "$(head -n 1 "$src" | tr '\t' ' ' | cut -c1-300)" || exit 1
  fi
  wake "$reason"
}

# steer_task: one supervision steer through the durable inbox. A squad_lead
# target needs a fire-and-forget id, or jg-send marks it as a request that
# expects a reply; <seed> makes that id stable for one event.
steer_task() {  # <task> <seed> <text>
  local id
  if [ "$(jg_meta_get "$STATE/$1.meta" kind 2>/dev/null)" = squad_lead ]; then
    id=$(printf '%s' "$2" | hash_pane | cut -c1-16)
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-send.sh" "$1" --fire-and-forget "$id" "$3" >/dev/null 2>&1
  else
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-send.sh" "$1" "$3" >/dev/null 2>&1
  fi
}

# lead_nudge: tell a squad_lead about a wait it owns. A lead busy mid-turn is
# interrupted first (bin/jg-control.sh), so the steer is read now rather than
# after the turn; an idle lead only gets the steer, which rings its doorbell;
# a dead or unreadable one gets the durable steer alone.
lead_nudge() {  # <task> <window> <seed> <text>
  squad_lead_busy_class "$2"
  if [ "$SQUAD_LEAD_BUSY_CLASS" = busy ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-control.sh" "$1" interrupt >/dev/null 2>&1 \
      || triage_log "interrupt of squad_lead $1 failed"
  fi
  steer_task "$1" "$3" "$4"
}

surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last declared=1 bounded=1 throttled=1 until now
  key=$(window_key "$win")
  task=$(window_to_task "$win" "$STATE")
  last=$(status_declared_wait_line "$STATE/$task.status")
  STALE_WAIT_DECLARATION=
  if status_is_paused "$last"; then
    declared=0
    bounded=0
    STALE_WAIT_DECLARATION=$(stale_wait_declaration "$task")
    if until=$(status_paused_until "$last"); then
      now=$(date +%s)
      if [ "$now" -lt "$until" ]; then
        throttled=0
      else
        STALE_WAIT_DECLARATION="$STALE_WAIT_DECLARATION:due"
        stale_wait_throttled "$key" "$STALE_WAIT_DECLARATION" && throttled=0
      fi
    else
      stale_wait_throttled "$key" "$STALE_WAIT_DECLARATION" && throttled=0
    fi
  elif status_is_captain_held "$last"; then
    declared=0
    bounded=0
    STALE_WAIT_DECLARATION=$(stale_wait_declaration "$task")
    if captain_held_silenced "$last"; then
      throttled=0
    else
      stale_wait_throttled "$key" "$STALE_WAIT_DECLARATION" && throttled=0
    fi
  elif captain_call_stale_bound "$key" "$task"; then
    bounded=0
    throttled=0
  elif [ -n "$STALE_WAIT_DECLARATION" ]; then
    bounded=0
  fi
  if [ "$throttled" -ne 0 ]; then
    jg_wake_append stale "$win" "stale: $win" || exit 1
    stale_wait_record "$key"
  fi
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_write_tracking "$key"
  if [ "$declared" -eq 0 ]; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
  elif [ "$bounded" -eq 0 ]; then
    # A backlog hold is NOT a declared pause, and must not be dressed up as one:
    # the loop-top reconciliation and pause_state_class both read the status LINE,
    # so a .paused-* flag this line does not support would be cleared on the next
    # poll - taking the throttle with it - and would hand the mate and dead-agent
    # cadences a declaration they were never given. Only the shared re-surface
    # marker is kept, which is the whole of what this bound needs.
    rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key"
  else
    clear_pause_state "$key"
  fi
  if [ "$throttled" -eq 0 ]; then
    triage_log "absorbed non-terminal stale (declared wait or open captain call already re-surfaced this window): $win"
    return 0
  fi
  wake "stale: $win"
}

# A worker's `paused:` line is its own claim about its silence, and authoritative
# crew state outranks it. A no-mistakes run parked at a gate holds
# no pending drive call - the call returns at the gate - so an idle pane under
# such a claim is a lane nothing will resume: either juggernaut owes an ask-user
# decision or the worker owes its own gate answer, and its drive process may be
# gone. Without this check the claim buys the declared-wait cadence (hours) after
# one bare stale that names nothing, so the supervisor learns the truth only when
# a human notices. A `working:` claim needs no such check: it never buys that
# cadence, so the existing first-sight surface and wedge ladder already reach it. A gate the worker escalated as an open run-bound decision is
# not contradicted: juggernaut already holds it. Wakes ONCE per (status signature, crew-state line), naming the
# task and the real state; a new status append or a new gate state may wake
# again. The jg-crew-state.sh read is costly, so it is taken at most once per
# STALE_ESCALATE_SECS per window unless the status log changed. A claim with no
# contradicting run state keeps every existing path, including the 4 h recheck.
declared_wait_contradiction() {  # <window> <task> <window-key>
  local win=$1 task=$2 key=$3 statusf sig read_marker raised state reason
  statusf="$STATE/$task.status"
  status_is_paused "$(status_declared_wait_line "$statusf")" || return 0
  sig=$(jg_wake_signal_sig "$statusf" || true)
  read_marker="$STATE/.truth-read-$key"
  if [ "$(cat "$read_marker" 2>/dev/null || true)" = "$sig" ] \
    && [ "$(age_of "$read_marker")" -lt "$STALE_ESCALATE_SECS" ]; then
    return 0
  fi
  printf '%s' "$sig" > "$read_marker"
  state=$("$JG_CREW_STATE_BIN" "$task" 2>/dev/null) || true
  case "$state" in "state: parked · source: run-step · "?*) ;; *) return 0 ;; esac
  # A gate the worker already escalated under its run-bound key is one juggernaut
  # was told about; wedge_wait_evidence owns that verified wait.
  case "$state" in
    *" · run: "?*) status_has_open_needs_decision "$statusf" "${state##* · run: }" && return 0 ;;
  esac
  raised="$STATE/.truth-raised-$key"
  [ "$(cat "$raised" 2>/dev/null || true)" != "$sig $state" ] || return 0
  reason="stale: $win (task $task says paused, but its run is ${state#state: parked · source: run-step · } - a parked gate holds no pending drive call, so nothing resumes this lane until juggernaut decides or steers)"
  jg_wake_append stale "$win" "$reason" || exit 1
  printf '%s' "$sig $state" > "$raised"
  wake "$reason"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m now
  m=$(stat_mtime "$f") || { echo 999999; return; }
  jg_epoch_seconds_to now
  [ "$m" -le "$now" ] || { echo 999999; return; }
  echo $(( now - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers.
# Each file is compared against its persisted reported signature in .seen-* rather
# than mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one and same-second writes cannot slip through a strict
# -nt comparison.
# Status signatures include observable file and readability state, while turn-end
# markers retain their size-and-mtime signature.
# A status file is asked the wider wake question instead, so it also stays quiet
# when the only bytes it grew past the classified offset are this home's own
# bookkeeping appends; jg_wake_signal_seen_current (bin/jg-wake-lib.sh) owns that
# rule and every other signature change still reads as unreported.
#
# A path a signal batch may name. Cleaning up a finished lane removes its status
# record for good, so a path detached between detection and classification is
# dropped rather than reported: nothing can be read from it, and a wake about it
# would name a path that no longer exists. The deliberate exception is a dangling
# *.status symlink, whose link is the evidence that the record still belongs to a
# live lane.
reportable_signal_path() { # <path>
  [ -e "$1" ] && return 0
  case "$1" in *.status) [ -L "$1" ] ;; *) return 1 ;; esac
}

# Pure read: prints one "<seen-file>\t<sig>\t<file>" line per changed file.
# The caller records reported state only after surfacing or intentional absorption,
# and commits a status classification position only after a successful span read.
scan_signals() {
  local f sig sf exclude
  # A remote mate's own parent channel is not a self-home task status log; the
  # home-shape-aware exclusion and its precedent live in
  # status_scan_parent_channel_exclude (jg-classify-lib.sh).
  exclude=$(status_scan_parent_channel_exclude "$STATE")
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ "$f" = "$exclude" ] && continue
    reportable_signal_path "$f" || continue
    sig=$(jg_wake_signal_sig "$f") || continue
    [ -n "$sig" ] || continue
    sf=$(jg_wake_signal_seen_path "$STATE" "$f")
    case "$f" in
      *.status) jg_wake_signal_seen_current "$STATE" "$f" && continue ;;
      *) [ "$sig" = "$(cat "$sf" 2>/dev/null)" ] && continue ;;
    esac
    printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
  done
  return 0
}

# Merge the pre-grace signal scan with its post-grace re-scan into ONE batch. A
# file the re-scan reports again supersedes its earlier observation (last write
# wins, the same rule the marker commits below and the drain's own same-key
# collapse follow), because the re-scan exists precisely to coalesce one crew's
# two writes into one reported event. Without this the batch names that file
# twice and EVERY consumer writes one durable row per occurrence - so a single
# coalesced lane event lands in the wake queue as two rows, inflating its depth
# and inviting a repeated wake for work already reported.
signal_batch_merge() {  # <pre-grace-rows> <re-scan-rows>
  printf '%s\n%s\n' "$1" "$2" | awk -F '\t' '
    NF >= 3 {
      if (!($3 in seen)) order[++count] = $3
      seen[$3] = 1
      line[$3] = $0
    }
    END { for (i = 1; i <= count; i++) print line[order[i]] }
  '
}

# Deliver a durably queued process-event result to juggernaut. Publication is
# owned by bin/jg-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake juggernaut, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason captured="" stranded="" unstarted=""
  PROCEVENT_SURFACED=
  [ -s "$JG_WAKE_QUEUE" ] || return 0
  jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
  while IFS= read -r key; do
    case "$key" in procevent:*) ;; *) continue ;; esac
    [ -e "$(procevent_surfaced_marker "$key")" ] && continue
    PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
    # A stranded source or one whose launch never proved itself is the opposite
    # of a captured result: nothing is collecting for it. Headlining either as
    # a capture would present it as healthy, which is the shape of defect
    # these wakes exist to surface.
    case "$key" in
      procevent:*:stranded:*) stranded="$stranded $key" ;;
      procevent:*:launch-failed:*) unstarted="$unstarted $key" ;;
      *) captured="$captured $key" ;;
    esac
  done < <(jg_wake_queued_keys_locked check)
  if [ -z "$PROCEVENT_SURFACED" ]; then
    jg_lock_release "$JG_WAKE_QUEUE_LOCK"
    return 0
  fi
  reason="check:"
  [ -z "$captured" ] || reason="$reason process-event result captured:$captured"
  if [ -n "$stranded" ]; then
    [ "$reason" = "check:" ] || reason="$reason;"
    reason="$reason process-event source stranded:$stranded"
  fi
  if [ -n "$unstarted" ]; then
    [ "$reason" = "check:" ] || reason="$reason;"
    reason="$reason process-event source failed to start:$unstarted"
  fi
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  JG_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${JG_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${JG_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${JG_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

JG_ACTIVE_CHECK_PID=
JG_ACTIVE_CHECK_PGID=
JG_CHECK_OUTPUT=
JG_CHECK_RESULT=
JG_CHECK_SIGNAL_PENDING=

jg_check_output_cleanup() {
  [ -z "$JG_CHECK_OUTPUT" ] || rm -f -- "$JG_CHECK_OUTPUT"
  JG_CHECK_OUTPUT=
}

jg_active_check_stop() {
  local pid=${JG_ACTIVE_CHECK_PID:-} pgid=${JG_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  JG_ACTIVE_CHECK_PID=
  JG_ACTIVE_CHECK_PGID=
}

# Stop-signal dispositions, installed with the EXIT trap below. HUP and TERM
# keep bash's native fatal-signal handling, which runs watcher_cleanup through
# the EXIT trap and then exits on every supported bash. A trap body such as
# 'exit 1' is not reliable for them: bash 5.2 runs a pending trap inside the
# parse of the next command substitution, the body then fails to parse ("trap:
# line 2: unexpected EOF while looking for matching `)'", or nothing at all),
# and the signal is consumed, so a stop request could leave this watcher
# polling forever while its stopper waits (fixed upstream in bash 5.3). Bash
# 3.2 holds HUP and TERM until a running command substitution's child exits, so
# jg_backend_capture pane reads go through watcher_capture instead. INT keeps
# its trap because bash ignores a direct SIGINT while a child runs.
watcher_stop_signals() {
  trap - HUP TERM
  trap 'exit 1' INT
}

run_check_capture() {
  local pgid
  jg_check_output_cleanup
  JG_CHECK_RESULT=
  JG_CHECK_OUTPUT=$(mktemp "$STATE/.jg-check-output.XXXXXX") || return 1
  chmod 0600 "$JG_CHECK_OUTPUT" || { jg_check_output_cleanup; return 1; }
  JG_CHECK_SIGNAL_PENDING=
  # Defer stop signals only until the check's process group is recorded for
  # watcher_cleanup. Keep command substitutions out of this window: bash 5.2
  # can drop a trap that is pending when one is parsed (watcher_stop_signals).
  trap 'JG_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( JG_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$JG_CHECK_OUTPUT" 2>/dev/null &
  JG_ACTIVE_CHECK_PID=$!
  JG_ACTIVE_CHECK_PGID=$JG_ACTIVE_CHECK_PID
  set +m
  watcher_stop_signals
  [ -z "$JG_CHECK_SIGNAL_PENDING" ] || exit 1
  pgid=$(ps -o pgid= -p "$JG_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" != "$JG_ACTIVE_CHECK_PGID" ]; then
    jg_active_check_stop || true
    jg_check_output_cleanup
    return 1
  fi
  wait "$JG_ACTIVE_CHECK_PID" 2>/dev/null || true
  JG_ACTIVE_CHECK_PID=
  jg_active_check_stop || return 1
  JG_CHECK_RESULT=$(cat "$JG_CHECK_OUTPUT" 2>/dev/null || true)
  jg_check_output_cleanup
}

JG_CAPTURE_OUTPUT=
WATCHER_CAPTURE=

jg_capture_output_cleanup() {
  [ -z "$JG_CAPTURE_OUTPUT" ] || rm -f -- "$JG_CAPTURE_OUTPUT"
  JG_CAPTURE_OUTPUT=
}

# watcher_capture: jg_backend_capture into WATCHER_CAPTURE with its exit status.
# The read runs as a waited background process group rather than inside $(...),
# so a stop is not held for a blocked read (watcher_stop_signals). The group is
# recorded like a check's, so watcher_cleanup stops a read still in flight.
watcher_capture() {  # <backend> <target> <lines> [expected-label]
  local rc pgid
  jg_capture_output_cleanup
  WATCHER_CAPTURE=
  JG_CAPTURE_OUTPUT=$(mktemp "$STATE/.jg-capture-output.XXXXXX") || return 1
  JG_CHECK_SIGNAL_PENDING=
  trap 'JG_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  # The group's stderr is redirected before the fork: bash 3.2 on macOS can
  # print a harmless "child setpgid ... Operation not permitted" race from the
  # child before the command's own redirections apply.
  set -m
  { jg_backend_capture "$@" < /dev/null > "$JG_CAPTURE_OUTPUT" & } 2>/dev/null
  JG_ACTIVE_CHECK_PID=$!
  JG_ACTIVE_CHECK_PGID=$JG_ACTIVE_CHECK_PID
  set +m
  watcher_stop_signals
  [ -z "$JG_CHECK_SIGNAL_PENDING" ] || exit 1
  pgid=$(ps -o pgid= -p "$JG_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$pgid" ] && [ "$pgid" != "$JG_ACTIVE_CHECK_PGID" ]; then
    jg_active_check_stop || true
    jg_capture_output_cleanup
    return 1
  fi
  wait "$JG_ACTIVE_CHECK_PID"
  rc=$?
  JG_ACTIVE_CHECK_PID=
  jg_active_check_stop || { jg_capture_output_cleanup; return 1; }
  WATCHER_CAPTURE=$(cat "$JG_CAPTURE_OUTPUT" 2>/dev/null || true)
  jg_capture_output_cleanup
  return "$rc"
}

# 0 when any signaled status file carries a captain-relevant event in the bytes
# appended since this watcher last classified it. The start offset is the
# classified-position field in that file's .seen-* marker, and jg-classify-lib.sh's
# status-span contract owns both that format and what counts as actionable in
# the span. Reading the SPAN rather than the last line is what stops a later
# routine append - a `working:` note landing inside SIGNAL_GRACE below - from
# hiding the `needs-decision`, `blocked`, `failed`, or `done` event that arrived
# just before it: the .seen-* marker advances either way, so an event absorbed
# here is never re-read. Non-.status arguments (.turn-ended markers, which carry
# no verb) are skipped. A 1 here is NOT "benign" on its own: a no-verb signal,
# including a newly declared captain hold, still needs the authoritative working
# proof or the eligible opt-in bare turn-end pane-churn proof before it is benign.
# Also populates JG_SIGNAL_NEEDS_DECISION_FILES (space-separated status-file
# paths) with exactly the files whose newly classified span carries one of the
# decision-owned classes defined by the status-span contract, so the caller can
# route those - and only those - signal rows as main-only
# (docs/pi-supervision-branch.md). Stale and heartbeat rows retain their existing
# eligibility rules.
signal_files_actionable() {  # <status-file> ...
  local f task record rest endpoint ident needs_decision rc found=1
  JG_SIGNAL_SURFACE_ENDPOINTS=''
  JG_SIGNAL_NEEDS_DECISION_FILES=''
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || [ -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    record=''; needs_decision=0
    status_span_first_actionable_record "$f" \
      "$(jg_wake_signal_seen_size "$STATE" "$f")" record needs_decision
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      # Could not classify this log. Surface it rather than absorbing it, and
      # record NO classified endpoint for it below, so its content is classified
      # again once it is readable. The wake signature still advances, which is
      # what bounds this to one report per distinct file state.
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    JG_SIGNAL_SURFACE_ENDPOINTS="${JG_SIGNAL_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    if [ "$needs_decision" -eq 1 ]; then
      JG_SIGNAL_NEEDS_DECISION_FILES="${JG_SIGNAL_NEEDS_DECISION_FILES} ${f}"
    fi
    if [ "$rc" -eq 0 ] || [ "$needs_decision" -eq 1 ]; then
      found=0
    fi
  done
  return "$found"
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# jg-push-transition-lib.sh because push and poll paths must write one format.
# Mark each actionable status log through the endpoint captured by the heartbeat
# scan. Called after the backstop enqueues its wake, so the same events are not
# re-surfaced by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f endpoint ident rc=0
  while IFS=$(printf '\t') read -r f endpoint ident; do
    [ -n "$f" ] || continue
    if [ "$endpoint" = ERROR ]; then
      mark_surface_reported "$f" "$ident" || rc=1
    else
      mark_surfaced "$f" "$endpoint" "$ident" || rc=1
    fi
  done <<EOF
$JG_HEARTBEAT_SURFACE_ENDPOINTS
EOF
  return "$rc"
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any status log carries a captain-relevant event past the position already
# surfaced to juggernaut (.hb-surfaced-<task>). It walks every log rather than only
# those whose LAST line looks captain-relevant, because the event this backstop
# most needs to catch is precisely one a later routine append has already moved
# past. Pure detect, no side effects: the caller enqueues first, then marks
# surfaced. Because every captain-relevant signal/stale already marks itself
# surfaced when it wakes juggernaut, this normally finds nothing and the heartbeat
# is absorbed; it surfaces only an event the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task record rest endpoint ident rc found=1 sig marker exclude
  # Same self-home exclusion as scan_signals: a remote mate's parent channel
  # must not come back through the heartbeat fail-safe backstop.
  exclude=$(status_scan_parent_channel_exclude "$STATE")
  JG_HEARTBEAT_SURFACE_ENDPOINTS=''
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    record=$(status_span_first_actionable_record "$f" "$(hb_surfaced_offset "$task")")
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      sig=$(status_observed_signature "$f")
      marker=$(_hb_surfaced_path "$task")
      status_presentation_marker_reported_matches "$marker" "$sig" && continue
      JG_HEARTBEAT_SURFACE_ENDPOINTS="${JG_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"ERROR"$'\t'"${sig}"$'\n'
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}; rest=${record#*$'\t'}; ident=${rest%%$'\t'*}
    JG_HEARTBEAT_SURFACE_ENDPOINTS="${JG_HEARTBEAT_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    [ "$rc" -eq 0 ] && found=0
  done
  return "$found"
}

# config/lane-target: one positive integer, the per-home lane floor. Prints it
# and returns 0 only for a regular file holding exactly that; an absent,
# unreadable, or malformed file returns 1 and is never treated as a number, so
# the caller falls back to the no-worker-working rule.
lane_target_value() {
  local path=$JG_HOME/config/lane-target raw
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  raw=$(awk 'NF { print }' "$path" 2>/dev/null) || return 1
  case "$raw" in ''|*"$'\n'"*) return 1 ;; esac
  case "$raw" in *[!0-9]*) return 1 ;; esac
  [ "$raw" -gt 0 ] || return 1
  printf '%s\n' "$raw"
}

# Open lanes: every state/<task>.meta whose kind is ship (the default when a
# meta omits it) or scout. A squad_lead endpoint's own meta (kind=squad_lead) is
# not a lane of this home, so it never counts toward the floor.
# Fork hook (thin layer over upstream): the fleet-flow add-on owns the rule that
# a lane parked on a stale external wait stops counting toward the cap, so when
# its installed check is present its `counted` column is the open-lane number and
# this home never re-derives it. Absent, erroring, timing out, or a malformed row
# falls back to the meta count below, byte-for-byte upstream behaviour; the
# counting rule stays in the add-on, not here.
open_lane_count() {
  local check counted meta kind count=0
  check=${XDG_DATA_HOME:-$HOME/.local/share}/jg-fleet-flow/jg-flow-check.sh
  if [ -f "$check" ] && [ -x "$check" ] \
    && counted=$(jg_run_timed "${JG_FLOW_CHECK_TIMEOUT_SECS:-10}" "$check" "$JG_HOME" --summary 2>/dev/null); then
    counted=$(printf '%s\n' "$counted" | awk -F '\t' 'NF == 9 && NR == 1 { print $8 }')
    case "$counted" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$counted"; return 0 ;;
    esac
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)
    case "${kind:-ship}" in
      ship|scout) count=$((count + 1)) ;;
    esac
  done
  printf '%s\n' "$count"
}

# A malformed config/lane-target is reported once per distinct content, never
# every heartbeat and never as a number.
warn_invalid_lane_target_once() {
  local marker=$STATE/.ready-work-lane-target-invalid current
  current=$(cat "$JG_HOME/config/lane-target" 2>/dev/null) || current=unreadable
  [ "$(cat "$marker" 2>/dev/null)" = "$current" ] && return 0
  printf '%s' "$current" > "$marker" 2>/dev/null || true
  triage_log "lane-target is not a positive integer; using the no-worker-working rule instead"
}

# Base-cadence idle-home check: 0 when this home (primary or squad_lead) has
# dispatchable queued work and sits below its lane floor, so ready work is
# started without anyone asking. With
# config/lane-target naming a positive integer N, the floor is fewer than N open
# lanes, and a home with working workers but free slots is exactly the 5 Oct
# stall that the no-worker-working rule missed. Otherwise (no usable target, or
# open lanes at or above it) the rule is the older one: no worker is provably
# working, so open lanes that only wait never hide an idle home. A condition
# that still holds re-raises on READY_WORK_RESURFACE_SECS; a new ready set
# fires at once. Sets
# READY_WORK_IDS and READY_WORK_REASON. An empty ready set withdraws any queued
# ready-work notification so a stale prompt stops being presented, while its
# resurface record is kept so a transient empty set (every ready item briefly
# held or in flight) cannot reset the re-raise window. Intake is independent of
# the heartbeat's idle backoff and runs before an away heartbeat can exit.
ready_work_waits_idle() {
  local meta task target open now surfaced surfaced_at surfaced_ids ready_rc freed
  READY_WORK_IDS=
  READY_WORK_REASON=
  READY_WORK_IDS=$(jg_ready_work_ids "$JG_HOME")
  ready_rc=$?
  if [ -z "$READY_WORK_IDS" ]; then
    # A non-zero status means the backlog could not be read, not that the
    # condition is false, so leave the queued row for the next cycle instead of
    # withdrawing a valid notification on a transient read failure.
    [ "$ready_rc" -eq 0 ] || return 1
    # The condition no longer holds: withdraw any queued ready-work notification
    # so it stops being presented instead of naming items since held or put in
    # flight until an acknowledgement that may never come. Keep the resurface
    # record so this transient empty set cannot reset the re-raise window and
    # let the identical set fire again the moment it returns.
    jg_wake_withdraw check ready-work || true
    return 1
  fi
  target=$(lane_target_value) || target=
  if [ -z "$target" ] && [ -f "$JG_HOME/config/lane-target" ]; then
    warn_invalid_lane_target_once
  fi
  if [ -n "$target" ] && open=$(open_lane_count) && [ "$open" -lt "$target" ]; then
    READY_WORK_REASON="check: ready work waiting with free lane slots ($open/$target open): $READY_WORK_IDS - dispatch them now, P0 first, up to project capacity"
  else
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      task=${meta##*/}
      crew_is_provably_working "${task%.meta}" && return 1
    done
    READY_WORK_REASON="check: ready work waiting with no worker working: $READY_WORK_IDS - dispatch them now, P0 first, up to project capacity"
  fi
  # Re-raise gate: a new ready set fires at once; the same still-holding set only
  # again after READY_WORK_RESURFACE_SECS. A record without a usable timestamp
  # (the pre-timestamp format, or a rewound clock) counts as never surfaced.
  jg_epoch_seconds_to now
  surfaced=$(cat "$STATE/.ready-work-surfaced" 2>/dev/null) || surfaced=
  case "$surfaced" in
    *$'\t'*) surfaced_at=${surfaced%%$'\t'*}; surfaced_ids=${surfaced#*$'\t'} ;;
    *) surfaced_at=0; surfaced_ids=$surfaced ;;
  esac
  [ "$surfaced_ids" != "$READY_WORK_IDS" ] && return 0
  case "$surfaced_at" in ''|*[!0-9]*) surfaced_at=0 ;; esac
  # A place freed since this set was surfaced makes the wake actionable now, so
  # the resurface window does not hold it back. bin/jg-teardown.sh and
  # bin/jg-pr-check.sh write state/.capacity-freed; this read is the contract.
  freed=$(cat "$STATE/.capacity-freed" 2>/dev/null) || freed=
  case "$freed" in ''|*[!0-9]*) freed=0 ;; esac
  [ "$freed" -gt "$surfaced_at" ] && return 0
  [ "$(( now - surfaced_at ))" -ge "$READY_WORK_RESURFACE_SECS" ]
}

# A launch refused for host memory leaves state/admission-refused and nothing
# retries it. The newest sampler verdict is the measurement admission reads, so
# fire once per record the moment it admits launches again; a home with no
# sampler stays silent rather than inventing one. bin/jg-jev-mem-guard.sh owns
# the verdict and the record.
admission_retry_waits_memory() {
  local record epoch task verdict seen
  record=$(cat "$STATE/admission-refused" 2>/dev/null) || return 1
  [ -n "$record" ] || return 1
  epoch=$(printf '%s\n' "$record" | cut -f1)
  task=$(printf '%s\n' "$record" | cut -f2)
  verdict=$(awk -F '\t' 'NF >= 5 && $5 != "" { v = $5 } END { print v }' \
    "$STATE/host-memory.tsv" 2>/dev/null) || verdict=
  case "$verdict" in OK|UNKNOWN) ;; *) return 1 ;; esac
  ADMISSION_RETRY_KEY="$epoch:$task"
  seen=$(cat "$STATE/.admission-retry-surfaced" 2>/dev/null) || seen=
  [ "$seen" != "$ADMISSION_RETRY_KEY" ] || return 1
  ADMISSION_RETRY_REASON="check: host memory admits launches again, so retry the launch of ${task:-a queued task} refused at ${epoch} (bin/jg-spawn.sh clears the refusal record on success)"
  return 0
}

# The stalled-backlog condition the wait-timers chain escalates
# (addons/wait-timers/README.md "Stalled ready backlog"): this squad_lead home
# has a ready item that could start now, and either a free lane or no worker
# provably working. A free lane is fewer open lanes than config/lane-target, or
# than 4 without a usable one. A home at its floor is still stalled when no
# worker is provably working (the ready-work wake's "no worker working" case),
# because lanes that only wait on a merge or a cleanup must not hide an idle
# lead. An item could start now unless its project's declared capacity is
# already held (bin/jg-project-capacity-lib.sh). Sets READY_STALL_IDS (startable
# ids, P0 first), READY_STALL_OPEN, READY_STALL_TARGET, READY_STALL_MODE
# (free-lanes or no-worker), and READY_STALL_LANES (the open lane ids,
# comma-joined, so the chain can see a start). When ready work exists but the
# condition does not hold, READY_STALL_WHY names the reason (lanes-working or
# project-capacity). Returns 0 when the condition holds, 1 when it does not,
# and 2 when the backlog cannot be read, so an unknown poll never clears or
# fires an episode.
ready_backlog_stall_state() {
  local rows rc id repo proj cfg seen='|' full='|' meta kind
  READY_STALL_IDS='' READY_STALL_OPEN='' READY_STALL_TARGET='' READY_STALL_LANES='' READY_STALL_MODE='' READY_STALL_WHY=''
  [ -f "$(jg_compat_marker "$JG_HOME")" ] && [ ! -L "$(jg_compat_marker "$JG_HOME")" ] || return 1
  rows=$(jg_ready_work_rows "$JG_HOME"); rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$rows" ] || return 1
  READY_STALL_TARGET=$(lane_target_value) || READY_STALL_TARGET=4
  READY_STALL_OPEN=$(open_lane_count) || return 2
  READY_STALL_MODE=free-lanes
  if [ "$READY_STALL_OPEN" -ge "$READY_STALL_TARGET" ]; then
    READY_STALL_MODE=no-worker
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      if crew_is_provably_working "${id%.meta}"; then READY_STALL_WHY=lanes-working; return 1; fi
    done
  fi
  cfg=$(jg_project_capacity_config_dir "$JG_HOME" "$CONFIG" 2>/dev/null) || cfg=
  while read -r id repo; do
    [ -n "$id" ] || continue
    proj="$JG_HOME/projects/$repo"
    if [ -n "$cfg" ] && [ "$repo" != - ] && [ -d "$proj" ]; then
      case "$seen" in
        *"|$repo|"*) ;;
        *)
          seen="$seen$repo|"
          # A declaration or holder count that cannot be read keeps the item:
          # nothing then starts at all, which is exactly what must escalate.
          if jg_project_capacity_lookup "$cfg" "$repo" && [ -n "$JG_PROJECT_CAPACITY" ] \
            && jg_project_capacity_occupants "$(jg_treehouse_project_lock_path "$proj" 2>/dev/null)" "$proj" "$STATE" "" \
            && [ "$JG_PROJECT_CAPACITY_OCCUPANTS" -ge "$JG_PROJECT_CAPACITY" ]; then
            full="$full$repo|"
          fi
          ;;
      esac
      case "$full" in *"|$repo|"*) continue ;; esac
    fi
    READY_STALL_IDS="${READY_STALL_IDS:+$READY_STALL_IDS }$id"
  done <<EOF
$rows
EOF
  [ -n "$READY_STALL_IDS" ] || { READY_STALL_WHY=project-capacity; return 1; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(jg_meta_get "$meta" kind 2>/dev/null || true)
    case "${kind:-ship}" in
      ship|scout) id=${meta##*/}; READY_STALL_LANES="${READY_STALL_LANES:+$READY_STALL_LANES,}${id%.meta}" ;;
    esac
  done
  return 0
}

# Records the ready set just surfaced with its epoch, after the wake was
# enqueued, so the re-raise gate above is answerable on the next heartbeat.
record_ready_work_surfaced() {
  local now
  jg_epoch_seconds_to now
  printf '%s\t%s\n' "$now" "$READY_WORK_IDS" > "$STATE/.ready-work-surfaced"
}

# Thin hook for the ask-default add-on, which owns every
# decision: for each ask it recorded that has not been defaulted yet, run
# `ask-default decide` and let it apply the ask's safe default when the captain
# is unreachable and the ask's clock has run out. Located like the other add-on
# shims (JG_ADDONS_DIR, else the in-repo addons/, else the pre-fold clone at
# $JG_HOME/projects/juggernaut-addons); with the
# add-on absent this returns at once, writing nothing, and the loop is unchanged.
# Runs once per CHECK_INTERVAL. The probe reads the away record: the captain is
# reachable unless an away record (never quiet mode's) exists. Held, waiting, and
# reachable asks stay exactly as they are; a decide error is logged, never a wake.
# Sets ASK_DEFAULT_REASON and returns 0 when at least one ask was just defaulted.
ask_default_tick() {
  local tool rec id out rc ids='' probe
  tool=$(jg_addon_path "$JG_HOME" ask-default/ask-default)
  [ -x "$tool" ] || return 1
  [ "$(age_of "$STATE/.last-ask-default-check")" -ge "$CHECK_INTERVAL" ] || return 1
  touch "$STATE/.last-ask-default-check"
  # shellcheck disable=SC2016 # the probe's own command substitution runs inside decide
  probe=$(printf '[ "$(%q mode --path %q 2>/dev/null)" != away ]' \
    "$SCRIPT_DIR/jg-afk-contract.sh" "$STATE/.afk-contract")
  for rec in "$JG_HOME/data/ask-default/asks"/*; do
    [ -f "$rec" ] || continue
    id=${rec##*/}
    # Skip the add-on's apply locks and its in-flight <id>.<pid> record staging.
    case "$id" in
      *.lock) continue ;;
      *.*) case "${id##*.}" in *[!0-9]*) ;; *) [ ! -f "${rec%.*}" ] || continue ;; esac ;;
    esac
    grep -q '^defaulted_at=' "$rec" && continue
    rc=0
    out=$(JG_HOME="$JG_HOME" "$tool" decide "$id" --probe-cmd "$probe" 2>&1) || rc=$?
    case "$rc" in
      0) case "$out" in *'decision: defaulted'*) ids="$ids $id" ;; esac ;;
      10|11|12) ;;
      *) triage_log "ask-default decide $id failed (rc=$rc): $(printf '%s' "$out" | tail -n 1)" ;;
    esac
  done
  [ -n "$ids" ] || return 1
  ASK_DEFAULT_REASON="check: ask-default safe default applied while the captain was unreachable:$ids (recorded in data/ask-default/applied.log)"
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    jg_backend_has_push "$b" || continue
    # SquadLead endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked squad_lead agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = squad_lead ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (jg_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if jg_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(JG_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 jg_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# A confirmed merge owns its own cleanup. bin/jg-teardown.sh runs without
# --force, so its own gates (unlanded work, an incomplete captain-call
# inventory, an owed public reply, an uncleared Relay link) stay in charge; a
# refusal becomes one wake naming it rather than leaving the task half landed.
# Both steps run detached so this cycle keeps supervising. The board is rebuilt
# from the payload it already carries, which drops the cards that just landed.
post_merge_cleanup() {  # <id>
  local id=$1 started="$STATE/.post-merge-cleanup-$1.started" log="$STATE/.post-merge-cleanup-$1.log"
  ( set -C; : > "$started" ) 2>/dev/null || return 0
  (
    local line
    if ! env JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/jg-teardown.sh" "$id" > "$log" 2>&1; then
      line=$(grep -m1 '^REFUSED' "$log" 2>/dev/null) || line=
      jg_wake_append check "post-merge-cleanup-$id" \
        "check: cleanup after the merge of $id was refused: ${line:-see $log}" \
        || triage_log "cleanup refusal for $id could not be queued"
    fi
  ) </dev/null >/dev/null 2>&1 &
}

# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# JG_PROCEVENT_LAUNCH_CONFIRM_SECONDS is validated here, at arm time, and an
# unusable value refuses to arm. This is deliberately NOT symmetry with the
# tunables above, which this watcher only defaults and never validates. The
# reason is specific: every supervision cycle runs `jg-procevent.sh reconcile`
# with its output and exit status discarded, and reconcile refuses an unusable
# window by name before it launches anything. Under this watcher that refusal
# is invisible - every cycle would exit early, no source would ever start, and
# the whole home would sit disarmed while presenting as supervised. A watcher
# that refuses to arm is loud through an existing, independent, proven path:
# the liveness guard's WATCHER DOWN banner in juggernaut's own session. The
# message shape is reconcile's own, so the operator reads one refusal in both
# places. The refusal goes to stdout because bin/jg-watch-arm.sh relays the
# child's stdout and recognises `watcher: FAILED` as the typed failure line.
if ! jg_procevent_launch_confirm_seconds >/dev/null; then
  echo "watcher: FAILED - JG_PROCEVENT_LAUNCH_CONFIRM_SECONDS must be whole seconds from $JG_PROCEVENT_LAUNCH_CONFIRM_MIN_SECONDS to $JG_PROCEVENT_LAUNCH_CONFIRM_MAX_SECONDS"
  exit 1
fi

watcher_process_table() {
  local proc_root=${JG_PROC_ROOT_OVERRIDE:-/proc} stat_path stat_line pid
  local -a fields
  if [ -r "$proc_root/$$/stat" ]; then
    for stat_path in "$proc_root"/[0-9]*/stat; do
      read -r stat_line < "$stat_path" 2>/dev/null || continue
      read -r -a fields <<< "${stat_line##*)}"
      [ "${#fields[@]}" -ge 2 ] || continue
      pid=${stat_path%/stat}
      printf '%s %s\n' "${pid##*/}" "${fields[1]}"
    done
  else
    ps -A -o pid= -o ppid=
  fi
}


watcher_descendants() {
  local root=$1 excluded=${2:-0} table
  table=$(watcher_process_table) || return 1
  printf '%s\n' "$table" | awk -v root="$root" -v excluded="$excluded" '
    { parent[$1] = $2 }
    END {
      for (pid in parent) {
        p = pid; depth = 0
        while (p != "" && p != "0" && p != "1" && depth++ < 64) {
          if (p == excluded) break
          p = parent[p]
          if (p == root) { print pid; break }
        }
      }
    }'
}

watcher_record_children() {
  local root=$1 identity=$2 ledger=$3 recorder child child_identity current descendants
  trap - EXIT HUP INT TERM
  jg_current_pid recorder || return 1
  while jg_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$root" "$JG_HOME" \
    && [ "$JG_WATCHER_MATCHED_IDENTITY" = "$identity" ]; do
    descendants=$(watcher_descendants "$root" "$recorder") || return 1
    {
      for child in $descendants; do
        child_identity=$(jg_watcher_child_identity "$child" 2>/dev/null) || continue
        printf '%s\t%s\n' "$child" "$child_identity"
      done
      while IFS="$(printf '\t')" read -r child child_identity; do
        jg_pid_alive "$child" || continue
        current=$(jg_watcher_child_identity "$child" 2>/dev/null) || continue
        [ "$current" = "$child_identity" ] || continue
        printf '%s\t%s\n' "$child" "$child_identity"
      done < "$ledger"
    } | awk '!seen[$0]++' > "$ledger.next" || return 1
    mv -f "$ledger.next" "$ledger" || return 1
    sleep 1
  done
}


# evict_stalled_holder <pid>: retire a live lock holder whose beacon stalled past
# WATCHER_STALL_BOUND. The pid is signalled only while it still proves the
# lock's own recorded identity (jg_watcher_lock_matches_pid: this home, this
# script, and the starttime+cmdline proof the lock carries), so a recycled pid
# is never touched. After a five-second TERM grace, recheck the lock, original
# identity, and stalled beacon before KILL: Bash can inherit ignored TERM and
# cannot reset it with `trap - TERM`. Never use a name or pattern match.
# Succeeds only once the holder and identity-matched descendants are retired
# within the bounded waits; the steal mutex excludes concurrent reclamation.
evict_stalled_holder() {
  local status
  jg_lock_try_acquire_steal_mutex "$WATCH_LOCK.steal" || return 1
  evict_stalled_holder_locked "$1"
  status=$?
  jg_lock_release "$WATCH_LOCK.steal"
  return "$status"
}

evict_stalled_holder_locked() {
  local pid=$1 i=0 identity descendants child child_identity recorded line
  jg_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$pid" "$JG_HOME" || return 1
  identity=$JG_WATCHER_MATCHED_IDENTITY
  descendants=$(watcher_descendants "$pid") || return 1
  recorded=$(awk '!seen[$0]++' "$WATCH_LOCK/children" 2>/dev/null || true)
  for child in $descendants; do
    child_identity=$(jg_watcher_child_identity "$child" 2>/dev/null) || continue
    printf -v line '%s\t%s' "$child" "$child_identity"
    recorded="$recorded"$'\n'"$line"
  done
  jg_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$pid" "$JG_HOME" || return 1
  [ "$JG_WATCHER_MATCHED_IDENTITY" = "$identity" ] || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  while [ "$i" -lt 50 ] && jg_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  if jg_pid_alive "$pid"; then
    [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null)" = "$pid" ] || return 1
    jg_watcher_lock_matches_pid "$STATE" "$WATCH_PATH" "$pid" "$JG_HOME" || return 1
    [ "$JG_WATCHER_MATCHED_IDENTITY" = "$identity" ] || return 1
    [ "$(jg_watcher_progress_age "$STATE")" -ge "$WATCHER_STALL_BOUND" ] || return 1
    kill -KILL "$pid" || return 1
  fi
  jg_watcher_retire_child_identities "$recorded" "$pid"
}

EVICTED_PID=
EVICTED_BEAT_AGE=
while ! jg_lock_try_acquire "$WATCH_LOCK"; do
  if [ -n "${JG_LOCK_HELD_PID:-}" ]; then
    beat_age=$(jg_watcher_progress_age "$STATE")
    if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
      # One eviction per arm: the retry re-reads the lock and beacon, so a
      # holder that exited leaves a dead-pid lock the normal reclaim takes,
      # and a rival arm that won first reads as a fresh running watcher.
      if [ -z "$EVICTED_PID" ] && [ "$beat_age" -ge "$WATCHER_STALL_BOUND" ] \
        && evict_stalled_holder "$JG_LOCK_HELD_PID"; then
        EVICTED_PID=$JG_LOCK_HELD_PID
        EVICTED_BEAT_AGE=$beat_age
        continue
      fi
      echo "watcher: lock held by live pid $JG_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $JG_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
done
if [ -n "$EVICTED_PID" ]; then
  echo "watcher: replaced stalled pid $EVICTED_PID (beacon ${EVICTED_BEAT_AGE}s past hard bound ${WATCHER_STALL_BOUND}s)"
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${JG_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${JG_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ] \
  && [ "${JG_WATCH_FOREGROUND_CHECKPOINT:-0}" != 1 ]; then
  if ! jg_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! jg_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${JG_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$JG_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
# Side-band ledger publication, detached from the poll loop.
#
# The poll loop owns the liveness beacon below, and jg-guard.sh reads that
# beacon's freshness as proof that supervision is alive. Publication is a
# side-band nicety bounded by JG_HOME_SUMMARY_TIMEOUT, but that bound is far
# larger than one poll and, in a home whose publication keeps failing, it is
# paid on every poll - so running it inline puts up to a full publication
# deadline between two beacon touches and can starve the guard's grace. Nothing
# in the poll depends on the ledger, so start it and move on: the beacon keeps
# advancing no matter how slow the publication is.
#
# The trade the detachment makes: a reader can briefly see a ledger that
# predates the event this poll just surfaced, where the inline call published
# first. Publication is eventually consistent by design and every reader
# re-derives current state from the owning home anyway, while beacon freshness
# is what the whole supervision chain rests on.
HOME_SUMMARY_PID=
home_summary_refresh_detached() {
  if [ -n "$HOME_SUMMARY_PID" ]; then
    if kill -0 "$HOME_SUMMARY_PID" 2>/dev/null; then
      return 0
    fi
    wait "$HOME_SUMMARY_PID" 2>/dev/null || true
    HOME_SUMMARY_PID=
  fi
  JG_HOME_SUMMARY_IF_IDLE=1 \
    "$SCRIPT_DIR/jg-home-summary-refresh.sh" --best-effort </dev/null >/dev/null 2>&1 &
  HOME_SUMMARY_PID=$!
}

# A ship's ready report records its PR without waiting on Main: jg-pr-check.sh
# --from-status owns which line counts and runs the named-head gate, then arms
# the merge poll, posts the ready card, and moves the ticket to review. A line
# it refuses or skips records nothing and still wakes Main as before.
ready_pr_record() {  # <status-file>
  local id=${1##*/} out
  case "$id" in *.status) id=${id%.status} ;; *) return 0 ;; esac
  [ -f "$STATE/$id.meta" ] || return 0
  if out=$(jg_run_timed "$CHECK_TIMEOUT" env JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/jg-pr-check.sh" --from-status "$id" 2>&1); then
    [ -z "$out" ] || triage_log "recorded the ready PR of $id"
  else
    triage_log "the ready PR of $id was not recorded: $(printf '%s\n' "$out" | tail -n 1)"
  fi
}

RECONCILE_REQUEST_PID=
reconcile_requests_pending() {
  local request
  [ -d "$STATE/reconcile-notify" ] && [ ! -L "$STATE/reconcile-notify" ] || return 1
  for request in \
    "$STATE/reconcile-notify"/.processing-request-*.json \
    "$STATE/reconcile-notify"/request-*.json; do
    [ -f "$request" ] && [ ! -L "$request" ] && return 0
  done
  return 1
}

reconcile_requests_detached() {
  if [ -n "$RECONCILE_REQUEST_PID" ]; then
    if kill -0 "$RECONCILE_REQUEST_PID" 2>/dev/null; then
      return 0
    fi
    if ! wait "$RECONCILE_REQUEST_PID" 2>/dev/null; then
      triage_log "squad_lead reconcile notify request deferred"
    fi
    RECONCILE_REQUEST_PID=
  fi
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/jg-squad-lead-reconcile.sh" process-requests </dev/null >/dev/null 2>&1 &
  RECONCILE_REQUEST_PID=$!
}

PR_POLL_CONTROL_LOCK=
PR_POLL_PUBLISH_LOCK=

pr_poll_control_release() {
  [ -z "$PR_POLL_CONTROL_LOCK" ] || jg_lock_release "$PR_POLL_CONTROL_LOCK" || return 1
  PR_POLL_CONTROL_LOCK=
}

pr_poll_publish_release() {
  [ -z "$PR_POLL_PUBLISH_LOCK" ] || jg_lock_release "$PR_POLL_PUBLISH_LOCK" || return 1
  PR_POLL_PUBLISH_LOCK=
}

WATCH_CHILD_RECORDER_PID=
watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ -n "$WATCH_CHILD_RECORDER_PID" ]; then
    kill -TERM "$WATCH_CHILD_RECORDER_PID" 2>/dev/null || true
    wait "$WATCH_CHILD_RECORDER_PID" 2>/dev/null || true
    WATCH_CHILD_RECORDER_PID=
  fi
  pr_poll_publish_release || cleanup_status=1
  pr_poll_control_release || cleanup_status=1
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${JG_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  if declare -F jg_memory_sampler_stop >/dev/null && [ "$owns_lock" -eq 1 ]; then jg_memory_sampler_stop; fi
  jg_active_check_stop || cleanup_status=1
  jg_check_output_cleanup
  jg_capture_output_cleanup
  jg_custom_check_snapshot_cleanup
  # A cycle that ends on a wake hands over to the next one through the arm
  # script; this stamp lets jg-supervision-lib.sh bridge that gap briefly.
  if [ "$owns_lock" -eq 1 ]; then touch "$STATE/.last-watcher-handoff" 2>/dev/null || true; fi
  if [ "$owns_lock" -eq 1 ] \
    && ! jg_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" \
      downtime "$CLEANUP_LOCK_BOUND"; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  # A delivered wake proves scan progress even though it exits before the
  # end-of-scan touch. Stamp only after releasing the lock, so an arm cannot
  # attach to a dying holder. Killed/evicted cycles never renew the beacon;
  # their predecessor's timestamp ages normally and PID checks still apply.
  if [ "$owns_lock" -eq 1 ] && [ -n "${JG_WATCH_DELIVERED_REASON:-}" ]; then
    touch "$STATE/.last-watcher-beat" 2>/dev/null || true
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
watcher_stop_signals
# This watcher's own pid, as recorded in the lock by jg_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
# Retain the last proven scan through handoff. Do not renew it until this
# cycle makes progress: a stalled successor must still age past grace.
printf '%s\n' "$JG_HOME" > "$WATCH_LOCK/jg-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
JG_WATCH_DELIVERY_PID=$WATCHER_PID
JG_WATCH_DELIVERY_IDENTITY=$(jg_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$JG_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
WATCH_OWNER_DIR=$(jg_lock_link_owner "$WATCH_LOCK") || exit 1
: > "$WATCH_OWNER_DIR/children" || exit 1
watcher_record_children "$WATCHER_PID" "$JG_WATCH_DELIVERY_IDENTITY" "$WATCH_OWNER_DIR/children" </dev/null >/dev/null 2>&1 &
WATCH_CHILD_RECORDER_PID=$!
if declare -F jg_memory_sampler_ensure >/dev/null; then jg_memory_sampler_ensure || triage_log "host memory sampler failed to start"; fi

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! jg_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/jg-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$JG_PR_POLL_RETIREMENT_REJECTED"
  jg_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

# Shared by both the first-notification and already-notified paths below so
# the retirement sequence (bin/jg-pr-lib.sh) is stated once.
retire_merged_pr_poll() {  # <id>
  local id=$1
  if jg_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh" merged; then
    jg_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh" \
      || triage_log "merged PR poll retirement remains recoverable for $id"
  else
    triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
  fi
}

# A poll armed before a state volume remount can fail capture only because its
# registration names the old device number; bin/jg-pr-lib.sh
# jg_pr_poll_registration_rerecord_device owns the proof and the rewrite.
# Returns 0 when a re-record was attempted under the control lock, so the caller
# captures again whatever the outcome: a concurrent re-arm may have published a
# valid poll instead, and the strict capture decides either way.
rerecord_device_shifted_pr_poll() {  # <id>
  local id=$1
  jg_pr_poll_registration_device_shifted "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh" || return 1
  PR_POLL_CONTROL_LOCK="$STATE/.control-$id.lock"
  jg_lock_acquire_wait "$PR_POLL_CONTROL_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$id.lock"
  jg_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK" || exit 1
  if jg_pr_poll_registration_rerecord_device "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh"; then
    triage_log "re-recorded PR poll identity for $id after its state volume device number changed"
  else
    triage_log "PR poll identity for $id was not re-recorded; the locked proof or rewrite did not hold"
  fi
  pr_poll_publish_release || exit 1
  pr_poll_control_release || exit 1
  return 0
}

resurface_after_downtime() {
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${JG_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! jg_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$JG_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  procevent_surface_queued
  # The independent sampler can publish after the earlier queue scan, while
  # arm-check is deciding recovery. Preserve that queued alert's richer reason.
  host_memory_surface_queued
  wake "check: rearm-resurface"
}

# Slow per-task checks (juggernaut writes these, e.g. a merged-PR poll).
# Time-based via .last-check mtime so the cadence survives watcher restarts.
# A due check runs on every cycle that reaches it, including a cycle whose
# actionable signal wake is about to exit (see the signal branch): the signal
# rows are already durable in the queue, so a check result appended here is
# delivered by the same drain as that signal, and a signal stream cannot
# starve a check. Checks are due only every CHECK_INTERVAL, so most cycles
# skip this block and fall straight through.
run_due_checks() {
  local c id out reason is_pr_poll provider url host path number custom_snapshot
  local merge_authority merge_authority_record_identity merge_outcome_rc
  local rejected_checks contribution_check_output contribution_check_diagnostics contribution_check_line
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    contribution_check_output=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$JG_HOME" "$JG_ROOT" \
          && [ -f "$JG_ROOT/bin/jg-x-poll.sh" ] && [ ! -L "$JG_ROOT/bin/jg-x-poll.sh" ]; then
          JG_HOME="$JG_HOME" run_check_capture "$JG_ROOT/bin/jg-x-poll.sh" || exit 1
          out=$JG_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if jg_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh" \
          || { rerecord_device_shifted_pr_poll "$id" \
            && jg_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh"; }; then
          is_pr_poll=1
          provider=$JG_PR_POLL_SNAPSHOT_PROVIDER
          url=$JG_PR_POLL_SNAPSHOT_URL
          host=$JG_PR_POLL_SNAPSHOT_HOST
          path=$JG_PR_POLL_SNAPSHOT_PATH
          number=$JG_PR_POLL_SNAPSHOT_NUMBER
          PR_POLL_CONTROL_LOCK="$STATE/.control-$id.lock"
          jg_lock_acquire_wait "$PR_POLL_CONTROL_LOCK" || exit 1
          if ! jg_pr_poll_snapshot_matches "$STATE" "$id" "$SCRIPT_DIR/jg-pr-poll.sh"; then
            pr_poll_control_release || exit 1
            triage_log "PR poll for $id changed before its validated check; skipping the stale snapshot"
            continue
          fi
          run_check_capture "$SCRIPT_DIR/jg-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$JG_CHECK_RESULT
        elif jg_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$JG_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$JG_CHECK_RESULT
          jg_custom_check_snapshot_cleanup
        else
          jg_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        if [ "$(basename "$c")" = contributions.check.sh ]; then
          contribution_check_output=
          contribution_check_diagnostics=
          while IFS= read -r contribution_check_line; do
            case "$contribution_check_line" in
              'contribution-wake: check: contributions '*)
                contribution_check_output="${contribution_check_output}${contribution_check_line#contribution-wake: }"$'\n'
                ;;
              *) contribution_check_diagnostics="${contribution_check_diagnostics}${contribution_check_line}"$'\n' ;;
            esac
          done <<EOF
$out
EOF
          if [ -n "$contribution_check_diagnostics" ]; then
            out=${contribution_check_diagnostics%$'\n'}
          elif [ -n "$contribution_check_output" ]; then
            continue
          fi
        fi
        reason="check: $c: $out"
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if [ "$(jg_meta_get "$STATE/$id.meta" kind)" = squad_lead ]; then
            # A merge poll armed on a squad_lead is residue: the mate is a
            # persistent worker, never landed work, and the merge it detected
            # belongs to a task in the mate's own home. Retire the poll with no
            # outcome and no wake; bin/jg-pr-check.sh refuses to arm another.
            retire_merged_pr_poll "$id"
            pr_poll_control_release || exit 1
            touch "$STATE/.last-check"
            triage_log "retired a merge poll armed on squad_lead $id without reporting an outcome"
            continue
          fi
          if ! jg_merge_authority_read "$STATE" "$id" \
              "$provider" "$host" "$path" "$number"; then
            triage_log "no matching persisted merge authority for $id; recording an external merge outcome"
          fi
          merge_authority=$JG_MERGE_AUTHORITY
          merge_authority_record_identity=$JG_MERGE_AUTHORITY_RECORD_IDENTITY
          merge_outcome_rc=0
          jg_merge_outcome_report "$JG_HOME" "$STATE" "$id" "$url" poll \
            "$merge_authority" || merge_outcome_rc=$?
          if [ "$merge_outcome_rc" -ne 0 ]; then
            triage_log "merge outcome for $id could not be recorded (rc=$merge_outcome_rc)"
            exit 1
          fi
          if [ -n "$merge_authority_record_identity" ] \
            && ! jg_merge_authority_remove_if_matches "$STATE" "$id" \
              "$provider" "$host" "$path" "$number" "$merge_authority" \
              "$merge_authority_record_identity"; then
            triage_log "published merge outcome for $id but could not retire its authority record"
            exit 1
          fi
          retire_merged_pr_poll "$id"
          pr_poll_control_release || exit 1
          touch "$STATE/.last-check"
          if [ "$JG_MERGE_OUTCOME_ALREADY_RECORDED" = true ]; then
            triage_log "absorbed duplicate merged PR poll result for $id"
            continue
          fi
          [ "$(jg_meta_get "$STATE/$id.meta" kind)" = scout ] || post_merge_cleanup "$id"
          wake "$reason"
        fi
        pr_poll_control_release || exit 1
        jg_wake_append check "$c" "$reason" || exit 1
        touch "$STATE/.last-check"
        wake "$reason"
      fi
      pr_poll_control_release || exit 1
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      jg_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
    if [ -n "$contribution_check_output" ]; then
      wake "$contribution_check_output"
    fi
  fi
}

while :; do
  # Home-gone exit: a deleted home, state directory, or code root means this
  # watcher's world is gone (a torn-down temporary home or a discarded
  # disposable checkout). Exit with a logged reason rather than writing state
  # into nothing, or into a live home from a checkout that no longer exists.
  # A detached helper this watcher started (home-summary refresh, reconcile)
  # can recreate a deleted state directory before the next poll, so a lock
  # with no holder at all is read as the same teardown: only a fresh watcher
  # ever recreates the lock, and that case is the self-eviction below.
  # Scoped to this process alone: no other watcher is signalled.
  if [ "$WATCH_HOME_EXISTED" -eq 1 ] && [ ! -d "$JG_HOME" ]; then
    echo "watcher: exiting - home no longer exists: $JG_HOME" >&2
    exit 1
  elif [ ! -d "$STATE" ]; then
    echo "watcher: exiting - state directory no longer exists: $STATE" >&2
    exit 1
  elif [ ! -e "$WATCH_LOCK/pid" ]; then
    echo "watcher: exiting - state directory was torn down (singleton lock removed): $STATE" >&2
    exit 1
  elif [ ! -d "$SCRIPT_DIR" ]; then
    echo "watcher: exiting - code root no longer exists: $SCRIPT_DIR" >&2
    exit 1
  fi

  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  if declare -F jg_memory_sampler_ensure >/dev/null; then jg_memory_sampler_ensure || triage_log "host memory sampler failed to restart"; fi
  host_memory_surface_queued
  # Stale test-browser reaper and load alarm; its own cadence file gates it.
  jg_reaper_tick || triage_log "browser reaper failed"
  if declare -F jg_model_outage_tick >/dev/null; then jg_model_outage_tick || triage_log "model-error observation failed"; fi
  # Remove confirmed orphan endpoints before replaying their old queue rows.
  phantom_pane_prune
  own_queue_resurface || { echo "watcher: own wake-queue observation failed" >&2; exit 1; }

  # Opt-in fleet activity ledger (docs/fleet-ledger.md): pick up newly appended
  # status lines before this cycle can exit on a wake. Off costs one file test.
  [ ! -e "$CONFIG/fleet-ledger" ] || JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE JG_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/jg-fleet-ledger.sh" capture || true

  if [ "$(age_of "$STATE/home-summary.json")" -ge "$HOME_SUMMARY_INTERVAL" ]; then
    home_summary_refresh_detached
  fi

  # Bearings publishes reconcile asks as local one-shot request files and
  # returns before any mate delivery. Supervision owns their later delivery;
  # a skipped or failed request remains durable for another poll.
  if reconcile_requests_pending; then
    reconcile_requests_detached
  fi

  # Parent-owned squad_lead pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  jg_pending_reply_tick "$STATE" || true

  # Endpoint liveness runs before queue observation: a positively dead or
  # missing squad_lead endpoint is relaunched here on a bounded cadence, which
  # is also what unsticks that mate's foreign wake queue. The tick's single
  # wake exits the cycle like every other wake, so its marker is stamped before
  # any relaunch and the restarted watcher will not re-probe early.
  squad_lead_liveness_tick || {
    echo "watcher: squad_lead liveness check failed" >&2
    exit 1
  }

  # A live squad_lead endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  squad_lead_wake_stall_tick || {
    echo "watcher: squad_lead wake-loop observation failed" >&2
    exit 1
  }

  # Process-to-event liveness repair. This never discovers a result by polling:
  # each registered source has its own child blocking on that source, and this
  # only republishes results already captured durably and restarts a source
  # whose owner is gone. It is a no-op with nothing registered. It never wakes,
  # so it stays ahead of signals: a constant signal stream must not stop a dead
  # source from being restarted.
  if [ -d "$STATE/procevent" ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi

  # Merge alerts the board refused while it was down are posted once it is back
  # (bin/jg-merge-alert.sh drain); a no-op with nothing queued, and it never wakes.
  if [ -d "$STATE/merge-alerts/pending" ]; then
    JG_HOME="$JG_HOME" "$SCRIPT_DIR/jg-merge-alert.sh" drain >/dev/null 2>&1 || true
  fi

  # The decision must read the wake queue as it stood at cycle start, because
  # the signal scan below appends this cycle's own rows. While unconsumed rows
  # from a previous cycle exist (a post-queue crash left its terminal row
  # undelivered), the durable recovery must surface before any check can
  # retire polls and append a fresh terminal row ahead of the crashed cycle's
  # row. The resurface wake ends the cycle; the signal scan and due checks
  # then run on the next cycle, losing nothing - signal markers only advance
  # when a signal is actually surfaced, check cadences are time-based, and
  # retirement receipts are durable. Quiet homes never enter this path: with
  # an empty wake queue the resurface falls through without waking.
  resurface_after_downtime

  # Signals are scanned FIRST, before the process-event, wait-timer and
  # inactive-outcome steps: wake() exits the cycle, so an earlier waking step
  # would starve the handoff path. Those steps run only on a cycle that does
  # not end on a signal wake; their state is durable, so they resume on the next
  # signal-free cycle. A due check runs ahead of a signal wake (run_due_checks)
  # so its result queues in that same wake and a constant signal stream cannot
  # starve it - but still after the downtime resurface above, because a pending
  # durable recovery outranks any new signal or check result. The squad_lead
  # repair ticks above stay ahead of signals because they only
  # wake to relaunch a dead endpoint or unstick a foreign queue, never for noise.
  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a operator's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full juggernaut turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  signal_wake=
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    # Sequential assignments, never sibling substitutions on one command: a
    # CHLD trap makes two $() arguments a bash 5.2 parse-error landmine.
    rescan=$(scan_signals)
    pending=$(signal_batch_merge "$pending" "$rescan")
    # The final coalesced signal set is the watcher-carried status-change
    # trigger for this home's published summary. Start it before either
    # surfacing or absorbing the signal, but never wait on it: see
    # home_summary_refresh_detached for why publication stays off the beacon's
    # path. Publication failure stays side-band.
    home_summary_refresh_detached
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      # A batch left with no reportable path reports nothing at all.
      reportable_signal_path "$f" || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    # #fleet: each status line change, in plain words. Read here because this is
    # the loop that already surfaced the span, so the channel costs no second
    # poll; the tail keeps the newest line, which is the change itself.
    if [ -x "$SCRIPT_DIR/jg-chat.sh" ]; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in *.status) ;; *) continue ;; esac
        reportable_signal_path "$f" || continue
        JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-chat.sh" note '#fleet' \
          "$(basename "$f" .status)" - status - \
          "$(awk 'NF { line = $0 } END { print line }' "$f" 2>/dev/null)" \
          >/dev/null 2>&1 || true
      done <<EOF
$pending
EOF
    fi
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file gained a captain-relevant event since it was last
    #     classified (its whole new span, not merely its last line);
    #   - or it is a no-verb wake (a bare turn-end, a working: note) with no
    #     positive evidence the crew is still executing - the crew stopped its turn
    #     with no actively-running pipeline and no busy pane, so it may be done
    #     (even via an interactive menu that wrote no done: status), waiting on a
    #     decision, or wedged. Absorbing such a turn-end is exactly the
    #     swallowed-finish this change guards against.
    # Positive evidence is either an authoritative provably-working verdict or, in a
    # home that opts in with config/turnend-churn-absorb and for a BARE turn-end
    # alone, a pane that rendered something since the previous poll
    # (signal_turnend_panes_churned) - the only proof available to a harness whose
    # busy state has no verified semantic source, bounded so it cannot defer that
    # task's turn-ends forever. Absorb stays evidence-driven: with neither proof the
    # wake surfaces exactly as before.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew is still executing) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. Both evidence
    # checks are costly (a bounded no-mistakes call, then a pane capture), so the ||
    # ordering evaluates them ONLY for a non-afk signal with no captain-relevant
    # status span, and the capture only once the authoritative verdict comes up short.
    JG_SIGNAL_SURFACE_ENDPOINTS=''
    JG_SIGNAL_NEEDS_DECISION_FILES=''
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    signal_files_actionable $files
    signal_actionable=$?
    # A decision-owned file's queued row payload is marked "needs-decision:"
    # instead of the ordinary "signal:" below (other files in the same batch
    # keep the ordinary payload). The wake reason line itself, and every
    # harness-arm consumer that pattern-matches it, stays byte-identical -
    # only the per-row payload changes. Two readers branch on that payload:
    # docs/pi-supervision-branch.md's Pi-only branch dispatcher, to keep a
    # decision-owned row off the supervision branch (jg-branch-dispatch.ts,
    # jg-primary-pi-watch.ts), and the away daemon, whose handle_durable_wakes
    # passes it to handle_wake (see the comment above handle_wake in
    # bin/jg-supervise-daemon.sh).
    # shellcheck disable=SC2086  # same space-separated status-path list
    if afk_present || [ "$signal_actionable" -eq 0 ] \
      || { ! signal_crew_provably_working $files && ! signal_turnend_panes_churned $files; }; then
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        reportable_signal_path "$f" || continue
        ready_pr_record "$f"
        file_reason="$reason"
        case " $JG_SIGNAL_NEEDS_DECISION_FILES " in *" $f "*) file_reason="needs-decision:$files" ;; esac
        jg_wake_append signal "$(basename "$f")" "$file_reason" || exit 1
      done <<EOF
$pending
EOF
      # The wake signature advances for every file in this batch, including one
      # whose span could not be classified: it has now been reported, and this is
      # what bounds an unreadable log to one report per distinct file state. Only
      # a SUCCESSFULLY classified log commits a classification position below, so
      # an unreadable log's content is still classified once it becomes readable.
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in
          *.status)
            jg_wake_status_reported_commit "$STATE" "$f" "$sig" || true
            mark_surface_reported "$f" "$sig" || true
            ;;
          *) printf '%s' "$sig" > "$sf" ;;
        esac
      done <<EOF
$pending
EOF
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        jg_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || true
        mark_surfaced "$f" "$surface_end" "$surface_ident"
      done <<EOF
$JG_SIGNAL_SURFACE_ENDPOINTS
EOF
      [ -n "$files" ] || continue
      signal_wake=$reason
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        case "$f" in *.status) ;; *) printf '%s' "$sig" > "$sf" ;; esac
      done <<EOF
$pending
EOF
      signal_commit_error=0
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        jg_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" \
          || signal_commit_error=1
      done <<EOF
$JG_SIGNAL_SURFACE_ENDPOINTS
EOF
      if [ "$signal_commit_error" -ne 0 ]; then
        while IFS=$(printf '\t') read -r sf sig f; do
          [ -n "$sf" ] || continue
          reportable_signal_path "$f" || continue
          jg_wake_append signal "$(basename "$f")" "$reason" || exit 1
        done <<EOF
$pending
EOF
        [ -n "$files" ] || continue
        signal_wake=$reason
      else
        triage_log "absorbed benign $reason"
      fi
    fi
  fi

  # Keep the fleet comms feed current, on for every install with no flag to set.
  # The exporter owns its own cursor and lock and returns at once when nothing
  # moved, so a cycle pays one cheap process here; its failure is absorbed so a
  # feed problem can never stall supervision.
  if [ -f "$SCRIPT_DIR/jg-comms-feed.sh" ] && [ ! -L "$SCRIPT_DIR/jg-comms-feed.sh" ]; then
    "$SCRIPT_DIR/jg-comms-feed.sh" sync >/dev/null 2>&1 || true
  fi

  run_due_checks
  if [ -n "$signal_wake" ]; then
    wake "$signal_wake"
  fi

  # Deliver any queued-but-unsurfaced process-event result, including one a
  # runner published while this watcher was between cycles. It waits behind
  # signals and due checks, which are durable and surface on this cycle or the
  # next, so a continuous result stream cannot starve them.
  procevent_surface_queued

  if declare -F jg_wait_timers_tick >/dev/null; then jg_wait_timers_tick || { echo "watcher: waiting-state timer check failed" >&2; exit 1; }; fi

  host_memory_surface_queued

  # The existing poll loop also owns the bounded inactive-outcome cadence.
  # This is mechanical and silent unless a durable terminal-outcome obligation
  # was created, so quiet cycles never wake juggernaut or consume model tokens.
  inactive_out=
  if inactive_out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/jg-inactive-reconcile.sh" scan 2>/dev/null); then
    if [ -n "$inactive_out" ]; then
      wake "check: inactive-outcome"
    fi
  else
    triage_log "inactive-outcome reconciliation unavailable"
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the operator finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified, or the declaration a busy pane's
  # crossed turn bound already handed to the away-mode daemon).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    # Steering-inbox loss detection runs before the squad_lead stale
    # exemption below, because a mate's steers land in an inbox too.
    [ -z "$task" ] || inbox_steer_check "$w" "$task"
    key=$(window_key "$w")
    last=$(status_declared_wait_line "$STATE/$task.status")
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    # An idle squad_lead endpoint is healthy by design, so a mate is admitted to
    # the pane-stale path ONLY to serve a status-declared wait's bounded
    # re-surface. This gate reads the shared predicate rather than the pause verb
    # alone so it includes a declared `captain-held` status. A hold recorded only
    # in the backlog while the mate still says `working:` or `done:` is outside
    # this guard: reaching it would require backlog reads for windows this gate
    # deliberately skips, putting that read on the ordinary poll hot path.
    if [ "$kind" = squad_lead ] && ! status_is_paused_or_captain_held "$last"; then
      [ -z "$task" ] || prompt_gate_check "$w" "$task" || true
      if watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")"; then
        stuck_gate_check "$w" "$task" "$key" "$WATCHER_CAPTURE" "$kind"
      fi
      continue
    fi
    backend=$(window_backend "$w")
    watcher_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" || continue
    tail40=$WATCHER_CAPTURE
    stuck_gate_check "$w" "$task" "$key" "$tail40" "$kind"
    if [ -n "$task" ] && prompt_gate_check "$w" "$task" "$tail40"; then continue; fi
    h=$(printf '%s' "$tail40" | hash_pane)
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    observe_window_progress "$key" "$task" "$last"
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    if window_progress_absorbed "$w" "$task" "$key" "$h" "$prev" "$busy_now"; then continue; fi
    if [ "$busy_now" -ne 0 ] && [ "$kind" != squad_lead ] && [ -n "$task" ]; then
      declared_wait_contradiction "$w" "$task" "$key"
    fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # juggernaut. Detection itself is unchanged from above.
        if [ "$kind" = squad_lead ]; then
          case "$(pause_state_class "$w" "$task")" in
            paused) handle_paused_stale "$w" "$task" "$h" ;;
            *)      clear_pause_tracking "$key" ;;
          esac
        elif afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before,
          # except that a captain-held pane is never handed over while the
          # away-posture record exists (captain_held_silenced).
          if captain_held_silenced "$last"; then
            printf '%s' "$h" > "$sf"
            triage_log "absorbed stale (captain-held, never rechecked while the away-posture record exists): $w"
          elif [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            jg_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's latest status event is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once juggernaut hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source jg-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              clear_write_tracking "$key"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            elif captain_call_stale_bound "$key" "$task"; then
              # The line is captain-relevant and stays so, but the backlog says
              # the captain already holds this work: further NEW pane hashes with
              # the same status-log state have nothing to add while they are
              # deciding. Only that new-hash repetition is bounded - the first
              # sight already alarmed, a new hash inside the window is absorbed,
              # and a new hash after it alarms again. A stable hash stays as inert
              # here as it already was after a first terminal alarm.
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_write_tracking "$key"
              triage_log "absorbed stale (open captain call already surfaced for this status): $w"
            else
              jg_wake_append stale "$w" "stale: $w" || exit 1
              stale_wait_record "$key"
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_write_tracking "$key"
              stale_status="$STATE/$(window_to_task "$w" "$STATE").status"
              stale_record=$(status_span_first_actionable_record "$stale_status" 0)
              case $? in
                0|1) stale_end=${stale_record%%$'\t'*}; stale_rest=${stale_record#*$'\t'}; stale_ident=${stale_rest%%$'\t'*} ;;
                *) stale_end=''; stale_ident='' ;;
              esac
              mark_surfaced "$stale_status" "$stale_end" "$stale_ident"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task" "$h"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: a declared wait pause_state_class admits (its header owns which
          #     liveness evidence each kind of crew must supply), so absorb on the long
          #     PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no admitted declared wait.
          #     Surface immediately so juggernaut inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task" "$h"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task" "$h"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task" "$key"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
        else
          rm -f "$ssf" "$ewf"
          clear_write_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased and
        # the pause would re-surface every poll instead of once per long cadence.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      # Record the forward window->key map beside the hash, so the
      # phantom-pane prune can still find (and prune) this window's markers
      # after the record that enumerated it is gone. Written once.
      [ -e "$STATE/.tracked-$key" ] || printf '%s\t%s\n' "$w" "$backend" > "$STATE/.tracked-$key"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task" "$key"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
      else
        rm -f "$ssf" "$ewf"
        clear_write_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          # Inconclusive, but the declared wait itself still stands, so only the
          # per-hash bookkeeping resets. The re-surface throttle bounds the
          # DECLARATION, not the pane hash: an idle parked pane whose display
          # ticks (a clock, a token counter) changes hash without changing what
          # is being waited on, and clearing the throttle here would hand that
          # same wait a fresh window on every tick - the first sight of each new
          # hash reaches surface_nonterminal_stale below, so the whole declared
          # wait would re-alarm far inside PAUSE_RESURFACE_SECS.
          none)   clear_stale_hash_tracking "$key" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)

  # Ready intake must not inherit idle heartbeat backoff (up to two hours),
  # nor be starved by away-mode heartbeats. Keep its base cadence independent.
  if [ "$(age_of "$STATE/.last-ready-work-check")" -ge "$HEARTBEAT" ]; then
    touch "$STATE/.last-ready-work-check"
    if ready_work_waits_idle; then
      reason=$READY_WORK_REASON
      jg_wake_append check ready-work "$reason" || exit 1
      record_ready_work_surfaced
      wake "$reason"
    fi
    # A refused launch becomes retryable on the same base-cadence clock.
    if admission_retry_waits_memory; then
      reason=$ADMISSION_RETRY_REASON
      jg_wake_append check admission-retry "$reason" || exit 1
      printf '%s' "$ADMISSION_RETRY_KEY" > "$STATE/.admission-retry-surfaced" || true
      wake "$reason"
    fi
  fi

  # Asks the ask-default add-on recorded are decided on the check cadence.
  if ask_default_tick; then
    jg_wake_append check ask-default "$ASK_DEFAULT_REASON" || exit 1
    wake "$ASK_DEFAULT_REASON"
  fi

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      jg_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant event the per-wake path absorbed by mistake.
      # Enqueue first, then record every status log surfaced through its end so the
      # next heartbeat does not re-fire it (enqueue-before-suppress preserved);
      # this wake sends juggernaut to the whole fleet, so every log is read.
      jg_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced || true
      wake "heartbeat"
    else
      if ! mark_all_captain_relevant_surfaced; then
        jg_wake_append heartbeat heartbeat heartbeat || exit 1
        touch "$STATE/.last-heartbeat"
        wake "heartbeat"
      fi
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Renew liveness only after a complete supervision scan. The predecessor's
  # beacon stays readable during handoff but keeps its original age while
  # checks block. Actionable wakes stamp in watcher_cleanup after lock release.
  touch "$STATE/.last-watcher-beat" || exit 1

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
