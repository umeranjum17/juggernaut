#!/usr/bin/env bash
# jg-switch.sh - the reader of the switch manifest: which switches a change declared are still off in a home.
#
# Usage:
#   jg-switch.sh status [--home <dir>]... [<change-id>]   per home, one line for each switch still off
#   jg-switch.sh verify [--home <dir>]... [<change-id>]   status, exit 1 while any manifest row is off (detector lines never count)
#   jg-switch.sh refresh-releases [--home <dir>]          look up each npm row's latest release into state/tool-releases.tsv
#   jg-switch.sh flags <project> [--home <dir>]           the flag sheet: every flag that changes how the project ships, with its value, default and flip
#   jg-switch.sh count --home <dir> [<change-id>...]      one line `switches-off:<n> detectors:<m>`: the manifest rows of those changes
#                                                         that are off, and every detector line (no ids: no manifest row is read)
#   jg-switch.sh apply <change-id> <name> [--home <dir>] [--owner-word "<text>"] [--value <v>]
#                                                         turn one policy row on; the owner's word is required for who=owner
#
# Output, per home: `home <id>` then `off <change-id> <kind> <name> <reason> <who>` for each manifest row that is off, then
# `off - detector <name> <reason> <who>` for each standing finding that no change declared (a wiring step that failed in the
# home's last go-live row, an unarmed check, a restart marker). A home with nothing off prints only its header.
#
# Manifest (core/machines/switches.tsv, or JG_SWITCH_MANIFEST), tab separated: change-id, kind, name, want, who, expires, reason.
# There is no command column: every kind's check lives here, so a data file never carries a command. Kinds:
#   file    config/<name> exists (want present) or is non-empty (want nonempty)        reason absent | empty
#   policy  jg_trunk_policy <key>[@project] equals want; want `set` = any value         reason unset | differs
#   mode    the machine <name> is a line of config/machine-enforce                      reason absent
#   check   state/<name>.check.sh and state/<name>.check-trust both exist               reason unarmed
#   wiring  <name> is not a failed step in the home's last data/trunk-in-use.tsv row    reason wiring-failed
#   npm     `<name> --version` is at or above its toolchain.versions pin, and not behind the cached latest release
#                                                                             reason below-pin | behind-release | absent
#   restart state/trunk-live-restart-pending is not newer than state/.session-start-complete   reason restart-pending
#   waiver  config/<file> has a line for the project: name is `<file>:<project>`        reason absent
# Every check runs in its own process under jg-timeout-lib.sh (JG_SWITCH_TIMEOUT seconds, default 20); a check that hits
# the bound reads off with reason `timeout`, so one stuck kind cannot hang the command.
# A release lookup is a network call, so it never runs in `status`: `refresh-releases` runs `npm view <package> version` for each
# npm row (package from the pin row, else the name), each under jg-timeout-lib.sh (JG_SWITCH_REFRESH_TIMEOUT seconds, default 8),
# and writes `<name> <latest|-> <epoch> <ok|failed>` to state/tool-releases.tsv. The watched tool-update check runs it; go-live never does.
# A tool at its pin whose cache row is missing, failed or older than 48 hours (JG_SWITCH_RELEASE_MAX_AGE seconds) reads
# `unknown-release`: printed as `unknown ...` instead of `off ...`, so neither verify nor the delivery observer counts it.
# The one write is `apply` of a policy row: it appends `<name>=<want>` to config/trunk-policy, which the policy reader
# takes as the last matching line. It needs --owner-word for a who=owner row; no other kind is written here.
# The flag sheet (`flags`) prints one tab-separated line per flag: `flag <name> <value> <default> <flip command>`. Flags: each trunk-policy
# key the home set for the project (`key@project` or `key`), the registry's yolo word, the go-live and release waiver lines, and each
# standing proof bypass that covers the project. A flag at its default prints no line; a home with none prints `no flags set`.
# Environment: JG_HOME, JG_SWITCH_MANIFEST, JG_SWITCH_TOOLCHAIN (the pin table, default <repo>/toolchain.versions).
set -u
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/jg-timeout-lib.sh
. "$SCRIPT_DIR/jg-timeout-lib.sh"
# shellcheck source=bin/jg-trunk-policy-lib.sh
. "$SCRIPT_DIR/jg-trunk-policy-lib.sh"
MANIFEST="${JG_SWITCH_MANIFEST:-$ROOT/core/machines/switches.tsv}"
TOOLCHAIN="${JG_SWITCH_TOOLCHAIN:-$ROOT/toolchain.versions}"
BOUND="${JG_SWITCH_TIMEOUT:-20}"
REFRESH_BOUND="${JG_SWITCH_REFRESH_TIMEOUT:-8}"
RELEASE_MAX_AGE="${JG_SWITCH_RELEASE_MAX_AGE:-172800}"
NAME_RE='^[A-Za-z0-9._@-]+$'

