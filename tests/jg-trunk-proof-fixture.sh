#!/usr/bin/env bash
# shellcheck shell=bash
# The proof a local-trunk landing reads at a lane's exact head (`jg-trunk.sh proof`), written by hand for a fixture lane.
# Source it from a suite that lands a lane; it runs nothing by itself.

# jg_test_trunk_proof <task-data-dir> <head> card|seal
# One input of that proof besides the completion receipt: the merge-card's approved evidence that cites a file, or a
# sealed clean done-done run holding it.
jg_test_trunk_proof() {
  local d=$1 h=$2
  mkdir -p "$d/.done-done/runs"
  case $3 in
    card) printf '{"head":"%s","verdict":"pass","check":{"claim":"a user can land","evidence":["%s/run.log"]}}\n' "$h" "$d" > "$d/merge-card.json" ;;
    seal) printf 'ok\n' > "$d/run.log"
      printf '{"schema":1,"run_id":"20261109T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-09T00:00:00Z","files":["run.log"]}\n' "${h:0:8}" "$h" > "$d/.done-done/runs/run-$h.json" ;;
  esac
}
