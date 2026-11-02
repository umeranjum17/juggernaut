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
# The strip runs inside the destination pane and reads the pane's own
# environment when it runs, never this process's: the pane inherits from the
# herdr server and re-exports from the shell profile after this process has
# built the launch, so a name list computed here misses exactly the credentials
# that reach workers.
#
# Names only: the launch text this file emits carries variable NAMES and
# patterns, never a value, and nothing here prints, logs, or records a value.

# Shapes a provider credential takes. Case-insensitive, suffix-anchored, and
# deliberately narrow: a name that merely contains KEY (STARSHIP_SESSION_KEY,
# GIT_CONFIG_KEY_0) is not a credential and is never stripped.
JG_LAUNCH_ENV_CREDENTIAL_SHAPES='_api_key _apikey _token _secret _secret_key
_password _passwd _credential _credentials _access_key _access_key_id
_private_key'

# jg_launch_env_strip_prefix <allowlist-names>: print the statement this launch
# pins in front of everything else. It walks the pane's exported names and
# unsets every credential-shaped one that the newline-separated allowlist (read
# from config/launch-env-allowlist, empty when the home has not opted in) does
# not name. POSIX sh, so every pane shell runs it unchanged.
jg_launch_env_strip_prefix() {
  local shape lower pattern='' allow='' name i c
  for shape in $JG_LAUNCH_ENV_CREDENTIAL_SHAPES; do
    lower=
    for ((i = 0; i < ${#shape}; i++)); do
      c=${shape:i:1}
      case "$c" in
      [a-z]) c="[$c${c^^}]" ;;
      esac
      lower="$lower$c"
    done
    pattern="$pattern${pattern:+|}*$lower"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    allow="$allow${allow:+|}$name"
  done <<<"$1"
  # shellcheck disable=SC2016  # expanded by the pane shell
  printf 'for jg_n in $(env | sed -n %s); do case $jg_n in %s) unset "$jg_n";; esac; done; unset jg_n; ' \
    "'s/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'" "${allow:+$allow) ;; }$pattern"
}
