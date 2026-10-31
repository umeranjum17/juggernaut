#!/usr/bin/env bash
# Drive merge-card's public check command with isolated pool and judge boundaries.
# done-done supplies the capture folder; no real account or board is changed.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run under done-done}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/home/config" "$work/home/data/Umer" "$work/config" "$work/wt"
export JG_HOME=$work/home DONE_DONE_HOME=$work/config
export PATH="$work/bin:$PATH"
cat >"$work/bin/pool" <<'POOL'
#!/usr/bin/env bash
echo 'no Claude account can take a worker' >&2
exit 1
POOL
cat >"$work/bin/pi" <<'PI'
#!/usr/bin/env bash
echo 'commandcode deepseek/deepseek-v4.1-flash 262K'
PI
cat >"$work/bin/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
echo '  codex,all_models,10,unknown'
QUOTA
cat >"$work/bin/done-done" <<'DD'
#!/usr/bin/env bash
case $1 in
  --version) echo 0.6.12 ;;
  check)
    [ "${2:-}" != --help ] || { echo '--citation-base'; exit 0; }
    model=$(python3 -c 'import os,yaml; print(yaml.safe_load(open(os.environ["DONE_DONE_HOME"]+"/config.yaml"))["judge"]["model"])')
    echo "judge boundary: $* model=$model" >>"$JUDGE_LOG"
    if [ "${SOL_LIMIT:-0}" = 1 ] && [ "$model" = openai-codex/gpt-6.1-sol ]; then
      echo '{"error":"429 quota exhausted"}'; exit 2
    fi
    echo '{"claim":"Umer can check a merge with a dry Claude pool","result":"pass","evidence":[]}' ;;
esac
DD
chmod +x "$work/bin/"*
printf 'command=%s\nstate=%s\n' "$work/bin/pool" "$work/pool" >"$JG_HOME/config/account-pool"
printf 'judge:\n  route: answerer:pi\n  model: openai-codex/gpt-6.1-sol\n' >"$DONE_DONE_HOME/config.yaml"
export JUDGE_LOG=$work/judges
: >"$JUDGE_LOG"
{
  echo 'Target: real merge-card check; fixture pool and done-done judge boundary (no hosted inference).'
  echo 'Start: Claude pool returns no account can take a worker.'
  echo 'Action: merge-card check --judge answerer:pi Umer <isolated worktree> HEAD -'
  bash "$repo/merge-card/merge-card" check --judge answerer:pi Umer "$work/wt" HEAD -
  test "$(jq -r .verdict "$JG_HOME/data/Umer/merge-card.json")" = pass
  echo 'Action: merge-card check Umer <isolated worktree> HEAD - (Sol quota error)'
  SOL_LIMIT=1 bash "$repo/merge-card/merge-card" check Umer "$work/wt" HEAD -
  test "$(jq -r .verdict "$JG_HOME/data/Umer/merge-card.json")" = pass
  cat "$JUDGE_LOG"
  grep -q 'model=commandcode/deepseek/deepseek-v4.1-flash' "$JUDGE_LOG"
  echo 'PASS: explicit non-Claude and dry-pool Sol-to-Goat checks complete.'
} >"$evidence/merge-card-transcript.txt" 2>&1
jq -n '{target:{version:"merge-card check"},start:"Isolated home with a dry Claude pool; fixture judge boundary, no inference.",steps:["Run merge-card check with an explicit answerer:pi judge.","Run merge-card check without a route, reject Sol with a quota error, and answer on listed Command Code DeepSeek.","Read saved pass verdicts and judge invocations."],result:"Both merge checks pass despite a dry Claude pool; fallback tries Sol then Goat without changing global config."}' >"$evidence/steps.json"
