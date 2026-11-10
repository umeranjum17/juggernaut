#!/usr/bin/env bash
# jg-backend.sh - runtime-backend selection, meta helpers, selector resolution,
# and dispatch for juggernaut's session-provider abstraction.
#
# Design: data/jg-backend-design-d7/report.md ("Backend Interface") and
# data/jg-backend-design-d7/herdr-addendum.md ("Events as the core
# abstraction"). P1 extracted the tmux command sequences that jg-send.sh,
# jg-peek.sh, jg-watch.sh, jg-spawn.sh, and jg-teardown.sh already ran inline
# into bin/backends/tmux.sh, with those SAME command sequences, so the default
# (tmux) path stays byte-identical. P2 adds bin/backends/herdr.sh, a verified
# spawn-capable backend with its own required CI lane, behind `--backend
# herdr`/`JG_BACKEND=herdr`/`config/backend`, and behind runtime auto-detection
# when juggernaut itself is running inside herdr with no explicit backend setting;
# see herdr-addendum.md and data/jg-backend-design-d7/herdr-verification-p2.md for
# its empirical basis.
# P3 adds bin/backends/zellij.sh, also EXPERIMENTAL and spawn-capable, behind
# `--backend zellij`/`JG_BACKEND=zellij`/`config/backend` - NOT behind runtime
# auto-detection (report.md's Open Question #2: start with a dedicated
# background session for predictability, unlike tmux's/herdr's ambient-session
# reuse); see report.md's "Zellij Backend" section and docs/zellij-backend.md
# for its empirical basis. P4 makes Orca spawn-capable: Orca owns both the
# task worktree and the terminal endpoint. P5 adds bin/backends/cmux.sh, also
# EXPERIMENTAL and spawn-capable, behind `--backend cmux`/`JG_BACKEND=cmux`/
# `config/backend`, and behind runtime auto-detection when juggernaut itself is
# running inside a cmux-spawned terminal (primary CMUX_WORKSPACE_ID marker, or
# the documented macOS fallback signals when cmux's claude wrapper strips that
# marker) with no explicit backend setting - unlike Orca, which stays
# never-auto-detected because it also owns the task worktree; see
# docs/cmux-backend.md for its empirical basis.
# Codex App is intentionally not in the known set yet.
# docs/codex-app-backend.md owns that blocked backend contract.
#
# Compatibility contract: a task's meta may omit `backend=`; every reader here
# treats that as `tmux` (jg_backend_of_meta), and jg-spawn.sh does not write
# `backend=tmux` for a default-backend task, so existing and newly spawned
# default-path metas stay byte-identical. Only a task spawned on a non-tmux
# spawn-capable backend, currently herdr, zellij, orca, or cmux, carries an
# explicit `backend=` line.
#
# Event-source framing (herdr-addendum "Events as the core abstraction"): a
# backend's supervision surface is conceptually an EVENT SOURCE - it produces
# task events (status-changed, went-stale, exited) that map onto juggernaut's
# existing signal/stale/check/heartbeat wake vocabulary. The tmux adapter has
# no native event push, so jg-watch.sh's poll loop over the pull primitives
# below (capture, list-live, busy-state via regex) IS the default event-source
# implementation that synthesizes those events; P1 only names that seam, it
# does not change the loop's behavior. The pull primitives also stay available
# on their own for on-demand reads (jg-peek.sh, jg-crew-state.sh).
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

JG_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
JG_BACKEND_LIB_DIR="$(cd "$(dirname "$JG_BACKEND_SCRIPT")" && pwd)"
unset JG_BACKEND_SCRIPT
JG_BACKEND_DEFAULT_ROOT="$(cd "$JG_BACKEND_LIB_DIR/.." && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-${JG_ROOT:-$JG_BACKEND_DEFAULT_ROOT}}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
JG_BACKEND_CONFIG_DIR="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

# Verified backend adapters. Extend only after a backend gets its own
# bin/backends/<name>.sh and empirical verification, mirroring AGENTS.md
# section 4's harness-verification discipline. herdr is verified (P2;
# data/jg-backend-design-d7/herdr-addendum.md) and has its own required CI lane,
# with current coverage in docs/herdr-backend.md and
# docs/verification/runtime-backends.md. zellij is EXPERIMENTAL (P3;
# data/jg-backend-design-d7/report.md "Zellij Backend") - verified against the
# real 0.44.0 binary (docs/zellij-backend.md). orca is EXPERIMENTAL and
# spawn-capable; unlike tmux/herdr/zellij it is also the worktree provider.
# cmux is EXPERIMENTAL and spawn-capable, session-provider-only like
# herdr/zellij - verified against the real 0.64.17 binary (docs/cmux-backend.md).
# hc (Herdr Core) is KNOWN but not spawn-capable: its core primitives are
# verified in the isolated hc lab, and it joins JG_BACKEND_SPAWN only after its
# verify plan lands (docs/hc-backend.md).
# codex-app remains deliberately absent; see docs/codex-app-backend.md.
JG_BACKEND_KNOWN="tmux herdr zellij orca cmux hc"
JG_BACKEND_SPAWN="tmux herdr zellij orca cmux"

# jg_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. jg-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
jg_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

jg_backend_is_known() {  # <name>
  jg_backend_list_contains "$JG_BACKEND_KNOWN" "$1"
}