die() { echo "jg-switch: $*" >&2; exit "${2:-2}"; }
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }

# --- the checks: one kind per case, run as `_probe <home> <kind> <name> <want>`; prints `on` or the reason it is off ---
version_of() { "$1" --version 2>/dev/null | sed -nE 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1; }
at_least() {  # <have> <min>: dotted numbers
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}
last_row_status() { tail -n 1 "$1/data/trunk-in-use.tsv" 2>/dev/null | cut -f4; }
# The cached latest release against what is installed: `on`, `behind-release`, or `unknown-release` when the row is missing,
# failed, older than the age bound, or unreadable.
release_state() {  # <home> <name> <have>
  local latest at st now
  IFS=$'\t' read -r latest at st < <(awk -F'\t' -v t="$2" '$1 == t { print $2 "\t" $3 "\t" $4; exit }' "$1/state/tool-releases.tsv" 2>/dev/null)
  now=$(date +%s)
  if [ "${st-}" != ok ] || ! [[ ${at-} =~ ^[0-9]+$ ]] || ! [[ ${latest-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || [ $((now - at)) -gt "$RELEASE_MAX_AGE" ]; then echo unknown-release
  elif at_least "$3" "$latest"; then echo on; else echo behind-release; fi
}
probe() {  # <home> <kind> <name> <want>
  local home=$1 kind=$2 name=$3 want=$4 key proj val pin have status
  case $kind in
    file)
      [ -e "$home/config/$name" ] || { echo absent; return; }
      if [ "$want" = nonempty ] && [ ! -s "$home/config/$name" ]; then echo empty; else echo on; fi ;;
    policy)
      key=${name%%@*}; proj=; [ "$key" = "$name" ] || proj=${name#*@}
      val=$(JG_CONFIG_OVERRIDE="$home/config" jg_trunk_policy "$key" "$proj") || val=
      if [ "$want" = set ]; then { [ -n "$val" ] && echo on; } || echo unset
      elif [ "$val" = "$want" ]; then echo on; else echo differs; fi ;;
    mode) grep -qxF -- "$name" "$home/config/machine-enforce" 2>/dev/null && echo on || echo absent ;;
    check) [ -f "$home/state/$name.check.sh" ] && [ -f "$home/state/$name.check-trust" ] && echo on || echo unarmed ;;
    wiring)
      status=$(last_row_status "$home")
      case $status in
        *wiring-failed:*) case ",${status##*wiring-failed:}," in *",$name,"*) echo wiring-failed; return ;; esac ;;
      esac
      echo on ;;
    npm)
      pin=$(awk -v t="$name" '$1 == t { n = split($2, a, "@"); print a[n] }' "$TOOLCHAIN" 2>/dev/null | head -n 1)
      have=$(version_of "$name")
      if [ -z "$have" ]; then echo absent
      elif [ -n "$pin" ] && ! at_least "$have" "$pin"; then echo below-pin
      else release_state "$home" "$name" "$have"; fi ;;
    restart)
      if [ -e "$home/state/trunk-live-restart-pending" ] && ! [ "$home/state/.session-start-complete" -nt "$home/state/trunk-live-restart-pending" ]; then
        echo restart-pending
      else echo on; fi ;;
    waiver)
      grep -q "^${name#*:} " "$home/config/${name%%:*}" 2>/dev/null && echo on || echo absent ;;
    *) echo "unknown-kind" ;;
  esac
}

# Run one check under the bound: prints `on`, a reason, or `timeout`.
run_probe() {  # <home> <kind> <name> <want>
  local out rc
  out=$(jg_run_timed "$BOUND" bash "$0" _probe "$@" 2>/dev/null); rc=$?
  if jg_timed_out "$rc" 2>/dev/null || [ "$rc" -eq 124 ]; then echo timeout; return; fi
  [ "$rc" -eq 0 ] && [ -n "$out" ] || { echo error; return; }
  printf '%s\n' "$out"
}

