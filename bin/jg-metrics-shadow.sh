#!/usr/bin/env bash
# jg-metrics-shadow.sh - the host and fleet numbers on Prometheus plus
# node_exporter, in shadow: both paths run at once and the shell collection stays
# authoritative.
#
# WHY THIS EXISTS (migration step 5g). The heartbeat and the fleet report gather
# the same four numbers in shell: load from /proc/loadavg (bin/jg-reaper-lib.sh),
# available memory from /proc/meminfo (bin/jg-jev-mem-guard.py, add-ons
# host-memory), free disk from df(1) (bin/jg-tmp-sweep.sh), and fleet shape from
# the per-home records (bin/jg-fleet-heartbeat.sh). Prometheus with node_exporter
# is the mature replacement: one scrape gives the three host numbers, an
# alerting rule replaces an alarm in shell, and the fleet shape arrives as a
# textfile the shipped collector already writes. This step only proves the
# scrape reproduces the numbers the shell reports; nothing switches, and this
# script writes nothing into any home.
#
# docs/metrics-shadow.md owns the metric model, the parity contract, the
# measured line count of each path and the measured memory cost of the two
# processes. This script is the one owner of the shadow's mechanics: the config
# file it renders, the two processes, the textfile bridge that carries fleet
# shape, and the replay that compares both paths field by field.
#
# CONTRACT (this header is the one owner of the shadow's shape).
#   config   a home enables the shadow with config/metrics-shadow; the same file
#            may set `prometheus-bin <path>`, `node-exporter-bin <path>`,
#            `scrape-interval <duration>`, `retention <duration>`, `listen
#            <host:port>` and `node-listen <host:port>`. JG_METRICS_SHADOW=on
#            enables it for one run and the matching JG_METRICS_SHADOW_<KEY>
#            variables override the file. No file means off, and every command
#            but parity and status says so and exits 0, so a home without the
#            shadow behaves exactly as before.
#   files    Prometheus is configured by file and by nothing else: start renders
#            prometheus.yml from the settings above and runs it with
#            --config.file. Nothing else in that file is rewritten, so the file
#            is the whole configuration and an operator can read it.
#   dir      the two processes keep their bytes outside the home, in
#            ${JG_METRICS_SHADOW_DIR:-$XDG_CACHE_HOME/jg-metrics-shadow}:
#            prometheus.yml, textfile/ for the bridge, tsdb/, logs and pids.
#   shape    fleet shape reaches Prometheus as a node_exporter textfile written
#            by the shipped collector: export runs bin/jg-fleet-heartbeat.sh rows
#            and formats those rows into jg_fleet_home_* series. No rule is
#            re-implemented, so the switch this proves keeps this bridge and
#            drops only the host numbers from shell.
#   parity   both paths measure load, available memory, free disk on the root
#            mount and fleet shape over one instant, one row per field, with the
#            tolerance per field named in TOLERANCES below. A row that differs
#            beyond its tolerance is printed and counted, so a difference names
#            the field rather than the run. A parity that compared nothing, or
#            that did not compare all three host numbers, is a failure and never
#            a pass.
#   corrupt  --corrupt tampers with one exported sample before the comparison,
#            which parity must then report as a difference, so a green run is
#            never vacuous. The tampered sample is healed from the pinned rows
#            before parity exits, so the shadow never keeps a lie.
#   write    nothing here writes into a home. No record, summary, status line or
#            state file is created, changed or removed: export reads the rows the
#            shipped collector prints and writes only into the shadow's own
#            directory.
#
# Usage:
#   jg-metrics-shadow.sh start                  start both processes
#   jg-metrics-shadow.sh stop                   stop them
#   jg-metrics-shadow.sh status                 one line per process
#   jg-metrics-shadow.sh export                 write the fleet-shape textfile
#   jg-metrics-shadow.sh sync                   start if needed, then export
#   jg-metrics-shadow.sh parity [--corrupt]     compare both paths, field by field
#
# Options: --corrupt tampers with one exported sample first.
#
# Env: JG_METRICS_SHADOW, JG_METRICS_SHADOW_DIR, JG_METRICS_SHADOW_PROMETHEUS_BIN,
#      JG_METRICS_SHADOW_NODE_EXPORTER_BIN, JG_METRICS_SHADOW_SCRAPE_INTERVAL,
#      JG_METRICS_SHADOW_RETENTION, JG_METRICS_SHADOW_LISTEN,
#      JG_METRICS_SHADOW_NODE_LISTEN, JG_FLEET_HEARTBEAT_BIN.
set -u
export LC_ALL=C
SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-${JG_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-${STATE:-$JG_HOME/state}}"
CONFIG="${JG_CONFIG_OVERRIDE:-${CONFIG:-$JG_HOME/config}}"
DIR="${JG_METRICS_SHADOW_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/jg-metrics-shadow}"

