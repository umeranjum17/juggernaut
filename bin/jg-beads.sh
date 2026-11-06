#!/usr/bin/env bash
# jg-beads.sh - the one guarded way to run bd and dolt.
#
# Usage: BEADS_DIR=<store>/.beads jg-beads.sh init --prefix <prefix>
#        BEADS_DIR=<store>/.beads jg-beads.sh check
#        BEADS_DIR=<store>/.beads jg-beads.sh dolt version
#        BEADS_DIR=<store>/.beads jg-beads.sh dolt sql -q <query>
#        BEADS_DIR=<store>/.beads jg-beads.sh <bd verb> [args...]
#        jg-beads.sh --help
#
# `init` creates an embedded, stealth store; no bd init flag reaches it. `check` proves the pins
# and the store without running either tool. `dolt` runs in the store's database folder and
# refuses a query naming a dolt_push, pull, fetch, clone, remote or backup procedure.
# Every other verb is a bd call from the store's parent, so a relative path means that folder.
# bd verbs served: show list ready count search blocked create update close reopen dep label
# comment comments note, plus what a migration needs: `import <file>`, `export -o <name>` with a
# plain name, so the file lands beside the store, and `config set` for status.custom and
# allowed_prefixes only. Any other is refused, so a verb that can reach a server, a remote or a
# git tree needs a deliberate change here.
#
# Refusals (exit 2, neither tool run):
#   - BEADS_DIR unset, relative, a symlink, or not named `.beads`. Its parent must exist, because
#     bd also writes `<parent>/.beads.gate.lock` outside BEADS_DIR: the whole write path is the
#     parent, one folder per store.
#   - a parent inside any git tree (`.git` in it or above it, symlinks resolved), the real home
#     folder, or /. bd init inside a tree can write `.beads/` and core.hooksPath.
#   - BEADS_DOLT_SHARED_SERVER set to anything: bd init then returns 0 and puts every home on one
#     database. A store whose metadata or config names a server or lacks stealth mode as well.
#   - --global, --db, --database, -C or --directory anywhere in a bd call, because each moves the
#     call off BEADS_DIR, and --mem-profile or --cpu-profile, which write outside it.
#   - a bd or dolt whose sha256 is not its toolchain.versions row for this platform, checked
#     before its first run, even for a version. JG_BEADS_BD and JG_BEADS_DOLT name the binary;
#     otherwise each comes from PATH.
#
# Every call forces BD_DISABLE_METRICS=1, DO_NOT_TRACK=1 and BD_NON_INTERACTIVE=1, since bd metrics
# are on by default, and drops every other BEADS_*, BD_*, DOLT_* and GIT_* variable but BEADS_ACTOR.
# HOME, XDG_* and TMPDIR point at `<parent>/.jg-beads-env`, because both tools write `$HOME/.dolt`,
# and dolt's metrics and version check are off there; without that even `dolt version` calls out.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pin-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-pin-lib.sh"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'jg-beads: %s\n' "$*" >&2; exit 2; }

