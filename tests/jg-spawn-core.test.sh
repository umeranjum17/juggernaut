#!/usr/bin/env bash
# The spawn decision core, proved through the dispatcher bin/jg-spawn.sh calls: bin/jg-spawn-core.sh
# builds the Go command on first use. The expected answers are the shell functions' own, pinned by
# the parity replay in core/spawn/README.md; this suite keeps the shapes that replay found interesting.
# Usage: tests/jg-spawn-core.test.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
lab=$(mktemp -d "${TMPDIR:-/tmp}/jg-spawn-core.XXXXXX")
trap 'rm -rf -- "$lab"' EXIT
export JG_STATE_OVERRIDE=$lab/state TMPDIR=$lab
if ! command -v "${JG_SPAWN_CORE_GO:-go}" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH; install go to build the spawn core\n'
  exit 0
fi
core=$ROOT/bin/jg-spawn-core.sh
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok: %s\n' "$1"; else printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
rc() { "$@" >/dev/null 2>&1; echo $?; }
# head_is: the output of the command on stdin starts with the given text, printed back whole when it does.
head_is() { local want=$1 got; got=$(cat); case "$got" in "$want"*) printf %s "$want" ;; *) printf %s "$got" ;; esac; }

check "claude takes a quoted model" "$("$core" model-flag claude sonnet)" "--model 'sonnet' "
check "the default model adds nothing" "$("$core" model-flag claude default)|$("$core" model-flag claude '')" "|"
check "an unverified harness gets no model flag" "$("$core" model-flag bogus sonnet)" ""
check "a quote in the model is closed and reopened" "$("$core" model-flag pi "it's")" "--model 'it'\\''s' "
check "claude maps every shared level" "$("$core" effort-flag claude max x)" "--effort 'max' "
check "codex max is scoped to the model that advertises it" "$("$core" effort-flag codex max gpt-5.6-luna)|$("$core" effort-flag codex max other)" "-c 'model_reasoning_effort=\"max\"' |"
check "grok omits the levels it rejects" "$("$core" effort-flag grok high x)|$("$core" effort-flag grok xhigh x)" "--reasoning-effort 'high' |"
check "muse maps max onto its ultra" "$("$core" effort-flag muse max x)" "--reasoning-effort 'ultra' "
check "kimi and cursor never receive an effort flag" "$("$core" effort-flag kimi high x)$("$core" effort-flag cursor high x)" ""
check "opencode puts the effort in the config JSON for a provider that exposes it" "$("$core" effort-flag opencode high 'anthropic/claude-opus-5-5')" ',"agent":{"build":{"model":"anthropic/claude-opus-5-5","variant":"high"}}'
check "opencode omits an effort its provider lacks, and an unresolved model" "$("$core" effort-flag opencode xhigh 'anthropic/x')$("$core" effort-flag opencode high default)" ""
check "an unknown effort word adds nothing" "$("$core" effort-flag claude bogus x)" ""
check "pi ultra without a model it can validate stops the spawn" "$(rc "$core" effort-flag --harness-script "$ROOT/bin/jg-harness.sh" pi ultra gpt-5)" 1
check "rigor ranks no-mistakes over direct-PR over local-only" "$("$core" rigor-rank no-mistakes)$("$core" rigor-rank direct-PR)$("$core" rigor-rank local-only)$("$core" rigor-rank other)" 3210

