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
# `init` creates an embedded, stealth store; no bd init flag reaches it. It adds the on_hold status
# and the hold rule: a blocked or on_hold row must name a non-blank metadata.hold_reason. bd needs no
# reason and its hooks cannot refuse, so the rule is a Dolt CHECK that every writer meets. Run again
# on a store missing the rule, `init` adds it; on a store with the rule, it refuses.
# `check` proves the pins and the store, then reads the rule with dolt: a rule gone or changed exits
# 2 naming it, and a read that fails reports that failure, never a missing rule. It then reads
# telemetry back from dolt and exits 2 on a flag not off or on a trace either tool leaves in this
# store's forced home once its metrics run. Its last line sums the store up for the start checks.
# `dolt version` and `dolt sql -q` run the pinned dolt in the store's database folder, and a query
# naming a dolt_push, pull, fetch, clone, remote or backup procedure is refused. `dolt <anything else>`
# is the bd dolt subcommand.
# Every other verb is a bd call from the store's parent, so a relative path means that folder.
# bd stays whole: every verb, flag and config key reaches it unless bd_refusals names the rule the
# call breaks. That list is the one place a call is refused for what it does, each entry with its
# reason, and it was surveyed from the pinned bd's own help; a new pin needs the same survey.
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
#   - a call in bd_refusals: it reaches a server, a remote or a network, turns metrics on, writes
#     into a git tree or its hooks, or exposes a secret. The message starts `refused (<rule>):`.
#   - a bd or dolt whose sha256 is not its toolchain.versions row for this platform, checked
#     before its first run, even for a version. JG_BEADS_BD and JG_BEADS_DOLT name the binary;
#     otherwise each comes from PATH.
#
# Every call forces BD_DISABLE_METRICS=1, DO_NOT_TRACK=1 and BD_NON_INTERACTIVE=1, since bd metrics
# are on by default, and drops every other BEADS_*, BD_*, DOLT_* and GIT_* variable but BEADS_ACTOR,
# and every token, secret, password, API key and PAT variable, since bd prints part of one it finds.
# HOME, XDG_* and TMPDIR point at `<parent>/.jg-beads-env`, because both tools write `$HOME/.dolt`,
# and dolt's metrics and version check are off there; without that even `dolt version` calls out.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pin-lib.sh disable=SC1091
. "$SCRIPT_DIR/jg-pin-lib.sh"

# The hold rule. bd keeps ephemeral rows in wisps, so that table carries it too, under its own name.
HOLD_RULES='issues hold_needs_reason
wisps wisp_hold_needs_reason'
HOLD_CHECK="status NOT IN ('blocked','on_hold') OR CHAR_LENGTH(TRIM(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(metadata,'\$.hold_reason')),''))) > 0"
# The same rule as the pinned dolt stores it, so a weaker rule under the right name reads as changed.
HOLD_STORED="((NOT((\`status\` IN ('blocked', 'on_hold')))) OR (char_length(trim(both ' ' from coalesce(json_unquote(json_extract(\`metadata\`, '\$.hold_reason')),''))) > 0))"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'jg-beads: %s\n' "$*" >&2; exit 2; }

