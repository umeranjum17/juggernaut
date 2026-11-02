#!/usr/bin/env bash
# Propose a clone's forge binding from its origin remote, for project-add intake.
# Prints exactly one line to stdout:
#   forge=gerrit evidence=<the protocol fact that suggests it>
#   forge=none
# and exits 0 either way; a missing clone or a directory that is not a git work
# tree exits 2 with an error on stderr.
#
# PROPOSAL ONLY. This never writes the registry and no use-time path calls it:
# the captain's confirmation at intake is what binds the forge, and
# data/projects.md holds that answer as `forge=gerrit`, which
# bin/jg-project-mode.sh owns (docs/gerrit-forge-integration.md section 3).
# A confirmed record exists because detection can be wrong, so nothing re-derives
# the binding from the clone later.
#
# Evidence read, all from the clone's own git config and never from the network:
#   - an origin fetch or push URL on SSH port 29418, Gerrit's default SSH port;
#   - an origin push refspec targeting refs/for/, Gerrit's change-creating ref.
# Anything else proposes none. A Gerrit server on a non-default port behind an
# HTTPS remote carries neither fact, which is why the captain is asked rather
# than told.
# Usage: jg-forge-detect.sh <clone-dir>
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

DIR=${1:?usage: jg-forge-detect.sh <clone-dir>}
if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $DIR is not a git work tree" >&2
  exit 2
fi

urls=$( { git -C "$DIR" config --get-all remote.origin.url || true
  git -C "$DIR" config --get-all remote.origin.pushurl || true; } 2>/dev/null)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  case "$url" in
    ssh://*)
      authority=${url#ssh://}
      authority=${authority%%/*}
      case "$authority" in
        *:29418)
          printf 'forge=gerrit evidence=origin remote %s uses SSH port 29418\n' "$url"
          exit 0
          ;;
      esac
      ;;
  esac
done <<EOF
$urls
EOF

refspecs=$(git -C "$DIR" config --get-all remote.origin.push 2>/dev/null || true)
while IFS= read -r refspec; do
  case "$refspec" in
    *:refs/for/*)
      printf 'forge=gerrit evidence=origin push refspec %s targets refs/for/\n' "$refspec"
      exit 0
      ;;
  esac
done <<EOF
$refspecs
EOF

printf 'forge=none\n'
