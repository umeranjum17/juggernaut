#!/usr/bin/env bash
# bd_compat.py has one mode, `tables`: it answers a bd call from fleet.db.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/home" "$t/store" "$t/path"
cp -r "$repo/core/item-store/." "$t/store/"
rm -rf -- "$t/store/adapters/bd_forms"
prog=$t/store/adapters/bd_compat.py
cp "$repo/core/item-store/adapters/bd_compat.py" "$prog" 2>/dev/null
export JG_HOME=$t/home
bd() { python3 -I "$prog" "$@"; }
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# 1: --mode prints tables, with or without config/bd-tables
[ "$(bd --mode 2>/dev/null)" = tables ] || bad "--mode without config/bd-tables"
mkdir -p "$t/home/config"; : >"$t/home/config/bd-tables"
if [ "$(bd --mode 2>/dev/null)" = tables ]; then ok "--mode prints tables"; else bad "--mode with config/bd-tables"; fi

# 2: no family module
err=$(bd show x --json 2>&1 >/dev/null); rc=$?
if [ "$rc" = 2 ] && [ "$err" = "bd_compat: form not supported: show --json" ]; then ok "unsupported form exits 2"; else bad "unsupported: rc=$rc err=$err"; fi

# 3: a stand-in family module
mkdir -p "$t/store/adapters/bd_forms"
printf 'class NotSupported(Exception):\n    pass\n\ndef run(argv, stdin_text):\n    return ("hello\\n", 3)\n' >"$t/store/adapters/bd_forms/read.py"
out=$(bd show x --json 2>/dev/null </dev/null); rc=$?
if [ "$rc" = 3 ] && [ "$out" = hello ]; then ok "family module answers"; else bad "module: rc=$rc out=$out"; fi
exit "$fail"