# Prints the nearest folder at or above <real folder> with a .git in it, or nothing outside any tree.
git_tree_of() {  # <real folder>
  local up=$1
  while :; do
    [ ! -e "$up/.git" ] || { printf '%s\n' "${up:-/}"; return; }
    [ -n "$up" ] || return 0
    up=${up%/*}
  done
}

# Sets STORE_PARENT to the real parent of BEADS_DIR, or refuses before anything is written.
store_path_check() {
  local dir=${BEADS_DIR-} parent tree real_home
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
  tree=$(git_tree_of "$STORE_PARENT")
  [ -z "$tree" ] || die "BEADS_DIR is inside the git tree at $tree; keep the store outside any tree"
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
      BEADS_*|BD_*|DOLT_*|GIT_*|*TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|*_PAT) unset "$name" ;;
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

# Dolt runs from the store's database folder.
db_enter() {
  local db
  db=$(sed -n 's/.*"dolt_database": *"\([^"]*\)".*/\1/p' "$BEADS_DIR/metadata.json")
  [ -n "$db" ] && [ -d "$BEADS_DIR/embeddeddolt/$db" ] || die "no database folder for ${db:-this store} in $BEADS_DIR/embeddeddolt"
  cd -- "$BEADS_DIR/embeddeddolt/$db" || die "cannot enter the database folder of $BEADS_DIR"
}

# Prints "<table> <rule>" for each rule gone or changed. Runs in the database folder.
hold_rule_gaps() {  # <dolt>
  local stored table rule
  stored=$("$1" sql -r csv -q "SELECT constraint_name, check_clause FROM information_schema.check_constraints WHERE constraint_name LIKE '%hold_needs_reason'") \
    || die "cannot read the hold rule from $BEADS_DIR"
  while read -r table rule; do
    grep -Fqx "$rule,\"$HOLD_STORED\"" <<< "$stored" || printf '%s %s\n' "$table" "$rule"
  done <<< "$HOLD_RULES"
}

run_init() {  # --prefix <prefix>
  local bd dolt gaps table rule
  [ "$#" -eq 2 ] && [ "$1" = --prefix ] || die "usage: jg-beads.sh init --prefix <prefix>"
  case "$2" in ''|-*|*[!A-Za-z0-9_-]*) die "a prefix is letters, digits, - and _ only: $2" ;; esac
  pin_check bd
  bd=$PINNED_TOOL
  pin_check dolt
  dolt=$PINNED_TOOL
  mkdir -p -- "$BEADS_DIR" || die "cannot create $BEADS_DIR"
  cd -- "$STORE_PARENT" || die "cannot enter $STORE_PARENT"
  [ -e "$BEADS_DIR/metadata.json" ] || "$bd" init --quiet --stealth --prefix "$2" || exit $?
  store_mode_check
  db_enter
  gaps=$(hold_rule_gaps "$dolt") || exit $?
  [ -n "$gaps" ] || die "$BEADS_DIR is already a store; init never runs twice"
  # The status must exist first, or a refused on_hold would be bd's status check and not the rule.
  "$bd" config set status.custom on_hold:frozen > /dev/null || exit $?
  while read -r table rule; do
    "$dolt" sql -q "ALTER TABLE $table ADD CONSTRAINT $rule CHECK ($HOLD_CHECK)" || exit $?
  done <<< "$gaps"
  # wisps is not versioned, so a repair of that rule alone leaves nothing to commit.
  "$dolt" add -A && "$dolt" commit --allow-empty --author 'jg-beads <jg-beads@local>' -m 'Add the hold rule' > /dev/null || exit $?
}

# dolt answers from the forced config, and bd has no such answer, so its proof is what metrics leave.
# dolt keeps a lock in eventsData even with metrics off, so only another file there is a trace.
telemetry_check() {  # <dolt>
  local flag trace
  for flag in metrics.disabled versioncheck.disabled; do
    [ "$("$1" config --global --get "$flag" 2>/dev/null)" = true ] || die "telemetry is not off: dolt does not read $flag as true"
  done
  trace=$(find "$HOME" \( -name machine-id -o -name version_check.txt -o -path '*/eventsData/*' ! -name dolt.lock \) -print -quit)
  [ -z "$trace" ] || die "telemetry ran from this store: $trace"
  printf 'telemetry: off\n'
}

run_check() {
  local tool gaps
  for tool in bd dolt; do
    pin_check "$tool"
    printf '%s: %s (pinned %s)\n' "$tool" "$PINNED_TOOL" "$(jg_pin_version "$tool")"
  done
  store_mode_check
  printf 'store: %s (embedded, stealth)\n' "$BEADS_DIR"
  db_enter
  gaps=$(hold_rule_gaps "$PINNED_TOOL") || exit $?
  [ -z "$gaps" ] || die "hold rule missing or changed in $BEADS_DIR: $(cut -d' ' -f2 <<< "$gaps" | tr '\n' ' ')"
  printf 'rule: hold_needs_reason (issues, wisps)\n'
  telemetry_check "$PINNED_TOOL"
  printf 'healthy: bd %s, dolt %s, hold rule present, telemetry off\n' "$(jg_pin_version bd)" "$(jg_pin_version dolt)"
}

