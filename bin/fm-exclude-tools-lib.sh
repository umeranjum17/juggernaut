#!/usr/bin/env bash
# alias shim (slice S3, deleted by slice S10). Behaviour: bin/jg-alias-lib.sh.
set -u
_jg_alias_dir=${BASH_SOURCE[0]%/*}
[ "$_jg_alias_dir" != "${BASH_SOURCE[0]}" ] || _jg_alias_dir=.
# shellcheck source=/dev/null
. "$_jg_alias_dir/jg-alias-lib.sh"
jg_alias_shim "${BASH_SOURCE[0]}" "$0" "$@"
