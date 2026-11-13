#!/usr/bin/env bash
# Execute one tracked Juggernaut command in a configured remote squad_lead home.
#
# Usage:
#   jg-on.sh [--stdin] <squad-lead-id|unambiguous-ssh-alias> <jg-command> [args...]
#
# Routes come only from remote records in data/squad_leads.md, or, when none of
# them matches, from a runner registered in config/runners (core/runners/
# registry.sh; the route is the runner id). A record names an
# SSH config alias, remote Juggernaut code root, and remote JG_HOME. A host alias
# may be used directly only when exactly one record selects it; an ambiguous
# alias is refused. The command must be a genuine executable in this checkout's
# bin/jg-*.sh namespace. No per-command table exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# jg-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. JG_SSH_ALIVE_INTERVAL and JG_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
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
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
REG="$(jg_compat_pick "$DATA/squad_leads.md")"
PROTOCOL=1

# shellcheck source=bin/jg-squad-lead-registry-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
if [ "${1:-}" = --stdin ]; then
  STDIN_MODE=caller
  shift
fi
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe squad_lead id or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  jg-*.sh) ;;
  *) die "remote command must be a basename in the jg-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$JG_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Juggernaut checkout: $COMMAND"
git -C "$JG_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Juggernaut checkout: $COMMAND"
[ ! -L "$REG" ] || die "no safe squad_lead registry at $REG"

MATCHES=0
HOST=
ROOT=
HOME_PATH=
[ -f "$REG" ] || REG=/dev/null
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  squad_lead_registry_parse_line "$line" || die "malformed squad_lead registry entry: $line"
  [ "$SQUAD_LEAD_REGISTRY_REMOTE" -eq 1 ] || continue
  if [ "$SQUAD_LEAD_REGISTRY_ID" = "$ROUTE" ] || [ "$SQUAD_LEAD_REGISTRY_HOST" = "$ROUTE" ]; then
    MATCHES=$((MATCHES + 1))
    HOST=$SQUAD_LEAD_REGISTRY_HOST
    ROOT=$SQUAD_LEAD_REGISTRY_ROOT
    HOME_PATH=$SQUAD_LEAD_REGISTRY_HOME
  fi
done < "$REG"
if [ "$MATCHES" -eq 0 ] && runner=$("$JG_ROOT/core/runners/registry.sh" get "$JG_HOME" "$ROUTE" 2>/dev/null); then
  MATCHES=1
  HOST=$(printf '%s\n' "$runner" | sed -n 's/^ssh=//p')
  ROOT=$(printf '%s\n' "$runner" | sed -n 's/^root=//p')
  HOME_PATH=$(printf '%s\n' "$runner" | sed -n 's/^home=//p')
fi
[ "$MATCHES" -gt 0 ] || die "no remote squad_lead, runner or SSH alias matches '$ROUTE'"
[ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured squad_leads; use a squad_lead id"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${JG_SSH_BIN:-ssh}
ALIVE_INTERVAL=${JG_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${JG_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "JG_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "JG_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "JG_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "JG_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" jg-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
if [ "$STDIN_MODE" = caller ]; then
  exec "$SSH_BIN" "${SSH_ARGS[@]}"
fi
exec "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null
