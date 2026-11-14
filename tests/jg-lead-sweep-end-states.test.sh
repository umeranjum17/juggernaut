#!/usr/bin/env bash
# Journey: lead-sweep.sh run sweeps a lane whose last status line is `resolved` (answered), through the real caller.
# a) a resolved lane whose head is on the trunk is torn down once, with its id and no --force;
# b) a resolved lane whose head is not landed is not torn down and is reported once; the next beat prints nothing;
# c) a done lane that has not landed prints nothing; a paused lane is never touched.
# Usage: tests/jg-lead-sweep-end-states.test.sh
set -euo pipefail
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/../core/lead-sweep" && pwd -P)
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
export HOME=$d/home TMPDIR=$d GIT_CONFIG_GLOBAL=$d/gitconfig GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT
mkdir -p "$HOME"; git config --global user.email t@t; git config --global user.name t; git config --global init.defaultBranch trunk
FM=$d/fm; P=$FM/projects/proj; mkdir -p "$FM/state" "$FM/data" "$P"
git -C "$P" init -q; echo 1 > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm base
export STUB_LOG=$d/calls
cat > "$d/teardown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
rm -f "$JG_STATE_OVERRIDE/$1.meta"
STUB
cat > "$d/control" <<'STUB'
#!/usr/bin/env bash
date +%s > "$JG_STATE_OVERRIDE/$1.exit"
STUB
cat > "$d/agent" <<'STUB'
#!/usr/bin/env bash
echo alive
STUB
chmod +x "$d/teardown" "$d/control" "$d/agent"
export JG_LEAD_SWEEP_TEARDOWN=$d/teardown JG_LEAD_SWEEP_CONTROL=$d/control JG_LEAD_SWEEP_AGENT=$d/agent
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want: $3, got: $2)"; fails=$((fails + 1)); fi; }
lane() {
  git -C "$P" branch "fm/$1" trunk; git -C "$P" checkout -q "fm/$1"; echo "$1" > "$P/$1"; git -C "$P" add "$1"
  git -C "$P" commit -qm "$1"; git -C "$P" checkout -q trunk
  printf 'kind=ship\nproject=%s\nbranch=fm/%s\n' "$P" "$1" > "$FM/state/$1.meta"
  printf '%s\n' "$2" > "$FM/state/$1.status"
}
onto() { git -C "$P" merge -q --no-ff "fm/$1" -m "land $1"; git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"; }
git -C "$P" rev-parse trunk > "$FM/state/trunk-tip-proj"
sweep() { : > "$STUB_LOG"; "$SRC/lead-sweep.sh" run "$FM" > "$d/out" 2>&1; }
tore() { grep -c "^$1\$" "$STUB_LOG" || true; }

lane answered 'resolved [at=1]: answered'; lane open 'resolved [at=1]: answered'; lane waiting 'done [at=1]: ready'; lane parked 'paused [at=1]: wait'
onto answered
sweep
check "a: the landed resolved lane is torn down once" "$(tore answered)" 1
check "a: it is reported cleaned up" "$(grep -c '^lead-sweep: answered cleaned up (its head is on the trunk)' "$d/out")" 1
check "b: the unlanded resolved lane is not torn down" "$(tore open)" 0
check "b: it is reported once" "$(grep -c '^lead-sweep: open ended as resolved, left alone' "$d/out")" 1
sweep
check "b: the next beat prints nothing" "$(wc -c < "$d/out" | tr -d ' ')" 0
check "c: the unlanded done lane and the paused lane are not torn down" "$(tore waiting)$(tore parked)" 00
[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
