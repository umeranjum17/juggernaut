#!/usr/bin/env bash
# Point the old inline wakes in state/fleet-pulse.check.sh at this feature's scripts: a retro wake that still
# globs only main-home jg-retro-*/report.md at bin/fleet-retro-due.sh (newest report.md across known homes), and a
# Fable wake that still greps session logs itself at bin/fleet-fable.sh (the model guard's allow-tasks decides).
# When its 2h report still counts landings as merged PRs only, retarget the report onto the trunk era, all
# blocks or none: landed, live and rtl from bin/trunk-pulse.sh (a home with no trunk records keeps its
# merged-PR count), asks>2h from bin/lead-asks.sh, and the open/working/dry row from
# ../fleet-flow/bin/jg-flow-check.sh with JG_MAIN_HOME set to this home. A check that has the report but not
# every block in the known form is left as it is, and the blocks it lacks are named (exit 1).
# A run that changed the check's bytes re-registers it with the home's bin/jg-check-register.sh before it exits,
# even when a later block then fails, so the watcher keeps accepting the check it runs.
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
register=$home/bin/jg-check-register.sh
if [ "$DRY" -eq 0 ]; then
  [ -x "$register" ] || { echo "fleet-pulse wiring: $home has no bin/jg-check-register.sh; $check left as it is" >&2; exit 1; }
  before=$(sha256sum <"$check")
  rebind() {  # the watcher runs a check only while its bytes match their registration
    local rc=$?
    if [ "$(sha256sum <"$check")" != "$before" ]; then
      env -u JG_STATE_OVERRIDE JG_HOME="$home" "$register" fleet-pulse || rc=1
    fi
    exit "$rc"
  }
  trap rebind EXIT
fi

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

python3 - "$check" "$feature" "$home" "$DRY" <<'PY'
import pathlib, re, sys
path, feature, home, dry = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4] == "1"
text = path.read_text()
if "fleet-pulse 2h" not in text:
    sys.exit(0)
def q(p):
    return "'" + p.replace("'", "'\\''") + "'"
trunk, asks = q(f"{feature}/bin/trunk-pulse.sh"), q(f"{feature}/bin/lead-asks.sh")
flow = q(str(pathlib.Path(feature).parent / "fleet-flow" / "bin" / "jg-flow-check.sh"))
landed_block = (
    "  # Trunk-era landings (core/fleet-pulse/bin/trunk-pulse.sh): a home with trunk records lands on its trunk\n"
    "  # and goes live there, so its landed count comes from those records; a merged-PR home keeps the count above.\n"
    f'  tr=""; if t=$({trunk} "$hp" "$((now - 7200))" "$now"); then\n'
    "    IFS=$'\\t' read -r m tl tw <<<\"$t\"; tr=\"/live$tl/rtl$tw\"; [ \"$tw\" = - ] || tr=\"${tr}m\"\n"
    "  fi\n"
)
# name, marker of the retargeted form, pattern of the old form, replacement
blocks = [
    ("landed", "trunk-pulse.sh", re.compile(r"(?m)^(?=  w=0 p=0 b=0\n)"), landed_block),
    ("landed-line", "$name:landed$m$tr/open", re.compile(re.escape("$name:landed$m/open")), "$name:landed$m$tr/open"),
    ("legend", "landed = trunk landings", re.compile(re.escape("fleet-pulse 2h (landings = merged PRs; ")),
     "fleet-pulse 2h (landed = trunk landings, else merged PRs; live = trunk live moves; rtl = minutes the oldest "
     "landed commit waits to go live; asks>2h = open keyed lead asks to Main; "),
    ("flow", "jg-flow-check.sh", re.compile(
        r"IFS=\$'\\t' read -r _ o fw rd dw ow ms ct dy <<<\"\$\(timeout 25 \S*fm-flow-check\.sh \"\$hp\" --summary 2>/dev/null\)\""),
     f"IFS=$'\\t' read -r _ o fw rd dw ow ms ct dy _ <<<\"$(JG_MAIN_HOME={q(home)} timeout 25 {flow} \"$hp\" --summary 2>/dev/null)\""),
    ("asks", "lead-asks.sh", re.compile(r"lk=\$\(python3 - (\"[^\"\n]*\") \"\$now\" <<'PY'\n.*?\nPY\n\)\n", re.S),
     lambda m: f'lk=$({asks} {m.group(1)} "$now")\n'),
]
todo, missing = [], []
for name, marker, pat, repl in blocks:
    if marker in text:
        continue
    if len(pat.findall(text)) != 1:
        missing.append(name)
        continue
    todo.append(name)
    text = pat.sub(repl if callable(repl) else repl.replace("\\", "\\\\"), text, count=1)
if missing:
    sys.stderr.write(f"fleet-pulse wiring: {path} has the 2h report but not these blocks in the known form: "
                     f"{' '.join(missing)}; left as it is\n")
    sys.exit(1)
if not todo:
    sys.exit(0)
if dry:
    print(f"would retarget the 2h report in {path} onto the trunk era: {' '.join(todo)}")
    sys.exit(0)
path.write_text(text)
print(f"retargeted the 2h report in {path} onto the trunk era: {' '.join(todo)}")
PY
