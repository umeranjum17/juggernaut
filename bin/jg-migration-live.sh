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
# Usage: jg-migration-live.sh [--quiet] [--link] [<part>]
#   (nothing)   probe every part, write the data and print the table
#   <part>      probe the one part named (its slug, or its first word) and print its row
#   --quiet     write the data and print nothing
#   --link      print the card's link only (no probe): the board deep link, else the page's
#               file path; exit 1 when no card is posted
#
# CONTRACT.
#   data    $DIR/live.tsv holds one row per part: part, state, detail, pr, tab separated.
#           A live row's detail carries the count measured on the path; a pending or
#           absent row's pr names the open pull request that finishes it, read from
#           $DIR/prs.tsv (one `gh pr list` per pass, kept when the read fails).
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
#           own the names, addresses and switches read here (`jg-bus gateway status --row`
#           owns the chat row's measurement), and bin/jg-kv-lib.sh owns
#           the home's login every bus call here makes; this file re-spells none of
#           them without this header changing too.
#   cost    one pass runs a bounded handful of processes, one real message and one
#           read of the open pull requests, and writes nothing outside $DIR except the
#           bus command bin/jg-bus.sh builds when it is missing or older than its source.
#           A probe never starts, restarts or reloads a service.
set -u
PROBE_TIMEOUT=${PROBE_TIMEOUT:-4}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$ROOT}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
CFG=${JG_CONFIG_OVERRIDE:-$JG_HOME/config}
DIR=${JG_DATA_OVERRIDE:-$JG_HOME/data}/migration-card
# shellcheck source=bin/jg-kv-lib.sh
. "$SCRIPT_DIR/jg-kv-lib.sh"

PART_SLUGS=(nats accounts wake inbox leases dapr godaemons gate escalation fiveminute deletions rules axi addons policy pendingreplies leadwake linecounts chat)
PART_NAMES=('NATS server' 'per-home accounts' 'wake queue' 'task inbox' 'leases' 'Dapr' 'Go daemons' 'merge gate' 'escalation ladder' 'five-minute merge' 'deletions' 'rules JSON' 'juggernaut-axi' 'add-on removal' 'Rego policy' 'pending-replies cleanup' 'lead-wake cleanup' 'line counts from git' 'captain chat (Telegram)')
# Per part: a case-insensitive pattern over open pull request titles.
PART_PR_RE=('nats|bus server|machine bus' 'account' 'wake queue|wake engine|wake' 'inbox|wake queue' 'lease' 'dapr|wait ladder' ' go\b|in go|go consumer|go wake' 'merge gate' 'wait ladder|escalation' 'merge-on-green|five-minute|merge path' 'delet|release c-' 'rules json|crew-dispatch|rego' 'juggernaut-axi' 'add-on|addon' 'rego|opa|policy' 'pending-repl' 'lead-wake|leadwake' 'line count' 'chat gateway|telegram|captain chat')

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

# nats_call <client> <url> [args...]: one client call as this home's account, bounded
# by PROBE_TIMEOUT. The machine's server runs one account per home and refuses the
# empty user, so a probe that connects without a login measures only that refusal;
# bin/jg-kv-lib.sh owns the login and keeps the password off the argument list.
nats_call() { # <client> <url> [args...]
  local client=$1 url=$2
  shift 2
  JG_KV_DEADLINE=$PROBE_TIMEOUT jg_kv_run "$client" "$url" "$STATE" "$@"
}

# home_account: the account this home logs in as, empty when it holds none.
home_account() {
  local login
  login=$(jg_kv_login "$STATE") || return 0
  printf '%s\n' "${login%%$'\t'*}"
}

