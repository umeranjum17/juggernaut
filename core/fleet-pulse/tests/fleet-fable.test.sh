#!/usr/bin/env bash
# The fleet pulse's Fable wake asks the installed model guard, so allow-tasks is the one list.
# Journey: an old-style pulse check with the inline Fable block wakes for a fable-* task the guard
# allows (the reported bug); wiring.sh retargets the block onto bin/fleet-fable.sh, and the same
# check then stays quiet for that task and still wakes for a task the list does not name, for a
# session no task owns, and once the guard copy is too old to answer. Disposable homes, session
# logs, Claude config and guard install only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user XDG_DATA_HOME=$d/share JG_TREEHOUSE=$d/treehouse JG_CLAUDE_PROJECTS=$d/projects
mkdir -p "$HOME/.claude" "$JG_TREEHOUSE" "$JG_CLAUDE_PROJECTS"
unset CLAUDE_CONFIG_DIR JG_CLAUDE_MODEL_GUARD

fail=0
ok() { echo "ok $1"; }
no() { echo "FAIL $1" >&2; fail=1; }

# The real guard, installed the way a host installs it, with the captain's allow-tasks beside it.
bash "$root/claude-model-guard/wiring.sh" --install >/dev/null
guard=$(bash "$root/claude-model-guard/wiring.sh" --where)
printf '# Juggernaut research on Fable\nfable-*\n' >"${guard%/*}/allow-tasks"

main=$d/main lead=$d/lead
mkdir -p "$main/state" "$main/data" "$lead/state"
printf -- '- lead - research (home: %s; scope: x)\n' "$lead" >"$main/data/squad_leads.md"
task() { # task <home> <id>: a task record whose worktree is $d/wt/<id>
  mkdir -p "$d/wt/$2"
  printf 'worktree=%s\nharness=claude\n' "$d/wt/$2" >"$1/state/$2.meta"
}
task "$main" fable-research
task "$main" fric-other
task "$lead" fable-lead-dig
session() { # session <cwd> <folder>: a fresh session log that ran Fable in <cwd>
  mkdir -p "$JG_CLAUDE_PROJECTS/$2"
  printf '{"type":"user","cwd":"%s","sessionId":"s"}\n{"type":"assistant","message":{"model":"claude-fable-5-1"}}\n' "$1" \
    >"$JG_CLAUDE_PROJECTS/$2/$(date +%s%N).jsonl"
}
pulse() { rm -f "$main/state/.fleet-fable.last"; bash "$main/state/fleet-pulse.check.sh" 2>&1 || true; }

# The old inline block, as a hand-written pulse check carries it.
cat >"$main/state/fleet-pulse.check.sh" <<EOF
#!/usr/bin/env bash
set -u
now=\$(date +%s)
# Fable ban (captain 10 Oct: "fable should not be used ever until I say so"): any Claude session log written in the
# last 20 min that ran claude-fable, including pi subagents through the Claude bridge that no task record shows.
fab=\$(find $JG_CLAUDE_PROJECTS -name '*.jsonl' -mmin -20 2>/dev/null | xargs -r grep -lE '"model":"claude-fable' 2>/dev/null | xargs -r -n1 dirname | xargs -r -n1 basename | sort -u | head -3 | tr '\n' ' ')
FM=$main/state/.fleet-fable.last
if [ -n "\$fab" ] && { [ ! -f "\$FM" ] || [ \$((now - \$(stat -c %Y "\$FM"))) -ge 900 ]; }; then
  touch "\$FM"; echo "fleet-fable: Fable is banned but ran in: \$fab- find the lane or supervision host (config/supervision-host), stop it, steer its lead"; exit 0
fi
echo later
EOF

# 1) The bug: an allowed fable-* task wakes the old check.
session "$d/wt/fable-research" wt-fable-research
case $(pulse) in fleet-fable:*) ok old-check-wakes-for-allowed-task ;; *) no old-check-wakes-for-allowed-task ;; esac

# 2) wiring.sh retargets the inline block; a second run changes nothing.
bash "$root/fleet-pulse/wiring.sh" "$main" >/dev/null
# shellcheck disable=SC2016 # a literal marker
if grep -q 'fleet-fable.sh' "$main/state/fleet-pulse.check.sh" && ! grep -qF 'fab=$(find' "$main/state/fleet-pulse.check.sh"; then
  ok wiring-retargets-fable-block
else
  no wiring-retargets-fable-block
fi
before=$(sha256sum <"$main/state/fleet-pulse.check.sh")
bash "$root/fleet-pulse/wiring.sh" "$main" >/dev/null
if [ "$before" = "$(sha256sum <"$main/state/fleet-pulse.check.sh")" ]; then ok wiring-rerun-unchanged; else no wiring-rerun-unchanged; fi

# 3) The fix: the allowed task is quiet, here and in a lead home's task.
session "$d/wt/fable-lead-dig/sub" wt-fable-lead-dig
got=$(pulse)
if [ "$got" = later ]; then ok allowed-tasks-quiet; else no "allowed-tasks-quiet (got: $got)"; fi

# 4) A task the list does not name still wakes, named by its task id; the allowed ones are not named.
session "$d/wt/fric-other" wt-fric-other
got=$(pulse)
case $got in "fleet-fable: Fable ran outside the model guard's allow-tasks in: fric-other -"*) ok unlisted-task-wakes ;; *) no "unlisted-task-wakes (got: $got)" ;; esac

# 5) The wake mark holds a repeat for 15 minutes.
bash "$main/state/fleet-pulse.check.sh" >/dev/null
if [ "$(bash "$main/state/fleet-pulse.check.sh")" = later ]; then ok wake-mark-suppresses; else no wake-mark-suppresses; fi

# 6) A session no task owns (a supervision host) wakes, named by its session folder.
rm -rf -- "$JG_CLAUDE_PROJECTS/wt-fric-other"
session "$main" main-home
got=$(pulse)
case $got in *" in: main-home -"*) ok taskless-session-wakes ;; *) no "taskless-session-wakes (got: $got)" ;; esac
rm -rf -- "$JG_CLAUDE_PROJECTS/main-home"

# 7) A guard copy too old to answer the query wakes once instead of deciding.
cp "$guard" "$d/guard.new"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$guard"
got=$(pulse)
case $got in *"cannot answer allowed <task-id>"*) ok stale-guard-wakes ;; *) no "stale-guard-wakes (got: $got)" ;; esac
cp "$d/guard.new" "$guard"

# 8) No guard installed: this host has no Fable ban, so nothing wakes.
session "$d/wt/fric-other" wt-fric-other
mv "$guard" "$d/guard.off"
got=$(pulse)
if [ "$got" = later ]; then ok no-guard-quiet; else no "no-guard-quiet (got: $got)"; fi

[ "$fail" -eq 0 ] || exit 1
echo PASS fleet-fable
