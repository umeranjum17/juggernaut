#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home"; E=(env HOME="$T/home" XDG_DATA_HOME="$T/data"); printf keep > "$T/data-other"
"${E[@]}" "$A/wiring.sh" >/dev/null; "${E[@]}" "$A/unwiring.sh" >/dev/null; [ ! -e "$T/data/jg-fleet-flow/jg-flow-check.sh" ] && [ "$(cat "$T/data-other")" = keep ]; before=$(sha256sum "$T/data-other"); "${E[@]}" "$A/unwiring.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/data-other")" ]; echo 'PASS fleet-flow uninstall'