# bus_roundtrip <url>: send one real message and read it back. 0 carried, 2 no client.
bus_roundtrip() {
  local url=$1 client sub out pid body="jg-live-probe-$$"
  client=$(nats_client) || return 2
  [ -n "$client" ] || return 2
  sub="jg.probe.$$"
  out=$(mktemp "${TMPDIR:-/tmp}/jg-live.XXXXXX") || return 2
  nats_call "$client" "$url" sub --count 1 "$sub" >"$out" 2>/dev/null &
  pid=$!
  sleep 0.3
  nats_call "$client" "$url" pub "$sub" "$body" >/dev/null 2>&1
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
  nats_call "$client" "$url" stream info "$stream" --json 2>/dev/null \
    | sed -n 's/.*"messages":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# bus_traffic <url>: the messages the server holds, summed over its streams.
bus_traffic() {
  local url=$1 client name total=0 streams=0 n
  client=$(nats_client) || { printf 'no message count without a nats client'; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    n=$(stream_msgs "$url" "$name")
    total=$((total + ${n:-0})); streams=$((streams + 1))
  done < <(nats_call "$client" "$url" stream ls -n 2>/dev/null)
  printf '%s messages held in %s streams' "$total" "$streams"
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

# config_chain <file>: that NATS config and the files it includes, one per line. An
# include may be quoted or bare, and a relative one names a file beside the config that
# includes it, which is how nats-server reads it.
config_chain() {
  local file=$1 inc
  [ -r "$file" ] || return 0
  printf '%s\n' "$file"
  while IFS= read -r inc; do
    case $inc in /*) ;; *) inc=$(dirname -- "$file")/$inc ;; esac
    printf '%s\n' "$inc"
  done < <(sed -n 's/^[[:space:]]*include[[:space:]]\{1,\}"\{0,1\}\([^";[:space:]]*\).*/\1/p' "$file" 2>/dev/null)
}

# count_lines <file>: newline count, zero when the file is absent.
count_lines() { [ -r "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# server_conf <pid>: the config file the running NATS server was started with. ps cuts its
# output to the caller's COLUMNS (a pane's width), which cut the path short; -ww never cuts.
server_conf() {
  [ -n "${1:-}" ] || return 1
  ps -ww -o args= -p "$1" 2>/dev/null | sed -n 's/.*[[:space:]]-c[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | head -n 1
}

probe_nats() {
  local url hostport host port pid state=live detail traffic
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
    *) state=pending detail="the port answers but a message did not come back (login: $(home_account | grep . || echo 'none for this home'))" ;;
  esac
  [ "$state" = live ] || { printf 'pending\t%s\n' "$detail"; return 0; }
  traffic=$(bus_traffic "$url")
  if [ -n "${pid:-}" ]; then
    printf 'live\tpid %s, port %s, %s; %s\n' "$pid" "$port" "$detail" "$traffic"
  else
    printf 'live\tport %s, pid not readable, %s; %s\n' "$port" "$detail" "$traffic"
  fi
}

# probe_accounts: the server's own config names the accounts it loaded, and this home
# logging in proves the server holds its account: the server reports the account a
# connection landed on, so a login it ignored or refused is not counted as one.
probe_accounts() {
  local pid conf blocks=0 homes=0 file n account client landed
  pid=$(pidfile_pid nats || port_pid "$(host_port "$(nats_url)" | sed 's/.*://')")
  conf=$(server_conf "${pid:-}")
  if [ -n "${conf:-}" ]; then
    while IFS= read -r file; do
      n=$(grep -cE '^[[:space:]]*accounts[[:space:]]*\{' "$file" 2>/dev/null)
      [ "${n:-0}" -gt 0 ] || continue
      blocks=$((blocks + n))
      # One account per two-space block; the system account carries no home.
      n=$(grep -E '^[[:space:]]{2}[A-Za-z0-9_.-]+[[:space:]]*\{' "$file" 2>/dev/null | grep -cvE '^[[:space:]]*SYS[[:space:]]*\{')
      homes=$((homes + ${n:-0}))
    done < <(config_chain "$conf")
  fi
  if [ -z "${pid:-}" ]; then
    printf 'pending\tno server is running to carry them\n'
    return 0
  fi
  if [ "$blocks" -eq 0 ]; then
    printf 'pending\tthe server runs without accounts (pid %s, config %s); it must be restarted from the unit to load them\n' \
      "$pid" "${conf:-not readable}"
    return 0
  fi
  account=$(home_account)
  if [ -z "$account" ]; then
    printf 'pending\tthe server loads %s home accounts and none is this home'"'"'s, so it has no login here\n' "$homes"
    return 0
  fi
  client=$(nats_client) || client=
  [ -n "$client" ] || { printf 'pending\tthe server loads %s home accounts; no nats client to log in as %s\n' "$homes" "$account"; return 0; }
  landed=$(nats_call "$client" "$(nats_url)" account info 2>/dev/null | sed -n 's/^[[:space:]]*Account:[[:space:]]*//p' | head -n 1)
  if [ "$landed" = "$account" ]; then
    printf 'live\tthe server loads %s home accounts; this home logs in as %s, its own account\n' "$homes" "$account"
  else
    printf 'pending\tthe server loads %s home accounts and refused this home'"'"'s login as %s\n' "$homes" "$account"
  fi
}

# stream_field <url> <stream> <field>: one top-level value of the stream's info.
stream_field() {
  local client
  client=$(nats_client) || return 1
  nats_call "$client" "$1" stream info "$2" --json 2>/dev/null \
    | sed -n "s/^[[:space:]]*\"$3\":[[:space:]]*\"\{0,1\}\([^\",]*\).*/\\1/p" | head -n 1
}

# probe_queue <part-label> <stream> <switch-key>: the bus-backed path. The stream is
# the store, and the read model is current only while bin/jg-wake-bus.sh's cursor
# (state/.wake-bus.cursor) sits inside the stream it reads: a cursor past the stream's
# last sequence was left by a stream the server has since remade, and a render that
# trusts it reads nothing new.
probe_queue() {
  local label=$1 stream=$2 key=$3 count owed url cursor last made
  if grep -qw off "$CFG/$key" 2>/dev/null; then
    printf 'pending\tthe %s is on the files: config/%s says off\n' "$label" "$key"
    return 0
  fi
  url=$(nats_url)
  count=$(stream_msgs "$url" "$stream")
  if [ -z "$count" ]; then
    printf 'pending\tthe server carries no %s stream for this home'"'"'s account (%s), so the %s is not on the bus\n' \
      "$stream" "$(home_account)" "$label"
    return 0
  fi
  cursor=$(awk -v s="$stream" '$1 == s && $2 ~ /^[0-9]+$/ { print $2 }' "$STATE/.wake-bus.cursor" 2>/dev/null | tail -n 1)
  last=$(stream_field "$url" "$stream" last_seq)
  case ${last:-x} in *[!0-9]*) last='' ;; esac
  if [ -n "${cursor:-}" ] && [ -n "$last" ] && [ "$cursor" -gt "$last" ]; then
    printf 'pending\tthe renderer reads %s from sequence %s and the stream ends at %s, so %s records are not in the read model\n' \
      "$stream" "$cursor" "$last" "$count"
    return 0
  fi
  made=$(awk -v s="$stream" '$1 == s { print $3 }' "$STATE/.wake-bus.cursor" 2>/dev/null | tail -n 1)
  if [ -n "${made:-}" ] && [ "$made" != "$(stream_field "$url" "$stream" created)" ]; then
    printf 'pending\tthe renderer'"'"'s cursor was taken on an earlier %s than the server holds, so its %s records are not all in the read model\n' \
      "$stream" "$count"
    return 0
  fi
  owed=$(count_lines "$STATE/.wake-bus.outbox.jsonl")
  if [ "${owed:-0}" -gt 0 ]; then
    printf 'pending\t%s events wait in this home'"'"'s outbox because the server refuses them; %s records on %s\n' \
      "$owed" "$count" "$stream"
    return 0
  fi
  printf 'live\tthe bus is the store, %s records on %s, rendered through sequence %s of %s\n' \
    "$count" "$stream" "${cursor:-0}" "${last:-0}"
}

probe_leases() {
  local out rc
  leases_held() { nats_call "$(nats_client)" "$(nats_url)" kv ls JG_LEASES 2>/dev/null | grep -c . || true; }
  [ -x "$ROOT/bin/jg-lease.sh" ] || { printf 'absent\tbin/jg-lease.sh is not in this checkout\n'; return 0; }
  out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CFG" \
    timeout 20 "$ROOT/bin/jg-lease.sh" check jg-live-probe 2>&1)
  rc=$?
  case $rc in
    0) printf 'live\tthe store answers, %s leases held in this store, jg-live-probe is held by %s\n' "$(leases_held)" "$out" ;;
    1) printf 'live\tthe store answers, %s leases held in this store, none on the probe id\n' "$(leases_held)" ;;
    *) printf 'pending\tthe lease store could not answer (exit %s)\n' "$rc" ;;
  esac
}

