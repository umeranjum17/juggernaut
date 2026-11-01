#!/usr/bin/env bash
# Durable alert ledger: the wake queue forgets a row once it is handled, so each
# call records the rows now queued and stamps the ones that left it as cleared.
# Usage: fleet-alerts-ledger.sh <home> [--now <epoch>]
# Writes <home>/data/metrics/alerts.tsv (raised, seq, kind, key, cleared).
# Precision is the call cadence: a row raised and cleared between calls is missed.
set -euo pipefail
[ "$#" -ge 1 ] || { echo 'usage: fleet-alerts-ledger.sh <home> [--now <epoch>]' >&2; exit 2; }
home=$1; now=$(date +%s)
[ "${2:-}" != --now ] || now=${3:?--now needs an epoch}
queue=$home/state/.wake-queue ledger=$home/data/metrics/alerts.tsv
mkdir -p "$home/data/metrics"
[ -f "$ledger" ] || printf 'raised\tseq\tkind\tkey\tcleared\n' > "$ledger"
[ -f "$queue" ] || : > "$queue"
tmp=$(mktemp "$ledger.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
awk -F '\t' -v OFS='\t' -v now="$now" '
  FILENAME == ARGV[1] { if (NF >= 5) q[$1 FS $2] = 1; next }
  FNR == 1 { print; next }
  { if ($5 == "" && !(($1 FS $2) in q)) $5 = now; print }' "$queue" "$ledger" > "$tmp"
awk -F '\t' -v OFS='\t' 'FILENAME == ARGV[1] { seen[$1 FS $2] = 1; next }
  NF >= 5 && $3 != "heartbeat" && !(($1 FS $2) in seen) { print $1, $2, $3, $4, "" }' \
  "$ledger" "$queue" >> "$tmp"
cat "$tmp" > "$ledger"
