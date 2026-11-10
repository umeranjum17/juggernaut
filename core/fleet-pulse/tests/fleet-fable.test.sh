#!/usr/bin/env bash
# The fleet pulse's Fable wake asks the installed model guard, so allow-tasks is the one list.
# Journey: an old-style pulse check with the inline Fable block wakes for a fable-* task the guard
# allows (the reported bug); wiring.sh retargets the block onto bin/fleet-fable.sh, and the same
# check then stays quiet for that task and still wakes for a task the list does not name, for a
# session no task owns, and once the guard copy is too old to answer. A quota-failover one-line test
# is judged by the task its folder names, and a route-level test (no task) is still named. The check stays registered
# through each retarget, even one whose 2h report step then refuses. Disposable homes, session
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
mkdir -p "$main/bin" "$main/state" "$main/data" "$lead/state"
# The home's register script is this checkout's; accepted is the gate the watcher applies to a state check.
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$root/../bin/jg-check-register.sh" >"$main/bin/jg-check-register.sh"
chmod +x "$main/bin/jg-check-register.sh"
accepted() { bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" fleet-pulse' _ "$root/.." "$1/state"; }
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
chmod 700 "$main/state/fleet-pulse.check.sh"
cp "$main/state/fleet-pulse.check.sh" "$d/old-check.sh"
JG_HOME=$main "$main/bin/jg-check-register.sh" fleet-pulse >/dev/null

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
if accepted "$main"; then ok watcher-accepts-retargeted-check; else no watcher-accepts-retargeted-check; fi
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

# 7) quota-failover's one-line tests (the 10 Nov alarm: two PONG probes in mktemp folders for allowed fable-* tasks).
#    A test for a task runs in a folder naming it, so the guard decides on that task; a route-level test names none.
session /tmp/jg-probe-fable-recon-type-design.abc123 -tmp-jg-probe-fable-recon-type-design-abc123
got=$(pulse)
if [ "$got" = later ]; then ok allowed-task-probe-quiet; else no "allowed-task-probe-quiet (got: $got)"; fi
session /tmp/jg-probe-fric-probe-lane.abc123 -tmp-jg-probe-fric-probe-lane-abc123
got=$(pulse)
case $got in *" in: fric-probe-lane -"*) ok unlisted-task-probe-wakes ;; *) no "unlisted-task-probe-wakes (got: $got)" ;; esac
rm -rf -- "$JG_CLAUDE_PROJECTS/-tmp-jg-probe-fric-probe-lane-abc123"
session /tmp/tmp.cyL4npllY3 -tmp-tmp-cyL4npllY3
got=$(pulse)
case $got in *" in: -tmp-tmp-cyL4npllY3 -"*) ok route-probe-wakes ;; *) no "route-probe-wakes (got: $got)" ;; esac
rm -rf -- "$JG_CLAUDE_PROJECTS/-tmp-tmp-cyL4npllY3"

# 8) A guard copy too old to answer the query wakes once instead of deciding.
cp "$guard" "$d/guard.new"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' >"$guard"
got=$(pulse)
case $got in *"cannot answer allowed <task-id>"*) ok stale-guard-wakes ;; *) no "stale-guard-wakes (got: $got)" ;; esac
cp "$d/guard.new" "$guard"

# 9) No guard installed: this host has no Fable ban, so nothing wakes.
session "$d/wt/fric-other" wt-fric-other
mv "$guard" "$d/guard.off"
got=$(pulse)
if [ "$got" = later ]; then ok no-guard-quiet; else no "no-guard-quiet (got: $got)"; fi

# 10) A run that retargets the Fable block and then refuses the 2h report (not every block in the known form)
#     exits 1 and still leaves the check it edited registered.
part=$d/part
mkdir -p "$part/state"
cp -r "$main/bin" "$part/"
{ grep -v '^echo later$' "$d/old-check.sh"; echo "echo 'fleet-pulse 2h (landings = merged PRs; '"; } >"$part/state/fleet-pulse.check.sh"
chmod 700 "$part/state/fleet-pulse.check.sh"
JG_HOME=$part "$part/bin/jg-check-register.sh" fleet-pulse >/dev/null
rc=0; bash "$root/fleet-pulse/wiring.sh" "$part" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 1 ] && grep -q 'fleet-fable.sh' "$part/state/fleet-pulse.check.sh"; then ok partial-run-edits-and-refuses; else no "partial-run-edits-and-refuses (rc=$rc)"; fi
if accepted "$part"; then ok watcher-accepts-partly-retargeted-check; else no watcher-accepts-partly-retargeted-check; fi

[ "$fail" -eq 0 ] || exit 1
echo PASS fleet-fable
