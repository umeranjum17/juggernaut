#!/usr/bin/env bash
# Install or remove the pi-quota-failover wrapper for the no-mistakes
# pipeline agent, and wire it in with one key-level edit of
# ~/.no-mistakes/config.yaml (or $NM_CONFIG).
#
#   wiring.sh [--dry-run] [--restore] [--config <path>] [--home <dir>]
#
# --dry-run   print the changes and write nothing.
# --restore   remove agent_path_override.pi and the installed copy.
# --home      alternate install dir (default ~/.local/share/jg-pipeline-quota-failover)
#
# A key that already names this step's wrapper is left as it is, so a rerun is a no-op. A key that names
# the wrapper the pre-rename installer wrote (~/.local/share/fm-pipeline-quota-failover/pi-quota-failover)
# is this step's own earlier wiring: its value is moved to the current wrapper, after the backup. Any other
# value belongs to someone else and is refused untouched.
#
# The edit never prints the config or any value in it; it reports only the
# key name and the wrapper path it wrote. A timestamped backup of the config
# is written next to it before the first change. The no-mistakes daemon
# re-reads the config per run, so no daemon restart is needed or performed.
set -u

die() { echo "wiring.sh: $*" >&2; exit 1; }

dry=0 restore=0
install_root=${HOME:?}/.local/share/jg-pipeline-quota-failover
config=${NM_CONFIG:-${HOME:?}/.no-mistakes/config.yaml}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --restore) restore=1 ;;
    --config) config=$2; shift ;;
    --home) install_root=$2; shift ;;
    *) die "unknown argument: $1 (use --dry-run, --restore, --config <path>, --home <dir>)" ;;
  esac
  shift
done

src=$(cd "$(dirname "$0")" && pwd)/pi-quota-failover
[ -f "$src" ] || die "wrapper not found next to wiring.sh"
[ -f "$config" ] || die "no config at $config"

wrapper=$install_root/pi-quota-failover
legacy_wrapper=${HOME:?}/.local/share/fm-pipeline-quota-failover/pi-quota-failover

if [ "$restore" = 1 ]; then
  [ "$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print((c.get("agent_path_override") or {}).get("pi") or "")' "$config" 2>/dev/null)" = "$wrapper" ] \
    || die "agent_path_override.pi is not $wrapper; nothing to restore"
  if [ "$dry" = 1 ]; then echo "dry-run: would remove key agent_path_override.pi and $wrapper"; exit 0; fi
  cp -p "$config" "$config.bak-pqf-restore-$(date +%s)" || die "cannot back up $config"
  python3 - "$config" <<'EOF'
import sys, re
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out, i, removed = [], 0, False
while i < len(lines):
    line = lines[i]
    if re.match(r'^agent_path_override:', line):
        i += 1
        while i < len(lines) and (lines[i].startswith((' ', '\t')) or lines[i].strip() == ''):
            i += 1
        removed = True
        continue
    out.append(line)
    i += 1
if not removed:
    sys.exit("config has no active agent_path_override block")
open(path, 'w').write(''.join(out))
EOF
  rm -f "$wrapper"
  echo "removed key agent_path_override.pi and $wrapper (backup written next to the config)"
  exit 0
fi

have=$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print((c.get("agent_path_override") or {}).get("pi") or "")' "$config" 2>/dev/null) \
  || die "cannot parse $config with python3-yaml"
case $have in
  '') key=add ;;
  "$wrapper") key=keep ;;
  "$legacy_wrapper") key=move ;;
  *) die "agent_path_override.pi already points at $have, which is neither $wrapper nor the pre-rename $legacy_wrapper; refusing to replace it (restore first)" ;;
esac

if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $wrapper"
  case $key in
    add) echo "dry-run: would add key agent_path_override.pi = $wrapper to $config (backup first)" ;;
    move) echo "dry-run: would move key agent_path_override.pi from the pre-rename $legacy_wrapper to $wrapper in $config (backup first)" ;;
    keep) echo "dry-run: key agent_path_override.pi is already $wrapper; config unchanged" ;;
  esac
  exit 0
fi

mkdir -p "$install_root" || die "cannot create $install_root"
tmp_wrapper=$install_root/.pi-quota-failover.$$
if ! cp -p "$src" "$tmp_wrapper" || ! chmod +x "$tmp_wrapper" || ! mv -f "$tmp_wrapper" "$wrapper"; then
  rm -f -- "$tmp_wrapper"
  die "cannot atomically install wrapper at $wrapper"
fi

if [ "$key" = add ]; then
  cp -p "$config" "$config.bak-pqf-$(date +%Y%m%d-%H%M%S)" || die "cannot back up $config"
  # Key-level edit: append the new top-level key at the end of the document
  # (YAML keys are order-free, so nothing else in the file moves or changes).
  python3 - "$config" "$wrapper" <<'EOF'
import sys
path, wrapper = sys.argv[1], sys.argv[2]
text = open(path).read()
if not text.endswith('\n'):
    text += '\n'
text += '\nagent_path_override:\n  pi: ' + wrapper + '\n'
open(path, 'w').write(text)
EOF
  echo "added key agent_path_override.pi = $wrapper to $config (backup written next to it)"
elif [ "$key" = move ]; then
  backup=$config.bak-pqf-$(date +%Y%m%d-%H%M%S)
  cp -p "$config" "$backup" || die "cannot back up $config"
  # Key-level edit: only the value on the one `pi:` line of the block-form agent_path_override key changes.
  # The result is parsed again, and anything but the current wrapper under the key puts the backup back.
  if ! python3 - "$config" "$legacy_wrapper" "$wrapper" <<'EOF'
import re, sys, yaml
path, legacy, wrapper = sys.argv[1:]
lines = open(path).read().splitlines(keepends=True)
hits, block = [], False
for i, line in enumerate(lines):
    text = line.rstrip('\n')
    if re.match(r'^agent_path_override:\s*(?:#.*)?$', text):
        block = True
        continue
    if block and text.strip() and not text.startswith((' ', '\t')):
        block = False
    if block and re.match(r'^[ \t]+pi:\s*' + re.escape(legacy) + r'\s*(?:#.*)?$', text):
        hits.append(i)
if len(hits) != 1:
    sys.exit("found %d block-form agent_path_override.pi lines naming the pre-rename wrapper; expected one" % len(hits))
lines[hits[0]] = lines[hits[0]].replace(legacy, wrapper, 1)
open(path, 'w').write(''.join(lines))
got = ((yaml.safe_load(open(path)) or {}).get('agent_path_override') or {}).get('pi')
if got != wrapper:
    sys.exit("the edited config does not read back agent_path_override.pi as the current wrapper")
EOF
  then
    cp -p "$backup" "$config" || die "cannot put the backup $backup back over $config"
    die "cannot move agent_path_override.pi from $legacy_wrapper to $wrapper in $config; the config is unchanged"
  fi
  echo "moved key agent_path_override.pi from the pre-rename $legacy_wrapper to $wrapper in $config (backup written next to it)"
else
  echo "key agent_path_override.pi already $wrapper; config unchanged"
fi
echo "installed $wrapper; the next pipeline run picks it up (no daemon restart needed)"