brief=$lab/brief.md
printf 'intro\nDelivery contract: mode=direct-PR forge=github upstream-consent=github.com/o/r\nShip branch: fm/t1\n' > "$brief"
agree() { "$core" delivery-agree --id t1 --mode direct-PR --yolo off --branch fm/t1 --relaunch=0 --upstream-consent github.com/o/r --brief "$brief" --source-brief "$brief" --project proj --standing-forge github "$@"; }
check "a brief that agrees with the spawn passes" "$(rc agree)" 0
check "a mode mismatch is refused by name" "$(agree --mode no-mistakes 2>&1 | head_is "error: delivery mismatch for t1: the brief says mode=direct-PR")" "error: delivery mismatch for t1: the brief says mode=direct-PR"
check "a branch mismatch is refused" "$(agree --branch fm/other 2>&1 | head_is "error: branch mismatch for t1: the brie")" "error: branch mismatch for t1: the brie"
check "a consent mismatch names none for an absent token" "$(agree --upstream-consent '' 2>&1 | grep -o 'passed none')" "passed none"
check "a forge mismatch tells how to re-scaffold" "$(agree --standing-forge none 2>&1 | grep -o 're-scaffold it with jg-brief.sh t1 proj --mode direct-PR,')" "re-scaffold it with jg-brief.sh t1 proj --mode direct-PR,"
check "yolo on is refused on gerrit" "$(sed -i 's/forge=github/forge=gerrit/' "$brief"; agree --standing-forge gerrit --yolo on 2>&1 | head_is "error: --yolo on is refused for t1: pr")" "error: --yolo on is refused for t1: pr"
check "yolo off on gerrit passes" "$(rc agree --standing-forge gerrit)" 0
printf 'Delivery contract: mode=direct-PR\n' > "$brief"
check "a brief with no Ship branch line warns on the legacy branch" "$(agree --upstream-consent '' --standing-forge none 2>&1 | head_is "warning: $brief records no ship")" "warning: $brief records no ship"
check "a relaunch accepts the recorded branch" "$(agree --upstream-consent '' --standing-forge none --branch fm/x --relaunch=1 2>&1 | grep -o 'relaunching on the task.s recorded branch fm/x')" "relaunching on the task's recorded branch fm/x"
check "a missing brief stops the spawn" "$(rc agree --brief "$lab/none.md")" 1

notices() { "$core" delivery-notices --id t1 --mode local-only --branch fm/t1 --project proj "$@" 2>&1; }
check "dropping below the standing posture is announced" "$(notices --standing-mode no-mistakes --standing-branch fm/ | head_is "notice: t1 ships mode=local-only while the standing posture for proj is no-mistakes")" "notice: t1 ships mode=local-only while the standing posture for proj is no-mistakes"
check "a conditional policy raises no notice" "$(notices --standing-mode no-mistakes-prod-only --standing-branch fm/)" ""
check "a registered prefix the branch lacks is announced" "$(notices --standing-mode '' --standing-branch x/ | head_is "notice: t1 ships branch=fm/t1 while proj registers the ship-bra")" "notice: t1 ships branch=fm/t1 while proj registers the ship-bra"

