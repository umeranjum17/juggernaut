#!/usr/bin/env bash
# Point the old inline wakes in state/fleet-pulse.check.sh at this feature's scripts: a retro wake that still
# globs only main-home jg-retro-*/report.md at bin/fleet-retro-due.sh (newest report.md across known homes), and a
# Fable wake that still greps session logs itself at bin/fleet-fable.sh (the model guard's allow-tasks decides).
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] || { echo 'usage: wiring.sh [--dry-run] <home>' >&2; exit 2; }
home=$(cd "$1" && pwd -P)
feature=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
check=$home/state/fleet-pulse.check.sh
[ -f "$check" ] || exit 0

# One line per old inline wake: <name> <the marker it still carries> <the script it calls instead>.
retargets=(
  "retro|jg-retro-\*/report\.md|$feature/bin/fleet-retro-due.sh"
  "fable|fab=\$(find |$feature/bin/fleet-fable.sh"
)
for entry in "${retargets[@]}"; do
  IFS='|' read -r name marker script <<<"$entry"
  grep -q -- "$marker" "$check" || continue
  if [ "$DRY" -eq 1 ]; then
    echo "would retarget $name wake in $check -> $script"
    continue
  fi
  python3 - "$check" "$script" "$home" "$name" <<'PY'
import pathlib, re, sys
path, script, home = map(pathlib.Path, sys.argv[1:4])
name = sys.argv[4]
call = (
    f"if msg=$({script.as_posix()!r} {home.as_posix()!r}); then\n"
    '  echo "$msg"; exit 0\n'
    "fi\n"
)
blocks = {
    "retro": (
        "# Fleet retro every 2-3 days (captain 5 Oct): wake Main once 60 h after the last retro report.\n",
        r"# Fleet retro every 2-3 days.*?\n"
        r"last=\$\(ls -t .*?jg-retro-\*/report\.md.*?\n"
        r"RM=.*\n"
        r"if \[ -n \"\$last\" \].*?\n"
        r"  touch \"\$RM\"; echo \"fleet-retro due:.*?\n"
        r"fi\n",
    ),
    "fable": (
        "# Fable outside the model guard's allow-tasks (captain 10 Oct ban; 9 Nov Juggernaut research may run it).\n",
        r"# Fable ban.*?\n"
        r"fab=\$\(find .*?\n"
        r"FM=.*\n"
        r"if \[ -n \"\$fab\" \].*?\n"
        r"  touch \"\$FM\"; echo \"fleet-fable:.*?\n"
        r"fi\n",
    ),
}
comment, pattern = blocks[name]
new, n = re.compile(pattern, re.S).subn(comment + call, path.read_text(), count=1)
if n != 1:
    sys.stderr.write(f"install: could not retarget {name} wake in {path}\n")
    sys.exit(1)
path.write_text(new)
print(f"retargeted {name} wake: {path} -> {script}")
PY
done
