#!/usr/bin/env bash
# Source before a tool that can spawn Claude. Cache only folder paths and variable
# names, never credentials. A configured pool failure never uses the default login.
# JG_POOL_REQUIRE_FRESH=1 refuses cached picks for callers requiring current capacity.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

jg_pool_claude_env() {
  local home=${JG_HOME:?set JG_HOME} command=byokit-accounts state='' line out='' reason='' cache folder var age
  local -a shed=()
  cache=$home/state/claude-tool-pick.json
  [ -f "$home/config/account-pool" ] || { echo 'pool: config/account-pool is missing' >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in command=*) command=${line#command=} ;; state=*) state=${line#state=} ;; esac
  done <"$home/config/account-pool"
  if ! out=$(timeout 120 "$command" pick claude --json --state "$state" 2>&1); then reason=$out; out=''; fi
  folder=$(jq -r '.set.CLAUDE_CONFIG_DIR // ""' <<<"$out" 2>/dev/null) || folder=''
  if [ ! -d "$folder" ] || ! jq -e '.ok == true and (.set.CLAUDE_CONFIG_DIR | type == "string" and startswith("/")) and
    ((.unset // []) | type == "array" and all(.[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")))' <<<"$out" >/dev/null 2>&1; then
    reason=${reason:-invalid pool answer}
    if [ "${JG_POOL_REQUIRE_FRESH:-0}" = 1 ]; then
      echo "pool: fresh pick failed ($reason); cached accounts will not be used" >&2
      return 1
    fi
    out=$(cat "$cache" 2>/dev/null) || out=''
    age=$(jq -r 'now - .saved_at | floor' <<<"$out" 2>/dev/null) || age=unknown
    echo "pool: pick failed ($reason); last good pick age ${age}s" >&2
  else
    out=$(jq '{ok:true,id,set:{CLAUDE_CONFIG_DIR:.set.CLAUDE_CONFIG_DIR},unset:(.unset // []),saved_at:now}' <<<"$out") || return 1
    [ -d "$folder" ] || return 1
    mkdir -p "$home/state" || return 1
    local tmp
    tmp=$(mktemp "$cache.XXXXXX") || return 1
    if ! printf '%s\n' "$out" >"$tmp" || ! mv "$tmp" "$cache"; then rm -f "$tmp"; return 1; fi
  fi
  folder=$(jq -er '.set.CLAUDE_CONFIG_DIR | select(type == "string" and startswith("/"))' <<<"$out" 2>/dev/null) || {
    echo 'pool: no usable pick or last good pick; Claude was not started' >&2; return 1;
  }
  [ -d "$folder" ] || { echo "pool: selected folder is missing: $folder" >&2; return 1; }
  mapfile -t shed < <(jq -r '.unset[]?' <<<"$out")
  for var in "${shed[@]}"; do
    [[ $var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    unset "$var"
  done
  export CLAUDE_CONFIG_DIR=$folder
  echo "pool: Claude folder $folder" >&2
}