# The argument grammar: the dispatcher prints the parsed variables for the spawn to eval, or the
# refusal that stops it. These keep the shapes the intake replay (core/spawn/README.md) found interesting.
intake() { "$core" intake "$@" 2>&1; }
var() { sed -n "s/^$1=//p" | head -1; }
check "a ship request is parsed into the spawn's variables" "$(intake t1 proj --mode direct-PR --yolo off --harness=claude | var MODE)|$(intake t1 proj --mode direct-PR --yolo off --harness=claude | var HARNESS_ARG)|$(intake t1 proj --mode direct-PR --yolo off | var POS)" "'direct-PR'|'claude'|('t1' 'proj')"
check "a value flag followed by another flag is refused" "$(intake --model --mode x)" "error: --model requires a value"
check "a flag with no value at the end is refused" "$(intake t1 --backend)" "error: --backend requires a value"
check "an empty value is refused by name" "$(intake t1 --effort=)" "error: --effort requires a non-empty value"
check "an unknown effort is refused" "$(intake t1 --effort turbo)" "error: --effort must be one of low, medium, high, xhigh, max, ultra"
check "the last repeat of a flag wins" "$(intake t1 p --mode local-only --yolo off --mode direct-PR | var MODE)" "'direct-PR'"
check "a traceparent is accepted only on a squad_lead" "$(intake t1 --traceparent 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01 | head -1)" "error: --traceparent applies only to --squad-lead spawns; every other spawn resolves its own carrier from this home's frozen trace-context decision"
check "an all-zero traceparent is refused" "$(intake --squad-lead t1 --traceparent 00-00000000000000000000000000000000-b7ad6b7169203331-01)" "error: --traceparent is not a valid W3C traceparent"
check "a ship without a mode is held for the spawn to refuse after the account check" "$(intake t1 proj | var INTAKE_REFUSAL | head_is "'error: ship spawns require --mode")" "'error: ship spawns require --mode"
check "no-mistakes-prod-only is not a task mode" "$(intake t1 proj --mode no-mistakes-prod-only --yolo off | var INTAKE_REFUSAL | head_is "'error: no-mistakes-prod-only is a registry policy")" "'error: no-mistakes-prod-only is a registry policy"
check "an upstream consent is folded to lower case" "$(intake t1 proj --mode direct-PR --yolo off --upstream-consent GitHub.com/O/R | var UPSTREAM_CONSENT)" "'github.com/o/r'"
check "an upstream consent with a dot-dot is refused" "$(intake t1 proj --mode direct-PR --yolo off --upstream-consent a/../c | var INTAKE_REFUSAL)" "'error: --upstream-consent must be <host>/<owner>/<repo> (got '\\''a/../c'\\'')'"
check "a relaunch may not restate the recorded mode" "$(intake --relaunch t1 --mode direct-PR | var INTAKE_REFUSAL)" "'error: --relaunch reuses the task'\\''s recorded delivery mode; --mode cannot override it'"
check "a scout may not carry a mode" "$(intake --scout t1 proj --mode direct-PR | var INTAKE_REFUSAL | head_is "'error: --mode applies only to ship spawns")" "'error: --mode applies only to ship spawns"
check "a squad_lead may not carry a base branch, a scout may" "$(intake --squad-lead t1 --base-branch x | var INTAKE_REFUSAL | head_is "'error: --base-branch applies only")|$(intake --scout t1 proj --base-branch x | var INTAKE_REFUSAL)" "'error: --base-branch applies only|''"
check "an off-critical-path decision is parsed for a ship" "$(intake t1 proj --mode direct-PR --yolo off --off-critical-path "captain: run it" | var OFF_CRITICAL_PATH)|$(intake t1 proj --mode direct-PR --yolo off --off-critical-path "captain: run it" | var OFF_CRITICAL_PATH_SET)" "'captain: run it'|'1'"
check "an empty off-critical-path decision is refused" "$(intake t1 proj --mode direct-PR --yolo off --off-critical-path=)" "error: --off-critical-path requires the captain's words as a non-empty value"
check "a relaunch may not restate the critical-path decision" "$(intake --relaunch t1 --off-critical-path x | var INTAKE_REFUSAL)" "'error: --relaunch reuses the task'\\''s recorded critical-path decision; --off-critical-path cannot override it'"
check "a scout may not carry a critical-path decision" "$(intake --scout t1 proj --off-critical-path x | var INTAKE_REFUSAL | head_is "'error: --off-critical-path applies only to ship spawns")" "'error: --off-critical-path applies only to ship spawns"
check "a quote in a positional survives the round trip" "$(eval "$("$core" intake "it's here" proj)"; printf %s "${POS[0]}")" "it's here"

