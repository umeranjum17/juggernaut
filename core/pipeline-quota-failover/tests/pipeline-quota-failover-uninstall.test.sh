#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.no-mistakes" "$T/bin"; printf 'keep: yes\n' > "$T/home/.no-mistakes/config.yaml"; cp "$T/home/.no-mistakes/config.yaml" "$T/original"
cat > "$T/bin/cp" <<'CP'
#!/usr/bin/env bash
/bin/cp "$@"
if [ -n "${MARKER:-}" ]; then
  for arg in "$@"; do case "$arg" in */.pi-quota-failover.*) touch "$MARKER"; while [ ! -e "$RELEASE" ]; do sleep 0.02; done ;; esac; done
fi
CP
chmod +x "$T/bin/cp"; E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" PATH="$T/bin:$PATH")
"${E[@]}" "$A/wiring.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null
cp "$T/home/data/pi-quota-failover" "$T/old-wrapper"; MARKER="$T/marker" RELEASE="$T/release" "${E[@]}" "$A/wiring.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null & pid=$!
for _ in $(seq 1 200); do [ -e "$T/marker" ] && break; sleep 0.02; done
[ -e "$T/marker" ] && cmp -s "$T/old-wrapper" "$T/home/data/pi-quota-failover"; touch "$T/release"; wait "$pid"
"${E[@]}" "$A/unwiring.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null
cmp -s "$T/original" "$T/home/.no-mistakes/config.yaml" && [ ! -e "$T/home/data/pi-quota-failover" ]; before=$(sha256sum "$T/home/.no-mistakes/config.yaml"); "${E[@]}" "$A/unwiring.sh" --home "$T/home/data" --config "$T/home/.no-mistakes/config.yaml" >/dev/null; [ "$before" = "$(sha256sum "$T/home/.no-mistakes/config.yaml")" ]; echo 'PASS pipeline-quota-failover atomic install and uninstall'

# The pre-rename install (~/.local/share/fm-pipeline-quota-failover) is this step's own wiring: the first run moves the key
# to the current wrapper with a backup, the second is a no-op, and a wrapper from anywhere else is still refused untouched.
C=$T/legacy/pipeline.yaml; old=$T/home/.local/share/fm-pipeline-quota-failover/pi-quota-failover; new=$T/home/.local/share/jg-pipeline-quota-failover/pi-quota-failover
mkdir -p "$T/legacy"; printf 'keep: yes\nagent_path_override:\n  pi: %s\n# trailing comment\n' "$old" > "$C"
"${E[@]}" "$A/wiring.sh" --dry-run --config "$C" | grep -q 'would move key agent_path_override.pi from the pre-rename'
"${E[@]}" "$A/wiring.sh" --config "$C" | grep -q "^moved key agent_path_override.pi from the pre-rename $old to $new"
[ "$(cat "$C")" = "$(printf 'keep: yes\nagent_path_override:\n  pi: %s\n# trailing comment' "$new")" ] && [ -x "$new" ]
grep -q "pi: $old" "$C".bak-pqf-*
before=$(sha256sum < "$C"); "${E[@]}" "$A/wiring.sh" --config "$C" | grep -q "^key agent_path_override.pi already $new; config unchanged"; [ "$before" = "$(sha256sum < "$C")" ]
printf 'agent_path_override:\n  pi: /opt/someone-else/pi\n' > "$C"; before=$(sha256sum < "$C")
if "${E[@]}" "$A/wiring.sh" --config "$C" 2>"$T/err"; then echo 'FAIL a foreign wrapper must be refused' >&2; exit 1; fi
grep -q 'refusing to replace it' "$T/err" && [ "$before" = "$(sha256sum < "$C")" ]; echo 'PASS pipeline-quota-failover adopts its pre-rename wrapper and refuses a foreign one'
