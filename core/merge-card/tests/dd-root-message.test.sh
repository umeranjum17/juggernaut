#!/usr/bin/env bash
# A card run from a home that is not a done-done repository names what it could not find and where it looked.
# Fixture home and a stub done-done that answers `doctor` like the real one; nothing is posted.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mc=$here/../merge-card
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/jh/data/t1"
cat > "$work/bin/done-done" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = doctor ] || exit 0
if [ -f .done-done.yaml ]; then
  echo '{"checks":[{"check":"evidence_root","status":"ok","detail":"writable: /nonexistent/evidence/app"}]}'
else
  echo '{"checks":[{"check":"evidence_root","status":"missing","detail":"unknown without a valid config"}]}'
fi
STUB
chmod +x "$work/bin/done-done"
printf 'screen: none\noutcome: x\n' > "$work/jh/data/t1/checks.md"
out=$(cd "$work" && PATH=$work/bin:$PATH JG_HOME=$work/jh bash "$mc" post --board "$work/board.json" t1 - abc123 - 2>&1) && rc=0 || rc=$?
printf '%s\n' "$out"
[ "$rc" -ne 0 ] || { echo "not ok - the card was posted without a receipt"; exit 1; }
case $out in *"no passed-test receipt"*) ;; *) echo "not ok - the refusal is gone"; exit 1 ;; esac
case $out in
  *"could not find done-done's evidence root"*"$work/jh"*".done-done.yaml"*) echo "ok - the message names what it could not find and where it looked" ;;
  *) echo "not ok - the message does not say the evidence root was not found in $work/jh"; exit 1 ;;
esac
