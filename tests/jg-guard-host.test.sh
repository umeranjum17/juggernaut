#!/usr/bin/env bash
# The guard host, proved end to end: repo-guard, the first Rego rule, refuses a gh/gh-axi write to a
# repository off the allow list and never resolves a fork clone's parent; a new guard is one .rego file
# under policy/guard/ with every core file byte-identical; OPA is the engine and the Go host is the one
# command that asks it.
# Usage: tests/jg-guard-host.test.sh
# shellcheck disable=SC2016 # the single-quoted cases are literal commands, never expanded here
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/jg-guard-host.XXXXXX")
trap 'rm -rf -- "$d"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export HOME=$d/home XDG_CONFIG_HOME=$d/xdg TMPDIR=$d
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$d/gitconfig
# The guard host builds into a state dir: keep that out of the checkout under test.
export JG_STATE_OVERRIDE=$d/state
mkdir -p "$HOME"
: >"$GIT_CONFIG_GLOBAL"
HOST=$ROOT/bin/jg-guard-host.sh
GO=${JG_GUARD_HOST_GO:-go}
fails=0
ok() { printf 'ok: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "text $3" "$2" ;; esac; }
# hook <dir> <command> [VAR=value...]: the Claude PreToolUse payload, printed "<exit>|<output>"
hook() {
  local dir=$1 command=$2 out rc
  shift 2
  out=$(cd "$dir" && jq -Rn --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c},cwd:""}' | env "$@" "$HOST" hook 2>&1) && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}
verdict() { local s; s=$(hook "$@"); printf '%s' "${s%%|*}"; }

# OPA is the engine this rule needs and Go builds the host: with either absent the whole test
# skips, not asserts.
if ! command -v opa >/dev/null 2>&1; then
  printf 'skip: no opa on PATH; install OPA 1.22.0 to run the guard policy and its seven contract cases\n'
  exit 0
fi
if ! command -v "$GO" >/dev/null 2>&1; then
  printf 'skip: no Go toolchain on PATH (%s); install go to build the guard host and run its decisions\n' "$GO"
  exit 0
fi
check "the rule's own Rego contract tests pass" "$(cd "$ROOT" && opa test policy/guard 2>&1 | tail -n 1)" "PASS: 7/7"

# --- repo-guard, the first rule, through the host ---
git init -q "$d/clone"
git -C "$d/clone" remote add origin https://github.com/umeranjum17/juggernaut.git
git -C "$d/clone" remote add parent https://github.com/them/juggernaut.git
clone=$d/clone
check "the host loads every rule this repo ships" "$("$HOST" --list)" "repo_guard"
check "a write on this clone's own origin passes" "$(hook "$clone" 'gh-axi pr create --title t')" '0|'
check "a read verb is never judged" "$(hook "$clone" 'gh-axi pr view 1 --repo them/juggernaut')" '0|'
check "a command with no gh call is not judged" "$(hook "$clone" 'echo gh-axi pr create')" '0|'
out=$(hook "$clone" 'gh-axi pr create --repo them/juggernaut --title t')
check "a write against the parent is refused" "${out%%|*}" 2
has "the refusal names the refused repository" "${out#*|}" 'them/juggernaut'
has "the refusal names the allow list" "${out#*|}" 'umeranjum17/*'
has "the refusal names the rule that made it" "${out#*|}" '[repo_guard]'
for command in 'gh pr comment 1 --body b -R them/juggernaut' 'gh-axi issue create --repo=them/juggernaut' 'gh pr merge 2 -Rthem/juggernaut'; do
  check "an off-list write is refused: $command" "$(verdict "$clone" "$command")" 2
done
check "GH_REPO resolves the target like --repo" "$(verdict "$clone" 'gh-axi pr create' GH_REPO=them/juggernaut)" 2
check "a write with no resolvable repository is refused" "$(verdict "$d" 'gh-axi pr create')" 2

# --- a new guard is one .rego file, with no core change ---
mkdir -p "$d/feature/bin" "$d/feature/core/guard-host" "$d/feature/policy"
cp "$ROOT/bin/jg-guard-host.sh" "$d/feature/bin/"
cp -R "$ROOT/core/guard-host/." "$d/feature/core/guard-host/"
cp -R "$ROOT/policy/." "$d/feature/policy/"
cat >"$d/feature/policy/guard/zz_probe.rego" <<'PROBE'
# A throwaway rule. Adding it changed no core file, which is the host's contract.
package guard.zz_probe

import future.keywords.contains
import future.keywords.if

deny contains "probe refused it" if input.command != ""
PROBE
probe=$d/feature/bin/jg-guard-host.sh
core_hash() { (cd "$ROOT" && find core/guard-host policy bin/jg-guard-host.sh -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
before=$(core_hash)
check "one new file is enough for the host to load the rule" "$(JG_GUARD_HOST_BIN=$d/feature-bin "$probe" --list | paste -sd ' ' -)" "repo_guard zz_probe"
out=$(cd "$clone" && jq -Rn --arg c 'echo probe-me' '{tool_name:"Bash",tool_input:{command:$c},cwd:""}' | JG_GUARD_HOST_BIN=$d/feature-bin "$probe" hook 2>&1) && rc=0 || rc=$?
check "the new rule refuses the call it judges" "$rc" 2
has "the refusal names the new rule" "$out" '[zz_probe] probe refused it'
check "the core files are byte-identical with the new rule loaded" "$(core_hash)" "$before"
check "the whole added cost is one file" "$(diff -rq -- "$ROOT/core/guard-host" "$d/feature/core/guard-host"; diff -q -- "$ROOT/bin/jg-guard-host.sh" "$d/feature/bin/jg-guard-host.sh"; diff -q -- "$ROOT/policy/guard/repo_guard.rego" "$d/feature/policy/guard/repo_guard.rego" || true)" ""

[ "$fails" -eq 0 ] || { printf '%s check(s) failed\n' "$fails" >&2; exit 1; }
printf 'guard-host: one Rego rule file plus one test file, no core change, OPA decides, Go hosts\n'
