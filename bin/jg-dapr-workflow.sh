#!/usr/bin/env bash
# jg-dapr-workflow.sh - run the wait-timer and escalation ladder as a Dapr workflow.
#
#   bin/jg-dapr-workflow.sh up                       build the worker, start the three processes, report
#   bin/jg-dapr-workflow.sh status                   report them and change nothing
#   bin/jg-dapr-workflow.sh down                     stop what `up` started
#   bin/jg-dapr-workflow.sh start <class> <task> <key> [payload]   schedule one wait episode (the key is its id)
#   bin/jg-dapr-workflow.sh clear <key>              the owner cleared the wait: stop its ladder
#   bin/jg-dapr-workflow.sh episode <key>            runtime status and the rungs that fired
#   bin/jg-dapr-workflow.sh install                  the OWNER path: tools, worker, systemd user units
#
# THE PARTS. Dapr 1.19 runs the workflow engine on two processes: the scheduler (which holds
# the durable timers and, with --placement-enabled, replaces the old placement service) and the
# sidecar (app id escalation-wait-timers, an actor-enabled SQLite state store, the resiliency
# file core/bus/dapr/resiliency.yaml). The third process is core/escalation-workflow, the Go
# worker that owns the ladder; its header owns the workflow's shape, and
# core/bus/workflows/escalation-wait-timers.json owns every number (read through
# bin/jg-escalation-workflows.sh, so a home's config override applies here too).
#
# CONTRACT.
#   state    $STATE/workflow: ports, the state store, the scheduler's data, logs and pid files.
#            Ports are chosen free on the first run and kept, so a restart finds the same ones.
#   argv     `argv <part>` prints one process's command line. `up` and the systemd units both run
#            exactly that line, so a detached run proves what the service will run.
#   rules    the worker applies priority, budget, back-off, coalescing and auto-resolve from
#            core/bus/workflows/escalation-optimization.json (a home's config copy, or
#            JG_ESCALATION_OPT, wins), the same file and the same state/.escalation-opt files the
#            shell tick reads; a home with no such file runs the bare ladder.
#   delivery a fired rung is delivered by `bin/jg-escalation-workflows.sh deliver`, the same wake
#            line and queue key the shell ladder uses.
#   install  never runs from a session start or an update. It refuses when the installed worker
#            unit names another home (JG_WORKFLOW_TAKE_OWNERSHIP=1 moves it on purpose), and
#            refuses when this account has no user session, writing nothing in both cases.
# Env: JG_HOME, JG_STATE_OVERRIDE; JG_WORKFLOW_UNIT_DIR (default ~/.config/systemd/user) and
# JG_WORKFLOW_SYSTEMCTL (default systemctl) let a test prove the install without a real manager.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
RT=$STATE/workflow
SRC=$ROOT/core/escalation-workflow
WORKER=${JG_WORKFLOW_BIN:-$STATE/bin/jg-escalation-worker}
export NPM_CONFIG_PREFIX=${NPM_CONFIG_PREFIX:-$HOME/.local}
export PATH=$NPM_CONFIG_PREFIX/bin:$PATH
UNIT_DIR=${JG_WORKFLOW_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
SYSTEMCTL=${JG_WORKFLOW_SYSTEMCTL:-systemctl}
PARTS="scheduler sidecar worker"
# shellcheck source=bin/jg-pin-lib.sh
. "$SCRIPT_DIR/jg-pin-lib.sh"

die() { printf 'jg-dapr-workflow: %s\n' "$*" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; }

# ports: eight free ports, chosen once. Order: scheduler grpc, healthz, metrics, etcd client,
# etcd peer, sidecar http, sidecar grpc, sidecar internal grpc.
ports() {
  if [ ! -s "$RT/ports" ]; then
    mkdir -p "$RT" || die "cannot create $RT"
    python3 -c '
import socket
s = [socket.socket() for _ in range(8)]
for x in s: x.bind(("127.0.0.1", 0))
print(" ".join(str(x.getsockname()[1]) for x in s))' >"$RT/ports" || die "cannot pick free ports (python3 is needed)"
  fi
  cat "$RT/ports"
}
port() { ports | awk -v n="$1" '{ print $n }'; }

listening() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }

# The definition in force, from the one reader that knows the home's override.
definition() { "$SCRIPT_DIR/jg-escalation-workflows.sh" show 2>/dev/null | sed -n 's/^definition: //p'; }