# jg_backend_detect: detect the runtime juggernaut itself is CURRENTLY executing
# inside, from verified environment markers (mirrors bin/jg-harness.sh's
# env-marker detection layer for harnesses). Prints the detected backend name
# and returns 0, or returns 1 when nothing is detected. Nesting resolves
# INNERMOST-first: tmux sets $TMUX in every process running inside it, even a
# tmux started inside a herdr pane, so $TMUX is checked first and wins over
# HERDR_ENV=1 in that nested case. herdr injects HERDR_ENV=1 (plus
# HERDR_SOCKET_PATH/HERDR_PANE_ID) into every process it manages a pane for;
# HERDR_ENV=1 alone (no $TMUX) selects herdr. cmux injects CMUX_WORKSPACE_ID
# (plus CMUX_SURFACE_ID/CMUX_SOCKET_PATH and the legacy CMUX_TAB_ID/
# CMUX_PANEL_ID aliases) into every terminal surface it spawns - verified from
# the shipped source (`TerminalSurface+StartupEnvironment.swift`'s
# `applyManagedCmuxContextEnvironment`, which marks all five keys
# `protectedKeys`, i.e. non-overridable) and corroborated by cmux's own CLI
# (`cmux_open.swift`) reading `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` as its own
# ambient-target fallback, exactly how `$TMUX` and `HERDR_ENV` work for their
# backends. CMUX_WORKSPACE_ID, not CMUX_SOCKET_PATH, is the chosen marker:
# CMUX_SOCKET_PATH is independently documented as a user-settable override for
# pointing the CLI at a non-default socket, so its mere presence would not
# reliably mean "running inside a cmux-spawned terminal" the way
# CMUX_WORKSPACE_ID does. cmux is checked LAST because it is a terminal
# application (the outermost layer, like iTerm2/Terminal.app), not a session
# multiplexer - both tmux and herdr can run nested inside a cmux-provided
# shell, but cmux cannot run nested inside either of them, so a tmux or herdr
# marker set alongside CMUX_WORKSPACE_ID always means that multiplexer is the
# innermost, currently-executing layer and must win.
#
# cmux FALLBACK signals (docs/cmux-backend.md "Runtime auto-detection" owns
# the empirical record): cmux's bundled `claude` PATH shim routes through
# cmux-claude-wrapper, whose passthrough path unsets every CMUX_* variable
# before exec'ing the real binary - so a claude-harness juggernaut launched in
# a cmux tab can have NO CMUX_WORKSPACE_ID at all. When that primary marker is
# absent (and only then), two macOS-only fallback signals are consulted:
#   1. __CFBundleIdentifier == com.cmuxterm.app - LaunchServices' app-identity
#      env var, inherited by every process a cmux tab spawns and NOT stripped
#      by the wrapper (it only unsets CMUX_*, TERMINFO, and CLAUDECODE).
#      Authoritative in the common wrapper-strip case, but also inherited into
#      every pane of a tmux server started from a cmux tab - the $TMUX check
#      winning FIRST is what keeps that false positive absorbed.
#   2. Process ancestry reaching the running cmux app (resolved by bundle id
#      via lsappinfo, plus a bundle-shaped `ps` comm match so the install
#      location is never hardcoded). Authoritative when the environment was
#      scrubbed entirely (no bundle id to inherit); NOT usable from inside
#      tmux, where the tmux server reparents to launchd and the chain never
#      reaches cmux - which is fine, because $TMUX already won there.
# Callers needing the winning signal read JG_BACKEND_DETECT_SIGNAL (set to
# TMUX, HERDR_ENV, CMUX_WORKSPACE_ID, bundle-id, or ancestry) and
# JG_BACKEND_DETECTED after a direct (non-command-substitution) call.
JG_BACKEND_CMUX_BUNDLE_ID="com.cmuxterm.app"

jg_backend_detect() {
  JG_BACKEND_DETECTED=""
  JG_BACKEND_DETECT_SIGNAL=""
  if [ -n "${TMUX:-}" ]; then
    JG_BACKEND_DETECTED=tmux
    JG_BACKEND_DETECT_SIGNAL=TMUX
    printf 'tmux'
    return 0
  fi
  if [ "${HERDR_ENV:-}" = "1" ]; then
    JG_BACKEND_DETECTED=herdr
    JG_BACKEND_DETECT_SIGNAL=HERDR_ENV
    printf 'herdr'
    return 0
  fi
  if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    JG_BACKEND_DETECTED=cmux
    JG_BACKEND_DETECT_SIGNAL=CMUX_WORKSPACE_ID
    printf 'cmux'
    return 0
  fi
  if jg_backend_detect_cmux_fallback; then
    JG_BACKEND_DETECTED=cmux
    printf 'cmux'
    return 0
  fi
  return 1
}

# jg_backend_detect_cmux_fallback: the two macOS-only cmux fallback signals
# (see jg_backend_detect's header comment). Sets JG_BACKEND_DETECT_SIGNAL to
# bundle-id or ancestry on success. Cheap-first: the bundle-id check is a pure
# env read; the ancestry walk (subprocess-per-hop) runs only when it misses.
jg_backend_detect_cmux_fallback() {
  [ "$(uname 2>/dev/null)" = Darwin ] || return 1
  if [ "${__CFBundleIdentifier:-}" = "$JG_BACKEND_CMUX_BUNDLE_ID" ]; then
    JG_BACKEND_DETECT_SIGNAL=bundle-id
    return 0
  fi
  if jg_backend_detect_cmux_app_is_ancestor; then
    JG_BACKEND_DETECT_SIGNAL=ancestry
    return 0
  fi
  return 1
}

# jg_backend_detect_cmux_app_pid: the running cmux app's pid, resolved by
# bundle id via lsappinfo (`"pid"=<n>`), or failure when lsappinfo is missing,
# errors, or the app is not running (lsappinfo prints nothing, exit 0).
jg_backend_detect_cmux_app_pid() {
  command -v lsappinfo >/dev/null 2>&1 || return 1
  local out pid
  out=$(lsappinfo info -only pid -app "$JG_BACKEND_CMUX_BUNDLE_ID" 2>/dev/null) || return 1
  pid=${out##*=}
  pid=$(printf '%s' "$pid" | tr -d '[:space:]"')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$pid"
}

# jg_backend_detect_cmux_app_is_ancestor: walk this process's parent chain and
# report whether it reaches the cmux app - matching either the lsappinfo-
# resolved pid (bundle id, no path assumption) or a bundle-shaped comm path
# (`*/cmux.app/Contents/MacOS/cmux`, any install location) when lsappinfo
# could not resolve one. Stops at launchd (ppid 1), where a tmux server that
# was started from a cmux tab has already reparented - ancestry can never
# false-positive from inside tmux.
jg_backend_detect_cmux_app_is_ancestor() {
  local cmux_pid pid ppid comm hops=0
  cmux_pid=$(jg_backend_detect_cmux_app_pid) || cmux_pid=""
  pid=$$
  while [ "$hops" -lt 32 ]; do
    if [ -n "$cmux_pid" ] && [ "$pid" = "$cmux_pid" ]; then
      return 0
    fi
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
    comm="${comm#"${comm%%[![:space:]]*}"}"
    comm="${comm%"${comm##*[![:space:]]}"}"
    [ -n "$comm" ] || return 1
    case "$comm" in
      */cmux.app/Contents/MacOS/cmux) return 0 ;;
    esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$ppid" -gt 1 ] || return 1
    pid=$ppid
    hops=$((hops + 1))
  done
  return 1
}

# jg_backend_name: resolve the ACTIVE backend for a NEW spawn, absent an
# explicit per-task override. Precedence: JG_BACKEND env, then config/backend
# (a single word on its first non-empty line, mirroring config/crew-harness),
# then runtime auto-detection (jg_backend_detect), then default tmux. A
# per-task `--backend` flag is parsed by the caller (jg-spawn.sh) and takes
# precedence over this resolution entirely; it is not read here. Auto-detect
# fires only when nothing was explicitly configured, so an explicit setting
# always wins. Auto-detected herdr stays silent like tmux. Selecting cmux via
# auto-detect prints one loud stderr notice because cmux remains experimental;
# the notice names the winning signal, so a fallback-detected cmux (bundle id or
# ancestry, after the claude wrapper stripped CMUX_WORKSPACE_ID) is visibly
# distinct from the primary-marker case.
jg_backend_name() {
  local line v detected marker
  if [ -n "${JG_BACKEND:-}" ]; then
    printf '%s' "$JG_BACKEND"
    return 0
  fi
  if [ -f "$JG_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    done < "$JG_BACKEND_CONFIG_DIR/backend"
  fi
  # Called directly (not in a command substitution) so the detect signal
  # globals survive into the notice below.
  if jg_backend_detect >/dev/null; then
    detected=$JG_BACKEND_DETECTED
    if [ "$detected" = cmux ]; then
      case "$JG_BACKEND_DETECT_SIGNAL" in
        bundle-id) marker="FALLBACK signal __CFBundleIdentifier=$JG_BACKEND_CMUX_BUNDLE_ID; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        ancestry) marker="FALLBACK signal process-ancestry reaching the running cmux app; CMUX_WORKSPACE_ID absent, stripped by cmux's bundled claude wrapper" ;;
        *) marker="CMUX_WORKSPACE_ID" ;;
      esac
      echo "NOTICE: auto-detected cmux runtime ($marker) - spawning into the EXPERIMENTAL cmux backend. Set config/backend or pass --backend tmux to opt out." >&2
    fi
    printf '%s' "$detected"
    return 0
  fi
  printf 'tmux'
}