# --- the standing findings no change declared (never counted by verify) ---
detectors() {  # <home>
  local home=$1 status steps step name
  status=$(last_row_status "$home")
  case $status in
    *wiring-failed:*)
      steps=${status##*wiring-failed:}
      for step in ${steps//,/ }; do tab off - detector "$step" wiring-failed auto; done ;;
  esac
  for name in installed-drift tool-update-check; do
    [ -f "$home/state/$name.check.sh" ] || tab off - detector "$name" unarmed auto
  done
  [ "$(probe "$home" restart trunk-live-restart-pending -)" = on ] || tab off - detector restart-marker restart-pending owner
}

# Print one home's report; returns 1 when a manifest row is off.
report_home() {  # <home> <change-id|''>
  local home=$1 only=$2 id kind name want who r rc=0
  echo "home $(basename "$home")"
  while IFS=$'\t' read -r id kind name want who _ _ || [ -n "$id" ]; do
    case $id in ''|'#'*) continue ;; esac
    [ -z "$only" ] || case " $only " in *" $id "*) ;; *) continue ;; esac
    [[ $name =~ $NAME_RE || $kind = waiver ]] || { tab off "$id" "$kind" "$name" bad-name "$who"; rc=1; continue; }
    r=$(run_probe "$home" "$kind" "$name" "$want")
    [ "$r" = on ] && continue
    [ "$r" != unknown-release ] || { tab unknown "$id" "$kind" "$name" "$r" "$who"; continue; }
    tab off "$id" "$kind" "$name" "$r" "$who"; rc=1
  done < "$MANIFEST"
  detectors "$home"
  return "$rc"
}

# Look up the latest release of each npm tool the manifest names; one failed lookup is recorded as failed, never fatal.
cmd_refresh() {
  local home=${JG_HOME:-$ROOT} tools name pkg out rc tmp
  while [ $# -gt 0 ]; do
    case $1 in
      --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -r "$MANIFEST" ] || die "no manifest at $MANIFEST"
  [ -d "$home/state" ] || die "no state directory in $home"
  tools=$(awk -F'\t' '$1 !~ /^#/ && $2 == "npm" && !seen[$3]++ { print $3 }' "$MANIFEST")
  tmp=$(mktemp "$home/state/.tool-releases.XXXXXX") || die "cannot write in $home/state"
  for name in $tools; do
    [[ $name =~ $NAME_RE ]] || continue
    pkg=$(awk -v t="$name" '$1 == t { print $2; exit }' "$TOOLCHAIN" 2>/dev/null)
    case ${pkg:1} in *@*) pkg=${pkg%@*} ;; *) pkg=$name ;; esac
    out=$(jg_run_timed "$REFRESH_BOUND" npm view "$pkg" version 2>/dev/null); rc=$?
    out=$(printf '%s\n' "$out" | tail -n 1)
    if [ "$rc" -eq 0 ] && [[ $out =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then tab "$name" "$out" "$(date +%s)" ok
    else tab "$name" - "$(date +%s)" failed; fi
  done > "$tmp"
  mv -f "$tmp" "$home/state/tool-releases.tsv"
}

cmd_status() {  # <verify:0|1> args...
  local verify=$1 only="" homes=() h rc=0; shift
  while [ $# -gt 0 ]; do
    case $1 in
      --home) [ $# -ge 2 ] || die "--home needs a directory"; homes+=("$2"); shift 2 ;;
      -*) die "unknown option $1" ;;
      *) only="$only $1"; shift ;;
    esac
  done
  [ -r "$MANIFEST" ] || die "no manifest at $MANIFEST"
  [ ${#homes[@]} -gt 0 ] || homes=("${JG_HOME:-$ROOT}")
  for h in "${homes[@]}"; do [ -d "$h" ] || die "no such home: $h"; report_home "$h" "$only" || rc=1; done
  [ "$verify" -eq 1 ] && return "$rc"
  return 0
}

# The numbers the go-live row carries: the off rows of the named changes, and the detector lines of the home.
cmd_count() {  # --home <dir> [<change-id>...]
  local home="" ids="" out n m
  while [ $# -gt 0 ]; do
    case $1 in
      --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
      -*) die "unknown option $1" ;;
      *) ids="$ids $1"; shift ;;
    esac
  done
  [ -r "$MANIFEST" ] || die "no manifest at $MANIFEST"
  [ -d "$home" ] || die "no such home: $home"
  out=$(report_home "$home" "${ids:--}")
  n=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "off" && $2 != "-" { n++ } END { print n + 0 }')
  m=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "off" && $2 == "-" { n++ } END { print n + 0 }')
  echo "switches-off:$n detectors:$m"
}

cmd_apply() {
  local id=${1-} name=${2-} home=${JG_HOME:-$ROOT} word="" value="" row kind want who r
  [ -n "$id" ] && [ -n "$name" ] || die "usage: apply <change-id> <name> [--home <dir>] [--owner-word <text>] [--value <v>]"
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --home) home=${2-}; shift 2 ;;
      --owner-word) word=${2-}; shift 2 ;;
      --value) value=${2-}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -r "$MANIFEST" ] || die "no manifest at $MANIFEST"
  row=$(awk -F'\t' -v i="$id" -v n="$name" '$1 == i && $3 == n { print; exit }' "$MANIFEST")
  [ -n "$row" ] || die "no manifest row $id $name"
  IFS=$'\t' read -r _ kind _ want who _ <<< "$row"
  [ "$who" != owner ] || [ -n "$word" ] || die "$id $name is the owner's call: pass --owner-word with the owner's words"
  [ "$kind" = policy ] || die "apply writes only policy rows; $name is kind $kind"
  [[ $name =~ $NAME_RE ]] || die "bad name $name"
  [ "$want" != set ] || want=$value
  [ -n "$want" ] || die "$name wants any value: pass --value"
  case $want in *$'\n'*) die "a value takes one line" ;; esac
  [ -d "$home/config" ] || die "no config directory in $home"
  printf '%s=%s\n' "$name" "$want" >> "$home/config/trunk-policy"
  r=$(run_probe "$home" policy "$name" "$(awk -F'\t' -v i="$id" -v n="$name" '$1 == i && $3 == n { print $4; exit }' "$MANIFEST")")
  echo "applied $id $name=$want: now $r"
}