write_resources() {
  mkdir -p "$RT/res" || die "cannot create $RT/res"
  cat >"$RT/res/statestore.yaml" <<EOF
# Written by bin/jg-dapr-workflow.sh: the actor-enabled store the workflow engine keeps its history in.
apiVersion: dapr.io/v1alpha1
kind: Component
metadata:
  name: statestore
spec:
  type: state.sqlite
  version: v1
  metadata:
    - name: connectionString
      value: "$RT/workflow.db"
    - name: actorStateStore
      value: "true"
EOF
  cp "$ROOT/core/bus/dapr/resiliency.yaml" "$RT/res/resiliency.yaml" || die "no resiliency file in $ROOT/core/bus/dapr"
}

# argv <part>: one process's command line, one word per line.
argv() {
  local sp
  sp=$(port 1)
  case $1 in
    scheduler)
      printf '%s\n' "$(command -v dapr-scheduler)" --id "$(basename "$JG_HOME")-sched" --listen-address 127.0.0.1 \
        --port "$sp" --healthz-port "$(port 2)" --metrics-port "$(port 3)" --etcd-client-port "$(port 4)" \
        --etcd-initial-cluster "$(basename "$JG_HOME")-sched=http://127.0.0.1:$(port 5)" \
        --etcd-data-dir "$RT/etcd" --placement-enabled --override-broadcast-host-port "127.0.0.1:$sp" ;;
    sidecar)
      printf '%s\n' "$(command -v daprd)" --app-id escalation-wait-timers --mode standalone --resources-path "$RT/res" \
        --dapr-http-port "$(port 6)" --dapr-grpc-port "$(port 7)" --dapr-internal-grpc-port "$(port 8)" \
        --metrics-port 0 --log-level "${JG_WORKFLOW_LOG_LEVEL:-info}" --scheduler-host-address "127.0.0.1:$sp" ;;
    worker) printf '%s\n' "$WORKER" serve ;;
  esac
}

worker_env() {
  printf '%s\n' "DAPR_GRPC_PORT=$(port 7)" "JG_ESCALATION_WORKFLOW=$(definition)" "JG_HOME=$JG_HOME" \
    "JG_STATE_OVERRIDE=$STATE" "JG_ESCALATION_OPT=${JG_ESCALATION_OPT:-}" "JG_WORKFLOW_DELIVER=$SCRIPT_DIR/jg-escalation-workflows.sh deliver"
}

ensure_tool() {  # <tool>: at the pin or newer, installed from the pinned release when not
  local tool=$1 want have
  want=$(jg_pin_version "$tool") || die "$tool has no row in toolchain.versions"
  have=$(bash "$SCRIPT_DIR/jg-bootstrap.sh" version "$tool" 2>/dev/null || true)
  if [ -z "$have" ] || [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | head -n 1)" != "$want" ]; then
    bash "$SCRIPT_DIR/jg-bootstrap.sh" install "$tool" >&2 || die "install of the pinned $tool $want failed"
  fi
}

build() {
  command -v go >/dev/null 2>&1 || die "no Go toolchain to build the worker (install go)"
  if [ -x "$WORKER" ] && [ -z "$(find "$SRC" -name '*.go' -newer "$WORKER" -print -quit)" ]; then return 0; fi
  mkdir -p "${WORKER%/*}" || die "cannot create ${WORKER%/*}"
  ( cd "$SRC" && go build -o "$WORKER.tmp.$$" . ) >&2 || { rm -f -- "$WORKER.tmp.$$"; die "the worker did not build"; }
  mv -f -- "$WORKER.tmp.$$" "$WORKER"
}

pid_of() { cat "$RT/$1.pid" 2>/dev/null; }
# A pid file counts only while the process still runs our command (a reused pid is not ours).
alive() {
  local pid
  pid=$(pid_of "$1")
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] && tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qF -- "$(argv "$1" | head -n 1)"
}

report() {
  local part rc=0
  for part in $PARTS; do
    if alive "$part"; then printf '%-9s running pid %s\n' "$part" "$(pid_of "$part")"; else printf '%-9s not running\n' "$part"; rc=1; fi
  done
  return $rc
}

start_part() {
  local part=$1 words=() w
  alive "$part" && return 0
  while IFS= read -r w; do words+=("$w"); done <<EOF
$(argv "$part")
EOF
  if [ "$part" = worker ]; then
    ( while IFS= read -r w; do export "${w?}"; done <<EOF
$(worker_env)
EOF
      exec setsid "${words[@]}" ) >"$RT/$part.log" 2>&1 </dev/null &
  else
    setsid "${words[@]}" >"$RT/$part.log" 2>&1 </dev/null &
  fi
  echo $! >"$RT/$part.pid"
}

