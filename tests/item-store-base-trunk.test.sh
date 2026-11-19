#!/usr/bin/env bash
# `jg-item base` for a local-trunk project answers the home's current trunk (release/vN, the name bin/jg-trunk.sh works on), not the
# policy row's fixed `trunk`: a repo with release/v10 and no `trunk` branch gives refs/heads/release/v10. A project that is not
# registered local-trunk keeps the answer of its policy row.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$HERE/lib.sh"
jg_git_identity fmtest fmtest@example.invalid
ITEM=$ROOT/core/item-store
TMP_ROOT=$(jg_test_tmproot item-base-trunk)
unset JG_TASK_ID JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_ROOT_OVERRIDE
export JG_ITEM_TICK_LEASE_S=0
want() { [ "$3" = "$2" ] || fail "$1: wanted [$2], got [$3]"; pass "$1"; }

C=$TMP_ROOT/home; P=$C/projects/trunkproj; Q=$C/projects/plainproj
mkdir -p "$C/state" "$C/config" "$C/data"
: > "$C/config/item-store"
# trunkproj has release/v10 and no `trunk` branch; plainproj is a local project on main
git init -q -b release/v10 "$P"; git -C "$P" commit -q --allow-empty -m base
git init -q -b main "$Q"; git -C "$Q" commit -q --allow-empty -m base
printf '%s\n' 'release/v10' > "$C/state/trunk-branch-trunkproj"
git -C "$P" rev-parse release/v10 > "$C/state/trunk-tip-trunkproj"
printf '%s\n' '- trunkproj [local-trunk] - fixture' '- plainproj [local] - fixture' '- nobranch [local-trunk] - fixture' > "$C/data/projects.md"
mkdir -p "$C/projects/nobranch"
JG_HOME="$C" ITEM="$ITEM" python3 -I -c 'import os, sys; sys.path.insert(0, os.environ["ITEM"]); import itemdb
st = itemdb.open_db(os.environ["JG_HOME"], "owner:registry"); at = itemdb.stamp(st)
st.set_policy(at, "trunkproj", "standard", st.me, "test:policy:trunkproj", mode="local-trunk", trunk="trunk")
st.set_policy(at, "nobranch", "standard", st.me, "test:policy:nobranch", mode="local-trunk", trunk="trunk")
st.set_policy(at, "plainproj", "standard", st.me, "test:policy:plainproj", mode="local", trunk="main")'

jg() { env JG_HOME="$C" "$ITEM/jg-item" "$@" 2>&1; }
want trunk-project-base-is-release-branch refs/heads/release/v10 "$(jg base trunkproj)"
want local-project-keeps-policy-trunk refs/heads/main "$(jg base plainproj)"
want trunk-project-without-trunk-state-keeps-policy-trunk refs/heads/trunk "$(jg base nobranch)"