probe_dapr() {
  local pid url n
  pid=$(pgrep -x daprd 2>/dev/null | head -n 1)
  url=$(cfg dapr-http-url)
  if ! command -v daprd >/dev/null 2>&1; then
    printf 'absent\tdaprd is not installed (dapr init --slim)\n'
  elif [ -n "${url:-}" ] && curl -fsS -m "$PROBE_TIMEOUT" -o /dev/null "$url/v1.0/healthz" 2>/dev/null; then
    n=$(curl -fsS -m "$PROBE_TIMEOUT" "$url/v1.0/metadata" 2>/dev/null | jq -r '(.components // []) | length' 2>/dev/null)
    printf 'live\tdaprd%s answers at %s with %s components loaded\n' "${pid:+ pid $pid}" "$url" "${n:-0}"
  elif [ -n "${pid:-}" ]; then
    printf 'pending\tdaprd pid %s runs and nothing answers at %s, so it is not the stack sidecar\n' "$pid" "${url:-no dapr-http-url set}"
  else
    printf 'pending\tdaprd is installed and not running\n'
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
    printf 'live\tthe watcher sources core/wait-timers on every tick; %s timers open in this home\n' \
      "$(find "$STATE/.waiting-timers" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf 'pending\tthe escalation ladder is not sourced by the watcher\n'
  fi
}