# The launch builders: the grants and settings that depend only on the task's own directories, the
# home's identity, the model and the launch-env allow-list.
mkdir -p "$lab/b/state" "$lab/b/data" "$lab/b/code/.agents/skills"
b=$(cd "$lab/b" && pwd -P)
check "rovo gets one override with the effort and exactly the task's three paths" "$("$core" rovo-override high "$lab/b/data" "$lab/b/state" t1)" "--config-override '{\"agent\":{\"efficiencyLevel\":\"high\"},\"toolPermissions\":{\"allowedExternalPaths\":[\"$b/data/t1\",\"$b/state/t1.inbox\",\"$b/state/t1.status\"]}}' "
check "rovo omits an effort it cannot take" "$("$core" rovo-override ultra "$lab/b/data" "$lab/b/state" t1 | grep -c efficiencyLevel)" 0
check "rovo with a data directory that does not exist stops" "$(rc "$core" rovo-override high "$lab/b/none" "$lab/b/state" t1)" 1
check "claude is granted this task's channel directories and they are made" "$("$core" claude-add-dirs ship "$lab/b/state" "$lab/b/data" "$lab/b/code" t1)|$(test -d "$b/state/t1.inbox/handled" && test -d "$b/data/t1" && echo made)" "--add-dir '$b/state/operational-inbox' --add-dir '$b/state/t1.inbox' --add-dir '$b/data/t1' --add-dir '$b/code/.agents/skills' |made"
check "a squad_lead is granted its steering inbox and the parent's pending replies" "$("$core" claude-add-dirs squad_lead "$lab/b/state" "$lab/b/data" "$lab/b/code" t2)" "--add-dir '$b/state/t2.inbox' --add-dir '$b/state/pending-replies' "
check "a code root with no skills directory stops the claude grant" "$(rc "$core" claude-add-dirs ship "$lab/b/state" "$lab/b/data" "$lab/b" t1)" 1
mkdir -p "$lab/b/lead"
"$core" opencode-lead-grant "$lab/b/lead" "$lab/b/state" t3 "$lab/b/code"
check "an opencode squad_lead's grant allows its channels and denies edits to the parent's tooling" "$(grep -o '"edit":{.*' "$lab/b/lead/.opencode/opencode.json")" '"edit":{"*/code/bin/**":"deny","*/code/docs/**":"deny","*/code/.agents/skills/**":"deny"}}}'
tok=$("$core" launch-home-token "$lab/b")
check "the home token is a sha-256 of the physical path" "${#tok}" 64
check "opencode on the console provider and with no model keeps the shared store" "$("$core" opencode-db "$tok" t1 opencode/gpt-5)$("$core" opencode-db "$tok" t1 '')$("$core" opencode-db "$tok" t1 default)" ""
check "opencode on another provider takes its own store named by home and task" "$("$core" opencode-db "$tok" t1 openai/gpt-5)" "OPENCODE_DB='juggernaut-${tok:0:12}-t1.db' "
mkdir -p "$lab/xdg/opencode"
check "opencode on a Go model without a key in auth.json keeps the shared store" "$(XDG_DATA_HOME=$lab/xdg "$core" opencode-db "$tok" t1 opencode-go/glm-5)" ""
printf '{"opencode-go":{"type":"api"}}\n' > "$lab/xdg/opencode/auth.json"
check "opencode on a Go model with a key in auth.json takes its own store" "$(XDG_DATA_HOME=$lab/xdg "$core" opencode-db "$tok" t1 opencode-go/glm-5)" "OPENCODE_DB='juggernaut-${tok:0:12}-t1.db' "
printf '# keys\n\nFOO\nBAR_2\n' > "$lab/allow"
check "the launch-env allow-list yields its names and skips blanks and comments" "$("$core" launch-env-names "$lab/allow" | tr '\n' ' ')" "FOO BAR_2 "
printf 'FOO\nA-B\n' > "$lab/bad-allow"
check "an allow-list with a bad name is refused with 1" "$(rc "$core" launch-env-names "$lab/bad-allow")" 1
check "the strip walks the pane's own exported names, not the spawner's" "$("$core" launch-env-strip '' | grep -c 'env | sed -n')" 1
check "the strip names no credential name the spawning process happens to hold" "$(JG_T_API_KEY=x "$core" launch-env-strip '' | grep -c JG_T_API_KEY)" 0
check "an allow-listed credential is the one name the strip carries" "$("$core" launch-env-strip $'JG_U_API_KEY\n' | grep -cF 'JG_U_API_KEY) ;;')" 1
check "a filtered launch forwards names by reference and ends in the quoted launch" "$(printf %s "it's" | "$core" launch-env-wrap FOO 1 | sed 's/.* COMPACT_ADVISER_DISABLE=1//')" " \${TRACEPARENT+\"TRACEPARENT=\$TRACEPARENT\"} /bin/sh -c 'it'\\''s'"

