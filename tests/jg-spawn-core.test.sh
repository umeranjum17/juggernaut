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

# The dispatcher never turns a core that cannot run into an answer.
JG_SPAWN_CORE_BIN=$lab/none/jg-spawn-core JG_SPAWN_CORE_GO=$lab/no-such-go "$core" model-flag claude x >/dev/null 2>&1
check "no binary and no toolchain exits 2, not an answer" "$?" 2
check "an unknown command exits 2" "$(rc "$core" nonsense)" 2

[ "$fails" -eq 0 ] || { printf '%d check(s) failed\n' "$fails"; exit 1; }
printf 'all jg-spawn-core tests passed\n'
