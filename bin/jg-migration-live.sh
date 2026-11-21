#!/usr/bin/env bash
# jg-migration-live.sh - probe each part of the stack on this machine for the
# migration card: does it run here, and what was measured.
#
# WHY THIS EXISTS. "What is live now and what is pending" is a measurement, not a
# memory, so every line the card shows comes from a probe run here: the process and
# the port for a service, a real command for a tool, and
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
#   owner   bin/jg-bus.sh and core/merge-on-green/ own the names, addresses and
#           switches read here (`jg-bus gateway status --row` owns the chat row's
#           measurement); this file re-spells none of them without this header
#           changing too.
#   cost    one pass runs a bounded handful of processes and one read of the open pull requests, and writes nothing outside $DIR except the
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

PART_SLUGS=(wake inbox leases godaemons gate escalation fiveminute deletions rules axi addons policy pendingreplies leadwake linecounts chat)
PART_NAMES=('wake queue' 'task inbox' 'leases' 'Go daemons' 'merge gate' 'escalation ladder' 'five-minute merge' 'deletions' 'rules JSON' 'juggernaut-axi' 'add-on removal' 'Rego policy' 'pending-replies cleanup' 'lead-wake cleanup' 'line counts from git' 'captain chat (Telegram)')
# Per part: a case-insensitive pattern over open pull request titles.
PART_PR_RE=('wake queue|wake engine|wake' 'inbox|wake queue' 'lease' ' go\b|in go|go consumer|go wake' 'merge gate' 'wait ladder|escalation' 'merge-on-green|five-minute|merge path' 'delet|release c-' 'rules json|crew-dispatch|rego' 'juggernaut-axi' 'add-on|addon' 'rego|opa|policy' 'pending-repl' 'lead-wake|leadwake' 'line count' 'chat gateway|telegram|captain chat')

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

# count_lines <file>: newline count, zero when the file is absent.
count_lines() { [ -r "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# probe_wake, probe_inbox: the wake queue and the task inboxes are local files
# (the `direct` and `off` modes), so a path that is there is live and says how many rows it holds.
probe_wake() {
  local queue="$STATE/.wake-queue"
  if [ -e "$queue" ]; then
    printf 'live\tthe wake queue is the local file state/.wake-queue, %s rows\n' "$(count_lines "$queue")"
  else
    printf 'pending\tno state/.wake-queue file in this home yet\n'
  fi
}

probe_inbox() {
  local n
  n=$(find "$STATE" -maxdepth 1 -type d -name '*.inbox' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt 0 ]; then
    printf 'live\tthe task inboxes are local folders under state/, %s of them\n' "$n"
  else
    printf 'pending\tno task inbox folder under state/ in this home yet\n'
  fi
}

probe_leases() {
  local out rc
  [ -x "$ROOT/bin/jg-lease.sh" ] || { printf 'absent\tbin/jg-lease.sh is not in this checkout\n'; return 0; }
  out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" JG_CONFIG_OVERRIDE="$CFG" \
    timeout 20 "$ROOT/bin/jg-lease.sh" check jg-live-probe 2>&1)
  rc=$?
  case $rc in
    0) printf 'live\tthe store state/kv.db answers, jg-live-probe is held by %s\n' "$out" ;;
    1) printf 'live\tthe store state/kv.db answers, none on the probe id\n' ;;
    *) printf 'pending\tthe lease store could not answer (exit %s)\n' "$rc" ;;
  esac
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
    wake) probe_wake ;;
    inbox) probe_inbox ;;
    leases) probe_leases ;;
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
