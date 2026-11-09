#!/usr/bin/env bash
# Render the primary-harness supervision operating block for session start and
# the short repair line used by guards and turn-end hooks. On a non-Pi primary
# with a supervision protocol (claude, cursor, opencode, omp, grok, codex) whose
# home runs the supervision host (jg_supervision_host_enabled in
# bin/jg-supervision-engine-lib.sh: by default on Claude, by
# config/supervision-host elsewhere, never with config/supervision-host-off), the block
# adds one state line and the host's main-side protocol
# (docs/supervision-protocols/supervision-host.md, whose lines tagged
# "{<harness>,...} " render only for the listed harnesses), and Grok's arm
# command becomes the host; on a home that does not run it the output is
# unchanged.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$REPO_ROOT}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"
DOC_DIR="$REPO_ROOT/docs/supervision-protocols"

HARNESS=
READ_ONLY=0
AFK=0
AFK_MODE=away
X_MODE=0
REPAIR_LINE=0
QUEUE_PENDING=0

usage() {
  cat <<'EOF'
Usage: jg-supervision-instructions.sh [--harness <name>] [--read-only 0|1] [--afk 0|1] [--afk-mode away|quiet] [--x-mode 0|1] [--repair-line] [--queue-pending 0|1]

Print the current primary harness's supervision operating instructions.
With --repair-line, print one concise repair instruction for guard and hook messages.
--afk-mode only matters when --afk 1 (present); it selects the away-mode vs
quiet-mode (kunchenguid/juggernaut#2356) wording, and defaults to away.
EOF
}

bool_value() {
  case "$1" in
    1|true|TRUE|yes|YES) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --read-only)
      [ "$#" -gt 1 ] || { echo "error: --read-only requires 0 or 1" >&2; exit 2; }
      READ_ONLY=$(bool_value "$2")
      shift 2
      ;;
    --afk)
      [ "$#" -gt 1 ] || { echo "error: --afk requires 0 or 1" >&2; exit 2; }
      AFK=$(bool_value "$2")
      shift 2
      ;;
    --afk-mode)
      [ "$#" -gt 1 ] || { echo "error: --afk-mode requires away or quiet" >&2; exit 2; }
      case "$2" in
        away|quiet) AFK_MODE=$2 ;;
        *) AFK_MODE=away ;;
      esac
      shift 2
      ;;
    --x-mode)
      [ "$#" -gt 1 ] || { echo "error: --x-mode requires 0 or 1" >&2; exit 2; }
      X_MODE=$(bool_value "$2")
      shift 2
      ;;
    --queue-pending)
      [ "$#" -gt 1 ] || { echo "error: --queue-pending requires 0 or 1" >&2; exit 2; }
      QUEUE_PENDING=$(bool_value "$2")
      shift 2
      ;;
    --repair-line)
      REPAIR_LINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$HARNESS" ]; then
  HARNESS=$("$SCRIPT_DIR/jg-harness.sh" 2>/dev/null || printf unknown)
fi

# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
LEAD_DAEMON=0
if jg_lead_daemon_home "$JG_ROOT" "$HARNESS"; then
  LEAD_DAEMON=1
fi

case "$HARNESS" in
  codex) SNIPPET="$DOC_DIR/codex.md"; [ "$LEAD_DAEMON" -eq 0 ] || SNIPPET="$DOC_DIR/codex-lead.md" ;;
  claude|opencode|pi|grok|cursor|omp) SNIPPET="$DOC_DIR/$HARNESS.md" ;;
  pi-signed) SNIPPET="$DOC_DIR/pi.md" ;;
  *) HARNESS=unknown; SNIPPET="$DOC_DIR/unknown.md" ;;
esac
[ -f "$SNIPPET" ] || SNIPPET="$DOC_DIR/unknown.md"
HOST_SNIPPET=
grok_arm='bin/jg-watch-arm.sh'
case "$HARNESS" in
  claude|cursor|opencode|omp|grok|codex)
    # shellcheck source=bin/jg-supervision-engine-lib.sh
    . "$SCRIPT_DIR/jg-supervision-engine-lib.sh"
    if jg_supervision_host_enabled "$CONFIG" "$HARNESS"; then
      HOST_SNIPPET="$DOC_DIR/supervision-host.md"
      grok_arm='bin/jg-supervision-host.sh park'
    fi
    ;;
