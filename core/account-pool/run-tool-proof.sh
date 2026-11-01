#!/usr/bin/env bash
# Drive the installed done-done judge backend against a fixture Claude executable.
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
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
work=$(mktemp -d /var/tmp/pool-tool-proof.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home/config" "$work/profile" "$work/bin" "$work/dd"
export JG_HOME=$work/home DONE_DONE_HOME=$work/dd POOL_PROFILE=$work/profile
export POOL_JUDGE_LOG=$evidence/judge-env.txt
cat >"$work/bin/pick" <<'SH'
#!/usr/bin/env bash
jq -nc --arg f "$POOL_PROFILE" '{ok:true,id:"Umer",set:{CLAUDE_CONFIG_DIR:$f},unset:["ANTHROPIC_API_KEY","ANTHROPIC_AUTH_TOKEN"]}'
SH
cat >"$work/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$CLAUDE_CONFIG_DIR" >>"$POOL_JUDGE_LOG"
cat >/dev/null
printf '{"structured_output":{}}\n'
SH
chmod +x "$work/bin/"*
printf 'command=%s\nstate=%s\n' "$work/bin/pick" "$work" >"$JG_HOME/config/account-pool"
# shellcheck source=account-pool/bin/jg-pool-claude-env.sh
. "$repo/account-pool/bin/jg-pool-claude-env.sh"
jg_pool_claude_env
export FIXTURE_CLAUDE=$work/bin/claude
# Resolve the real installed package without reading its user config or credentials.
export DONE_DONE_DIST
DONE_DONE_DIST=$(dirname "$(readlink -f "$(command -v done-done)")")
node --input-type=module <<'JS'
import {pathToFileURL} from 'node:url';
const base=pathToFileURL(process.env.DONE_DONE_DIST+'/');
const {loadConfig}=await import(new URL('config.js',base));
const {backend}=await import(new URL('judge.js',base));
const cfg=loadConfig(process.env.JG_HOME,'app: pool-fixture\n');
cfg.agent_path_override.claude=process.env.FIXTURE_CLAUDE;
const questions={relevance:{kind:'choice',instructions:'Read the fixture',options:{yes:'yes',no:'no'}}};
const be=await backend(cfg,{route:'claude-code',agent:'claude',model:'claude-haiku-5-5'},()=>'',questions);
// A fixture answer is deliberately not a model verdict; this proves the child env.
try { await be.ask('fixture',questions,AbortSignal.timeout(10000),[]); } catch { /* env assertion below is mandatory */ }
JS
test "$(cat "$POOL_JUDGE_LOG")" = "$POOL_PROFILE"
printf 'PASS: real done-done judge child inherited the pool folder\n' | tee "$evidence/result.log"
cat >"$evidence/steps.json" <<'JSON'
{"target":{"version":"installed done-done judge backend and checkout pool helper"},"start":"isolated pool and Claude fixture, no login","steps":["pick account Umer through real helper","ask real judge backend using a stub Claude executable","assert child CLAUDE_CONFIG_DIR equals selected folder"],"result":"judge child inherits pool folder; no credential read and no live model requested"}
JSON