# jg_backend_validate: refuse an unknown backend LOUDLY. Silent on success.
jg_backend_validate() {  # <name>
  local name=$1
  if ! jg_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $JG_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

jg_backend_validate_spawn() {  # <name>
  local name=$1
  jg_backend_validate "$name" || return 1
  jg_backend_list_contains "$JG_BACKEND_SPAWN" "$name" && return 0
  echo "error: backend '$name' does not support task spawning yet (spawn-supported: $JG_BACKEND_SPAWN)" >&2
  return 1
}

# jg_backend_required_tools: the backend-SPECIFIC CLI tools a juggernaut home on
# <backend> genuinely requires, beyond juggernaut's universal toolchain (owned by
# docs/configuration.md "Toolchain" and bootstrap's COMMON list). This is the
# single owner of the per-backend dependency delta, so bootstrap follows the
# RESOLVED backend instead of demanding an inactive backend's tools. Each set is:
#   - the session-provider CLI itself (tmux/herdr/zellij/orca/cmux);
#   - jq, for the JSON-emitting adapters (herdr, zellij, cmux) whose spawn/liveness
#     paths parse the backend's JSON output (see each adapter's
#     tool check, e.g. jg_backend_herdr_tool_check);
#   - the treehouse worktree provider for every session-provider-only backend
#     (tmux, herdr, zellij, cmux); orca owns its own task worktree and terminal,
#     so it drops both treehouse and any other backend's session CLI.
# Prints a single space-separated line and returns 0 for a known backend; returns
# 1 and prints nothing for an unknown backend.
jg_backend_required_tools() {  # <backend>
  case "$1" in
    tmux)   printf '%s' 'tmux treehouse python3' ;;
    herdr)  printf '%s' 'herdr jq treehouse python3' ;;
    zellij) printf '%s' 'zellij jq treehouse python3' ;;
    cmux)   printf '%s' 'cmux jq treehouse python3' ;;
    hc)     printf '%s' 'hc jq treehouse python3' ;;
    orca)   printf '%s' 'orca' ;;
    *) return 1 ;;
  esac
}

jg_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(jg_backend_required_tools "$backend") || return 1
  jg_backend_list_contains "$required" "$tool" || return 1
  case "$backend:$tool" in
    cmux:cmux)
      jg_backend_source cmux >/dev/null 2>&1 || return 1
      jg_backend_cmux_bin >/dev/null 2>&1
      ;;
    *) command -v "$tool" >/dev/null 2>&1 ;;
  esac
}

# jg_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every jg-*.sh script used to repeat inline.
jg_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 line value=''
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta" 2>/dev/null || true
  # compat (slice S1; deleted by S10): a record written before the rename names this kind with its old word.
  [ "$key" != kind ] || value=$(jg_compat_kind "$value")
  printf '%s' "$value"
}

