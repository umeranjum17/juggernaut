#!/usr/bin/env bash
# Root AGENTS.md is the all pack plus Main's pack: under 200 lines and 24 KiB.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
test "$(wc -l < AGENTS.md)" -lt 200 && test "$(wc -c < AGENTS.md)" -le 24576
