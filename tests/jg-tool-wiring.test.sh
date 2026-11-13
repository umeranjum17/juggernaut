#!/usr/bin/env bash
# bin/jg-bootstrap.sh install done-done on a clean HOME wires the pinned package: the real done-done-axi
# 0.6.27 layout ships integrations/firstmate/, and the install used to die with "brief include is not written".
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-tool-wiring.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
no() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

for name in firstmate juggernaut; do
  root=$tmp/$name/npm-root pkg=$tmp/$name/npm-root/done-done-axi home=$tmp/$name/home
  mkdir -p "$pkg/skills/done-done" "$pkg/integrations/$name" "$tmp/$name/bin" "$home/config" "$home/state" "$tmp/$name/user"
  : >"$pkg/skills/done-done/SKILL.md"
  printf 'brief block for %s\n' "$name" >"$pkg/integrations/$name/brief-include.md"
  printf '#!/bin/sh\nexit 0\n' >"$pkg/integrations/$name/merge-gate"
  # shellcheck disable=SC2016 # the shim body is written literally, its $1 $2 are the shim's own
  printf '#!/bin/sh\nif [ "$1 $2" = "root -g" ]; then echo %s; fi\n' "$root" >"$tmp/$name/bin/npm"
  chmod +x "$tmp/$name/bin/npm"
  out=$(env -i PATH="$tmp/$name/bin:$PATH" HOME="$tmp/$name/user" JG_HOME="$home" \
    bash "$here/bin/jg-bootstrap.sh" install done-done 2>&1) || { printf '%s\n' "$out" >&2; no "install failed for $name layout"; }
  grep -qF "brief block for $name" "$home/config/brief-include.md" || no "brief include missing for $name layout"
  [ -x "$home/config/merge-gate" ] || no "merge gate not placed for $name layout"
  printf '== %s layout: package ships integrations/%s/\n%s\n' "$name" "$name" "$out"
  printf 'exit 0; config/brief-include.md holds:\n'; sed 's/^/  | /' "$home/config/brief-include.md"
  printf 'config/merge-gate mode %s\n' "$(stat -c %a "$home/config/merge-gate")"
  printf 'ok - %s layout installs\n' "$name"
done
