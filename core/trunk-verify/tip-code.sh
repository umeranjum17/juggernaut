#!/usr/bin/env bash
# The verify judges with the code of the trunk tip (ticket verify-bootstrap): sourced by bin/jg-trunk.sh, never run.
#
# A home runs its verify from its own installed code, and the installed code moves only to the green pin, which the verify itself
# moves. A repair of the verifier that lands on the trunk above a frozen pin therefore never reached the verify that is meant to
# unfreeze the pin: it kept judging the range with the old milestone code. The verify now takes its code from the tip it judges:
# when the tip carries bin/jg-trunk.sh, the verify extracts the tip's bin, core and policy trees (git archive, no checkout) and runs
# the same `verify` command from them, once. State, data and config stay the home's, so only the code changes; JG_ROOT stays the
# home, so a go-live after the green result still moves this home. Nothing is installed and no home moves.
#   verify_in_tip_code <tip> <verify arguments>   returns 0 when the tip's code ran the verify (VERIFY_TIP_RC holds its result),
#                                                 1 when this code is the one to run it (the tip has no verifier, it is
#                                                 already running, or its code could not be read: a note says which)
# Needs from the caller: PROJ, DATA, JG_ROOT, SCRIPT_DIR.

VERIFY_TIP_RC=0

verify_in_tip_code() {  # <tip> <arguments of verify...>
  local tip=$1 code rc=0
  shift
  [ -z "${JG_VERIFY_CODE_AT:-}" ] || return 1
  git -C "$PROJ" cat-file -e "$tip:bin/jg-trunk.sh" 2>/dev/null || return 1
  mkdir -p "$DATA/trunk"
  code=$(mktemp -d "$DATA/trunk/.verify-code.XXXXXX") || { echo "verify: no room for the tip's code; this code judges" >&2; return 1; }
  if ! git -C "$PROJ" archive "$tip" bin core policy 2>/dev/null | tar -x -C "$code" 2>/dev/null || [ ! -x "$code/bin/jg-trunk.sh" ]; then
    rm -rf -- "$code"; echo "verify: the code of ${tip:0:12} could not be read; this code judges" >&2; return 1
  fi
  echo "verify: judging with the code of the tip ${tip:0:12}, not this home's installed code" >&2
  JG_VERIFY_CODE_AT=$tip JG_ROOT_OVERRIDE="$JG_ROOT" "$code/bin/jg-trunk.sh" verify "$@" || rc=$?
  rm -rf -- "$code"
  VERIFY_TIP_RC=$rc
}
