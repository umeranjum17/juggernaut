#!/usr/bin/env bash
# Put the receipt a task published for one head back into its single slot.
# Usage: jg-receipt-restore.sh <state-dir> <task-id> <head>
# One slot per task (state/<id>.run-receipt.json) holds only the newest receipt, so a lane that lands several
# pull requests had to republish by hand before each one. jg-run-receipt.sh also keeps the newest receipt for
# each head it published (state/<id>.run-receipt.<head>.json); this copies that file into the slot when the slot
# names another head. It judges nothing: acceptance still reads the restored receipt against its own rules (PASS,
# this head, this spawn generation, this pull request), and a later FAIL for the head is the newest file for it.
# Prints "restored" when it changed the slot. Exit 0 when nothing needed restoring or nothing is archived.
set -u
[ "$#" -eq 3 ] || { echo "usage: jg-receipt-restore.sh <state-dir> <task-id> <head>" >&2; exit 2; }
state=$1 id=$2 head=$3
case $id in ''|*/*|.*) exit 0 ;; esac
case $head in *[!0-9a-f]*|'') exit 0 ;; esac
[ "${#head}" -eq 40 ] || exit 0
slot=$state/$id.run-receipt.json
arch=$state/$id.run-receipt.$head.json
[ -f "$arch" ] && [ ! -L "$arch" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ "$(jq -r --arg t "$id" --arg h "$head" 'select(.task == $t and .head == $h) | .head' "$arch" 2>/dev/null)" = "$head" ] || exit 0
if [ -f "$slot" ] && [ ! -L "$slot" ] && [ "$(jq -r '.head // ""' "$slot" 2>/dev/null)" = "$head" ]; then exit 0; fi
[ ! -L "$slot" ] || exit 0
umask 077
tmp=$(mktemp "$state/.$id.run-receipt.XXXXXX") || exit 0
if cp -- "$arch" "$tmp" && mv -f -- "$tmp" "$slot"; then echo restored; else rm -f -- "$tmp"; fi
exit 0
