#!/usr/bin/env bash
# jg-install-actionlint.sh - install CI's pinned, verified actionlint build.
#
# Downloads the official GitHub release archive for the host OS/arch, verifies
# its per-archive SHA-256 pin, and installs the binary into the destination
# directory. Supported platforms: linux amd64/x86_64, linux arm64/aarch64,
# darwin amd64/x86_64, darwin arm64/aarch64. Pins come from the official
# actionlint release checksums file. Verification uses sha256sum when present,
# otherwise shasum -a 256. An unsupported OS/arch or a missing pin fails
# without downloading.
#
# Usage:
#   jg-install-actionlint.sh <destination-directory>
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
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/jg-lint-workflows.sh" --required-version)"

die() {
  printf 'jg-install-actionlint.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: jg-install-actionlint.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
# SHA-256 pins are from actionlint_1.7.12_checksums.txt on the official
# v1.7.12 release (https://github.com/rhysd/actionlint/releases/tag/v1.7.12).
case "${os}-${arch}" in
  Linux-x86_64|Linux-amd64)
    ARCHIVE="actionlint_${VERSION}_linux_amd64.tar.gz"
    SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    ;;
  Linux-aarch64|Linux-arm64)
    ARCHIVE="actionlint_${VERSION}_linux_arm64.tar.gz"
    SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
    ;;
  Darwin-x86_64|Darwin-amd64)
    ARCHIVE="actionlint_${VERSION}_darwin_amd64.tar.gz"
    SHA256=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    ;;
  Darwin-arm64|Darwin-aarch64)
    ARCHIVE="actionlint_${VERSION}_darwin_arm64.tar.gz"
    SHA256=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  *)
    die "unsupported platform ${os}-${arch}; need linux or darwin on amd64/x86_64 or arm64/aarch64"
    ;;
esac
[ -n "$SHA256" ] || die "no pinned checksum for ${os}-${arch}"

URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/${ARCHIVE}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jg-actionlint.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=6
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'jg-install-actionlint.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'jg-install-actionlint.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep $((1 << (download_attempt - 1)))
  download_attempt=$((download_attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the actionlint archive"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'jg-install-actionlint.sh: checksum mismatch for %s (expected %s, got %s)\n' \
    "$ARCHIVE" "$SHA256" "$ACTUAL_SHA256" >&2
  exit 1
}
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
mkdir -p "$DESTINATION"
install -m 0755 "$TMP/actionlint" "$DESTINATION/actionlint"
"$DESTINATION/actionlint" -version