esac

# A lead daemon home has no foreground checkpoints for the host to run in.
[ "$LEAD_DAEMON" -eq 0 ] || { HOST_SNIPPET=; grok_arm='bin/jg-watch-arm.sh'; }

checkpoint_seconds=${JG_CODEX_WATCH_CHECKPOINT:-180}
pi_ext="$JG_ROOT/.pi/extensions/jg-primary-pi-watch.ts"
pi_turnend_ext="$JG_ROOT/.pi/extensions/jg-primary-turnend-guard.ts"
omp_ext="$JG_ROOT/.omp/extensions/jg-primary-omp-watch.ts"
omp_turnend_ext="$JG_ROOT/.omp/extensions/jg-primary-turnend-guard.ts"
x_mode_env="$CONFIG/x-mode.env"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

x_mode_env_sh=$(shell_quote "$x_mode_env")

if [ "$X_MODE" -eq 0 ] && [ -f "$x_mode_env" ]; then
  X_MODE=1
fi

render_snippet() {  # [snippet]
  local line tags snippet=${1:-$SNIPPET}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '{'*'} '*)
        tags=${line%%\} *}
        tags=${tags#\{}
        case ",$tags," in *",$HARNESS,"*) ;; *) continue ;; esac
        line=${line#*\} }
        ;;
    esac
    line=${line//__JG_PI_EXT__/$pi_ext}
    line=${line//__JG_PI_TURNEND_EXT__/$pi_turnend_ext}
    line=${line//__JG_OMP_EXT__/$omp_ext}
    line=${line//__JG_OMP_TURNEND_EXT__/$omp_turnend_ext}
    line=${line//__JG_X_MODE_ENV_SH__/$x_mode_env_sh}
    line=${line//__JG_X_MODE_ENV__/$x_mode_env}
    line=${line//__JG_GROK_ARM__/$grok_arm}
    printf '%s\n' "$line"
  done < "$snippet"
}

repair_line() {
  if [ "$READ_ONLY" -eq 1 ]; then
    printf '%s\n' 'Watcher repair belongs to the session holding the fleet lock; do not drain, arm, or repair from this read-only session.'
    return 0
  fi
  if [ "$AFK" -eq 1 ]; then
    if [ "$AFK_MODE" = quiet ]; then
      printf '%s\n' 'Quiet mode owns watcher supervision; load /radio-silence and ensure the daemon is running instead of starting normal supervision directly.'
    else
      printf '%s\n' 'Away mode owns watcher supervision; load /watchover and ensure the daemon is running instead of starting normal supervision directly.'
    fi
    return 0
  fi

  prefix=
  if [ "$QUEUE_PENDING" -eq 1 ]; then
    prefix='After draining queued wakes, '
  fi
  if [ "$X_MODE" -eq 1 ]; then
    prefix="${prefix}source ${x_mode_env_sh} first, then "
  fi

  case "$HARNESS" in
    claude)
      printf '%s%s\n' "$prefix" 'watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn.'
      ;;
    codex)
      if [ "$LEAD_DAEMON" -eq 1 ]; then
        printf '%s%s\n' "$prefix" 'repair missing lead supervision by starting the always-on daemon: bin/jg-lead-daemon.sh start (idempotent; never a foreground checkpoint).'
        return 0
      fi
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with a foreground checkpoint: bin/jg-watch-checkpoint.sh --seconds ' "$checkpoint_seconds" '.'
      ;;
    pi|pi-signed)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the Pi tool jg_watch_arm_pi, or restart Pi with -e ' "$pi_turnend_ext" ' -e ' "$pi_ext" ' if the extensions are not loaded.'
      ;;
    omp)
      printf '%s%s%s%s%s%s\n' "$prefix" 'repair a missing or failed watcher cycle with the omp tool jg_watch_arm_omp, or restart omp inside this home so ' "$omp_turnend_ext" ' and ' "$omp_ext" ' auto-load from .omp/extensions/ (use -e with both paths only when starting omp from another directory).'
      ;;
    opencode)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision by letting the OpenCode TUI plugin arm after idle; use bin/jg-watch-arm.sh only as a manual recovery probe if the plugin reports failure.'
      ;;
    grok)
      printf '%s%s%s%s\n' "$prefix" 'repair missing watcher supervision with ' "$grok_arm" ' as its own Grok tracked background task, never shell &.'
      ;;
    cursor)
      printf '%s%s\n' "$prefix" 'watcher supervision is owned by the stop-hook park; inspect the hook registration and watcher startup path before ending the turn.'
      ;;
    *)
      printf '%s%s\n' "$prefix" 'repair missing watcher supervision according to the session-start block for this harness; do not use shell &.'
      ;;
  esac
}