# jg_backend_of_meta: the backend recorded in <meta-file>, defaulting to
# `tmux` when the field is absent - the P1 compatibility contract.
jg_backend_of_meta() {  # <meta-file>
  local v
  v=$(jg_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}

jg_backend_target_of_meta() {  # <meta-file>
  local meta=$1 backend terminal window
  backend=$(jg_backend_of_meta "$meta")
  if [ "$backend" = orca ]; then
    terminal=$(jg_meta_get "$meta" terminal)
    [ -n "$terminal" ] && { printf '%s' "$terminal"; return 0; }
  fi
  window=$(jg_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

# jg_meta_exited_on_purpose: succeeds when <meta-file>'s task has a
# `jg-control.sh exit` record (state/<id>.exit, an epoch) newer than its
# spawn_gen epoch, so the agent was stopped deliberately and no spawn or
# relaunch has superseded that. The record keeps its window= for relaunch and
# teardown; the watcher uses this to skip a stopped lane's endpoint, which may
# be dead, instead of treating it as stale on every arm.
jg_meta_exited_on_purpose() {  # <meta-file>
  local meta=$1 exited spawn
  exited=$(head -n 1 "${meta%.meta}.exit" 2>/dev/null)
  case "$exited" in ''|*[!0-9]*) return 1 ;; esac
  spawn=$(jg_meta_get "$meta" spawn_gen)
  spawn=${spawn#s}
  spawn=${spawn%%.*}
  case "$spawn" in ''|*[!0-9]*) spawn=0 ;; esac
  [ "$exited" -gt "$spawn" ]
}

# jg_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. New non-tmux records carry endpoint_task_id because their
# opaque runtime ids do not encode the task label. Legacy tmux records remain
# valid only when their window name itself is exactly jg-<task-id>.
# On success, sets JG_BACKEND_VALIDATED_BACKEND and
# JG_BACKEND_VALIDATED_TARGET. On failure, prints one refusal and returns 1.
jg_backend_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

jg_backend_endpoint_atom_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

# An Orca worktree id is the composite `<orca id>::<absolute worktree path>`
# that Orca itself returns, so the `:` and `/` characters every real value
# carries make the simple-atom check reject it. Juggernaut hands the id back to
# Orca opaquely and resolves it through Orca before removing anything, so this
# proves only the shape that can name one worktree: both halves of the first
# `::` split present, and the path half absolute.
jg_backend_orca_worktree_id_valid() {  # <value>
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    *::*) ;;
    *) return 1 ;;
  esac
  [ -n "${1%%::*}" ] || return 1
  case "${1#*::}" in
    /*) ;;
    *) return 1 ;;
  esac
}

jg_backend_validate_task_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend_count backend window worktree project binding_count binding
  local session pane recorded_session workspace tab terminal worktree_id surface
  JG_BACKEND_VALIDATED_BACKEND=
  JG_BACKEND_VALIDATED_TARGET=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id has no regular endpoint metadata at $meta; preserving task state." >&2
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    echo "REFUSED: task endpoint identity has an invalid task id; preserving task state." >&2
    return 1
  esac
  window=$(jg_backend_meta_exact_value "$meta" window) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous window endpoint; preserving task state." >&2
    return 1
  }
  worktree=$(jg_backend_meta_exact_value "$meta" worktree) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." >&2
    return 1
  }
  project=$(jg_backend_meta_exact_value "$meta" project) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous project identity; preserving task state." >&2
    return 1
  }
  case "$worktree$project$window" in *$'\n'*|*$'\r'*|*$'\t'*)
    echo "REFUSED: task $id has malformed endpoint metadata; preserving task state." >&2
    return 1
  esac
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0) backend=tmux ;;
    1) backend=$(jg_backend_meta_exact_value "$meta" backend) || backend= ;;
    *) backend= ;;
  esac
  if [ -z "$backend" ] || ! jg_backend_is_known "$backend"; then
    echo "REFUSED: task $id has a missing, ambiguous, or unknown backend identity; preserving task state." >&2
    return 1
  fi
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) binding= ;;
    1)
      binding=$(jg_backend_meta_exact_value "$meta" endpoint_task_id) || {
        echo "REFUSED: task $id has an empty endpoint task binding; preserving task state." >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: task $id has an ambiguous endpoint task binding; preserving task state." >&2
      return 1
      ;;
  esac
  if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
    echo "REFUSED: endpoint metadata belongs to task $binding, not $id; preserving task state." >&2
    return 1
  fi

  case "$backend" in
    tmux)
      session=${window%%:*}
      pane=${window#*:}
      if [ "$pane" = "$window" ] || [ "$pane" != "jg-$id" ] \
        || [ -z "$session" ]; then
        echo "REFUSED: tmux endpoint '$window' is malformed or does not belong to task $id; preserving task state." >&2
        return 1
      fi
      ;;
    herdr)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy Herdr endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      recorded_session=$(jg_backend_meta_exact_value "$meta" herdr_session) || recorded_session=
      workspace=$(jg_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
      tab=$(jg_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
      pane=$(jg_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
      if [ -z "$recorded_session" ] || [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! jg_backend_endpoint_atom_valid "$recorded_session" \
        || ! jg_backend_endpoint_atom_valid "$workspace" \
        || ! jg_backend_endpoint_atom_valid "${tab//:/_}" \
        || ! jg_backend_endpoint_atom_valid "${pane//:/_}"; then
        echo "REFUSED: Herdr endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
    zellij)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy Zellij endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      recorded_session=$(jg_backend_meta_exact_value "$meta" zellij_session) || recorded_session=
      tab=$(jg_backend_meta_exact_value "$meta" zellij_tab_id) || tab=
      pane=$(jg_backend_meta_exact_value "$meta" zellij_pane_id) || pane=
      case "$tab:$pane" in *[!0-9:]*) tab= ;; esac
      if [ -z "$recorded_session" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! jg_backend_endpoint_atom_valid "$recorded_session"; then
        echo "REFUSED: Zellij endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
    orca)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy Orca endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      terminal=$(jg_backend_meta_exact_value "$meta" terminal) || terminal=
      worktree_id=$(jg_backend_meta_exact_value "$meta" orca_worktree_id) || worktree_id=
      [ -n "$terminal" ] || {
        echo "REFUSED: missing terminal in $meta; cannot close Orca endpoint; preserving task state." >&2
        return 1
      }
      [ -n "$worktree_id" ] || {
        echo "REFUSED: missing orca_worktree_id in $meta; cannot remove Orca worktree; preserving task state." >&2
        return 1
      }
      if [ "$window" != "jg-$id" ] \
        || ! jg_backend_endpoint_atom_valid "$terminal" \
        || ! jg_backend_orca_worktree_id_valid "$worktree_id"; then
        echo "REFUSED: Orca endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      window=$terminal
      ;;
    cmux)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy cmux endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      workspace=$(jg_backend_meta_exact_value "$meta" cmux_workspace_id) || workspace=
      surface=$(jg_backend_meta_exact_value "$meta" cmux_surface_id) || surface=
      if [ -z "$workspace" ] || [ -z "$surface" ] || [ "$window" != "$workspace:$surface" ] \
        || ! jg_backend_endpoint_atom_valid "$workspace" \
        || ! jg_backend_endpoint_atom_valid "$surface"; then
        echo "REFUSED: cmux endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
    hc)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: hc endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      recorded_session=$(jg_backend_meta_exact_value "$meta" hc_session) || recorded_session=
      terminal=$(jg_backend_meta_exact_value "$meta" hc_terminal) || terminal=
      case "$terminal" in t[0-9]*) ;; *) terminal= ;; esac
      case "$terminal" in *[!a-z0-9]*) terminal= ;; esac
      if [ -z "$recorded_session" ] || [ -z "$terminal" ] \
        || [ "$window" != "$recorded_session:$terminal" ] \
        || ! jg_backend_endpoint_atom_valid "$recorded_session"; then
        echo "REFUSED: hc endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
  esac
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  JG_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  JG_BACKEND_VALIDATED_TARGET=$window
  return 0
}

jg_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window terminal
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(jg_meta_get "$meta" window)
    terminal=$(jg_meta_get "$meta" terminal)
    { [ -n "$window" ] && [ "$window" = "$target" ]; } || { [ -n "$terminal" ] && [ "$terminal" = "$target" ]; } || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

jg_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    jg-*)
      id=${raw#jg-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

jg_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(jg_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

jg_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  meta=$(jg_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$meta" ] && { jg_backend_of_meta "$meta"; return 0; }
  if [ -n "$resolved" ]; then
    meta=$(jg_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { jg_backend_of_meta "$meta"; return 0; }
  fi
  printf 'tmux'
}

jg_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(jg_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'jg-%s' "$id"
  return 0
}

# jg_backend_source: source the named backend's adapter file, once per shell.
# Each adapter is an independently linted canonical root. The /dev/null source
# boundaries keep runtime dispatch from importing all five adapter ASTs into
# every dispatcher consumer while preserving the runtime source operations.
# Bash 3.2 can enter an EXIT trap with status 0 after `set -e` aborts on a
# missing or unreadable dot-sourced file, and a newer Bash can print that
# diagnostic and keep going. Both report a successful teardown. Prove the
# adapter and the siblings it sources are readable regular files before `.`.
jg_backend_source_readable() {  # <path>
  [ -f "$1" ] && [ -r "$1" ]
}

jg_backend_source() {  # <name>
  local name=$1 adapter rel sibling
  jg_backend_validate "$name" || return 1
  adapter="$JG_BACKEND_LIB_DIR/backends/$name.sh"
  # The sibling list rides in the positional parameters: zsh does not
  # word-split an unquoted expansion, so a space-separated string is one path.
  case "$name" in
    tmux)
      set -- jg-tmux-lib.sh jg-composer-lib.sh jg-cursor-lib.sh jg-session-lock-lib.sh jg-agent-process-lib.sh jg-gemini-lib.sh
      ;;
    herdr)
      set -- jg-composer-lib.sh jg-transition-lib.sh jg-agent-process-lib.sh jg-session-lock-lib.sh jg-gemini-lib.sh
      ;;
    zellij)
      set -- jg-backend-hometag-lib.sh jg-composer-lib.sh
      ;;
    orca)
      set -- jg-composer-lib.sh
      ;;
    cmux)
      set -- jg-backend-hometag-lib.sh jg-composer-lib.sh
      ;;
    hc)
      set -- jg-composer-lib.sh jg-agent-process-lib.sh jg-session-lock-lib.sh jg-gemini-lib.sh
      ;;
    *)
      return 1
      ;;
  esac
  jg_backend_source_readable "$adapter" || return 1
  for rel in "$@"; do
    sibling="$JG_BACKEND_LIB_DIR/$rel"
    jg_backend_source_readable "$sibling" || return 1
  done
  case "$name" in
    tmux)
      if [ -z "${_JG_BACKEND_TMUX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_TMUX_SOURCED=1
      fi
      ;;
    herdr)
      if [ -z "${_JG_BACKEND_HERDR_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_HERDR_SOURCED=1
      fi
      ;;
    zellij)
      if [ -z "${_JG_BACKEND_ZELLIJ_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_ZELLIJ_SOURCED=1
      fi
      ;;
    orca)
      if [ -z "${_JG_BACKEND_ORCA_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_ORCA_SOURCED=1
      fi
      ;;
    cmux)
      if [ -z "${_JG_BACKEND_CMUX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_CMUX_SOURCED=1
      fi
      ;;
    hc)
      if [ -z "${_JG_BACKEND_HC_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$adapter" || return 1
        _JG_BACKEND_HC_SOURCED=1
      fi
      ;;
  esac
}

# jg_backend_resolve_selector: resolve a raw jg-send.sh/jg-peek.sh style
# selector to a live session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for a window/pane outside
#                      this juggernaut home) - backend-independent, a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's backend target
#                      (`window=` normally, `terminal=` for Orca) -
#                      backend-independent, a stored value, NOT re-verified
#                      against a live backend inventory (matches today's
#                      behavior: tmux window names can be trusted from meta
#                      without a live re-check).
#   "jg-<id>"          legacy task window label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/jg-<id>.meta exists.
#   anything else      first matched against recorded `window=`/`terminal=`
#                      metadata, then treated as an ad hoc bare window name and
#                      resolved by searching the legacy tmux live inventory.
jg_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(jg_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    window=$(jg_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    jg-*)
      echo "error: no metadata for $raw in $state; pass session:window to target a window outside this juggernaut home" >&2
      return 1
      ;;
    *)
      meta=$(jg_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(jg_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      jg_backend_source tmux || return 1
      jg_backend_tmux_resolve_bare_selector "$raw"
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin case-dispatch wrappers so a caller names an operation and a backend
# rather than hand-writing `case "$backend" in tmux) jg_backend_tmux_x ;; esac`
# at every call site. Each verified backend adds its own arm here, without
# changing call sites.

# jg_backend_capture: bounded plain-text session capture.
jg_backend_capture() {  # <backend> <target> <lines> [expected-label]
  local backend=$1
  shift
  jg_backend_source "$backend" || return 1
  case "$backend" in
    tmux) jg_backend_tmux_capture "$@" ;;
    herdr) jg_backend_herdr_capture "$@" ;;
    zellij) jg_backend_zellij_capture "$@" ;;
    orca) jg_backend_orca_capture "$@" ;;
    cmux) jg_backend_cmux_capture "$@" ;;
    hc) jg_backend_hc_capture "$@" ;;
    *) echo "error: no capture implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# JG_BACKEND_VISIBLE_CAPTURE: backends with a verified viewport-only read, each
# implementing jg_backend_<name>_visible_capture. This one list answers both the
# capability question and the dispatch, so they cannot disagree. cmux is absent
# pending live verification: its `read-screen` without `--scrollback` plausibly
# reads only the viewport, but that has not been observed on a real cmux, and
# the adapter's own capture opts into history with `--scrollback`. orca's
# `terminal read --limit` is a history read with no viewport mode. hc's `read`
# without --lines is the screen alone (proven by the hc lab journey).
JG_BACKEND_VISIBLE_CAPTURE="tmux herdr zellij hc"

# jg_backend_visible_capture_supported: whether <backend> can read the visible
# viewport WITHOUT scrollback. Callers that must not mistake a scrolled-away
# frame for the live screen ask this first and fail closed on a no.
jg_backend_visible_capture_supported() {  # <backend>
  jg_backend_list_contains "$JG_BACKEND_VISIBLE_CAPTURE" "$1"
}

# jg_backend_visible_capture: the visible viewport, never scrollback. A backend
# outside JG_BACKEND_VISIBLE_CAPTURE declines here rather than answering with a
# history-backed capture the caller would read as the live screen.
jg_backend_visible_capture() {  # <backend> <target> [expected-label]
  local backend=$1
  shift
  jg_backend_visible_capture_supported "$backend" || {
    echo "error: backend '$backend' has no verified viewport-bounded capture primitive" >&2
    return 1
  }
  jg_backend_source "$backend" || return 1
  "jg_backend_${backend}_visible_capture" "$@"
}

# jg_backend_send_key: one backend-supported named special key.
jg_backend_send_key() {  # <backend> <target> <key> [expected-label]
  local backend=$1
  shift
  jg_backend_source "$backend" || return 1
  case "$backend" in
    tmux) jg_backend_tmux_send_key "$@" ;;
    herdr) jg_backend_herdr_send_key "$@" ;;
    zellij) jg_backend_zellij_send_key "$@" ;;
    orca) jg_backend_orca_send_key "$@" ;;
    cmux) jg_backend_cmux_send_key "$@" ;;
    hc) jg_backend_hc_send_key "$@" ;;
    *) echo "error: no send-key implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

# jg_backend_doorbell_stale: whether <text> is a record-backed doorbell whose
# record is gone (bin/jg-operational-input.sh owns the test). The text submit
# below drops such a ring before it types, and the tmux and Herdr adapters drop
# it again just before their first Enter, with the verdict `record-missing`.
jg_backend_doorbell_stale() {  # <text>
  if ! type jg_operational_doorbell_stale >/dev/null 2>&1; then
    # shellcheck source=bin/jg-operational-input.sh
    . "$JG_BACKEND_LIB_DIR/jg-operational-input.sh" 2>/dev/null || return 1
  fi
  jg_operational_doorbell_stale "${1-}"
}

# jg_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the backend's
# proof-carrying verdict; callers require exact empty for confirmed delivery.
# A pane that already shows the recognised dialog is refused before any
# adapter types, so that submit neither types the text nor sends Enter.
jg_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1 rc=0 target label dialog
  shift
  target=$1
  label=${6:-}
  jg_backend_source "$backend" || return 1
  if jg_backend_doorbell_stale "${2-}"; then
    printf 'record-missing'
    return 0
  fi
  # Every Enter loop below reads the dialog sink, so it must exist before
  # any adapter types: a sink that fails here leaves the composer untouched.
  jg_composer_dialog_sink_prepare || {
    echo "error: the dialog check for a $backend submit could not be recorded" >&2
    return 1
  }
  # One composer read after the sink exists and before the adapter types.
  # The classify writes the sink; a named dialog means the next Enter would
  # answer it.
  if [ -n "$label" ]; then
    jg_backend_composer_state "$backend" "$target" "$label" >/dev/null || true
  else
    jg_backend_composer_state "$backend" "$target" >/dev/null || true
  fi
  if dialog=$(jg_composer_blocking_dialog_noted); then
    jg_composer_dialog_sink_release
    echo "error: blocked on a prompt: $dialog" >&2
    return 1
  fi
  case "$backend" in
    tmux) jg_backend_tmux_send_text_submit "$@" || rc=$? ;;
    herdr) jg_backend_herdr_send_text_submit "$@" || rc=$? ;;
    zellij) jg_backend_zellij_send_text_submit "$@" || rc=$? ;;
    orca) jg_backend_orca_send_text_submit "$@" || rc=$? ;;
    cmux) jg_backend_cmux_send_text_submit "$@" || rc=$? ;;
    hc) jg_backend_hc_send_text_submit "$@" || rc=$? ;;
    *) echo "error: no send-text implementation for backend '$backend'" >&2; rc=1 ;;
  esac
  jg_composer_dialog_sink_release
  return "$rc"
}

# jg_backend_send_nudge: deliver one machine-typed line (a doorbell or a wake)
# without ever leaving it behind in a human's input box. Nothing is typed unless
# the line could be taken back out: the backend must have a clear-line key, and
# a composer that already holds text is never touched (verdict `holds-text`,
# `not-withdrawable`). After the submit, a line that is still sitting in the
# composer - read back and proven to be exactly what we typed, nothing before
# or after it - is withdrawn with the clear key until the composer reads empty
# (verdict `withdrawn`; `stuck` when it still will not clear). Any other content
# is a human's and is left alone. Echoes the verdict: `empty` is the only
# confirmed delivery, and `withdrawn` means the line was taken back, so the
# durable record is still undelivered and a later ring is right.
# Callers must treat `holds-text`, `not-withdrawable`, and `withdrawn` as
# "nothing was delivered or left behind".
jg_backend_send_nudge() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local backend=$1 target=$2 text=$3 label=${7:-} verdict held
  case "$backend" in
    tmux|herdr|zellij|cmux) ;;
    *) printf 'not-withdrawable'; return 0 ;;
  esac
  jg_backend_source "$backend" || return 1
  if [ "$(jg_backend_composer_state "$backend" "$target" "$label" 2>/dev/null)" = pending ]; then
    printf 'holds-text'
    return 0
  fi
  verdict=$(jg_backend_send_text_submit "$backend" "$target" "$text" "$4" "$5" "$6" "$label") || return $?
  case "$verdict" in
    empty|record-missing|send-failed|dead|missing) printf '%s' "$verdict"; return 0 ;;
  esac
  held=$(jg_backend_withdraw_typed "$backend" "$target" "$text" "$label")
  case "$held" in
    empty|foreign) printf '%s' "$verdict" ;;
    *) printf '%s' "$held" ;;
  esac
}

# jg_backend_withdraw_typed: take <text> back out of the composer if, and only
# if, the composer holds exactly that text (ignoring whitespace and wrapping).
# Echoes `empty` (nothing there to withdraw), `withdrawn`, `foreign` (other
# content: a human's, never keyed), or `stuck` (ours, but it will not clear).
jg_backend_withdraw_typed() {  # <backend> <target> <text> [expected-label]
  local backend=$1 target=$2 want=${3//[[:space:]]/} label=${4:-} held i=0
  while [ "$i" -lt 6 ]; do
    held=$(jg_backend_capture "$backend" "$target" "$JG_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) \
      && held=$(jg_composer_extract_selected_content styled=0 "$held") || held=
    held=${held//[[:space:]]/}
    if [ -z "$held" ]; then
      if [ "$i" -eq 0 ]; then printf 'empty'; else printf 'withdrawn'; fi
      return 0
    fi
    [ "$held" = "$want" ] || { printf 'foreign'; return 0; }
    jg_backend_send_key "$backend" "$target" C-u "$label" >/dev/null 2>&1 || break
    sleep 0.2
    i=$((i + 1))
  done
  printf 'stuck'
}

# jg_backend_resubmit_typed: submit <text> again (Enter only, never retyped) if,
# and only if, the composer holds exactly that text, ignoring whitespace,
# wrapping, and trailing control residue. Echoes `foreign` (other content: a
# human's, never keyed), `empty` (submitted), or the last composer verdict.
jg_backend_resubmit_typed() {  # <backend> <target> <text> <retries> <enter-sleep> [expected-label]
  local backend=$1 target=$2 want=${3//[[:space:]]/} retries=$4 sleep_s=$5 label=${6:-} held state=foreign i=0
  held=$(jg_backend_capture "$backend" "$target" "$JG_COMPOSER_CAPTURE_LINES" "$label" 2>/dev/null) \
    && held=$(jg_composer_extract_selected_content styled=0 "$held") || held=
  held=${held//[[:space:]]/}
  [ -n "$want" ] && [ "${held#"$want"}" != "$held" ] && [ -z "$(printf '%s' "${held#"$want"}" | tr -d '[:cntrl:]')" ] \
    || { printf 'foreign'; return 0; }
  while [ "$i" -lt "$retries" ]; do
    jg_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || true
    sleep "$sleep_s"
    state=$(jg_backend_composer_state "$backend" "$target" "$label" 2>/dev/null)
    [ "$state" = pending ] || break
    i=$((i + 1))
  done
  printf '%s' "$state"
}

# jg_backend_kill: remove the task's session endpoint. An already-gone target
# is NOT an error and returns 0 silently, so ordinary cleanup of an
# already-exited session stays quiet. A nonzero return means the close could
# not do its job and the endpoint may still be live: the caller owns that
# refusal and must not delete the durable records that are the only thing
# naming the endpoint (bin/jg-teardown.sh's retain-and-stop path).
# How much each adapter can prove differs, and no arm ever guesses: tmux
# resolves a failed close against the window's exact recorded identity, Orca
# reports a close its missing CLI never attempted, and the remaining arms
# still report 0 for a close command that failed after being accepted.
# docs/verification/runtime-backends.md "Endpoint close" is the per-backend
# record.
jg_backend_kill() {  # <backend> <target>
  local backend=$1
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  jg_backend_source "$backend" || return 1
  case "$backend" in
    tmux) jg_backend_tmux_kill "$@" ;;
    herdr) jg_backend_herdr_kill "$@" ;;
    zellij) jg_backend_zellij_kill "$@" ;;
    orca) jg_backend_orca_kill "$@" ;;
    cmux) jg_backend_cmux_kill "$@" ;;
    hc) jg_backend_hc_kill "$@" ;;
    *) echo "error: no kill implementation for backend '$backend'" >&2; return 1 ;;
  esac
}

jg_backend_remove_worktree() {  # <backend> <worktree-id>
  local backend=$1
  shift
  jg_backend_source "$backend" || return 1
  case "$backend" in
    orca) jg_backend_orca_remove_worktree "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

jg_backend_worktree_path() {  # <backend> <worktree-id>
  local backend=$1
  shift
  jg_backend_source "$backend" || return 1
  case "$backend" in
    orca) jg_backend_orca_worktree_path "$@" ;;
    *) echo "error: backend '$backend' does not own task worktrees" >&2; return 1 ;;
  esac
}

# jg_backend_busy_state: semantic busy/idle/unknown for backends that expose
# native agent-state (herdr-addendum "busy state" row - the first backend
# where this gets real semantics beyond pane-regex). Backends with no such
# primitive (tmux) report unknown. Callers own the fallback policy: jg-watch.sh
# uses unknown as the cue for harness-scoped pane-tail detection, while
# jg-crew-state.sh also corroborates native idle verdicts with the recorded
# harness's signature before treating a no-run crew as not busy.
jg_backend_busy_state() {  # <backend> <target>
  local backend=$1
  shift
  jg_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    herdr) jg_backend_herdr_busy_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# jg_backend_composer_state: classify the composer/input area of <target> as
# empty|pending|pending-unproven|unknown for callers that need a pre-submit
# input guard, a submit acknowledgement, or a launch-readiness check. It is
# exposed so a caller other than the send path (the away-mode daemon's
# supervisor-pane pending-input guard in bin/jg-supervise-daemon.sh, and
# jg-spawn.sh's kimi readiness/delivery checks) can ask the same question
# without duplicating per-backend composer reading. Every adapter's named
# classifier is a THIN wrapper - capture plus a capability descriptor fed to
# the one shared shape owner (bin/jg-composer-lib.sh,
# jg_composer_classify_screen) - so no backend can hold a private shape
# assumption; zellij's classifier reads `dump-screen --ansi`, which replaced
# its old no-classifier content-diff reporting.
jg_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local backend=$1
  shift
  jg_backend_source "$backend" || { printf 'unknown'; return 0; }
  case "$backend" in
    tmux) jg_tmux_composer_state "$@" ;;
    herdr) jg_backend_herdr_composer_state "$@" ;;
    orca) jg_backend_orca_composer_state "$@" ;;
    cmux) jg_backend_cmux_composer_state "$@" ;;
    zellij) jg_backend_zellij_composer_state "$@" ;;
    hc) jg_backend_hc_composer_state "$@" ;;
    *) printf 'unknown' ;;
  esac
}

# jg_backend_target_exists: cheap, READ-ONLY existence check - does the
# recorded TARGET endpoint still exist on BACKEND? Never starts a server or
# session: for herdr this deliberately queries the pane directly instead of
# going through jg_backend_herdr_target_ready (which auto-starts the herdr
# server as a side effect via jg_backend_herdr_server_ensure - fine for an
# operation that is about to use the pane, wrong for a passive liveness
# probe). A gone tmux window or an unqueryable herdr pane (server down, pane
# closed), missing zellij pane, or unreadable Orca terminal simply fails, which
# IS "does not exist" for this purpose.
# Mirrors jg-crew-state.sh's pane_readable check; exists here as one shared
# primitive so callers that only need a fast alive/dead read (recovery
# digests, the session-start fleet digest) do not re-derive it inline.
jg_backend_target_exists() {  # <backend> <target> [expected-label]
  local backend=$1 target=$2 expected_label=${3:-} session pane
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
      ;;
    herdr)
      jg_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      # jg_backend_herdr_cli (not a raw HERDR_SESSION-only call): verified
      # empirically (docs/herdr-backend.md "Session targeting") that the bare
      # env var alone is NOT reliably honored once another herdr server is
      # already bound on the machine - it silently queries whatever server IS
      # running instead. jg_backend_herdr_cli appends the required --session
      # flag on top, so this check is correctly scoped even when the caller's
      # own ambient session (e.g. the primary juggernaut's default session) is
      # a DIFFERENT one than the target's.
      jg_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    zellij)
      jg_backend_source zellij || return 1
      jg_backend_zellij_target_ready "$target" "$expected_label"
      ;;
    orca)
      jg_backend_source orca || return 1
      jg_backend_orca_capture "$target" 1 >/dev/null 2>&1
      ;;
    cmux)
      jg_backend_source cmux || return 1
      jg_backend_cmux_target_ready "$target" "$expected_label"
      ;;
    hc)
      jg_backend_source hc || return 1
      jg_backend_hc_target_exists "$target"
      ;;
    *)
      return 1
      ;;
  esac
}

# jg_backend_agent_state: the single recovery-grade agent/endpoint state
# contract. It is deliberately richer than jg_backend_target_exists's cheap
# pane-presence read and prints exactly one of:
#   alive      - a verified harness agent is running.
#   dead       - the endpoint exists but confidently has no agent.
#   missing    - the recorded endpoint is authoritatively absent.
#   ambiguous  - the endpoint exists but its process cannot be attributed.
#   unreadable - a target or inventory read failed or contradicted itself.
#   unverified - this backend has no recovery classifier.
# Only `dead` and `missing` license recovery. Every `alive` is proven at
# process level through the shared classifier in bin/jg-agent-process-lib.sh,
# never from a registration or a rendered title alone. The tmux adapter
# requires a successful session inventory and returns `missing` only when it
# omits the exact window; the Herdr adapter reuses its strict husk classifier -
# which verifies a registered agent against `pane process-info` and the real
# process table, so a registration Herdr kept over a shell-only pane reads
# `dead` here (issue #4115) - then maps a positively stopped session server to
# `missing` only in this recovery-grade view. Zellij remains unverified because
# its squad_lead ghost-tab and agent-process recovery path has not been
# empirically validated. Orca and cmux do not support squad_lead spawns.
# The hc adapter reads its terminal record: hc's own not_found is `missing`, a
# finished terminal `dead`, and a live one is judged by its foreground process.
jg_backend_agent_state() {  # <backend> <target> [<meta> <task-id>]
  local backend=$1 target=$2
  jg_backend_source "$backend" || { printf 'unverified'; return 0; }
  case "$backend" in
    tmux) jg_backend_tmux_agent_state "$target" ;;
    herdr) jg_backend_herdr_agent_state "$target" "${3:-}" "${4:-}" ;;
    hc) jg_backend_hc_agent_state "$target" ;;
    *) printf 'unverified' ;;
  esac
}

# jg_backend_agent_exited: 0 only when <backend> proves from the process level
# that the present <target> holds nothing but a shell, i.e. the harness that
# ran there has exited. Unlike jg_backend_agent_state's `dead`, a missing
# registration never counts: Herdr answers agent_not_found for live harnesses
# it does not detect (docs/verification/rovo.md), so only its process view is
# trusted here. Every unproven read returns 1.
jg_backend_agent_exited() {  # <backend> <target>
  jg_backend_source "$1" || return 1
  case "$1" in
    tmux) [ "$(jg_backend_tmux_agent_state "$2")" = dead ] ;;
    herdr) jg_backend_herdr_agent_exited "$2" ;;
    hc) jg_backend_hc_agent_exited "$2" ;;
    *) return 1 ;;
  esac
}

# jg_backend_target_absent: whether <backend> authoritatively reports the exact
# recorded <target> gone. Prints one verdict: `absent` when a read happened and
# the backend definitively does not have the target, `present` when a read
# happened and the target exists, and `uncertain` when the read proves nothing
# either way - the backend being down or unreachable, a timeout, an
# unimplemented adapter, or an unparseable target. Each adapter owns what
# "definitively" means for it (bin/backends/<name>.sh owns each contract); the
# shared bar every implementation must hold is that absence is claimed only on
# the backend's OWN authoritative answer, never on a failed read, because a
# backend that restores state on restart (herdr) brings its targets back.
# A caller that destroys per-window state on absence must prune only on
# `absent` and keep everything on `uncertain`.
jg_backend_target_absent() {  # <backend> <target>
  local backend=$1 target=$2
  jg_backend_source "$backend" || { printf 'uncertain'; return 0; }
  case "$backend" in
    tmux) jg_backend_tmux_target_absent "$target" ;;
    herdr) jg_backend_herdr_target_absent "$target" ;;
    hc) jg_backend_hc_target_absent "$target" ;;
    *) printf 'uncertain' ;;
  esac
}

# Backward-compatible three-state view for existing callers. An
# authoritatively missing endpoint is confidently not a live agent, while every
# ambiguous, unreadable, or unverified result stays unknown.
jg_backend_agent_alive() {  # <backend> <target>
  case "$(jg_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# --- native event push (backend-extensible) ---------------------------------
#
# The watcher's event-wait splice (bin/jg-watch.sh) is backend-agnostic: it asks
# jg_backend_has_push whether a window's backend can push semantic state changes,
# and for those backends replaces its blind `sleep POLL` with a bounded wait on
# jg_backend_wait_transition. Every push-capable backend reuses the shared
# normalized-transition shape and policy table (bin/jg-transition-lib.sh); today
# only herdr implements the surface (docs/herdr-backend.md "Native
# pane.agent_status_changed push escalation"). A backend with no native push
# reports has-push false and returns 2 from the dispatchers below, so the
# watcher falls back to its poll loop - the permanent fail-closed backstop.

# jg_backend_has_push: 0 if <backend> exposes a native transition push stream.
jg_backend_has_push() {  # <backend>
  case "$1" in
    herdr) return 0 ;;
    *) return 1 ;;
  esac
}

# jg_backend_events_capable: 0 if <backend>'s push path is usable for <session>
# right now (version/schema/reader gate). Non-push backends are never capable.
# The watcher memoizes this per session so the potentially heavy capability
# probe is not repeated every poll.
jg_backend_events_capable() {  # <backend> <session>
  local backend=$1
  shift
  jg_backend_has_push "$backend" || return 1
  jg_backend_source "$backend" || return 1
  case "$backend" in
    herdr) jg_backend_herdr_events_capable "$@" ;;
    *) return 1 ;;
  esac
}

# jg_backend_wait_transition: bounded wait for a fresh actionable (blocked)
# transition on one of <pane_window...> in <session>, up to <timeout_secs>.
# Prints the normalized transition record and returns 0 on a fresh actionable
# edge; returns 1 on a clean timeout (the caller has effectively already slept);
# returns 2 when the event path is unusable (the caller sleeps the budget
# itself). Non-push backends always return 2.
jg_backend_wait_transition() {  # <backend> <session> <timeout_secs> <state_dir> <pane_window...>
  local backend=$1
  shift
  jg_backend_has_push "$backend" || return 2
  jg_backend_source "$backend" || return 2
  case "$backend" in
    herdr) jg_backend_herdr_wait_transition "$@" ;;
    *) return 2 ;;
  esac
}

jg_backend_commit_transition() {  # <backend> <state_dir> <session> <record>
  local backend=$1
  shift
  jg_backend_has_push "$backend" || return 1
  jg_backend_source "$backend" || return 1
  case "$backend" in
    herdr) jg_backend_herdr_commit_transition "$@" ;;
    *) return 1 ;;
  esac
}

jg_backend_clear_transition() {  # <backend> <state_dir> <window>
  local backend=$1
  shift
  jg_backend_has_push "$backend" || return 0
  jg_backend_source "$backend" || return 1
  case "$backend" in
    herdr) jg_backend_herdr_clear_transition "$@" ;;
    *) return 0 ;;
  esac
}
