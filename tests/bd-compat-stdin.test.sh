#!/usr/bin/env bash
# bd_compat.py reads stdin only for a form that names it (`-` or `--stdin`): show, list and ready finish at once with an open pipe on stdin.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
repo=$PWD
t=$(mktemp -d) || exit 1
trap 'rm -rf -- "$t"' EXIT
mkdir -p "$t/home" "$t/store/adapters/bd_forms"
cp -r "$repo/core/item-store/." "$t/store/"
rm -rf -- "$t/store/adapters/bd_forms"
mkdir -p "$t/store/adapters/bd_forms"
printf 'class NotSupported(Exception):\n    pass\n\ndef run(argv, stdin_text):\n    return ("stdin=[%%s]\\n" %% stdin_text, 0)\n' >"$t/store/adapters/bd_forms/read.py"
export JG_HOME=$t/home
fail=0
mkfifo "$t/pipe"
sleep 20 >"$t/pipe" & holder=$!
trap 'kill "$holder" 2>/dev/null; rm -rf -- "$t"' EXIT
for verb in "show x --json" "list --json" "ready --json"; do
  start=$SECONDS
  # shellcheck disable=SC2086
  out=$(timeout 5 python3 -I "$t/store/adapters/bd_compat.py" $verb <"$t/pipe" 2>&1); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "stdin=[]" ] && [ $((SECONDS - start)) -lt 5 ]; then echo "ok: $verb finishes with an open pipe on stdin"; else echo "FAIL: $verb rc=$rc out=$out"; fail=1; fi
done
out=$(printf 'from the pipe' | python3 -I "$t/store/adapters/bd_compat.py" show x --stdin 2>&1)
if [ "$out" = "stdin=[from the pipe]" ]; then echo "ok: a form that names --stdin reads it"; else echo "FAIL: --stdin read: $out"; fail=1; fi
exit "$fail"