# The launch templates: the verified command per adapter, with its placeholders, by kind.
check "a claude ship worker is launched with the dialog tool off and the worker statement" "$("$core" launch-template claude ship | grep -o -e '--disallowedTools=AskUserQuestion' -e 'You are a task worker launched by Juggernaut' | wc -l)" 2
check "a claude squad_lead gets neither" "$("$core" launch-template claude squad_lead | grep -c -e AskUserQuestion -e 'task worker')" 0
# The Claude tool part: a worker and a lead are launched without the tools they may not use, and with
# no MCP server, so the account's connectors (mail, file sharing, calendar, documents) never load.
deny_of() { "$core" launch-template claude "$1" | sed -n 's/.*--disallowedTools=\([^ ]*\) .*/\1/p'; }
worker_deny=AskUserQuestion,Artifact,Workflow,Agent,ScheduleWakeup,ReportFindings,ListAgents,Monitor,CronCreate,CronDelete,CronList,RemoteTrigger,SendMessage,EnterWorktree,ExitWorktree,PushNotification,DesignSync
check "a claude ship and a Recon worker deny the dialog, fan-out, publish and notify tools" "$(deny_of ship)|$(deny_of scout)" "$worker_deny|$worker_deny"
check "every claude kind loads no MCP server, so no account connector" "$(for k in ship scout squad_lead; do "$core" launch-template claude "$k" | grep -c -e ' --strict-mcp-config '; done | tr '\n' ' ')" "1 1 1 "
check "no claude kind denies a tool a task works with" "$(for k in ship squad_lead; do deny_of "$k" | tr ',' '\n'; done | grep -cx -e Bash -e Read -e Edit -e Write -e Glob -e Grep -e Skill -e ToolSearch -e WebFetch -e WebSearch -e TaskOutput -e TaskStop -e NotebookEdit)" 0
# The lead's list is the delegation guard's own: in a marked squad_lead home the guard refuses every
# name on it but Artifact, the one addition, and lets Artifact and the tools it leaves open through.
mkdir -p "$lab/lg/bin" "$lab/lg/state"; : > "$lab/lg/AGENTS.md"; printf 'lead1\n' > "$lab/lg/.jg-squad-lead-home"
guard() { env -u JG_ALLOW_SUBAGENT JG_ROOT_OVERRIDE="$lab/lg" JG_HOME="$lab/lg" JG_STATE_OVERRIDE="$lab/lg/state" bash "$ROOT/bin/jg-subagent-pretool-check.sh" --claude --tool "$1" 2>/dev/null; echo "$?"; }
lead_deny=$(deny_of squad_lead)
check "a claude squad_lead denies the guard's delegation tools and Artifact" "$lead_deny" "Artifact,Agent,Task,ListAgents,Workflow,ScheduleWakeup,CronCreate,CronDelete,RemoteTrigger,SendMessage,EnterWorktree,ExitWorktree,Monitor"
check "the guard refuses every lead-denied name but Artifact" "$(for t in $(printf %s "$lead_deny" | tr ',' ' '); do [ "$t" = Artifact ] || printf '%s=%s ' "$t" "$(guard "$t")"; done | tr ' ' '\n' | grep -vc '=2$')" 0
check "the guard lets Artifact and the observe and plan tools through, so the lead keeps those" "$(for t in Artifact TaskStop TaskOutput CronList TaskCreate; do guard "$t"; done | tr '\n' ' ')" "0 0 0 0 0 "
check "a codex worker disables hooks and a codex squad_lead keeps them" "$("$core" launch-template codex scout | grep -c -e '--disable hooks')|$("$core" launch-template codex squad_lead | grep -c -e '--disable hooks')" "1|0"
check "an opencode worker denies the question tool and a squad_lead keeps it" "$("$core" launch-template opencode ship | grep -cF 'question":"deny')|$("$core" launch-template opencode squad_lead | grep -cF 'question":"deny')" "1|0"
check "pi and pi-signed share one template" "$("$core" launch-template pi ship)" "$("$core" launch-template pi-signed ship)"
check "a name that is not a verified adapter prints nothing and exits 1" "$("$core" launch-template bogus ship)|$(rc "$core" launch-template bogus ship)" "|1"
check "no kind means a ship" "$("$core" launch-template grok)" "$("$core" launch-template grok ship)"

