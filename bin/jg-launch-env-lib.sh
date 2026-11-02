#!/usr/bin/env bash
# jg-launch-env-lib.sh - the owner of the provider-credential strip every
# launch applies to the worker's own environment, sourced by bin/jg-spawn.sh
# (ship, Recon, squad_lead, raw command, and relaunch all build here).
#
# docs/configuration.md "Provider credentials stripped from every launch" owns
# the operator contract and the shape list; this file owns their one
# implementation. A matched name is stripped unless config/launch-env-allowlist
# names it, so a credential a later provider invents is stripped with no code
# change here.
#
# Names only: this file reads the launching process's variable NAMES, never a
# value, and the launch text it emits carries names only. Nothing here prints,
# logs, or records a value.
#
# Limit, documented rather than hidden: the strip is computed from the process
# that builds the launch, so a variable that exists only inside the destination
# pane and not in this process survives. Launchers and their panes share
# lineage on every verified backend, so that gap needs a separately configured
# pane environment.

# Shapes a provider credential takes. Case-insensitive, suffix-anchored, and
# deliberately narrow: a name that merely contains KEY (STARSHIP_SESSION_KEY,
# GIT_CONFIG_KEY_0) is not a credential and is never stripped.
JG_LAUNCH_ENV_CREDENTIAL_SHAPES='_api_key _apikey _token _secret _secret_key
_password _passwd _credential _credentials _access_key _access_key_id
_private_key'

# jg_launch_env_is_credential_name <name>: succeed when NAME has a credential
# shape.
jg_launch_env_is_credential_name() {
  local name shape lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for shape in $JG_LAUNCH_ENV_CREDENTIAL_SHAPES; do
    case "$lower" in
    *"$shape") return 0 ;;
    esac
  done
  return 1
}

# jg_launch_env_strip_names <allowlist-names>: print, one per line, the
# credential-shaped names this process exports that the allowlist does not
# name. <allowlist-names> is the newline-separated name list read from
# config/launch-env-allowlist, empty when the home has not opted into that
# file.
jg_launch_env_strip_names() {
  local allowed=$'\n'"$1"$'\n' name
  while IFS= read -r name; do
    case "$allowed" in
    *$'\n'"$name"$'\n'*) continue ;;
    esac
    jg_launch_env_is_credential_name "$name" || continue
    printf '%s\n' "$name"
  done < <(compgen -e)
}

# jg_launch_env_strip_prefix <allowlist-names>: print the `unset ...; ` prefix
# this launch pins in front of everything else, or nothing when there is
# nothing to strip. The prefix runs in the destination pane, so the names it
# carries were present in the launching process and would otherwise be
# inherited by the worker.
jg_launch_env_strip_prefix() {
  local names name prefix='unset'
  names=$(jg_launch_env_strip_names "$1") || return 1
  [ -n "$names" ] || return 0
  while IFS= read -r name; do
    prefix="$prefix $name"
  done <<<"$names"
  printf '%s; ' "$prefix"
}
