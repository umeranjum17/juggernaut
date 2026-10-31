#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/bin" "$T/home/state"
printf '#!/bin/sh\nexit 0\n' > "$T/home/bin/jg-check-register.sh"
cat > "$T/home/bin/jg-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$JG_HOME/state/$1.check.sh" "$JG_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/bin/"jg-check-*.sh; printf unrelated > "$T/home/state/other"; touch "$T/home/state/0-nm-drain.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data"); "${E[@]}" "$A/wiring.sh" "$T/home" >/dev/null; out=$("${E[@]}" "$A/unwiring.sh" "$T/home"); [[ "$out" == *'prior nm-quiet'* ]]; [ ! -e "$T/home/state/0-nm-drain.check.sh" ] && [ ! -e "$T/home/state/0-nm-drain.check-trust" ] && [ ! -e "$T/data/jg-nm-drain/nm-drain.sh" ] && [ "$(cat "$T/home/state/other")" = unrelated ]; "${E[@]}" "$A/unwiring.sh" "$T/home" >/dev/null; echo 'PASS nm-drain uninstall'