# TOLERANCES. Every number is a sampling gap, not an allowance for a wrong
# answer: the shell reads the kernel at one instant and Prometheus serves the
# scrape that landed before it, so a field moves between the two reads.
#   load1         1.00 absolute. A one-minute average decays by 1/60 of a jump
#                 every second, so a scrape one interval old can differ.
#   MemAvailable  2% of the shell value. Available memory is the field a busy
#                 host moves fastest.
#   disk avail    64 MiB. Only a write moves it.
#   fleet shape   0, including the beacon age. Both sides read the same pinned
#                 rows, so the only thing the comparison can find here is a
#                 transport defect, and any difference must be shown.
LOAD_TOL=1.00
MEM_TOL_PCT=2
DISK_TOL_KIB=65536
CORRUPT=0
CMD=

die() { printf 'jg-metrics-shadow: %s\n' "$1" >&2; exit "${2:-1}"; }

# config_get <key> <default>: the value in force, from JG_METRICS_SHADOW_<KEY>,
# then the home's config/metrics-shadow, then the default this caller names.
config_get() { # <key> <default>
  local var value
  var="JG_METRICS_SHADOW_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  value=$(eval "printf '%s' \"\${$var:-}\"")
  if [ -z "$value" ] && [ -f "$CONFIG/metrics-shadow" ]; then
    value=$(awk -v k="$1" '$1 == k { sub(/^[^ ]+[ \t]+/, ""); print; exit }' "$CONFIG/metrics-shadow" 2>/dev/null)
  fi
  printf '%s\n' "${value:-$2}"
}

resolve_bins() {
  PROM=$(config_get prometheus-bin "$(command -v prometheus 2>/dev/null || true)")
  NODE=$(config_get node-exporter-bin "$(command -v node_exporter 2>/dev/null || true)")
  SCRAPE=$(config_get scrape-interval 2s)
  RETENTION=$(config_get retention 1h)
  LISTEN=$(config_get listen 127.0.0.1:19090)
  NODE_LISTEN=$(config_get node-listen 127.0.0.1:19100)
}

# shadow_gate: 0 when this home runs the shadow, 1 when it is off. Off is not an
# error: it prints nothing and the caller decides what to say.
shadow_gate() {
  [ -n "$CMD" ] || return 1
  if [ "${JG_METRICS_SHADOW:-}" = on ]; then return 0; fi
  [ -e "$CONFIG/metrics-shadow" ] || return 1
  return 0
}

# tool_gate: resolve the two binaries or say why the shadow cannot run. It never
# fails the caller, because a home without the tools must behave as before.
tool_gate() {
  resolve_bins
  if [ -z "$PROM" ] || [ ! -x "$PROM" ]; then
    printf 'skip: prometheus not found (set prometheus-bin in config/metrics-shadow or JG_METRICS_SHADOW_PROMETHEUS_BIN)\n'
    return 1
  fi
  if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    printf 'skip: node_exporter not found (set node-exporter-bin in config/metrics-shadow or JG_METRICS_SHADOW_NODE_EXPORTER_BIN)\n'
    return 1
  fi
}

prom_url() { printf 'http://%s\n' "$LISTEN"; }
node_url() { printf 'http://%s\n' "$NODE_LISTEN"; }