query_check() {  # <query>
  ! printf '%s' "$1" | grep -Eiq 'dolt_(push|pull|fetch|clone|remote|backup)' \
    || die "refused (remote): this query reaches a remote, which the store never does"
}

run_dolt() {  # version | sql -q <query> | <bd dolt subcommand> [args...]
  if [ "$#" -eq 3 ] && [ "$1" = sql ] && [ "$2" = -q ]; then
    query_check "$3"
  elif [ "$*" != version ]; then
    run_bd dolt "$@"
  fi
  pin_check dolt
  store_mode_check
  db_enter
  exec "$PINNED_TOOL" "$@"
}

# Refuses a path in a git tree, relative to the store's parent. A path not there yet is judged by the
# nearest folder that is, so a `..` past a missing folder cannot be judged and is refused too.
tree_path_check() {  # <path>
  local up=$1 tree
  case "$up" in /*) ;; *) up=$STORE_PARENT/$up ;; esac
  [ -d "$up" ] || [ ! -L "$up" ] || die "refused (git tree): $1 is a symlink, so where it writes cannot be judged"
  until [ -d "$up" ]; do
    case "$up" in */..|*/.) die "refused (git tree): $1 climbs out of a folder that does not exist" ;; esac
    up=${up%/*} up=${up:-/}
  done
  up=$(cd -P -- "$up" && pwd -P) || die "cannot read $1"
  tree=$(git_tree_of "$up")
  [ -z "$tree" ] || die "refused (git tree): $1 is inside the git tree at $tree"
}

# Prints each value CALL gives a flag, in every spelling pflag takes: --n v, --n=v, -n v, -nv, -qn v.
flag_values() {  # <long name> [short letter]
  local long=$1 short=${2:-_} arg value want=
  for arg in "${CALL[@]}"; do
    if [ -n "$want" ]; then printf '%s\n' "$arg"; want=; continue; fi
    case "$arg" in
      "--$long") want=1 ;;
      "--$long"=*) printf '%s\n' "${arg#*=}" ;;
      --*) ;;
      -*"$short"*)
        value=${arg#*"$short"} value=${value#=}
        if [ -n "$value" ]; then printf '%s\n' "$value"; else want=1; fi ;;
    esac
  done
}

flag_path_check() { local path; while IFS= read -r path; do tree_path_check "$path"; done < <(flag_values "$@"); }  # <long> [short]

secret_key_check() {  # <config key>
  ! printf '%s' "$1" | grep -Eiq 'token|secret|password|api_?key|\.pat$' || die "refused (secret): $1 holds a secret, and the store keeps none"
}

config_key_check() {  # <config key> <value>
  secret_key_check "$1"
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    sync.*|federation.*|backup.url|backup.git-*|dolt.auto-push*)
      die "refused (remote): $1 points the store at a remote" ;;
    dolt.host|dolt.port|dolt.user|dolt.mode|dolt.socket|dolt.auto-start|*server*)
      die "refused (server): $1 points the store at a server" ;;
    metrics.*|telemetry.*|otel.*) die "refused (metrics): $1 can turn metrics on" ;;
    no-git-ops) die "refused (git tree): $1 is what keeps bd's hands off git" ;;
    export.path) case "$2" in /*) tree_path_check "$2" ;; *) tree_path_check "$BEADS_DIR/$2" ;; esac ;;
    routing.*|repos.*) tree_path_check "$2" ;;
  esac
}

# The one refusal list. A call is matched on its non-flag words, so a flag before the verb changes
# nothing. The rules: a server, a remote or a network, metrics, a git tree or its hooks, a secret.
bd_refusals() {  # <bd args...>
  local arg key skip=''
  local -a words=()
  CALL=("$@")
  for arg in "$@"; do
    if [ -n "$skip" ]; then skip=; continue; fi
    case "$arg" in
      --actor|--dolt-auto-commit) skip=1 ;;
      -*) ;;
      *) words+=("$arg") ;;
    esac
  done
  key="${words[0]:-} ${words[1]:-} ${words[2]:-} "
  case "$key" in
    'init '*) die "refused (server): bd init can name a server, a remote or a git tree; jg-beads.sh init makes the store" ;;
    'serve '*) die "refused (server): bd serve opens a network listener, and only a throwaway tree may run one, never a store" ;;
    'dolt start '*|'dolt stop '*|'dolt killall '*|'dolt test '*|'dolt set '*|'dolt sql-server '*|'dolt clean-databases '*) die "refused (server): this runs or points at a Dolt server" ;;
    'migrate from-'*) die "refused (server): this moves the store to a server mode" ;;
    'sync '*|'bootstrap '*|'dolt push '*|'dolt pull '*|'dolt remote add '*|'dolt remote reset-data '*|'federation add-peer '*|'federation sync '*) die "refused (remote): this reaches a remote or a peer, and the store has none" ;;
    'ado status '*|'github status '*|'gitlab status '*|'jira status '*|'linear status '*) ;;
    'ado '[a-z]*|'github '[a-z]*|'gitlab '[a-z]*|'jira '[a-z]*|'linear '[a-z]*|'notion '[a-z]*) die "refused (network): this talks to the tracker's servers; only a local status is served, and notion's calls out" ;;
    'gate discover '*) die "refused (network): this runs gh against GitHub" ;;
    'gate check '*)
      { [ -n "$(flag_values type t)" ] && ! flag_values type t | grep -qvxE 'timer|bead'; } \
        || die "refused (network): this runs gh against GitHub unless --type is timer or bead" ;;
    'find-duplicates '*|'find-dups '*) ! flag_values method | grep -qx ai || die "refused (network): --method ai sends issues to a model API" ;;
    'admin compact '*) case " $* " in *' --auto '*|*' --auto='*) die "refused (network): --auto sends issues to a model API" ;; esac ;;
    'metrics on '*) die "refused (metrics): metrics stay off on every call" ;;
    'hooks install '*|'hooks uninstall '*|'hooks run '*|'worktree create '*|'worktree remove '*|'migrate sync '*|'config apply '*) die "refused (git tree): this changes a git tree or its hooks; config apply also adds a remote and starts a server" ;;
    'migrate hooks '*) case " $* " in *' --apply '*|*' --apply='*) die "refused (git tree): --apply rewrites git hooks" ;; esac ;;
    'create '*) flag_path_check repo ;;
    'migrate issues '*) flag_path_check to ;;
    'rules compact '*) flag_path_check path ;;
    'export '*|'mol distill '*|'migrate legacy-sqlite '*) flag_path_check output o ;;
    'setup '*) flag_path_check output o; for arg in "${words[@]:1}"; do tree_path_check "$arg"; done ;;
    'repo add '*|'formula convert '*) for arg in "${words[@]:2}"; do tree_path_check "$arg"; done ;;
    'backup init '*|'backup add '*|'backup restore '*)
      for arg in "${words[@]:2}"; do
        [[ "$arg" != *:* ]] || die "refused (remote): $arg is a URL, and a backup stays on this machine"; tree_path_check "$arg"
      done ;;
    'config get '*) secret_key_check "${words[2]:-}" ;;
    'config unset no-git-ops '*) die "refused (git tree): no-git-ops is what keeps bd's hands off git" ;;
    'config set '*) config_key_check "${words[2]:-}" "${words[3]:-}" ;;
    'config set-many '*) for arg in "${words[@]:2}"; do config_key_check "${arg%%=*}" "${arg#*=}"; done ;;
    'sql '*) query_check "$*" ;;
  esac
}

run_bd() {  # <verb> [args...]
  local arg
  for arg in "$@"; do
    case "$arg" in
      --global|--global=*|--db|--db=*|--database|--database=*|--directory|--directory=*|-C*|-[!-]*C*|--mem-profile*|--cpu-profile*)
        die "$arg would move this call off BEADS_DIR" ;;
    esac
  done
  bd_refusals "$@"
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
  check) run_check ;;
  dolt) shift; run_dolt "$@" ;;
  *) run_bd "$@" ;;
esac