ordinary_wake_line() {
  case "$HARNESS" in
    claude)
      printf '%s\n' '- Ordinary wake: the Stop-owned auto-arm (bin/jg-claude-stop-autoarm.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    codex)
      if [ "$LEAD_DAEMON" -eq 1 ]; then
        printf '%s\n' '- Ordinary wake: the always-on lead daemon already handled it in bash; act only on an injected event, then end the turn idle. Never run a foreground checkpoint.'
      else
        printf '%s\n' '- Ordinary wake: take the next foreground bin/jg-watch-checkpoint.sh checkpoint as directed below.'
      fi
      ;;
    pi|pi-signed)
      printf '%s\n' '- Ordinary wake: the Pi extension already owns watcher continuity; do not arm another cycle.'
      ;;
    omp)
      printf '%s\n' '- Ordinary wake: the omp extension already owns watcher continuity; do not arm another cycle.'
      ;;
    opencode)
      printf '%s\n' '- Ordinary wake: the OpenCode TUI plugin already owns watcher continuity; do not arm manually.'
      ;;
    grok)
      printf '%s%s%s\n' '- Ordinary wake: re-arm exactly one ' "$grok_arm" ' Grok tracked background task as directed below.'
      ;;
    cursor)
      printf '%s\n' '- Ordinary wake: the stop-hook park (bin/jg-turnend-guard-cursor.sh) already owns watcher continuity; drain and handle the wake, and do not arm another cycle yourself.'
      ;;
    *)
      printf '%s\n' '- Ordinary wake: follow the continuation in the harness protocol below; do not use shell &.'
      ;;
  esac
}

if [ "$REPAIR_LINE" -eq 1 ]; then
  repair_line
  exit 0
fi

RULE='================'
printf '%s\n' "$RULE"
printf 'SUPERVISION OPERATING INSTRUCTIONS - primary harness: %s\n' "$HARNESS"
printf '%s\n' "$RULE"
printf 'Current state:\n'
if [ "$READ_ONLY" -eq 1 ]; then
  printf '%s\n' '- Lock: read-only; do not drain, arm, spawn, steer, merge, or repair fleet state here.'
else
  printf '%s\n' '- Lock: held by this session; this session owns normal supervision unless away mode says otherwise.'
fi
if [ "$AFK" -eq 1 ]; then
  if [ "$AFK_MODE" = quiet ]; then
    printf '%s\n' '- Quiet mode: active; load /radio-silence and keep normal harness supervision paused while the daemon owns the watcher. Ordinary captain chat does NOT exit it - only an explicit /radio-silence off does.'
  else
    printf '%s\n' '- Away mode: active; load /watchover and keep normal harness supervision paused while the daemon owns the watcher.'
  fi
else
  printf '%s\n' '- Away/quiet mode: inactive.'
fi
if [ "$X_MODE" -eq 1 ]; then
  printf '%s%s%s\n' '- X mode: active; source ' "$x_mode_env" ' before launching any watcher process so the 30s cadence is inherited.'
else
  printf '%s\n' '- X mode: inactive; use the default watcher cadence.'
fi
if [ -n "$HOST_SNIPPET" ]; then
  printf '%s\n' '- Supervision host: on; it takes away-posture wakes and, where the dialog mirror is verified, eligible attended wakes itself, and hands the rest to you (protocol at the end of this block).'
fi
ordinary_wake_line
printf '%s\n' '- Fleet reads: for a heartbeat or any look at the fleet, run juggernaut-axi status, then juggernaut-axi lanes, wakes, holds or tasks for the part you need (one bounded table each); the raw scripts remain the writers and the fallback when the command is absent.'
printf '\n'
render_snippet
printf '\n'
if [ -n "$HOST_SNIPPET" ]; then
  render_snippet "$HOST_SNIPPET"
  printf '\n'
fi
