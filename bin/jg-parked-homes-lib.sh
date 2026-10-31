# shellcheck shell=bash disable=SC2034
# jg-parked-homes-lib.sh - the parked-home reader, owned by core/parked-homes.
#
# The parked-home rule - a parked squad_lead home gets no message, steer,
# answer, nudge or relaunch, and no config push - is decided by the predicates
# core/parked-homes/bin/jg-parked-homes-lib.sh defines; this file only sources
# it beside bin/ so every supervision producer gates through one implementation.

_JG_PARKED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JG_PARKED_LIB=$_JG_PARKED_LIB_DIR/../core/parked-homes/bin/jg-parked-homes-lib.sh
# A fixture checkout copied from bin/ alone has no core/ tree: with no reader there, nothing is
# parked, so every gate stays a no-op instead of failing the command that sourced it.
if [ -r "$_JG_PARKED_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_JG_PARKED_LIB"
else
  jg_parked_refuse_meta() { return 0; }
  jg_parked_skip_meta() { return 1; }
fi
