#!/usr/bin/env bash
# jg-account-pool-lib.sh - account-pool feature: config/account-pool parsing, the
# `byokit-accounts pick` call, the launch prefix its answer applies, the relaunch --account gate,
# and jg_account_hook, the one entry point bin/jg-spawn.sh and bin/jg-control.sh call. Sourced
# from $JG_ADDONS_DIR/account-pool/bin/; a home without the feature has only no-op hook lines.
# A pick answers with folder paths only, so no secret reaches a launch line, record or log.

# shellcheck source=/dev/null
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

type jg_run_timed >/dev/null 2>&1 || . "${SCRIPT_DIR:?sourced from a bin/ script}/jg-timeout-lib.sh"

JG_ACCOUNT_POOL_PICK_SECONDS=${JG_ACCOUNT_POOL_PICK_SECONDS:-120}
JG_ACCOUNT_POOL_REST_SECONDS=${JG_ACCOUNT_POOL_REST_SECONDS:-60}

# jg_account_pool_tool <harness>: the pool tool, or non-zero for an unmapped one.
jg_account_pool_tool() {
  case "$1" in
  claude) printf '%s\n' claude ;;
  codex) printf '%s\n' codex ;;
  pi | pi-signed) printf '%s\n' pi ;;
  cursor) printf '%s\n' cursor ;;
  opencode) printf '%s\n' opencode ;;
  *) return 1 ;;
  esac
}

# jg_account_pool_store_var <tool>: the environment variable a launch assigns
# the picked account folder to, or non-zero for an unmapped tool.
jg_account_pool_store_var() {
  case "$1" in
  claude) printf '%s\n' CLAUDE_CONFIG_DIR ;;
  codex) printf '%s\n' CODEX_HOME ;;
  pi) printf '%s\n' PI_CODING_AGENT_DIR ;;
  cursor) printf '%s\n' XDG_CONFIG_HOME ;;
  opencode) printf '%s\n' OPENCODE_CONFIG_DIR ;;
  *) return 1 ;;
  esac
}

# jg_account_pool_extra_vars <tool>: the other path variables the pool may set beside the store
# variable (Cursor also moves its config, gh and git files; OpenCode its data, state, cache and key
# file). Names only; values must be absolute paths. Any other variable makes the answer unusable.
jg_account_pool_extra_vars() {
  case "$1" in
  cursor) printf '%s\n' CURSOR_CONFIG_DIR GH_CONFIG_DIR GIT_CONFIG_GLOBAL ;;
  opencode) printf '%s\n' XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME OPENCODE_CONFIG ;;
  esac
}

# jg_account_pool_config <config-dir>: "command<TAB>state" for a usable
# config/account-pool; nothing when the file is absent; one error otherwise.
jg_account_pool_config() {
  local config=$1 file command state line
  file=$config/account-pool
  command=byokit-accounts
  state=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/account-pool must be a readable regular file naming the pool folder: $file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
    command=*) command=${line#command=} ;;
    state=*) state=${line#state=} ;;
    esac
  done <"$file"
  case "$state" in
  /*) ;;
  *)
    echo "error: config/account-pool must name the pool folder with one absolute state=<pool folder> line (blank lines and # comments are ignored): $file" >&2
    return 1
    ;;
  esac
  case "$command" in
  /*) ;;
  */*)
    echo "error: config/account-pool's command= must be an absolute path to byokit-accounts: $file" >&2
    return 1
    ;;
  esac
  printf '%s\t%s\n' "$command" "$state"
}

# jg_account_pool_detail <pick-json>: one fragment naming each account row and
# why it cannot take a worker. Reads names and states only.
jg_account_pool_detail() {
  jq -r '[ .rows[]? | select(type == "object") | "\(.name // .id // "an account") " +
    (if .state == "resting" then "resting" elif .state == "signed_out" then "signed out"
     elif .state == "signing" then "still signing in" elif .state == "not_included" then "not set up"
     else "not ready" end) ] | join(", ")' <<<"${1:-}" 2>/dev/null
}

# jg_account_pool_want_valid <choice>: 0 for `next` or one account id (letters, digits, dot,
# dash, underscore; at most 128); a path, flag or empty value is refused here, never passed on.
jg_account_pool_want_valid() {
  case "${1:-}" in
    next) return 0 ;;
    -*) return 1 ;;
    *[!A-Za-z0-9._-]* | '') return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# jg_account_pool_select <harness> <config-dir> [<want>]: "id<TAB>var<TAB>folder<TAB>unset names<TAB>VAR=path ..."