probe_fiveminute() {
  if [ ! -f "$STATE/merge-on-green.check.sh" ]; then
    printf 'pending\tmerge-on-green is not armed, so a green pull request waits for a person\n'
    return 0
  fi
  # A merge's minutes live on its ticket (jg-backlog.sh times <ticket>); no table file is kept.
  printf 'live\tthe merge-on-green check is armed in this home; each merge lands on its ticket\n'
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
    if version=$(timeout "$PROBE_TIMEOUT" "$bin" --version 2>/dev/null | head -n 1) && [ -n "$version" ]; then
      printf 'live\t%s (%s)\n' "$bin" "$version"
    else
      printf 'pending\t%s is on PATH and does not answer --version; run bin/jg-axi-link.sh\n' "$bin"
    fi
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
  else
    printf 'live\tthe add-ons live in core/ and no separate copy is left\n'
  fi
}

probe_policy() {
  local n out
  n=$(find "$ROOT/policy" -name '*.rego' ! -name '*_test.rego' 2>/dev/null | wc -l | tr -d ' ')
  if ! command -v opa >/dev/null 2>&1; then
    printf 'absent\topa is not installed; %s Rego policies wait in policy/\n' "$n"
  elif out=$(timeout 30 opa test "$ROOT/policy" 2>&1 | sed -n 's/^PASS: \([0-9]*\/[0-9]*\).*/\1/p'); [ -n "$out" ]; then
    printf 'live\topa answers: %s policy tests pass over %s Rego policies\n' "$out" "$n"
  else
    printf 'pending\topa is installed and the policy tests did not pass over %s Rego policies\n' "$n"
  fi
}