# The flag sheet for one project: what the home set away from the default, and the command that puts each back.
cmd_flags() {
  local proj=${1-} home=${JG_HOME:-$ROOT} key val def line n=0 file rule mode yolo id st scope target
  [ $# -eq 0 ] || shift
  [ -n "$proj" ] && [[ $proj =~ $NAME_RE ]] || die "usage: flags <project> [--home <dir>]"
  while [ $# -gt 0 ]; do
    case $1 in
      --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  [ -d "$home" ] || die "no such home: $home"
  echo "project $proj"
  while IFS= read -r line; do
    key=${line%%=*}; val=${line#*=}
    case $key in *@*) [ "${key#*@}" = "$proj" ] || continue; key=${key%@*} ;; esac
    def=$(JG_CONFIG_OVERRIDE=/nonexistent jg_trunk_policy "$key" "$proj" 2>/dev/null) || def=
    [ "$val" != "$def" ] || continue
    tab flag "$key@$proj" "$val" "${def:--}" "delete the last $key line for $proj in $home/config/trunk-policy"; n=$((n + 1))
  done < <(grep -E "^[A-Za-z0-9-]+(@$proj)?=" "$home/config/trunk-policy" 2>/dev/null)
  read -r mode yolo < <(JG_HOME=$home JG_DATA_OVERRIDE=$home/data bash "$SCRIPT_DIR/jg-project-mode.sh" --raw "$proj" 2>/dev/null)
  if [ "${yolo-}" = on ]; then
    tab flag yolo on off "remove +yolo from the $proj line in $home/data/projects.md"; n=$((n + 1))
  fi
  for file in trunk-live-waiver trunk-release-waiver; do
    rule=$(jg_trunk_waiver_rule "$home/config/$file" "$proj")
    [ -z "$rule" ] || { tab flag "$file" "$rule" none "delete the $proj line in $home/config/$file"; n=$((n + 1)); }
  done
  while IFS=$'\t' read -r id st scope target _; do
    [ "$st" = standing ] || continue
    [ "$scope" = home ] || [ "$target" = "$proj" ] || continue
    tab flag "proof-bypass:$scope" "$id" none "bin/jg-proof-bypass.sh end $id"; n=$((n + 1))
  done < <(JG_HOME=$home bash "$SCRIPT_DIR/jg-proof-bypass.sh" list --standing 2>/dev/null)
  [ "$n" -gt 0 ] || echo "no flags set"
}

case ${1-} in
  flags) shift; cmd_flags "$@" ;;
  _probe) shift; probe "$@" ;;
  status) shift; cmd_status 0 "$@" ;;
  verify) shift; cmd_status 1 "$@" ;;
  refresh-releases) shift; cmd_refresh "$@" ;;
  count) shift; cmd_count "$@" ;;
  apply) shift; cmd_apply "$@" ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