# wait_url <url> [seconds]: 0 once the endpoint answers.
wait_url() {
  local i=0
  while [ "$i" -lt "${2:-80}" ]; do
    curl -sf -o /dev/null --max-time 2 "$1" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

render_config() {
  local out=$DIR/prometheus.yml
  mkdir -p "$DIR/textfile" "$DIR/tsdb" || return 1
  printf 'global:\n  scrape_interval: %s\n  scrape_timeout: %s\n  evaluation_interval: %s\n' \
    "$SCRAPE" "$SCRAPE" "$SCRAPE" > "$out.tmp" || return 1
  printf 'scrape_configs:\n  - job_name: node\n    static_configs:\n      - targets: ["%s"]\n' \
    "$NODE_LISTEN" >> "$out.tmp" || return 1
  mv -f -- "$out.tmp" "$out"
}

# proc_start <pid>: the process start time, so a pid file can never name a
# different process that later reused the pid.
proc_start() { awk '{ sub(/.*\)/, ""); print $20 }' "/proc/$1/stat" 2>/dev/null; }

# start_one <name> <binary> <args...>: detached, logged, and recorded with its
# start time. 0 when the process answers or was already recorded alive.
start_one() { # <name> <url> <binary> <args...>
  local name=$1 url=$2 bin=$3 rec=$DIR/$1.pid pid start
  shift 3
  if [ -f "$rec" ]; then
    { read -r pid start < "$rec"; } 2>/dev/null || pid=
    if [ -n "${pid:-}" ] && [ "$(proc_start "$pid")" = "$start" ]; then return 0; fi
    rm -f -- "$rec"
  fi
  nohup "$bin" "$@" >> "$DIR/$name.log" 2>&1 &
  pid=$!
  wait_url "$url" 80 || { printf 'jg-metrics-shadow: %s did not answer on %s (see %s.log)\n' "$name" "$url" "$DIR" >&2; return 1; }
  start=$(proc_start "$pid") || return 1
  printf '%s\t%s\n' "$pid" "${start:--}" > "$rec.tmp" && mv -f -- "$rec.tmp" "$rec"
}

cmd_start() {
  tool_gate || return 0
  mkdir -p "$DIR" || die "cannot write $DIR"
  render_config || die "cannot write $DIR/prometheus.yml"
  start_one node_exporter "$(node_url)/metrics" "$NODE" \
    --web.listen-address="$NODE_LISTEN" --collector.textfile.directory="$DIR/textfile" \
    || die "node_exporter did not start"
  start_one prometheus "$(prom_url)/-/ready" "$PROM" \
    --config.file="$DIR/prometheus.yml" --storage.tsdb.path="$DIR/tsdb" \
    --storage.tsdb.retention.time="$RETENTION" --web.listen-address="$LISTEN" \
    --log.level=warn || die "prometheus did not start"
  printf 'started: prometheus on %s, node_exporter on %s (config %s)\n' \
    "$LISTEN" "$NODE_LISTEN" "$DIR/prometheus.yml"
}

# stop_one <name>: TERM the recorded process when the record still names the
# same process, and never touch a stranger that reused the pid.
stop_one() { # <name> <seconds>
  local name=$1 rec=$DIR/$1.pid pid start i=0
  [ -f "$rec" ] || { printf 'stopped: %s not running\n' "$name"; return 0; }
  { read -r pid start < "$rec"; } 2>/dev/null || pid=
  if [ -n "${pid:-}" ] && [ "$(proc_start "$pid")" = "$start" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt $(( ${2:-20} * 4 )) ] && [ "$(proc_start "$pid")" = "$start" ]; do sleep 0.25; i=$((i + 1)); done
    if [ "$(proc_start "$pid")" = "$start" ]; then
      printf 'jg-metrics-shadow: %s (pid %s) did not stop\n' "$name" "$pid" >&2
      return 1
    fi
    printf 'stopped: %s\n' "$name"
  else
    printf 'stopped: %s was not running\n' "$name"
  fi
  rm -f -- "$rec"
}

cmd_stop() { stop_one prometheus 20 && stop_one node_exporter 20; }

cmd_status() {
  local name rec pid start
  shadow_gate || { printf 'shadow\toff\t-\t-\n'; return 0; }
  tool_gate || return 0
  for name in prometheus node_exporter; do
    rec=$DIR/$name.pid
    if [ -f "$rec" ] && { read -r pid start < "$rec"; } 2>/dev/null \
      && [ -n "${pid:-}" ] && [ "$(proc_start "$pid")" = "$start" ]; then
      printf '%s\trunning\tpid=%s\trss=%s\n' "$name" "$pid" \
        "$(awk '/VmRSS/ { printf "%.1f MiB", $2 / 1024 }' "/proc/$pid/status" 2>/dev/null)"
    else
      printf '%s\tstopped\t-\t-\n' "$name"
    fi
  done
}

# shape_metrics: the shipped collector's rows, as node_exporter textfile series.
# A field it prints as `-` or `?` has no number, so it exports no sample and
# parity reports that field as skipped rather than as a difference.
shape_metrics() {
  awk -F '\t' '
    NF >= 8 {
      home = $1
      gsub(/["\\]/, "_", home)
      if ($3 ~ /^-?[0-9]+$/)  printf "jg_fleet_home_working{home=\"%s\"} %s\n", home, $3
      if ($4 ~ /^[0-9]+$/)    printf "jg_fleet_home_target{home=\"%s\"} %s\n", home, $4
      if ($5 ~ /^[0-9]+$/)    printf "jg_fleet_home_ready{home=\"%s\"} %s\n", home, $5
      if ($6 ~ /^[0-9]+$/)    printf "jg_fleet_home_waits{home=\"%s\"} %s\n", home, $6
      if ($7 ~ /^[0-9]+$/)    printf "jg_fleet_home_beacon_age_seconds{home=\"%s\"} %s\n", home, $7
      if ($2 ~ /^[A-Z]+$/)    printf "jg_fleet_home_verdict{home=\"%s\",verdict=\"%s\"} 1\n", home, $2
    }'
}

heartbeat_bin() { printf '%s\n' "${JG_FLEET_HEARTBEAT_BIN:-$SCRIPT_DIR/jg-fleet-heartbeat.sh}"; }

# rows_now: the current path's own rows, from the shipped collector.
rows_now() {
  local bin
  bin=$(heartbeat_bin)
  [ -x "$bin" ] || die "fleet heartbeat not found at $bin"
  JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" "$bin" rows
}

# export_rows <rows-file>: one atomic write of the textfile the collector reads.
export_rows() { # <rows-file>
  local tmp=$DIR/textfile/fleet-shape.prom.tmp
  mkdir -p "$DIR/textfile" || return 1
  shape_metrics < "$1" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$DIR/textfile/fleet-shape.prom"
}

cmd_export() {
  local rows
  shadow_gate || { printf 'skip: metrics shadow is off (config/metrics-shadow)\n'; return 0; }
  tool_gate || return 0
  mkdir -p "$DIR" || die "cannot write $DIR"
  rows=$DIR/.rows.$$
  rows_now > "$rows" || { rm -f -- "$rows"; return 1; }
  export_rows "$rows" || { rm -f -- "$rows"; return 1; }
  printf 'exported: %s series for %s home(s) into %s\n' \
    "$(grep -c . "$DIR/textfile/fleet-shape.prom" 2>/dev/null || echo 0)" \
    "$(grep -c . "$rows" 2>/dev/null || echo 0)" "$DIR/textfile/fleet-shape.prom"
  rm -f -- "$rows"
}

cmd_sync() {
  shadow_gate || return 0
  tool_gate || return 0
  cmd_start >/dev/null || return 0
  cmd_export >/dev/null || return 0
  return 0
}

# query <promql>: the newest sample's value, empty when the series has none.
query() {
  curl -sf --max-time 5 -G --data-urlencode "query=$1" "$(prom_url)/api/v1/query" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
}

# query_label <promql> <label>: one label of the newest sample, empty when none.
query_label() {
  curl -sf --max-time 5 -G --data-urlencode "query=$1" "$(prom_url)/api/v1/query" 2>/dev/null \
    | jq -r --arg l "$2" '.data.result[0].metric[$l] // empty' 2>/dev/null
}

# wait_scrape <millisecond-epoch>: 0 once Prometheus serves a fleet-shape sample
# scraped after that instant, so the comparison reads the bytes this run wrote
# and never a sample an earlier run left behind. The sample's own timestamp comes
# from PromQL's timestamp(), because an instant query's returned timestamp is the
# evaluation time and would satisfy any instant.
wait_scrape() { # <millisecond-epoch>
  local i=0 ts
  while [ "$i" -lt 80 ]; do
    ts=$(query 'timestamp(jg_fleet_home_verdict)')
    [ -n "$ts" ] || ts=$(query 'timestamp(jg_fleet_home_working)')
    if [ -n "$ts" ] && awk -v a="$ts" -v b="$1" 'BEGIN { exit !(a * 1000 > b) }'; then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# compare <label> <shell> <new> <tolerance>: one row, and 1 when it differs.
# An empty side is skipped rather than compared: neither path can measure it.
COMPARED=0
SKIPPED=0
DIFFS=0
compare() { # <field> <shell> <new> <tolerance>
  local field=$1 shell=$2 new=$3 tol=$4 delta verdict=ok
  case "$shell" in '' | *[!0-9.-]*) printf '%-26s %-18s %-18s %-10s skipped\n' "$field" "$shell" "$new" -; SKIPPED=$((SKIPPED + 1)); return 0 ;; esac
  case "$new" in '' | *[!0-9.eE+-]*) printf '%-26s %-18s %-18s %-10s skipped\n' "$field" "$shell" "$new" -; SKIPPED=$((SKIPPED + 1)); return 0 ;; esac
  delta=$(awk -v a="$shell" -v b="$new" 'BEGIN { printf "%.4f", b - a }')
  if awk -v d="$delta" -v t="$tol" 'BEGIN { exit !((d < 0 ? -d : d) > t) }'; then verdict='diff'; fi
  printf '%-26s %-18s %-18s %-10s %s\n' "$field" "$shell" "$new" "$delta" "$verdict"
  COMPARED=$((COMPARED + 1))
  [ "$verdict" = ok ] || DIFFS=$((DIFFS + 1))
  return 0
}

# compare_text <field> <shell> <new>: an exact string field, tolerance zero.
compare_text() { # <field> <shell> <new>
  local verdict=diff
  if [ -z "$2" ] || [ -z "$3" ]; then
    printf '%-26s %-18s %-18s %-10s skipped\n' "$1" "${2:--}" "${3:--}" -
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  [ "$2" = "$3" ] && verdict=ok
  printf '%-26s %-18s %-18s %-10s %s\n' "$1" "$2" "$3" - "$verdict"
  COMPARED=$((COMPARED + 1))
  [ "$verdict" = ok ] || DIFFS=$((DIFFS + 1))
}

# corrupt_one <rows-file> <copy>: publish one tampered sample on the new path
# alone, so a run that still reported no difference would mean the check cannot
# see anything. The first home's wait count moves by one in the copy that is
# exported, and the pinned rows the shell side is compared against stay true.
corrupt_one() { # <rows-file> <copy>
  local home
  home=$(awk -F '\t' 'NF >= 8 { print $1; exit }' "$1")
  [ -n "$home" ] || return 1
  CORRUPT_HOME=$home
  awk -F '\t' -v h="$home" 'BEGIN { OFS = "\t" }
    NF >= 8 && $1 == h && $6 ~ /^[0-9]+$/ { $6 = $6 + 1 } { print }' "$1" > "$2" \
    || return 1
  export_rows "$2"
}

# field_of <rows-file> <home> <column>: one field of one home's row.
field_of() { # <rows-file> <home> <column>
  awk -F '\t' -v h="$2" -v c="$3" 'NF >= 8 && $1 == h { print $c; exit }' "$1"
}

cmd_parity() {
  local rows base since root df_avail mem_kib load1 home c
  shadow_gate || { printf 'metrics shadow parity: not run, shadow is off (config/metrics-shadow)\n'; return 1; }
  # parity is an explicit check, so a tool it cannot find fails it rather than
  # skipping it: a run that did not happen must never be readable as a green one.
  resolve_bins
  if [ -z "$PROM" ] || [ ! -x "$PROM" ] || [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    printf 'metrics shadow parity: not run, prometheus or node_exporter not found\n'
    return 1
  fi
  if ! wait_url "$(prom_url)/-/ready" 1; then
    # parity is an explicit check, so an absent server is a failure rather than a
    # skip: a run that did not happen must never be readable as a green one.
    cmd_start >/dev/null || { printf 'metrics shadow parity: not run, prometheus did not start\n'; return 1; }
  fi
  base=$DIR/.parity.$$
  rows=$base.rows
  rows_now > "$rows" || die "cannot read the shipped collector's rows"
  if [ "$CORRUPT" -eq 1 ]; then
    corrupt_one "$rows" "$rows.corrupt" || { printf 'metrics shadow parity: corrupt_target=none\n'; rm -f -- "$rows"; return 1; }
  else
    export_rows "$rows" || die "cannot write the fleet-shape textfile"
  fi
  # The instant is pinned in milliseconds, after the write, so the sample the
  # comparison reads was scraped from the bytes this run published and never the
  # one an earlier run left behind.
  since=$(date +%s%3N)
  wait_scrape "$since" || { printf 'metrics shadow parity: not run, no fleet-shape sample was scraped\n'; rm -f -- "$rows"; return 1; }

  COMPARED=0 SKIPPED=0 DIFFS=0
  printf '%-26s %-18s %-18s %-10s %s\n' field shell prometheus delta verdict
  load1=$(awk 'NF { print $1; exit }' /proc/loadavg 2>/dev/null)
  compare load1 "$load1" "$(query node_load1)" "$LOAD_TOL"
  mem_kib=$(awk '/^MemAvailable:/ { printf "%.0f", $2 }' /proc/meminfo 2>/dev/null)
  compare mem_available_kib "$mem_kib" "$(query 'node_memory_MemAvailable_bytes/1024')" \
    "$(awk -v m="${mem_kib:-0}" -v p="$MEM_TOL_PCT" 'BEGIN { printf "%.0f", m * p / 100 }')"
  root=$(df -P / 2>/dev/null | awk 'NR == 2 { print $6; exit }')
  df_avail=$(df -P / 2>/dev/null | awk 'NR == 2 { print $4; exit }')
  compare disk_avail_kib "$df_avail" \
    "$(query "node_filesystem_avail_bytes{mountpoint=\"${root:-/}\",fstype!~\"tmpfs|overlay\"}/1024")" "$DISK_TOL_KIB"
  local -a homes=()
  while IFS=$'\t' read -r home _; do [ -n "$home" ] && homes+=("$home"); done < "$rows"
  for home in "${homes[@]}"; do
    for c in 3:working 4:target 5:ready 6:waits; do
      compare "fleet_${home}_${c#*:}" "$(field_of "$rows" "$home" "${c%%:*}")" \
        "$(query "jg_fleet_home_${c#*:}{home=\"$home\"}")" 0
    done
    compare_text "fleet_${home}_verdict" "$(field_of "$rows" "$home" 2)" \
      "$(query_label "jg_fleet_home_verdict{home=\"$home\"} == 1" verdict)"
    compare "fleet_${home}_beacon_age" "$(field_of "$rows" "$home" 7)" \
      "$(query "jg_fleet_home_beacon_age_seconds{home=\"$home\"}")" 0
  done
  if [ "$CORRUPT" -eq 1 ]; then
    printf 'corrupt: fleet_%s_waits moved by one on the prometheus path only\n' "${CORRUPT_HOME:-none}"
    export_rows "$rows"
  fi
  rm -f -- "$rows" "$rows.corrupt"
  printf 'metrics shadow parity: homes=%s fields_compared=%s fields_skipped=%s differences=%s\n' \
    "${#homes[@]}" "$COMPARED" "$SKIPPED" "$DIFFS"
  # A parity that compared nothing, or that never compared the three host
  # numbers, has proven nothing: that is a failure, never a pass.
  if [ "$COMPARED" -lt $((3 + ${#homes[@]})) ]; then
    printf 'metrics shadow parity: not proven, too few fields were comparable\n'
    return 1
  fi
  [ "$DIFFS" -eq 0 ]
}

while [ "$#" -gt 0 ]; do
  case $1 in
    --corrupt) CORRUPT=1; shift ;;
    start|stop|status|export|sync|parity) CMD=$1; shift ;;
    -h|--help) sed -n '2,73p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'usage: jg-metrics-shadow.sh start|stop|status|export|sync|parity [--corrupt] (see the header)\n' >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || { printf 'usage: jg-metrics-shadow.sh start|stop|status|export|sync|parity [--corrupt] (see the header)\n' >&2; exit 2; }
resolve_bins

case $CMD in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  export) cmd_export ;;
  sync) cmd_sync ;;
  parity) cmd_parity ;;
esac
