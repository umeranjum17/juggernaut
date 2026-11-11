#!/usr/bin/env bash
# The Fable pulse names the task of a pooled copy from data/copy-tasks.tsv (jg-spawn.sh appends one row per launch).
# Journey, through the real pulse script and the installed guard: an allowed fable-* task ran in a pooled copy and its
# record is gone: no wake; a task the list does not name ran later in the same copy: the wake names that task id; a
# session in a copy with no row: the wake names the folder. Disposable homes, session logs and guard install only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
export HOME=$d/user XDG_DATA_HOME=$d/share JG_TREEHOUSE=$d/treehouse JG_CLAUDE_PROJECTS=$d/projects
mkdir -p "$HOME/.claude" "$JG_TREEHOUSE" "$JG_CLAUDE_PROJECTS"
unset CLAUDE_CONFIG_DIR JG_CLAUDE_MODEL_GUARD
fail=0
ok() { echo "ok $1"; }
no() { echo "FAIL $1" >&2; fail=1; }

bash "$root/core/claude-model-guard/wiring.sh" --install >/dev/null
guard=$(bash "$root/core/claude-model-guard/wiring.sh" --where)
printf 'fable-*\n' >"${guard%/*}/allow-tasks"

main=$d/main
mkdir -p "$main/state" "$main/data"
copy=$d/pool/slot1
mkdir -p "$copy"
now=$(date +%s)
session() { # session <cwd> <folder> <epoch>: a session log that ran Fable in <cwd>, first written at <epoch>
  local ts
  ts=$(date -u -d "@$3" +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$JG_CLAUDE_PROJECTS/$2"
  printf '{"type":"user","cwd":"%s","timestamp":"%s"}\n{"type":"assistant","message":{"model":"claude-fable-5-1"}}\n' "$1" "$ts" \
    >"$JG_CLAUDE_PROJECTS/$2/$3.jsonl"
}
pulse() { rm -f "$main/state/.fleet-fable.last"; JG_FABLE_NOW=$now bash "$root/core/fleet-pulse/bin/fleet-fable.sh" "$main" 2>&1 || true; }

# Row in jg-spawn.sh's own format: copy, pane, task id, start.
printf '%s\tsess:1\tfable-research\t%s\n' "$copy" $((now - 900)) >"$main/data/copy-tasks.tsv"

# 1) Allowed task, record removed 3 minutes ago: no wake.
session "$copy" slot1 $((now - 180))
if [ -z "$(pulse)" ]; then ok allowed-task-in-copy-no-wake; else no allowed-task-in-copy-no-wake; fi

# 2) A task not on the list ran later in the same copy: the wake names it, not the older allowed one.
printf '%s\tsess:1\tfric-other\t%s\n' "$copy" $((now - 120)) >>"$main/data/copy-tasks.tsv"
rm -f "$JG_CLAUDE_PROJECTS"/slot1/*.jsonl
session "$copy" slot1 $((now - 60))
case $(pulse) in *"in: fric-other "*) ok later-task-named ;; *) no later-task-named ;; esac

# 3) A copy with no row: the wake names the folder, as before.
other=$d/pool/slot2
mkdir -p "$other"
rm -f "$JG_CLAUDE_PROJECTS"/slot1/*.jsonl
session "$other" slot2-folder $((now - 60))
case $(pulse) in *"in: slot2-folder "*) ok no-row-names-folder ;; *) no no-row-names-folder ;; esac

exit "$fail"
