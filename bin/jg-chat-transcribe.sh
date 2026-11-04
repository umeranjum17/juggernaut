#!/usr/bin/env bash
# jg-chat-transcribe.sh - the local speech-to-text engine behind the chat gateway's voice notes.
#
# Usage:
#   jg-chat-transcribe.sh setup     install the engine under state/captain-chat/stt (the owner's choice, never run
#                                   by install or session start); downloads about 72 MB (Hex) and 730 MB (model)
#   jg-chat-transcribe.sh run <wav> print the words in a 16 kHz mono wav on stdout, nothing else
#   jg-chat-transcribe.sh status    say whether the engine is installed
#
# The engine is Hex (github.com/anomalyco/hex, MIT) with its Parakeet Unified English model (NVIDIA Open
# Model License), run on the CPU through its headless `hex model transcribe`. Nothing leaves this machine.
# The binary is pinned to one release and checked against its sha256; Hex checks the model itself.
# Everything lives in state/captain-chat/stt, which git ignores; Hex writes nowhere else.
# Linux x64 only. The gateway (core/bus/cmd/jg-bus/gateway_transcribe.go) owns conversion, limits and the note line.
set -euo pipefail

VERSION=3.3.0
SHA256=e8c7b3a2ebeb1d7da5d6276d5f25145891d52178e3636347cb3ac331f7662622
URL="https://github.com/anomalyco/hex/releases/download/v${VERSION}/hex-${VERSION}-linux-x64"

home=${JG_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
dir=${JG_STATE_OVERRIDE:-$home/state}/captain-chat/stt
hex=$dir/hex

hexrun() {
  HEX_APPLICATION_SUPPORT_DIR=$dir/data XDG_CONFIG_HOME=$dir/xdg-config XDG_DATA_HOME=$dir/xdg-data \
    XDG_CACHE_HOME=$dir/xdg-cache VK_LOADER_DRIVERS_DISABLE='*' "$hex" "$@"
}

case "${1:-}" in
setup)
  [[ $(uname -sm) == "Linux x86_64" ]] || { echo "jg-chat-transcribe: only Linux x64 is supported" >&2; exit 1; }
  umask 077
  mkdir -p "$dir/data"
  if ! [[ -x $hex ]]; then
    curl -fL --progress-bar -o "$hex.part" "$URL"
    echo "$SHA256  $hex.part" | sha256sum -c --status || { rm -f -- "$hex.part"; echo "jg-chat-transcribe: checksum mismatch" >&2; exit 1; }
    chmod 700 "$hex.part" && mv "$hex.part" "$hex"
  fi
  echo '{"transcription_device":"cpu"}' >"$dir/data/settings.json"
  hexrun model install
  echo "jg-chat-transcribe: ready. Voice notes sent to the chat gateway are now transcribed."
  ;;
run)
  [[ -x $hex && -f ${2:-} ]] || exit 1
  hexrun model transcribe "$2"
  ;;
status)
  if [[ -x $hex ]] && hexrun model status >/dev/null 2>&1; then echo "installed ($dir)"; else echo "not installed"; exit 1; fi
  ;;
*)
  sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
  ;;
esac
