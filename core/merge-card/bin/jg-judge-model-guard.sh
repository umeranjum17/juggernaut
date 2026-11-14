#!/usr/bin/env bash
# jg-judge-model-guard.sh - refuse an expensive done-done judge model before any model call.
#
# Usage:
#   jg-judge-model-guard.sh [--judge <route-or-model>] [--tool-model <model>] [--config <config.yaml>]
#
# The done-done judge always runs on a cheap model, never a Fable or Opus one. The models it
# looks at are judge.model in the done-done config (default $DONE_DONE_HOME/config.yaml or
# ~/.done-done/config.yaml), the model the done-done-judge entry of config/tool-models.json
# names (passed as --tool-model), and the --judge value. Prints nothing and exits 0 when none is
# expensive; otherwise prints one line naming the model, where it was set and the cheap model to
# set, and exits 1. It never calls a model. merge-card and the bootstrap check both call it.
set -u
CHEAP_JUDGE_MODEL=claude-haiku-5-5
judge='' tool_model='' config=${DONE_DONE_HOME:-$HOME/.done-done}/config.yaml
while [ $# -gt 0 ]; do
  case $1 in
    --judge) judge=${2:-}; shift 2 ;;
    --tool-model) tool_model=${2:-}; shift 2 ;;
    --config) config=${2:-}; shift 2 ;;
    *) echo "jg-judge-model-guard: unknown argument $1" >&2; exit 2 ;;
  esac
done
cfg_model=$(python3 - "$config" <<'PY'
import sys, yaml
try:
    j = (yaml.safe_load(open(sys.argv[1])) or {}).get('judge') or {}
except FileNotFoundError:
    j = {}
print(j.get('model') or '')
PY
) || { echo "jg-judge-model-guard: cannot read $config" >&2; exit 2; }
rc=0
for pair in "--judge:$judge" "tool-models (done-done-judge):$tool_model" "judge.model in $config:$cfg_model"; do
  where=${pair%%:*} model=${pair#*:}
  case $(printf '%s' "$model" | tr '[:upper:]' '[:lower:]') in
    *fable*|*opus*)
      echo "done-done judge model $model ($where) is refused: the judge runs on a cheap model, never Fable or Opus; set $CHEAP_JUDGE_MODEL"
      rc=1 ;;
  esac
done
exit $rc
