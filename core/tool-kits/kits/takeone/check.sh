#!/usr/bin/env bash
# takeone kit check: one shell check on TakeOne's own run record, the receipt and the card. No model.
# Usage: check.sh <task kit folder> <board file> <card json>
# Prints `PASS - <what was checked>` and exits 0, or prints `refused: <reason>` and exits 1.
set -u
k=${1:?kit folder} board=${2:?board file} card=${3:?card json}
rec=$k/record
no() { echo "refused: $*"; exit 1; }
out=$(jq -r '.out // empty' "$rec/render.json" 2>/dev/null) || no "no readable render.json in the saved record"
frames=$(jq -r '.frames // 0' "$rec/render.json"); fps=$(jq -r '.fps // 0' "$rec/render.json")
[ -n "$out" ] && [ "$frames" -gt 0 ] && [ "$fps" -gt 0 ] || no "render.json names no film, frames or frame rate"
jq -e '.motion.storyboard' "$rec/take.json" >/dev/null 2>&1 || no "the saved take is not a motion take: take.json has no motion section"
film=$(jq -r --arg o "$out" '.files[]? | select(.path == $o) | .sha256' "$k/receipt.json")
[ -n "$film" ] || no "the receipt does not list the film $out that render.json names"
media=$(jq -r --arg h "$film" '.media[]? | select(.sha256 == $h) | .path' "$card" | head -n 1)
[ -n "$media" ] || no "the card holds another film: no media on it has the receipt's film hash"
copy=$(dirname "$board")/$media
[ -s "$copy" ] || no "the card's film $media is missing beside the board"
[ "$(sha256sum "$copy" | cut -d' ' -f1)" = "$film" ] || no "the card's film on disk differs from the card's own hash"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$copy") || no "ffprobe cannot read the card's film"
agree() { awk -v d="$1" -v f="$frames" -v p="$fps" 'BEGIN { x = d - f / p; exit ((x < 0 ? -x : x) <= 0.1) ? 0 : 1 }'; }
agree "$dur" || no "the film runs ${dur}s and render.json says $frames frames at $fps fps"
agree "$(jq -r --arg o "$out" '.files[] | select(.path == $o) | .seconds // 0' "$k/receipt.json")" || no "the receipt's measured film length disagrees with render.json"
echo "PASS - $out ${dur}s, $frames frames at $fps fps, on card $(jq -r .key "$card")"