wait_for() {  # <what> <command...>
  local what=$1 _
  shift
  for _ in $(seq 1 150); do "$@" && return 0; sleep 0.2; done
  die "$what did not come up in 30 seconds, see $RT/*.log"
}

cmd_up() {
  ensure_tool daprd
  ensure_tool dapr-scheduler
  build
  mkdir -p "$RT/etcd"
  write_resources
  start_part scheduler
  wait_for "the scheduler" listening "$(port 1)"
  start_part sidecar
  wait_for "the sidecar" listening "$(port 7)"
  start_part worker
  wait_for "the worker" grep -q 'serving' "$RT/worker.log"
  report
}

cmd_down() {
  local part pid
  for part in worker sidecar scheduler; do
    alive "$part" || continue
    pid=$(pid_of "$part")
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  done
  report >/dev/null || true
}

# Run the worker's own CLI against this home's sidecar.
via_worker() {
  [ -x "$WORKER" ] || die "the worker is not built: run bin/jg-dapr-workflow.sh up"
  DAPR_GRPC_PORT=$(port 7) JG_ESCALATION_WORKFLOW=$(definition) JG_ESCALATION_OPT=${JG_ESCALATION_OPT:-} \
    JG_STATE_OVERRIDE=$STATE "$WORKER" "$@"
}

unit_text() {  # <part>
  local part=$1 after=network.target w exec='' env=''
  case $part in sidecar) after=jg-workflow-scheduler.service ;; worker) after=jg-workflow-sidecar.service ;; esac
  while IFS= read -r w; do exec="$exec $w"; done <<EOF
$(argv "$part")
EOF
  if [ "$part" = worker ]; then
    while IFS= read -r w; do env="$env
Environment=\"$w\""; done <<EOF
$(worker_env)
EOF
  fi
  cat <<EOF
# Written by bin/jg-dapr-workflow.sh install for $JG_HOME; regenerate it there, never edit it.
[Unit]
Description=Juggernaut escalation workflow ($part)
After=$after
$( [ "$part" = scheduler ] || echo "Requires=$after" )

[Service]
Environment="JG_HOME=$JG_HOME"$env
WorkingDirectory=$RT
ExecStart=$exec
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
}

cmd_install() {
  local part owner name
  owner=$(sed -n 's/^Environment="JG_HOME=\(.*\)"$/\1/p' "$UNIT_DIR/jg-workflow-worker.service" 2>/dev/null | head -n 1)
  if [ -n "$owner" ] && [ "$owner" != "$JG_HOME" ] && [ -d "$owner" ] && [ "${JG_WORKFLOW_TAKE_OWNERSHIP:-0}" != 1 ]; then
    die "the installed workflow units belong to $owner; only that home installs them (JG_WORKFLOW_TAKE_OWNERSHIP=1 moves them here)" 3
  fi
  if [ "$SYSTEMCTL" = systemctl ] && ! systemctl --user show-environment >/dev/null 2>&1; then
    die "no systemd user session for this account, so no service to install; bin/jg-dapr-workflow.sh up runs the same processes detached" 4
  fi
  ensure_tool daprd
  ensure_tool dapr-scheduler
  build
  mkdir -p "$RT/etcd" "$UNIT_DIR" || die "cannot create $UNIT_DIR"
  write_resources
  for part in $PARTS; do
    name=jg-workflow-$part.service
    unit_text "$part" >"$UNIT_DIR/$name.new" || die "cannot write $UNIT_DIR/$name"
    mv -f -- "$UNIT_DIR/$name.new" "$UNIT_DIR/$name" || die "cannot write $UNIT_DIR/$name"
  done
  "$SYSTEMCTL" --user daemon-reload || die "daemon-reload failed"
  for part in $PARTS; do
    "$SYSTEMCTL" --user enable --now "jg-workflow-$part.service" || die "cannot start jg-workflow-$part.service, see journalctl --user -u jg-workflow-$part.service"
  done
  echo "workflow: installed and started ($UNIT_DIR)"
}

case ${1:-} in
  up) cmd_up ;;
  status) report ;;
  down) cmd_down ;;
  start) shift; via_worker start "$@" ;;
  clear) shift; via_worker clear "$@" ;;
  episode) shift; via_worker status "$@" ;;
  install) cmd_install ;;
  argv) argv "${2:?usage: jg-dapr-workflow.sh argv <scheduler|sidecar|worker>}" ;;
  unit) unit_text "${2:?usage: jg-dapr-workflow.sh unit <scheduler|sidecar|worker>}" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
