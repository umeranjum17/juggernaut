#!/usr/bin/env bash
# Install or remove Juggernaut's guarded Kimi crew turn-end hook.
#
# This command is the sole owner of the text-level edit to
# $HOME/.kimi-code/config.toml. It validates the existing TOML but never
# serializes it: install adds or replaces one marker-delimited Juggernaut region,
# and remove excises only that region. Missing, malformed, symlinked, partially
# marked, or otherwise surprising config is refused without a config write.
#
# The installed Stop hook always exits 0 and stays silent. It reads cwd from the
# hook payload, checks for a .jg-kimi-turnend pointer before registry work, and
# touches a task turn-end marker only when the pointer names a Juggernaut-created
# token in $HOME/.kimi-code/jg-turn-end.d/.
#
# Usage:
#   jg-kimi-turnend-hook.sh install
#   jg-kimi-turnend-hook.sh remove
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,18{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

if [ -z "${HOME:-}" ]; then
  printf 'jg-kimi-turnend-hook: refused: HOME is unset.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'jg-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'jg-kimi-turnend-hook: refused: jq is required by the installed Kimi turn-end hook.\n' >&2
  exit 1
fi

python3 - "$ACTION" "$HOME/.kimi-code" <<'PY'
import os
import re
import shutil
import stat
import sys
import tempfile

try:
    import tomllib
except ImportError:
    print(
        "jg-kimi-turnend-hook: refused: python3 with tomllib is required to validate config.toml.",
        file=sys.stderr,
    )
    raise SystemExit(1)

ACTION = sys.argv[1]
CONFIG_DIR = sys.argv[2]
CONFIG = os.path.join(CONFIG_DIR, "config.toml")
HOOK = os.path.join(CONFIG_DIR, "jg-turn-end.sh")
REGISTRY = os.path.join(CONFIG_DIR, "jg-turn-end.d")
BEGIN = b"# BEGIN JUGGERNAUT KIMI TURN-END HOOK"
BEGIN_OWNS_NEWLINE = BEGIN + b" (OWNS PRECEDING NEWLINE)"
END = b"# END JUGGERNAUT KIMI TURN-END HOOK"
IDENTIFIER = b"JUGGERNAUT KIMI TURN-END HOOK"
HOOK_NAME = b"jg-turn-end.sh"
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")

HOOK_BYTES = b'''#!/usr/bin/env bash
# Juggernaut Kimi turn-end hook. Managed by jg-kimi-turnend-hook.sh.
# This hook is deliberately passive: every path is silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er 'select(.hook_event_name == "Stop") | .cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
pointer="$workspace/.jg-kimi-turnend"
[ -f "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
auth_dir=${HOME:-}/.kimi-code/jg-turn-end.d
[ -n "${HOME:-}" ] || exit 0
target=$(cat "$auth_dir/$token" 2>/dev/null) || exit 0
case "$target" in /*.turn-ended) : ;; *) exit 0 ;; esac
touch -- "$target" 2>/dev/null || true
exit 0
'''


def refuse(reason: str) -> None:
    print(f"jg-kimi-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str) -> os.stat_result:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def parse_toml(data: bytes, label: str):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    try:
        parsed = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        refuse(f"{label} is malformed TOML: {error}.")
    hooks = parsed.get("hooks")
    if hooks is not None and not isinstance(hooks, list):
        refuse(f"{label} has an unexpected non-array 'hooks' value.")
    return parsed


def locate_region(data: bytes):
    normal_count = data.count(BEGIN + b"\n")
    owned_count = data.count(BEGIN_OWNS_NEWLINE + b"\n")
    end_count = data.count(END)
    identifier_count = data.count(IDENTIFIER)
    if normal_count + owned_count == 0 and end_count == 0 and identifier_count == 0:
        return None
    if normal_count + owned_count != 1 or end_count != 1 or identifier_count != 2:
        refuse("config.toml has partial, duplicated, or altered Juggernaut region markers.")
    marker = BEGIN_OWNS_NEWLINE if owned_count else BEGIN
    marker_at = data.find(marker)
    if marker_at != 0 and data[marker_at - 1 : marker_at] != b"\n":
        refuse("the Juggernaut begin marker is not at a line boundary.")
    start = marker_at
    if owned_count:
        if marker_at == 0 or data[marker_at - 1 : marker_at] != b"\n":
            refuse("the Juggernaut region claims a preceding newline that is absent.")
        start -= 1
    end_at = data.find(END, marker_at + len(marker))
    if end_at < 0:
        refuse("the Juggernaut end marker is missing.")
    after = end_at + len(END)
    if after < len(data):
        if data[after : after + 1] != b"\n":
            refuse("the Juggernaut end marker is not a complete line.")
        after += 1
    return start, after, marker


def block(marker: bytes) -> bytes:
    return b"\n".join(
        (
            marker,
            b"[[hooks]]",
            b'event = "Stop"',
            b'matcher = "^$"',
            b'command = "bash \\"$HOME/.kimi-code/jg-turn-end.sh\\" >/dev/null 2>&1 || true"',
            b"timeout = 1",
            END,
            b"",
        )
    )


def without_region(data: bytes, region) -> bytes:
    prefix = data[: region[0]]
    suffix = data[region[1] :]
    # Retain a newline so removal cannot join the captain's preceding line to content appended after installation.
    separator = b"\n" if region[2] == BEGIN_OWNS_NEWLINE and suffix else b""
    return prefix + separator + suffix


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_juggernaut_files_for_remove() -> None:
    if os.path.lexists(HOOK):
        info = regular_not_symlink(HOOK, "Juggernaut hook script")
        with open(HOOK, "rb") as stream:
            if stream.read() != HOOK_BYTES:
                refuse(f"Juggernaut hook script has unexpected content at {HOOK}.")
        if stat.S_IMODE(info.st_mode) & 0o077:
            refuse(f"Juggernaut hook script has unexpectedly broad permissions at {HOOK}.")
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Juggernaut registry is not a regular directory at {REGISTRY}.")
        for name in os.listdir(REGISTRY):
            path = os.path.join(REGISTRY, name)
            child = os.lstat(path)
            if not TOKEN_NAME.fullmatch(name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
                refuse(f"Juggernaut registry contains an unexpected entry at {path}.")


try:
    if not os.path.isdir(CONFIG_DIR) or os.path.islink(CONFIG_DIR):
        refuse(f"Kimi config directory is missing or unexpected at {CONFIG_DIR}.")
    config_info = regular_not_symlink(CONFIG, "Kimi config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    parse_toml(original, "config.toml")
    region = locate_region(original)
    outside = original if region is None else without_region(original, region)
    if HOOK_NAME in outside:
        refuse("config.toml references jg-turn-end.sh outside the Juggernaut-owned region.")

    if ACTION == "install":
        if os.path.lexists(REGISTRY):
            info = os.lstat(REGISTRY)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Juggernaut registry is not a regular directory at {REGISTRY}.")
        if os.path.lexists(HOOK):
            regular_not_symlink(HOOK, "Juggernaut hook script")
            with open(HOOK, "rb") as stream:
                existing_hook = stream.read()
            if existing_hook != HOOK_BYTES and not existing_hook.startswith(
                b"#!/usr/bin/env bash\n# Juggernaut Kimi turn-end hook."
            ):
                refuse(f"Juggernaut hook path has unexpected content at {HOOK}.")
        if region is None:
            marker = BEGIN if original.endswith(b"\n") else BEGIN_OWNS_NEWLINE
            addition = block(marker)
            candidate = original + (b"" if original.endswith(b"\n") else b"\n") + addition
        else:
            candidate = original[: region[0]] + (
                (b"\n" if region[2] == BEGIN_OWNS_NEWLINE else b"") + block(region[2])
            ) + original[region[1] :]
        parse_toml(candidate, "updated config.toml")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
        if installed_hook != HOOK_BYTES or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_juggernaut_files_for_remove()
        candidate = outside
        parse_toml(candidate, "config.toml after Juggernaut region removal")
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
