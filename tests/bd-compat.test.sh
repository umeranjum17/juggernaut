#!/usr/bin/env bash
# bd_compat.py answers a bd call by passing it to the wrapper (mode pass) or from the tickets tables (mode tables).
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/home" "$t/store"
cp -r "$repo/core/item-store/." "$t/store/"
rm -rf -- "$t/store/adapters/bd_forms"
prog=$t/store/adapters/bd_compat.py
cp "$repo/core/item-store/adapters/bd_compat.py" "$prog" 2>/dev/null
cat >"$t/beads.sh" <<'S'
#!/usr/bin/env bash
echo "args: $*"; cat; exit 7
S
chmod +x "$t/beads.sh"
export JG_HOME=$t/home JG_BEADS_SH=$t/beads.sh
bd() { python3 -I "$prog" "$@"; }
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# 1: pass mode hands over arguments and stdin, returns the wrapper's status
out=$(echo piped | bd show x --json 2>/dev/null); rc=$?
if [ "$rc" = 7 ] && [ "$out" = $'args: show x --json\npiped' ]; then ok "pass mode forwards and exits 7"; else bad "pass mode: rc=$rc out=$out"; fi

# 2: --mode follows config/bd-tables in the main home
[ "$(bd --mode 2>/dev/null)" = pass ] || bad "--mode without config/bd-tables"
mkdir -p "$t/home/config"; : >"$t/home/config/bd-tables"
if [ "$(bd --mode 2>/dev/null)" = tables ]; then ok "--mode pass, then tables"; else bad "--mode with config/bd-tables"; fi

# 3: tables mode, no family module
err=$(bd show x --json 2>&1 >/dev/null); rc=$?
if [ "$rc" = 2 ] && [ "$err" = "bd_compat: form not supported: show --json" ]; then ok "unsupported form exits 2"; else bad "unsupported: rc=$rc err=$err"; fi

# 4: tables mode, a stand-in family module
mkdir -p "$t/store/adapters/bd_forms"
printf 'class NotSupported(Exception):\n    pass\n\ndef run(argv, stdin_text):\n    return ("hello\\n", 3)\n' >"$t/store/adapters/bd_forms/read.py"
out=$(bd show x --json 2>/dev/null </dev/null); rc=$?
if [ "$rc" = 3 ] && [ "$out" = hello ]; then ok "family module answers"; else bad "module: rc=$rc out=$out"; fi
exit "$fail"
