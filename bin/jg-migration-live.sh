#!/usr/bin/env bash
# jg-migration-live.sh - probe each part of the stack on this machine for the
# migration card: does it run here, and what was measured.
#
# WHY THIS EXISTS. "What is live now and what is pending" is a measurement, not a
# memory, so every line the card shows comes from a probe run here: the process and
# the port for a service, a real message for the bus, a real command for a tool, and
# the record or the switch for a path that has no service of its own. No model turn
# is part of it, which is what lets it run on a cadence.
#
# Usage: jg-migration-live.sh [--quiet] [<part>]
#   (nothing)   probe every part, write the data and print the table
#   <part>      probe the one part named (its slug, or its first word) and print its row
#   --quiet     write the data and print nothing
#
# CONTRACT.
#   data    $DIR/live.tsv holds one row per part: part, state, detail, tab separated.
#           $DIR is ${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card, the folder
#           bin/jg-migration-card.sh posts its card from, and $DIR/live.at holds the
#           epoch of the last probe.
#   states  live     measured running on this machine
#           pending  present but not running, and the detail says why
#           absent   not installed on this machine at all
#   exit    always 0: this reports a measurement, it never gates.
#   parts   the names are the captain's own words, in his order, so the card reads
#           the way he asked the question.
#   owner   bin/jg-bus.sh, bin/jg-wake-bus.sh, core/bus/ and core/merge-on-green/
#           own the names, addresses and switches read here; this file re-spells
#           none of them without this header changing too.
#   cost    one pass runs a bounded handful of processes and one real message, and
#           writes nothing outside $DIR.
set -u
PROBE_TIMEOUT=${PROBE_TIMEOUT:-4}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CFG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
DIR=${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card

PART_SLUGS=(nats accounts wake inbox leases captain dapr godaemons gate escalation fiveminute deletions rules axi addons)
PART_NAMES=('NATS server' 'per-home accounts' 'wake queue' 'task inbox' 'leases' 'captain channel/ntfy' 'Dapr' 'Go daemons' 'merge gate' 'escalation ladder' 'five-minute merge' 'deletions' 'rules JSON' 'juggernaut-axi' 'add-on removal')

# cfg <key>: the captain channel's value in force, in bin/jg-bus.sh's own order -
# JG_CAPTAIN_CHANNEL, then this home's file, then the shipped defaults - so the
# first file carrying the key wins and one key can be overridden on its own.
cfg() {
  local key=$1 file value
  for file in "${JG_CAPTAIN_CHANNEL:-}" "$CFG/captain-channel" "$ROOT/defaults/captain-channel"; do
    [ -r "$file" ] || continue
    value=$(sed -n "s/^[[:space:]]*set[[:space:]]\{1,\}${key}[[:space:]]\{1,\}//p" "$file" | tail -n 1)
    [ -z "$value" ] || { printf '%s' "$value"; return 0; }
  done
  return 0
}

nats_url() {
  local url
  url=$(cfg nats-url)
  printf '%s\n' "${url:-nats://127.0.0.1:4222}"
}

# host_port <url>: host:port that URL dials.
host_port() {
  local rest=$1
  rest=${rest#*://}
  rest=${rest%%/*}
  rest=${rest%%\?*}
  [ -n "$rest" ] || rest=127.0.0.1:4222
  case $rest in *:*) printf '%s\n' "$rest" ;; *) printf '%s:4222\n' "$rest" ;; esac
}

# nats_client: the client binary every bus measurement goes through, when installed.
nats_client() {
  if [ -n "${JG_NATS_BIN:-}" ] && [ -x "${JG_NATS_BIN}" ]; then printf '%s\n' "$JG_NATS_BIN"; return 0; fi
  command -v nats 2>/dev/null
}

# pidfile_pid <name>: the pid $STATE/bus/<name>.pid records, when that process lives.
pidfile_pid() {
  local file="$STATE/bus/$1.pid" pid
  [ -r "$file" ] || return 1
  pid=$(tr -cd '0-9' < "$file" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

# port_pid <port>: the pid listening on that local port, from ss.
port_pid() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltnp 2>/dev/null | grep -F ":$1 " | head -n 1 | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'
}

# port_open <host> <port>: 0 when something answers there.
port_open() {
  timeout 2 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
}

# bus_roundtrip <url>: send one real message and read it back. 0 carried, 2 no client.
bus_roundtrip() {
  local url=$1 client sub out pid body="jg-live-probe-$$"
  client=$(nats_client) || return 2
  [ -n "$client" ] || return 2
  sub="jg.probe.$$"
  out=$(mktemp "${TMPDIR:-/tmp}/jg-live.XXXXXX") || return 2
  timeout "$PROBE_TIMEOUT" "$client" -s "$url" sub --count 1 --timeout "${PROBE_TIMEOUT}s" "$sub" >"$out" 2>/dev/null &
  pid=$!
  sleep 0.3
  timeout "$PROBE_TIMEOUT" "$client" -s "$url" pub "$sub" "$body" >/dev/null 2>&1
  wait "$pid" 2>/dev/null
  local rc=1
  grep -q "$body" "$out" && rc=0
  rm -f -- "$out"
  return "$rc"
}

# stream_msgs <url> <stream>: the message count the server holds for that stream.
stream_msgs() {
  local url=$1 stream=$2 client
  client=$(nats_client) || return 1
  timeout "$PROBE_TIMEOUT" "$client" -s "$url" stream info "$stream" --json 2>/dev/null \
    | sed -n 's/.*"messages":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# wake_stream <variable>: the stream name bin/jg-wake-bus.sh already owns.
wake_stream() {
  local name
  name=$(sed -n "s/^$1=//p" "$ROOT/bin/jg-wake-bus.sh" 2>/dev/null | head -n 1)
  printf '%s\n' "${name:-$2}"
}
channel_stream() {
  sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/core/bus/stream.json" 2>/dev/null | head -n 1
}

# config_chain <file>: that NATS config and the files it includes, one per line.
config_chain() {
  local file=$1 inc
  [ -r "$file" ] || return 0
  printf '%s\n' "$file"
  while IFS= read -r inc; do
    printf '%s\n' "$inc"
  done < <(sed -n 's/^[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null)
}

# count_lines <file>: newline count, zero when the file is absent.
count_lines() { [ -r "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# server_conf <pid>: the config file the running NATS server was started with.
server_conf() {
  [ -n "${1:-}" ] || return 1
  ps -o args= -p "$1" 2>/dev/null | sed -n 's/.*[[:space:]]-c[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -n 1
}

probe_nats() {
  local url hostport host port pid state=live detail
  url=$(nats_url)
  hostport=$(host_port "$url")
  host=${hostport%:*}
  port=${hostport##*:}
  pid=$(pidfile_pid nats || port_pid "$port")
  if ! port_open "$host" "$port"; then
    printf 'absent\tno server answers on %s:%s\n' "$host" "$port"
    return 0
  fi
  bus_roundtrip "$url"
  case $? in
    0) detail='a real message went out and came back' ;;
    2) detail='no nats client is installed, so no message could be sent' ;;
    *) state=pending detail='the port answers but a message did not come back' ;;
  esac
  if [ -n "${pid:-}" ]; then
    printf 'live\tpid %s, port %s, %s\n' "$pid" "$port" "$detail"
  else
    printf 'live\tport %s, pid not readable, %s\n' "$port" "$detail"
  fi
}

probe_accounts() {
  local pid conf blocks=0 file n written
  pid=$(pidfile_pid nats || port_pid "$(host_port "$(nats_url)" | sed 's/.*://')")
  conf=$(server_conf "${pid:-}")
  if [ -n "${conf:-}" ]; then
    while IFS= read -r file; do
      n=$(grep -cE '^[[:space:]]*accounts[[:space:]]*\{' "$file" 2>/dev/null)
      blocks=$((blocks + ${n:-0}))
    done < <(config_chain "$conf")
  fi
  written=$(grep -cE '^[[:space:]]{2}[A-Za-z0-9_.-]+[[:space:]]*\{' "$STATE/bus/accounts.conf" 2>/dev/null)
  [ "${written:-0}" -eq 0 ] || written=$((written - 1))  # the system account carries no home
  if [ "${blocks:-0}" -gt 0 ]; then
    printf 'live\t%s accounts are loaded by the server\n' "$written"
  elif [ -n "${pid:-}" ]; then
    printf 'pending\tthe server runs without accounts; accounts.conf names %s homes and the server must be restarted from the unit to load it\n' "${written:-0}"
  else
    printf 'pending\tno server is running to carry them; accounts.conf names %s homes\n' "${written:-0}"
  fi
}

# probe_queue <part-label> <stream> <switch-key>: the bus-backed path.
probe_queue() {
  local label=$1 stream=$2 key=$3 count
  if grep -qw off "$CFG/$key" 2>/dev/null; then
    printf 'pending\tthe %s is on the files: config/%s says off\n' "$label" "$key"
    return 0
  fi
  count=$(stream_msgs "$(nats_url)" "$stream")
  if [ -z "$count" ]; then
    printf 'pending\tthe server carries no %s stream, so the %s is not on the bus\n' "$stream" "$label"
    return 0
  fi
  printf 'live\tthe bus is the store, %s records on %s\n' "$count" "$stream"
}

probe_leases() {
  local out rc
  [ -x "$ROOT/bin/jg-lease.sh" ] || { printf 'absent\tbin/jg-lease.sh is not in this checkout\n'; return 0; }
  out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CFG" \
    timeout 20 "$ROOT/bin/jg-lease.sh" check jg-live-probe 2>&1)
  rc=$?
  case $rc in
    0) printf 'live\tthe store answers, jg-live-probe is held by %s\n' "$out" ;;
    1) printf 'live\tthe store answers, and holds no lease on the probe id\n' ;;
    *) printf 'pending\tthe lease store could not answer (exit %s)\n' "$rc" ;;
  esac
}

probe_captain() {
  local mode stream events msgs detail ntfy=
  mode=$(cfg mode)
  mode=${mode:-live}
  stream=$(channel_stream)
  stream=${stream:-CAPTAIN}
  events=$(count_lines "$STATE/captain-channel.jsonl")
  msgs=$(stream_msgs "$(nats_url)" "$stream")
  command -v ntfy >/dev/null 2>&1 && ntfy=installed
  if [ "$mode" != live ]; then
    printf 'pending\tmode %s, so nothing reaches the captain; %s events recorded, %s on %s\n' \
      "$mode" "$events" "${msgs:-0}" "$stream"
  elif [ -z "$ntfy" ]; then
    printf 'pending\tmode live, ntfy is not installed, so nothing is delivered; %s events recorded, %s on %s\n' \
      "$events" "${msgs:-0}" "$stream"
  else
    printf 'live\tmode live through %s; %s events recorded, %s on %s\n' \
      "$(cfg ntfy-server)" "$events" "${msgs:-0}" "$stream"
  fi
}

probe_dapr() {
  local pid
  pid=$(pgrep -x daprd 2>/dev/null | head -n 1)
  if [ -n "${pid:-}" ]; then
    printf 'live\tpid %s, sidecar at %s\n' "$pid" "$(cfg dapr-http-url)"
  elif command -v daprd >/dev/null 2>&1; then
    printf 'pending\tdaprd is installed and not running\n'
  else
    printf 'absent\tdaprd is not installed (dapr init --slim)\n'
  fi
}

probe_godaemons() {
  local pids
  pids=$(ps -eo pid=,args= 2>/dev/null | awk -v a="$STATE/bin/" -v b="$ROOT/core/" -v me="$$" \
    '$1 != me && (index($2, a) == 1 || index($2, b) == 1) { print $1 }' | tr '\n' ' ')
  if [ -n "${pids// /}" ]; then
    printf 'live\tpids %s run a Go part of this stack\n' "${pids% }"
  else
    printf 'pending\tno long-running Go daemon is running here (jg-bus serve is not started)\n'
  fi
}

probe_gate() {
  local gate="$CFG/merge-gate" steps
  if [ -f "$gate" ]; then
    steps=$(grep -vcE '^[[:space:]]*(#|$)' "$gate")
    printf 'live\tconfig/merge-gate runs %s step(s) before a merge\n' "$steps"
  else
    printf 'pending\tthis home has no config/merge-gate, so a merge is never gate-checked\n'
  fi
}

probe_escalation() {
  local lib="$ROOT/core/wait-timers/bin/jg-wait-timers-lib.sh"
  if [ -r "$lib" ] && grep -q 'core/wait-timers/bin/jg-wait-timers-lib.sh' "$ROOT/bin/jg-watch.sh" 2>/dev/null; then
    printf 'live\tthe watcher sources core/wait-timers on every tick\n'
  else
    printf 'pending\tthe escalation ladder is not sourced by the watcher\n'
  fi
}

probe_fiveminute() {
  if [ -f "$STATE/merge-on-green.check.sh" ]; then
    printf 'live\tthe merge-on-green check is armed in this home\n'
  else
    printf 'pending\tmerge-on-green is not armed, so a green pull request waits for a person\n'
  fi
}

probe_deletions() {
  local ledger="$DIR/ledger.tsv" target base del rows
  target=$(sed -n 's/^target=//p' "$CFG/migration-card" 2>/dev/null | tail -n 1)
  base=$(sed -n 's/^baseline-deleted=//p' "$CFG/migration-card" 2>/dev/null | tail -n 1)
  rows=$(count_lines "$ledger")
  if [ -z "${target:-}" ]; then
    printf 'pending\tno deletion target is configured for this home\n'
    return 0
  fi
  if [ "${rows:-0}" -eq 0 ]; then
    printf "pending\tno merge is recorded on this home's card yet, target %s lines\n" "$target"
    return 0
  fi
  del=$(awk -F'\t' -v d="${base:-0}" '{d+=$2} END{print d+0}' "$ledger")
  printf 'live\t%s merges recorded, %s of %s lines deleted\n' "$rows" "$del" "$target"
}

probe_rules() {
  local file="$CFG/crew-dispatch.json" n
  if [ ! -f "$file" ]; then
    printf 'pending\tno config/crew-dispatch.json, so dispatch routes on its defaults\n'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'pending\tconfig/crew-dispatch.json is there and jq is not installed to read it\n'
    return 0
  fi
  if ! n=$(jq -r '(.rules // []) | length' "$file" 2>/dev/null); then
    printf 'pending\tconfig/crew-dispatch.json does not parse\n'
    return 0
  fi
  printf 'live\tconfig/crew-dispatch.json parses, %s rule(s)\n' "$n"
}

probe_axi() {
  local bin version
  if bin=$(command -v juggernaut-axi 2>/dev/null); then
    version=$(timeout "$PROBE_TIMEOUT" "$bin" --version 2>/dev/null | head -n 1)
    printf 'live\t%s%s\n' "$bin" "${version:+ ($version)}"
  elif [ -x "$ROOT/bin/juggernaut-axi" ]; then
    printf 'absent\tbin/juggernaut-axi ships in this checkout and no juggernaut-axi is installed on PATH\n'
  else
    printf 'absent\tjuggernaut-axi is not installed\n'
  fi
}

probe_addons() {
  local found='' d
  for d in "$JG_HOME"/projects/*addon*; do
    [ -e "$d" ] || continue
    found="$found $(basename "$d")"
  done
  if [ -n "$found" ]; then
    printf 'pending\ta separate add-on checkout is still here:%s\n' "$found"
  elif [ -d "$ROOT/addons" ]; then
    printf 'live\tthe add-ons live in addons/ of this checkout and no separate copy is left\n'
  else
    printf 'absent\tno add-on copy is here at all\n'
  fi
}

probe() {  # <slug>: one row, "state<TAB>detail"
  case $1 in
    nats) probe_nats ;;
    accounts) probe_accounts ;;
    wake) probe_queue 'wake queue' "$(wake_stream WAKE_STREAM JG_WAKE)" wake-bus ;;
    inbox) probe_queue 'task inbox' "$(wake_stream INBOX_STREAM JG_INBOX)" wake-bus ;;
    leases) probe_leases ;;
    captain) probe_captain ;;
    dapr) probe_dapr ;;
    godaemons) probe_godaemons ;;
    gate) probe_gate ;;
    escalation) probe_escalation ;;
    fiveminute) probe_fiveminute ;;
    deletions) probe_deletions ;;
    rules) probe_rules ;;
    axi) probe_axi ;;
    addons) probe_addons ;;
    *) printf 'pending\tunknown part %s\n' "$1" ;;
  esac
}

# write_rows: every part, in the captain's order, into $DIR/live.tsv.
write_rows() {
  local i tmp
  mkdir -p "$DIR" || return 1
  tmp=$(mktemp "$DIR/.live.XXXXXX") || return 1
  for i in "${!PART_SLUGS[@]}"; do
    printf '%s\t%s\n' "${PART_NAMES[$i]}" "$(probe "${PART_SLUGS[$i]}")"
  done > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DIR/live.tsv" || { rm -f -- "$tmp"; return 1; }
  date -u +%s > "$DIR/live.at"
}

main() {
  local quiet=0 part='' i row
  while [ "$#" -gt 0 ]; do
    case $1 in
      --quiet) quiet=1 ;;
      -*) printf 'jg-migration-live: unknown option %s\n' "$1" >&2; return 2 ;;
      *) part=$1 ;;
    esac
    shift
  done
  if [ -n "$part" ]; then
    for i in "${!PART_SLUGS[@]}"; do
      [ "${PART_SLUGS[$i]}" = "$part" ] || [ "${PART_NAMES[$i]}" = "$part" ] || continue
      row=$(probe "${PART_SLUGS[$i]}")
      printf '%s\t%s\t%s\n' "${PART_NAMES[$i]}" "${row%%$'\t'*}" "${row#*$'\t'}"
      return 0
    done
    printf 'jg-migration-live: no part named %s\n' "$part" >&2
    return 2
  fi
  write_rows || { printf 'jg-migration-live: cannot write %s\n' "$DIR/live.tsv" >&2; return 1; }
  [ "$quiet" -eq 1 ] && return 0
  printf 'PART\tSTATE\tMEASURED\n'
  while IFS=$'\t' read -r name state detail; do
    printf '%s\t%s\t%s\n' "$name" "$state" "$detail"
  done < "$DIR/live.tsv"
  return 0
}

main "$@"
