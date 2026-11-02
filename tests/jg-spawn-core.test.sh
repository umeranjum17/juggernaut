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
check "a stripped credential is named and an allow-listed one is not" "$(env -i PATH="$PATH" JG_SPAWN_CORE_GO="${JG_SPAWN_CORE_GO:-go}" JG_STATE_OVERRIDE="$JG_STATE_OVERRIDE" JG_T_API_KEY=x JG_U_API_KEY=y "$core" launch-env-strip $'JG_U_API_KEY\n')" "unset JG_T_API_KEY; "
check "a filtered launch forwards names by reference and ends in the quoted launch" "$(printf %s "it's" | "$core" launch-env-wrap FOO 1 | sed 's/.* COMPACT_ADVISER_DISABLE=1//')" " \${TRACEPARENT+\"TRACEPARENT=\$TRACEPARENT\"} /bin/sh -c 'it'\\''s'"

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
