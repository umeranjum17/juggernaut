#!/usr/bin/env bash
# Journey: the delivery tick (bin/jg-delivery-tick.sh, the real caller) stops the agent of a Built lane at once.
# a) a done lane with a PASS receipt at its branch head has its agent exited once; state/<id>.exit records it;
# b) the next tick does nothing more for it (its exit record is newer than the done line);
# c) a done lane with no receipt, a FAIL receipt, a receipt for another head, a working lane, a parked lane and a lane
#    whose agent is gone are never exited;
# d) an exit that fails is reported once on stderr and never stops the pass; the tick still exits 0.
# Usage: tests/jg-lane-stop-at-built.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT
mkdir -p "$HOME"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$FM/config" "$P"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base
export STUB_LOG=$d/calls; : > "$STUB_LOG"
cat > "$d/control" <<'STUB'
#!/usr/bin/env bash
printf 'control %s\n' "$*" >> "$STUB_LOG"
[ ! -e "$JG_STATE_OVERRIDE/nocontrol-$1" ] || exit 1
[ "$2" != exit ] || date +%s > "$JG_STATE_OVERRIDE/$1.exit"
STUB
cat > "$d/agent" <<'STUB'
#!/usr/bin/env bash
[ ! -e "$JG_STATE_OVERRIDE/gone-$1" ] || { echo dead; exit 0; }
echo alive
STUB
chmod +x "$d/control" "$d/agent"
export JG_LANE_END_CONTROL=$d/control JG_LANE_END_AGENT=$d/agent
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
# lane <id> <status line> <receipt: pass|fail|none|stale>
lane() {
  git -C "$P" branch "fm/$1" trunk; git -C "$P" checkout -q "fm/$1"; echo "$1" > "$P/$1"; git -C "$P" add "$1"
  git -C "$P" commit -qm "$1"; git -C "$P" checkout -q trunk
  printf 'kind=ship\nproject=%s\nbranch=fm/%s\nspawn_gen=g1\n' "$P" "$1" > "$FM/state/$1.meta"
  printf '%s\n' "$2" > "$FM/state/$1.status"
  head=$(git -C "$P" rev-parse "fm/$1")
  case $3 in
    pass) jq -n --arg t "$1" --arg h "$head" '{task:$t,spawn_gen:"g1",head:$h,verdict:"PASS"}' > "$FM/state/$1.run-receipt.json" ;;
    fail) jq -n --arg t "$1" --arg h "$head" '{task:$t,spawn_gen:"g1",head:$h,verdict:"FAIL"}' > "$FM/state/$1.run-receipt.json" ;;
    stale) jq -n --arg t "$1" '{task:$t,spawn_gen:"g1",head:"0000000000000000000000000000000000000000",verdict:"PASS"}' > "$FM/state/$1.run-receipt.json" ;;
  esac
}
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$FM" 2>"$d/err" >"$d/out"; }
lane built 'done [at=1]: ready' pass
lane norcpt 'done [at=1]: ready' none
lane failrc 'done [at=1]: ready' fail
lane stalerc 'done [at=1]: ready' stale
lane busy 'working [at=1]: x' pass
lane parked 'done [at=1]: ready' pass; : > "$FM/state/parked.parked"
lane gone 'done [at=1]: ready' pass; : > "$FM/state/gone-gone"
lane nostop 'done [at=1]: ready' pass; : > "$FM/state/nocontrol-nostop"
touch -d '-1 hour' "$FM/state"/*.status
tick
check 'only the Built lanes were exited' "$(sort "$STUB_LOG" | tr '\n' ';')" 'control built exit;control nostop exit;'
check 'the exit record says the agent is stopped' "$([ -s "$FM/state/built.exit" ] && echo yes)" yes
check 'no exit record for a lane that is not Built' "$(cd "$FM/state" && printf '%s ' *.exit)" 'built.exit '
check 'a failed exit is reported once on stderr' "$(grep -c 'nostop is Built, but its agent could not be stopped' "$d/err")" 1
: > "$STUB_LOG"
tick
check 'the next tick exits only the lane whose exit failed' "$(cat "$STUB_LOG")" 'control nostop exit'
check 'the failure is not reported again' "$(grep -c 'nostop is Built' "$d/err" || true)" 0
check 'the branch and the record stay' "$(git -C "$P" rev-parse --verify -q refs/heads/fm/built >/dev/null && [ -f "$FM/state/built.meta" ] && echo yes)" yes
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
