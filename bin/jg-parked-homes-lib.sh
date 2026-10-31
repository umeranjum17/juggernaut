# shellcheck shell=bash disable=SC2034
# jg-parked-homes-lib.sh - the parked-home reader, owned by core/parked-homes.
#
# The parked-home rule - a parked squad_lead home gets no message, steer,
# answer, nudge or relaunch, and no config push - is decided by the predicates
# core/parked-homes/bin/jg-parked-homes-lib.sh defines; this file only sources
# it beside bin/ so every supervision producer gates through one implementation.

_JG_PARKED_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_JG_PARKED_LIB_DIR/../core/parked-homes/bin/jg-parked-homes-lib.sh"