probe_pendingreplies() {
  local records
  records=$(find "$STATE/pending-replies" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  if grep -q '^jg_pending_reply_path()' "$ROOT/bin/jg-pending-reply-lib.sh" 2>/dev/null; then
    printf 'pending\tthe per-waiter record file is still in bin/jg-pending-reply-lib.sh; %s record files in this home\n' "$records"
  else
    printf 'live\tno per-waiter record file is left; %s stray record files in this home\n' "$records"
  fi
}

probe_leadwake() {
  local markers
  markers=$(find "$STATE" -maxdepth 1 -name '.squad-lead-wake-*' 2>/dev/null | wc -l | tr -d ' ')
  if grep -q 'lead_wake_tick' "$ROOT/bin/jg-watch.sh" 2>/dev/null; then
    printf 'live\tthe watcher calls core/lead-wake each tick; %s lead-wake markers in this home\n' "$markers"
  else
    printf 'pending\tcore/lead-wake is in this checkout and the watcher does not call it; %s lead-wake markers in this home\n' "$markers"
  fi
}

# probe_chat: the captain's Telegram chat. A home with no token file is off and nothing else runs
# (no build, no network); with one, `jg-bus gateway status --row` measures the service, one getMe
# and the six-leg round-trip record, and sends no message.
probe_chat() {
  local tok out
  tok=$(cfg telegram-token-file)
  tok=${tok:-config/captain-chat/telegram.token}
  case $tok in /*) ;; *) tok=$JG_HOME/$tok ;; esac
  if [ ! -e "$tok" ]; then
    printf 'absent\toff: no bot token on this machine; connect your own with jg-bus gateway setup\n'
    return 0
  fi
  if out=$(JG_HOME=$JG_HOME JG_STATE_OVERRIDE=$STATE timeout 30 "${JG_BUS_CMD:-$ROOT/bin/jg-bus.sh}" gateway status --row 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out" | head -n 1
  else
    printf 'pending\tthe gateway status could not be read\n'
  fi
}

probe_linecounts() {
  local ref head del add
  ref=$(sed -n 's/^baseline-ref=//p' "$CFG/migration-card" 2>/dev/null | tail -n 1)
  if [ -z "${ref:-}" ]; then
    printf 'pending\tno baseline-ref in config/migration-card, so no line count is taken from git\n'
    return 0
  fi
  head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  if ! read -r del add < <(git -C "$ROOT" diff --numstat "$ref" HEAD 2>/dev/null | awk '$1 != "-" { a += $1; d += $2 } END { print d + 0, a + 0 }'); then
    printf 'pending\tgit cannot diff %s against HEAD\n' "$ref"
    return 0
  fi
  if [ -z "${head:-}" ]; then
    printf 'pending\tgit cannot read HEAD of this checkout\n'
  else
    printf 'live\tgit counts %s deleted and %s added lines from %s to %s\n' "$del" "$add" "$ref" "$head"
  fi
}

probe() {  # <slug>: one row, "state<TAB>detail"
  case $1 in
    nats) probe_nats ;;
    accounts) probe_accounts ;;
    wake) probe_queue 'wake queue' "$(wake_stream WAKE_STREAM JG_WAKE)" wake-bus ;;
    inbox) probe_queue 'task inbox' "$(wake_stream INBOX_STREAM JG_INBOX)" wake-bus ;;
    leases) probe_leases ;;
    dapr) probe_dapr ;;
    godaemons) probe_godaemons ;;
    gate) probe_gate ;;
    escalation) probe_escalation ;;
    fiveminute) probe_fiveminute ;;
    deletions) probe_deletions ;;
    rules) probe_rules ;;
    axi) probe_axi ;;
    addons) probe_addons ;;
    policy) probe_policy ;;
    pendingreplies) probe_pendingreplies ;;
    leadwake) probe_leadwake ;;
    linecounts) probe_linecounts ;;
    chat) probe_chat ;;
    *) printf 'pending\tunknown part %s\n' "$1" ;;
  esac
}

# refresh_prs: one read of the open pull requests into $DIR/prs.tsv; a failed read keeps the last list.
refresh_prs() {
  local tmp
  command -v gh >/dev/null 2>&1 || return 0
  tmp=$(mktemp "$DIR/.prs.XXXXXX") || return 0
  if (cd "$ROOT" && timeout 30 gh pr list --state open --limit 100 --json number,url,title \
      --jq '.[] | [.number, .url, (.title | gsub("[\t\n]"; " "))] | @tsv') >"$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$DIR/prs.tsv"
  else
    rm -f -- "$tmp"
  fi
}

# pr_links <slug> <state>: the open pull requests that finish a part ("-" when it runs).
pr_links() {
  local i re urls
  [ "$2" = live ] && { printf -- '-'; return 0; }
  [ -r "$DIR/prs.tsv" ] || { printf 'the open pull request list could not be read'; return 0; }
  for i in "${!PART_SLUGS[@]}"; do
    [ "${PART_SLUGS[$i]}" = "$1" ] || continue
    re=${PART_PR_RE[$i]}
    urls=$(awk -F'\t' '{ print $2 "\t" $3 }' "$DIR/prs.tsv" | grep -iE "$re" | cut -f1 | head -n 2 | tr '\n' ' ')
    [ -n "${urls// /}" ] && printf '%s' "${urls% }" || printf 'no open pull request'
    return 0
  done
}

row() {
  local i=$1 out state
  out=$(probe "${PART_SLUGS[$i]}")
  state=${out%%$'\t'*}
  printf '%s\t%s\t%s\n' "${PART_NAMES[$i]}" "$out" "$(pr_links "${PART_SLUGS[$i]}" "$state")"
}

# write_rows: every part, in the captain's order, into $DIR/live.tsv.
write_rows() {
  local i tmp
  mkdir -p "$DIR" || return 1
  refresh_prs
  tmp=$(mktemp "$DIR/.live.XXXXXX") || return 1
  for i in "${!PART_SLUGS[@]}"; do row "$i"; done > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DIR/live.tsv" || { rm -f -- "$tmp"; return 1; }
  date -u +%s > "$DIR/live.at"
}

# card_link: the board deep link, else the card page's file, else exit 1.
card_link() {
  local key link page board
  key=$(sed -n 's/^card=//p' "$CFG/migration-card" 2>/dev/null | tail -n 1)
  [ -n "$key" ] || key=$(sed -n 's/^card=//p' "$DIR/current" 2>/dev/null | tail -n 1)
  [ -n "$key" ] || { printf 'jg-migration-live: no card is posted yet; run bin/jg-migration-card.sh live\n' >&2; return 1; }
  # shellcheck source=bin/jg-board-link-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/jg-board-link-lib.sh"
  if link=$(JG_HOME="$JG_HOME" JG_SIGNOFF_URL_FILE="${JG_SIGNOFF_URL_FILE:-$STATE/signoff-board.url}" jg_board_link reports "$key" 2>/dev/null); then
    printf '%s\n' "$link"
    return 0
  fi
  board=$(sed -n 's/^board=//p' "$CFG/migration-card" 2>/dev/null | tail -n 1)
  page="$(dirname "${board:-${JG_PROOF_BOARD:-/nonexistent/board.json}}")/reports/$key/index.html"
  [ -r "$page" ] || { printf 'jg-migration-live: card %s has no page and no board address is recorded\n' "$key" >&2; return 1; }
  printf 'jg-migration-live: no board address in state/signoff-board.url; the card page is a file\n' >&2
  printf 'file://%s\n' "$page"
}

main() {
  local quiet=0 part='' i
  # One login per pass, kept for every probe below (bin/jg-kv-lib.sh caches it per shell).
  jg_kv_login "$STATE" >/dev/null || true
  while [ "$#" -gt 0 ]; do
    case $1 in
      --quiet) quiet=1 ;;
      --link) card_link; return $? ;;
      -*) printf 'jg-migration-live: unknown option %s\n' "$1" >&2; return 2 ;;
      *) part=$1 ;;
    esac
    shift
  done
  if [ -n "$part" ]; then
    for i in "${!PART_SLUGS[@]}"; do
      [ "${PART_SLUGS[$i]}" = "$part" ] || [ "${PART_NAMES[$i]}" = "$part" ] || continue
      mkdir -p "$DIR" 2>/dev/null
      [ -r "$DIR/prs.tsv" ] || refresh_prs
      row "$i"
      return 0
    done
    printf 'jg-migration-live: no part named %s\n' "$part" >&2
    return 2
  fi
  write_rows || { printf 'jg-migration-live: cannot write %s\n' "$DIR/live.tsv" >&2; return 1; }
  [ "$quiet" -eq 1 ] && return 0
  printf 'PART\tSTATE\tMEASURED\tPULL REQUEST\n'
  cat "$DIR/live.tsv"
  return 0
}

main "$@"