# for a mapped harness with a usable pool; nothing when the pool is off; an error and non-zero on
# any refusal, never an ambient login fallback. <want> is a relaunch's --account choice: an id adds
# --prefer and the answer must be exactly that account; `next` picks plainly.
jg_account_pool_select() {
  local harness=$1 config=$2 want=${3:-} extras entry ename evalue allowed tool store_var cfg command state out errf rc id var folder shed reason detail shed_bad=0
  local -a prefer_arg=()
  tool=$(jg_account_pool_tool "$harness") || return 0
  cfg=$(jg_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || return 0
  store_var=$(jg_account_pool_store_var "$tool") || return 1
  command=${cfg%%$'\t'*}
  state=${cfg#*$'\t'}
  errf=$(mktemp "${TMPDIR:-/tmp}/jg-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  case "$want" in
    '' | next) ;;
    *) prefer_arg=(--prefer "$want") ;;
  esac
  out=$(jg_run_timed "$JG_ACCOUNT_POOL_PICK_SECONDS" "$command" pick "$tool" --json "${prefer_arg[@]}" --state "$state" 2>"$errf")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # A failed pick answers with the contract JSON on stdout and one sentence on stderr.
    reason=
    if printf '%s' "$out" | jq -e '.ok == false' >/dev/null 2>&1; then
      reason=$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)
      detail=$(jg_account_pool_detail "$out")
    fi
    [ -n "$reason" ] || reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot start a $tool worker: $reason${detail:+ ($detail)}; add or sign in to an account with '$command add $tool', then retry" >&2
    return 1
  fi
  rm -f "$errf"
  id=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  var=$(printf '%s' "$out" | jq -r --arg v "$store_var" 'if (.set | type) == "object" and (.set[$v] | type) == "string" then $v else empty end' 2>/dev/null)
  folder=$(printf '%s' "$out" | jq -r --arg v "$var" 'if $v == "" then empty else (.set[$v] // empty) end' 2>/dev/null)
  extras=
  allowed=" $(jg_account_pool_extra_vars "$tool" | tr '\n' ' ')"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    ename=${entry%%=*} evalue=${entry#*=}
    case "$allowed" in *" $ename "*) ;; *) shed_bad=1 ;; esac
    case "$evalue" in /*) ;; *) shed_bad=1 ;; esac
    case "$evalue" in *[[:space:]]*) shed_bad=1 ;; esac
    extras="${extras:+$extras }$entry"
  done < <(printf '%s' "$out" | jq -r --arg v "$store_var" '(.set // {}) | if type == "object" then to_entries[] | select(.key != $v) | "\(.key)=\(.value)" else empty end' 2>/dev/null)
  if ! shed=$(printf '%s' "$out" | jq -r '
      .unset // []
      | if type == "array" and all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*\\z"))
        then .[] else error("the unset list is not an array of variable names") end' 2>/dev/null); then
    shed=
    shed_bad=1
  fi
  shed=$(printf '%s' "$shed" | tr '\n' ' ')
  shed=${shed% }
  case "$id" in '' | *[!A-Za-z0-9._-]*) id= ;; esac
  case "$var" in "$store_var") ;; *) var= ;; esac
  case "$folder" in /*) ;; *) folder= ;; esac
  if [ -n "$folder" ] && { [ ! -d "$folder" ] || [ ! -r "$folder" ] || [ ! -x "$folder" ]; }; then
    folder=
  fi
  if [ -z "$id" ] || [ -z "$var" ] || [ -z "$folder" ] || [ "$shed_bad" = 1 ]; then
    echo "error: config/account-pool's '$command' answered with an unusable $tool account selection; expected an account id and one absolute account folder, with no secret" >&2
    return 1
  fi
  case "$want" in
    '' | next) ;;
    *)
      if [ "$id" != "$want" ]; then
        echo "error: config/account-pool's '$command' answered with account '${id:-none}' rather than the requested account '$want' for a $tool worker; the pool only prefers an account that is ready, so '$want' may be resting, signed out, or another tool's account" >&2
        return 1
      fi
      ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$var" "$folder" "$shed" "$extras"
}

# jg_account_pool_recorded_tool <command> <state> <id>: the pool tool of the account a running
# worker launched on, from the pool's own roster; one error and non-zero when it cannot answer.
jg_account_pool_recorded_tool() {
  local command=$1 state=$2 id=$3 out errf rc tool reason
  errf=$(mktemp "${TMPDIR:-/tmp}/jg-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  out=$(jg_run_timed "$JG_ACCOUNT_POOL_PICK_SECONDS" "$command" status "$id" --json --state "$state" 2>"$errf")
  rc=$?
  tool=$(printf '%s' "$out" | jq -r '.tool // empty' 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$tool" ]; then
    reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot read the running worker's account $id: $reason" >&2
    return 1
  fi
  rm -f "$errf"
  printf '%s\n' "$tool"
}

# jg_account_pool_rest <command> <state> <id>: rest one pool account (its own default rest;
# '<command> unrest <id>' returns it) so the next pick moves off it; one error and non-zero on refusal.
jg_account_pool_rest() {
  local command=$1 state=$2 id=$3 errf rc reason
  errf=$(mktemp "${TMPDIR:-/tmp}/jg-account-pool.XXXXXX") || {
    echo "error: config/account-pool cannot create a temporary file to run '$command'" >&2
    return 1
  }
  jg_run_timed "$JG_ACCOUNT_POOL_REST_SECONDS" "$command" rest "$id" --json --state "$state" >/dev/null 2>"$errf"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    reason=$(sed -n '1{s/^error: //;p;}' "$errf" 2>/dev/null)
    [ -n "$reason" ] || reason='the pool command could not run'
    rm -f "$errf"
    echo "error: config/account-pool cannot rest account $id: $reason; it stays on the pick's list until it rests" >&2
    return 1
  fi
  rm -f "$errf"
}

# The tools a relaunch may move between automatically, fixed in code from the plan's terms review
# (plan v2 section 3): OpenCode Go is excluded, as is any opencode-go model. Deliberately not config.
JG_ACCOUNT_POOL_AUTO_TOOLS="claude codex pi cursor"

# jg_account_pool_tuple_field <tuple> <index>: field <index> (1-based) of a tab-separated tuple.
jg_account_pool_tuple_field() { cut -f"$2" <<<"$1"; }

# --- jg_account_hook: the entry point of jg-spawn.sh's and jg-control.sh's hook lines ---
# jg_account_hook <event> [args]: an unknown event is a no-op, so a hook line
# from a newer fork never fails against an older feature checkout.

# argv [args]: prints shell code for the caller to eval that sets POOL_ACCOUNT_WANT
# and POOL_ACCOUNT_WANT_SET from --account <v> / --account=<v> and `set --` the
# remaining arguments in order, so the caller's own parser never sees --account.
jg_account_hook_argv() {
  local want='' set=0 a
  local -a rest=()
  while [ "$#" -gt 0 ]; do
    a=$1
    shift
    case "$a" in
      --account)
        [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ] || { echo 'echo "error: --account requires a value" >&2; exit 1'; return 0; }
        want=$1 set=1
        shift
        ;;
      --account=*) want=${a#--account=} set=1 ;;
      *) rest+=("$a") ;;
    esac
  done
  printf 'POOL_ACCOUNT_WANT=%q POOL_ACCOUNT_WANT_SET=%s; set --' "$want" "$set"
  [ "${#rest[@]}" -eq 0 ] || printf ' %q' "${rest[@]}"
  echo
}

# spawn-validate: jg-spawn's --account checks; reads RELAUNCH and JG_CONTROL_RELAUNCH_TX.
jg_account_hook_spawn_validate() {
  local want=${POOL_ACCOUNT_WANT:-}
  [ "${POOL_ACCOUNT_WANT_SET:-0}" = 1 ] || return 0
  [ -n "$want" ] || { echo "error: --account requires a non-empty value" >&2; return 1; }
  jg_account_pool_want_valid "$want" || { echo "error: --account takes 'next' or one pool account id, not '$want'" >&2; return 1; }
  [ "${RELAUNCH:-0}" = 1 ] || { echo "error: --account applies to a relaunch only; a fresh launch picks its pool account on its own" >&2; return 1; }
  [ "$want" != next ] || [ -n "${JG_CONTROL_RELAUNCH_TX:-}" ] || {
    echo "error: --account next rests the recorded account only in jg-control's pre-stop gate; a direct relaunch would ignore it and may re-pick the same account - use 'bin/jg-control.sh <task-id> relaunch --account next'" >&2
    return 1
  }
}

# control-validate <verb>: jg-control's --account checks, after its own parse.
jg_account_hook_control_validate() {
  [ "${POOL_ACCOUNT_WANT_SET:-0}" = 1 ] || return 0
  [ "$1" = relaunch ] || { echo "error: --account applies to 'relaunch' only" >&2; return 1; }
  [ -n "${POOL_ACCOUNT_WANT:-}" ] || { echo "error: --account requires a non-empty value" >&2; return 1; }
}

# relaunch-pre <harness> <config-dir> <to-model> <recorded-id> <from-model> <task-id>: the
# relaunch preflight's read-only pool half, after Kun's pin select has passed. A pin wins and
# refuses --account; --account takes every refusal that touches nothing and arms relaunch-commit;
# with neither, a canary pick proves the launch owner's pick can answer.
jg_account_hook_relaunch_pre() {
  local harness=$1 config=$2 to_model=$3 recorded=$4 from_model=$5 task=$6 want=${POOL_ACCOUNT_WANT:-} pin cfg tool
  POOL_RELAUNCH_MOVE=0
  pin=$(jg_worker_account_resolve "$harness" "$config") || return 1
  if [ -n "$pin" ]; then
    [ "${POOL_ACCOUNT_WANT_SET:-0}" = 0 ] || {
      echo "error: this home pins $harness workers to one account, and the pin wins over --account '$want'; change or remove the pin file, or relaunch without --account" >&2
      return 1
    }
    return 0
  fi
  [ "${POOL_ACCOUNT_WANT_SET:-0}" = 1 ] || { jg_account_pool_select "$harness" "$config" >/dev/null; return; }
  jg_account_pool_want_valid "$want" || { echo "error: --account takes 'next' or one account id, not '$want'" >&2; return 1; }
  jg_account_pool_tool "$harness" >/dev/null || {
    echo "error: --account applies to the harnesses whose pool tool exists (claude, codex, pi, pi-signed, cursor, opencode), not '$harness'" >&2
    return 1
  }
  cfg=$(jg_account_pool_config "$config") || return 1
  [ -n "$cfg" ] || { echo "error: --account needs this home's account pool: config/account-pool naming state=<pool folder>" >&2; return 1; }
  if [ "$want" = next ]; then
    [ -n "$recorded" ] || {
      echo "error: '--account next' moves the account the running worker launched on, and task $task records none; move it with '--account <id>' instead" >&2
      return 1
    }
    tool=$(jg_account_pool_recorded_tool "${cfg%%$'\t'*}" "${cfg#*$'\t'}" "$recorded") || return 1
    case " $JG_ACCOUNT_POOL_AUTO_TOOLS " in
      *" $tool "*) ;;
      *)
        echo "error: '--account next' cannot move an account of tool '$tool' automatically; move this worker by hand with 'bin/jg-control.sh $task relaunch --account <id>'" >&2
        return 1
        ;;
    esac
    case "$from_model$to_model" in
      *opencode-go*)
        echo "error: '--account next' cannot move a worker on the opencode-go provider automatically; move this worker by hand with 'bin/jg-control.sh $task relaunch --account <id>'" >&2
        return 1
        ;;
    esac
  fi
  POOL_RELAUNCH_MOVE=1
}

# relaunch-commit <harness> <config-dir> <recorded-id>: the relaunch's last pre-stop step, only
# when relaunch-pre armed a move, so the pool changes only once the verb can no longer refuse:
# `next` rests the recorded account, then a pick proves the launch can answer (an id: exactly it).
jg_account_hook_relaunch_commit() {
  local cfg
  [ "${POOL_RELAUNCH_MOVE:-0}" = 1 ] || return 0
  cfg=$(jg_account_pool_config "$2") || return 1
  [ -n "$cfg" ] || { echo "error: --account needs this home's account pool: config/account-pool naming state=<pool folder>" >&2; return 1; }
  [ "$POOL_ACCOUNT_WANT" != next ] || jg_account_pool_rest "${cfg%%$'\t'*}" "${cfg#*$'\t'}" "$3" || return 1
  jg_account_pool_select "$1" "$2" "$POOL_ACCOUNT_WANT" >/dev/null
}

# spawn-args: appends --account <v> to the caller's spawn_args array for jg-spawn --relaunch.
jg_account_hook_spawn_args() {
  [ "${POOL_ACCOUNT_WANT_SET:-0}" = 0 ] || spawn_args+=(--account "$POOL_ACCOUNT_WANT")
}

# raw-launch <config-dir>: a raw launch command cannot carry the picked account.
jg_account_hook_raw_launch() {
  [ -e "$1/account-pool" ] || [ -L "$1/account-pool" ] || return 0
  echo "error: config/account-pool does not support raw launch commands; use a named harness such as --harness claude, --harness codex, or --harness pi so the selected account cannot be overridden" >&2
  return 1
}

# spawn-pick <harness> <config-dir> <pin-tuple> [<want>]: sets POOL_ACCOUNT (the pick's
# tuple) and POOL_ACCOUNT_ID/VAR/FOLDER/UNSET, and exports a picked Claude root
# so trust registration writes the store the worker will read. A pin wins, and
# refuses a relaunch's --account <want>; a want with no pool refuses too.
jg_account_hook_spawn_pick() {
  local harness=$1 config=$2 pin=${3:-} want=${4:-}
  POOL_ACCOUNT='' POOL_ACCOUNT_ID='' POOL_ACCOUNT_VAR='' POOL_ACCOUNT_FOLDER='' POOL_ACCOUNT_UNSET='' POOL_ACCOUNT_EXTRA=''
  if [ -n "$pin" ]; then
    [ -z "$want" ] || {
      echo "error: this home pins $harness workers to one account, and the pin wins over --account '$want'; change or remove the pin file, or relaunch without it" >&2
      return 1
    }
    return 0
  fi
  POOL_ACCOUNT=$(jg_account_pool_select "$harness" "$config" "$want") || return 1
  [ -n "$POOL_ACCOUNT" ] || [ -z "$want" ] || {
    echo "error: this home has no account pool for $harness workers (no config/account-pool, or $harness has no pool tool), so --account '$want' cannot be honored; add config/account-pool or relaunch without it" >&2
    return 1
  }
  [ -n "$POOL_ACCOUNT" ] || return 0
  POOL_ACCOUNT_ID=$(jg_account_pool_tuple_field "$POOL_ACCOUNT" 1)
  POOL_ACCOUNT_VAR=$(jg_account_pool_tuple_field "$POOL_ACCOUNT" 2)
  POOL_ACCOUNT_FOLDER=$(jg_account_pool_tuple_field "$POOL_ACCOUNT" 3)
  POOL_ACCOUNT_UNSET=$(jg_account_pool_tuple_field "$POOL_ACCOUNT" 4)
  POOL_ACCOUNT_EXTRA=$(jg_account_pool_tuple_field "$POOL_ACCOUNT" 5)
  [ "$POOL_ACCOUNT_VAR" != CLAUDE_CONFIG_DIR ] || export CLAUDE_CONFIG_DIR=$POOL_ACCOUNT_FOLDER
}

# record-line: the task record's account= line, only for a pick.
jg_account_hook_record_line() {
  [ -z "${POOL_ACCOUNT:-}" ] || echo "account=$POOL_ACCOUNT_ID"
}

# spawn-line: appends account=<id> to SPAWN_ACCOUNT (the spawned line), only for a pick.
jg_account_hook_spawn_line() {
  [ -z "${POOL_ACCOUNT:-}" ] || SPAWN_ACCOUNT="${SPAWN_ACCOUNT:-} account=$POOL_ACCOUNT_ID"
}

# launch-prefix <harness> <pin-tuple>: runs after Kun's launch-prefix chain. A
# pick (no pin) replaces the ambient CLAUDE_CONFIG_DIR forward that chain adds
# with `env -u <name> ... <VAR>=<folder>`; the picked folder is the only secret-free input.
jg_account_hook_launch_prefix() {
  local name prefix=env own entry
  [ -n "${POOL_ACCOUNT:-}" ] && [ -z "${2:-}" ] || return 0
  if [ "$1" = claude ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    own="CLAUDE_CONFIG_DIR=$(shell_quote "$CLAUDE_CONFIG_DIR") "
    LAUNCH=${LAUNCH#"$own"}
  fi
  for name in $POOL_ACCOUNT_UNSET; do prefix="$prefix -u $name"; done
  for entry in ${POOL_ACCOUNT_EXTRA:-}; do prefix="$prefix ${entry%%=*}=$(shell_quote "${entry#*=}")"; done
  LAUNCH="$prefix $POOL_ACCOUNT_VAR=$(shell_quote "$POOL_ACCOUNT_FOLDER") $LAUNCH"
}

jg_account_hook() {
  local event=${1:-}
  shift || true
  case "$event" in
    argv | spawn-validate | control-validate | relaunch-pre | relaunch-commit | spawn-args | \
      raw-launch | spawn-pick | record-line | spawn-line | launch-prefix)
      "jg_account_hook_${event//-/_}" "$@" ;;
    *) return 0 ;;
  esac
}