# Sets STORE_PARENT to the real parent of BEADS_DIR, or refuses before anything is written.
store_path_check() {
  local dir=${BEADS_DIR-} parent up real_home
  [ -z "${BEADS_DOLT_SHARED_SERVER+set}" ] || die "BEADS_DOLT_SHARED_SERVER is set; a shared server is banned, unset it"
  [ -n "$dir" ] || die "BEADS_DIR is not set; bd never looks for a store by itself"
  case "$dir" in /*) ;; *) die "BEADS_DIR must be absolute: $dir" ;; esac
  case "$dir/" in */../*|*/./*) die "BEADS_DIR must have no . or .. parts: $dir" ;; esac
  [ "${dir##*/}" = .beads ] || die "BEADS_DIR must end in /.beads, so each store has its own parent: $dir"
  [ ! -L "$dir" ] || die "BEADS_DIR is a symlink: $dir"
  parent=${dir%/*}
  [ -d "${parent:-/}" ] || die "the parent of BEADS_DIR does not exist: $parent"
  STORE_PARENT=$(cd -P -- "${parent:-/}" && pwd -P) || die "cannot enter the parent of BEADS_DIR: $parent"
  real_home=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || real_home=/
  [ "$STORE_PARENT" != / ] && [ "$STORE_PARENT" != "$real_home" ] || die "the parent of BEADS_DIR takes bd's lock files, so it cannot be $STORE_PARENT"
  up=$STORE_PARENT
  while :; do
    [ ! -e "$up/.git" ] || die "BEADS_DIR is inside the git tree at $up; keep the store outside any tree"
    [ -n "$up" ] || break
    up=${up%/*}
  done
}

# An existing store must be the embedded, stealth kind this wrapper creates.
store_mode_check() {
  local meta=$BEADS_DIR/metadata.json config=$BEADS_DIR/config.yaml
  [ -f "$meta" ] || die "no store at $BEADS_DIR; create it with jg-beads.sh init --prefix <prefix>"
  grep -Eq '"dolt_mode": *"embedded"' "$meta" || die "$meta is not an embedded store; a server store is banned"
  ! grep -q 'server' "$meta" || die "$meta names a server; a server store is banned"
  grep -Eq '^no-git-ops: *true' "$config" 2>/dev/null || die "$config lacks no-git-ops: true; the store is not in stealth mode"
  ! grep -Eq '^[^#]*server' "$config" || die "$config names a server; a server store is banned"
}

# Sets PINNED_TOOL to the verified binary. The hash runs first, so an unpinned build never starts.
pin_check() {  # <bd|dolt>
  local tool=$1 path os arch want got
  if [ "$tool" = dolt ]; then path=${JG_BEADS_DOLT:-$(command -v dolt)}; else path=${JG_BEADS_BD:-$(command -v "$tool")}; fi
  [ -n "$path" ] && [ -x "$path" ] || die "$tool is not installed; toolchain.versions names the build this needs"
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  want=$(jg_pin_spec "$tool-sha256-$os-$arch") || die "toolchain.versions has no $tool build for $os-$arch"
  got=$({ sha256sum "$path" 2>/dev/null || shasum -a 256 "$path"; } | cut -d' ' -f1)
  [ "$got" = "$want" ] || die "$path is not the pinned $tool $(jg_pin_version "$tool"): its sha256 is $got, the pin is $want"
  PINNED_TOOL=$path
}

# Runs after the path check, so its first write lands in a folder already proved safe.
env_lock() {
  local name env=$STORE_PARENT/.jg-beads-env
  for name in $(compgen -e); do
    case "$name" in
      BEADS_DIR|BEADS_ACTOR) ;;
      BEADS_*|BD_*|DOLT_*|GIT_*) unset "$name" ;;
    esac
  done
  umask 077
  mkdir -p -- "$env/home/.dolt" "$env/tmp" || die "cannot write beside the store: $env"
  printf '{"metrics.disabled":"true","versioncheck.disabled":"true"}\n' > "$env/home/.dolt/config_global.json"
  export HOME=$env/home TMPDIR=$env/tmp
  export XDG_CONFIG_HOME=$HOME/.config XDG_CACHE_HOME=$HOME/.cache
  export XDG_DATA_HOME=$HOME/.local/share XDG_STATE_HOME=$HOME/.local/state
  export BD_DISABLE_METRICS=1 DO_NOT_TRACK=1 BD_NON_INTERACTIVE=1
  export BEADS_ACTOR=${BEADS_ACTOR:-juggernaut}
  export BEADS_CEILING_DIRECTORIES=$STORE_PARENT GIT_CEILING_DIRECTORIES=$STORE_PARENT
}

run_init() {  # --prefix <prefix>
  [ "$#" -eq 2 ] && [ "$1" = --prefix ] || die "usage: jg-beads.sh init --prefix <prefix>"
  case "$2" in ''|-*|*[!A-Za-z0-9_-]*) die "a prefix is letters, digits, - and _ only: $2" ;; esac
  [ ! -e "$BEADS_DIR/metadata.json" ] || die "$BEADS_DIR is already a store; init never runs twice"
  pin_check bd
  mkdir -p -- "$BEADS_DIR" || die "cannot create $BEADS_DIR"
  cd -- "$STORE_PARENT" || die "cannot enter $STORE_PARENT"
  "$PINNED_TOOL" init --quiet --stealth --prefix "$2" || exit $?
  store_mode_check
}

run_dolt() {  # version | sql -q <query>
  local db
  if [ "$#" -eq 3 ] && [ "$1" = sql ] && [ "$2" = -q ]; then
    printf '%s' "$3" | grep -Eiq 'dolt_(push|pull|fetch|clone|remote|backup)' \
      && die "this query reaches a remote, which the store never does"
  elif [ "$*" != version ]; then
    die "only dolt version and dolt sql -q <query> run here"
  fi
  pin_check dolt
  store_mode_check
  db=$(sed -n 's/.*"dolt_database": *"\([^"]*\)".*/\1/p' "$BEADS_DIR/metadata.json")
  [ -n "$db" ] && [ -d "$BEADS_DIR/embeddeddolt/$db" ] || die "no database folder for ${db:-this store} in $BEADS_DIR/embeddeddolt"
  cd -- "$BEADS_DIR/embeddeddolt/$db" || die "cannot enter the database folder of $BEADS_DIR"
  exec "$PINNED_TOOL" "$@"
}

run_bd() {  # <verb> [args...]
  local arg
  case "${1-}" in
    show|list|ready|count|search|blocked|create|update|close|reopen|dep|label|comment|comments|note) ;;
    import) [ "$#" -eq 2 ] && [ "${2#-}" = "$2" ] || die "usage: jg-beads.sh import <file>" ;;
    export)
      [ "$#" -eq 3 ] && [ "$2" = -o ] || die "usage: jg-beads.sh export -o <name>"
      case "$3" in ''|-*|.*|*/*) die "an export name is a plain file name beside the store: $3" ;; esac
      ;;
    config)
      [ "$#" -eq 4 ] && [ "$2" = set ] || die "bd config is not served except as config set <key> <value>"
      case "$3" in status.custom|allowed_prefixes) ;; *) die "bd config key $3 is not served here" ;; esac
      ;;
    *) die "bd ${1-} is not served here; see jg-beads.sh --help" ;;
  esac
  for arg in "$@"; do
    case "$arg" in
      --global|--global=*|--db|--db=*|--database|--database=*|--directory|--directory=*|-C*|-[!-]*C*|--mem-profile*|--cpu-profile*)
        die "$arg would move this call off BEADS_DIR" ;;
    esac
  done
  pin_check bd
  store_mode_check
  cd -- "$STORE_PARENT" || die "cannot enter $STORE_PARENT"
  exec "$PINNED_TOOL" "$@"
}

case "${1:-}" in ''|-h|--help) usage; exit 0 ;; esac
store_path_check
export BEADS_DIR=$STORE_PARENT/.beads
env_lock
case "$1" in
  init) shift; run_init "$@" ;;
  check)
    for tool in bd dolt; do
      pin_check "$tool"
      printf '%s: %s (pinned %s)\n' "$tool" "$PINNED_TOOL" "$(jg_pin_version "$tool")"
    done
    store_mode_check
    printf 'store: %s (embedded, stealth)\n' "$BEADS_DIR"
    ;;
  dolt) shift; run_dolt "$@" ;;
  *) run_bd "$@" ;;
esac
