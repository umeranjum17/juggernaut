#!/usr/bin/env bash
# jg-install-herdr.sh - install CI's pinned, verified Herdr build.
#
# Single owner of the exact Herdr version, official release asset URL, and
# SHA-256 pin used by the required real-Herdr CI lane. Never installs a
# floating package-manager latest.
#
# Usage:
#   jg-install-herdr.sh <destination-directory>
#
# Pins Herdr v0.7.4 (protocol 16), the suite-verified protocol-16 release.
# Selects the official GitHub Releases asset for the host OS/arch, downloads
# with a bounded max size and a bounded retry, verifies SHA-256 before install, then refuses to
# finish unless the binary reports the exact pin version and a client protocol
# at or above the required floor (16 for the real-Herdr family).
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

# Exact pin - change only with a re-verified real-Herdr matrix.
JG_HERDR_CI_VERSION=0.7.4
JG_HERDR_CI_TAG="v${JG_HERDR_CI_VERSION}"
JG_HERDR_CI_MIN_PROTOCOL=16
# Bounded download ceiling (bytes). The largest official 0.7.4 asset is under 20 MiB.
JG_HERDR_CI_MAX_BYTES=25000000
JG_HERDR_CI_REPO=ogulcancelik/herdr

die() {
  printf 'jg-install-herdr.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: jg-install-herdr.sh <destination-directory>}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    ASSET=herdr-linux-x86_64
    SHA256=bc0fc02d4ba500f9cac2353a43e67fe036785ecca6eb55378e050fac3c103059
    ;;
  Linux-aarch64|Linux-arm64)
    ASSET=herdr-linux-aarch64
    SHA256=544e0002de42806d1ab64ccdef3a7e7414f24717b0b6b022bc9e57d2eefd26a2
    ;;
  Darwin-arm64)
    ASSET=herdr-macos-aarch64
    SHA256=24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7
    ;;
  Darwin-x86_64)
    ASSET=herdr-macos-x86_64
    SHA256=ddf430133352e1712413d5d865b34a485546f4658893fc89986257d65a7585a8
    ;;
  *)
    die "unsupported platform ${os}-${arch}; official Herdr assets are linux/macos x86_64 and aarch64"
    ;;
esac

URL="https://github.com/${JG_HERDR_CI_REPO}/releases/download/${JG_HERDR_CI_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/jg-herdr.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Bounded retry around the download only. A transient network or runner failure
# (the GitHub release CDN, a dropped connection) must not fail the required
# lane, so the fetch is attempted at most JG_HERDR_CI_DOWNLOAD_ATTEMPTS times
# with a short linear backoff (default 5s, then 10s: a 15s ceiling of waiting).
# The SHA-256 pin and protocol floor below run once, on the downloaded file; a
# hash mismatch is never retried and fails on the first attempt.
JG_HERDR_CI_DOWNLOAD_ATTEMPTS=3
JG_HERDR_CI_RETRY_DELAY=${JG_HERDR_CI_RETRY_DELAY:-5}
attempt=1
while :; do
  printf 'jg-install-herdr.sh: downloading %s from %s (attempt %s of %s)\n' \
    "$ASSET" "$URL" "$attempt" "$JG_HERDR_CI_DOWNLOAD_ATTEMPTS" >&2
  # --fail: HTTP errors; --location: follow redirects; --max-filesize: bound.
  if curl -fsSL --max-filesize "$JG_HERDR_CI_MAX_BYTES" "$URL" -o "$TMP/$ASSET"; then
    break
  else
    curl_status=$?
  fi
  [ "$attempt" -lt "$JG_HERDR_CI_DOWNLOAD_ATTEMPTS" ] \
    || die "download failed for $URL after $JG_HERDR_CI_DOWNLOAD_ATTEMPTS attempts (last curl exit status $curl_status; bounded at $JG_HERDR_CI_MAX_BYTES bytes)"
  delay=$((JG_HERDR_CI_RETRY_DELAY * attempt))
  printf 'jg-install-herdr.sh: download attempt %s failed (curl exit status %s); retrying in %ss\n' \
    "$attempt" "$curl_status" "$delay" >&2
  rm -f "$TMP/$ASSET"
  sleep "$delay"
  attempt=$((attempt + 1))
done

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the Herdr asset"
fi

[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

mkdir -p "$DESTINATION"
install -m 0755 "$TMP/$ASSET" "$DESTINATION/herdr"

# Post-install version and protocol gates (no floating latest).
installed_version=$("$DESTINATION/herdr" --version 2>/dev/null | awk '{print $2; exit}')
[ "$installed_version" = "$JG_HERDR_CI_VERSION" ] \
  || die "installed herdr version is '${installed_version:-<empty>}', expected exact pin $JG_HERDR_CI_VERSION"

status=$("$DESTINATION/herdr" status --json 2>/dev/null) \
  || die "could not run 'herdr status --json' after install"
protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null) \
  || die "jq is required to parse herdr status after install"
case "$protocol" in
  ''|*[!0-9]*) die "could not read herdr client protocol from status --json" ;;
esac
[ "$protocol" -ge "$JG_HERDR_CI_MIN_PROTOCOL" ] \
  || die "herdr protocol $protocol is below the required floor $JG_HERDR_CI_MIN_PROTOCOL"

printf 'jg-install-herdr.sh: installed herdr %s (protocol %s) to %s\n' \
  "$installed_version" "$protocol" "$DESTINATION/herdr" >&2
"$DESTINATION/herdr" --version
