#!/usr/bin/env bash
# Bind the named key route to the existing special-key mode of jg-send.sh.
set -u
if [ "$#" -ne 2 ]; then
  printf 'usage: %s <target> <key>\n' "${0##*/}" >&2
  exit 2
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
exec "$ROOT/bin/jg-send.sh" "$1" --key "$2"