# The checks a spawn makes before it creates anything: a squad_lead's home, and a worker's worktree.
mkdir -p "$lab/h/active/state" "$lab/h/repo/bin" "$lab/h/lead/bin" "$lab/h/lead/data" "$lab/h/lead/state" "$lab/h/lead/config" "$lab/h/lead/projects"
printf 'lead1\n' > "$lab/h/lead/.jg-squad-lead-home"; : > "$lab/h/lead/AGENTS.md"
hv() { "$core" home-validate "$1" "$2" "$lab/h/active" "$lab/h/repo" .jg-squad-lead-home 2>&1; }
hp=$(cd "$lab/h" && pwd -P)
check "a seeded squad_lead home passes and prints its physical path" "$(hv lead1 "$lab/h/lead")" "$hp/lead"
check "a home marked for another squad_lead is refused by name" "$(hv lead2 "$lab/h/lead")" "error: juggernaut home $lab/h/lead is marked for squad_lead lead1, expected lead2"
check "the active home cannot be a squad_lead's home" "$(hv lead1 "$lab/h/active")" "error: squad_lead home cannot be the active juggernaut home: $lab/h/active"
check "a directory inside the repository cannot be a squad_lead's home" "$(mkdir -p "$lab/h/repo/in"; hv lead1 "$lab/h/repo/in")" "error: squad_lead home cannot be inside the juggernaut repo: $lab/h/repo/in"
check "a home that does not exist is refused" "$(hv lead1 "$lab/h/none")" "error: juggernaut home does not exist or is not a directory: $lab/h/none"
check "a working directory that resolves outside the home is refused" "$(rm -rf "$lab/h/lead/data"; mkdir -p "$lab/h/elsewhere"; ln -s "$lab/h/elsewhere" "$lab/h/lead/data"; hv lead1 "$lab/h/lead")" "error: squad_lead data directory must resolve inside the squad_lead home: $lab/h/lead/data"
rm -f "$lab/h/lead/data"; mkdir "$lab/h/lead/data"
check "a home with no AGENTS.md is not a juggernaut home" "$(rm "$lab/h/lead/AGENTS.md"; hv lead1 "$lab/h/lead")" "error: $lab/h/lead is not a juggernaut home (missing AGENTS.md)"
git_lab=$lab/g; mkdir -p "$git_lab"
git -C "$git_lab" init -q P && git -C "$git_lab/P" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i && git -C "$git_lab/P" worktree add -q ../W && mkdir -p "$git_lab/W/sub" "$git_lab/plain"
gp=$(cd "$git_lab" && pwd -P)
iso() { "$core" worktree-isolated "$1" "$gp/P" "$gp/P"; echo "rc=$?"; }
check "a linked worktree of the project is isolated" "$(iso "$git_lab/W" | tail -1)" "rc=0"
check "the spawning project itself is refused by name" "$(iso "$git_lab/P" | grep REASON)" "SPAWN_WT_REASON='it is the spawning project itself'"
check "a subdirectory of a worktree is not a worktree root" "$(iso "$git_lab/W/sub" | grep -c "subdirectory of worktree root .*$gp/W.*not a worktree root")" 1
check "a directory in no repository is refused" "$(iso "$git_lab/plain" | grep REASON)" "SPAWN_WT_REASON='it is not inside a git worktree'"
check "a path that is not a directory is refused" "$(iso "$git_lab/none" | grep REASON)" "SPAWN_WT_REASON='it is not a readable directory'"

# A home whose bin/ is a symlink to a checkout (the session-start suite's fake root, a relocated home)
# builds from the checkout the link points into, not from a core/ the link's parent lacks.
mkdir -p "$lab/linked/root"
ln -s "$ROOT/bin" "$lab/linked/root/bin"
check "a symlinked bin/ still builds the core from the real checkout" "$(JG_STATE_OVERRIDE=$lab/linked/state "$lab/linked/root/bin/jg-spawn-core.sh" model-flag claude sonnet 2>&1)" "--model 'sonnet' "

# The dispatcher never turns a core that cannot run into an answer.
JG_SPAWN_CORE_BIN=$lab/none/jg-spawn-core JG_SPAWN_CORE_GO=$lab/no-such-go "$core" model-flag claude x >/dev/null 2>&1
check "no binary and no toolchain exits 2, not an answer" "$?" 2
check "an unknown command exits 2" "$(rc "$core" nonsense)" 2

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-spawn-core tests passed\n'
