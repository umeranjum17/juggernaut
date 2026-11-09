# shellcheck shell=bash
# The single reader of the toolchain pin table (toolchain.versions, beside this repo's root).
# Usage: . bin/jg-pin-lib.sh
#
# jg_pin_file            print the table path.
# jg_pin_spec <tool>     print that row's exact spec. Nonzero when the tool has no row.
# jg_pin_version <tool>  print the version the repo verifies for that tool.
# jg_pin_npm <tool>      print the npm spec to install. Nonzero when the row is not npm-installable.
# jg_pin_sha_cached <file> <cache file>
#                        print the file's sha256, hashing it only when the file changed since the
#                        hash the cache file records.
#
# Callers: bin/jg-bootstrap.sh (its install commands and every floor), bin/jg-backlog-lib.sh,
# bin/jg-quota-axi-lib.sh, bin/jg-beads.sh, and the installer. Nothing here writes but
# jg_pin_sha_cached, into the cache file its caller names, and a missing table or row is a refusal
# rather than a silently assumed version. JG_PIN_FILE_OVERRIDE points at another table, which
# is how a test proves that changing one row changes what the install paths install.
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

JG_PIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

jg_pin_file() {
  printf '%s\n' "${JG_PIN_FILE_OVERRIDE:-$JG_PIN_ROOT/toolchain.versions}"
}

jg_pin_spec() {
  local tool=$1 file name spec
  file=$(jg_pin_file)
  [ -f "$file" ] || { echo "jg-pin-lib: no pin table at $file" >&2; return 1; }
  while read -r name spec _; do
    case "$name" in ''|'#'*) continue ;; esac
    [ "$name" = "$tool" ] || continue
    [ -n "${spec:-}" ] || break
    printf '%s\n' "$spec"
    return 0
  done < "$file"
  echo "jg-pin-lib: $tool has no row in $file" >&2
  return 1
}

jg_pin_version() {
  local spec
  spec=$(jg_pin_spec "$1") || return 1
  printf '%s\n' "${spec##*@}"
}

jg_pin_npm() {
  local spec
  spec=$(jg_pin_spec "$1") || return 1
  [[ $spec =~ ^.+@[0-9] ]] || return 1
  printf '%s\n' "$spec"
}

# A tool pinned by binary hash, like bd and dolt: the row for this platform, and a file's hash.
jg_pin_sha_want() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  jg_pin_spec "$1-sha256-$os-$arch"
}

jg_pin_sha_of() {
  { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1
}

# A file's identity for the hash cache: device, inode, size, and modify and change times to the
# nanosecond. Replacing, rewriting or touching the file moves at least one of them, and the change
# time cannot be set back.
_jg_pin_stat() {
  case ${OSTYPE:-} in
    darwin*) /usr/bin/stat -f '%d %i %z %Fm %Fc' "$1" 2>/dev/null ;;
    *) stat -c '%d %i %s %.9Y %.9Z' -- "$1" 2>/dev/null ;;
  esac
}

# A pinned binary is hashed before each start, and bd is 150 MB, so the hash is kept in <cache file>
# under the file's path and identity and read back while both match. A miss hashes the file and records
# it only when the identity held across the hash and the last change is at least two seconds old, so a
# write in the same timestamp tick as the hash cannot leave a stale record. A file stat cannot read is
# hashed every time. The caller still compares the hash with the pin, so a pin change applies at once.
jg_pin_sha_cached() {
  local file=$1 cache=$2 key line sha changed now
  key=$(_jg_pin_stat "$file") && key="$file $key" || key=
  if [ -n "$key" ] && [ -r "$cache" ] && { IFS= read -r line && IFS= read -r sha; } < "$cache" \
    && [ "$line" = "$key" ] && [ -n "$sha" ]; then
    printf '%s\n' "$sha"
    return 0
  fi
  sha=$(jg_pin_sha_of "$file")
  printf '%s\n' "$sha"
  [ -n "$key" ] && [ -n "$sha" ] && [ "$file $(_jg_pin_stat "$file")" = "$key" ] || return 0
  changed=${key##* }
  now=$(date +%s)
  [ $((now - ${changed%%.*})) -ge 2 ] || return 0
  { printf '%s\n%s\n' "$key" "$sha" > "$cache.$$" && mv -f -- "$cache.$$" "$cache"; } 2>/dev/null || {
    rm -f -- "$cache.$$"
    echo "jg-pin-lib: cannot write the hash cache $cache, so $file is hashed again on every start" >&2
  }
}

# The pinned version when the tool on PATH hashes to its row, so the answer never starts the binary.
jg_pin_hashed_version() {
  local path
  path=$(command -v "$1") || return 0
  [ "$(jg_pin_sha_of "$path")" != "$(jg_pin_sha_want "$1" 2>/dev/null)" ] || jg_pin_version "$1"
}
