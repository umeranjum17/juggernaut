#!/usr/bin/env bash
# done-done journey: the real bin/jg-ports-check.sh in a clone of this checkout. A change importing the Pi
# engine kit outside its adapter is refused naming the file, the same import inside the adapter passes, and
# the real tree has no unlisted client use. tests/jg-ports-check.test.sh owns the full case list.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
work=$(mktemp -d "${TMPDIR:-/tmp}/jg-ports-journey.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
{
  git clone -q --no-hardlinks "$root" "$work/r" || exit 1
  g() { git -C "$work/r" -c user.email=journey@example.invalid -c user.name=Journey "$@"; }
  g checkout -q -b cand
  # The clone carries the committed tree only; overlay the working files so the journey judges this head.
  rsync -a --exclude .git "$root"/ "$work/r"/
  g add -A; g commit -qm 'journey base' --allow-empty
  base=$(g rev-parse HEAD)
  echo '== real tree: --all'; "$work/r/bin/jg-ports-check.sh" --all && echo 'exit 0: no unlisted client use'
  mkdir -p "$work/r/ext"; printf 'import { ExtensionAPI } from "@earendil-works/%s";\n' pi-coding-agent >"$work/r/ext/new.ts"
  g add -A; g commit -qm 'pi kit outside the adapter'
  echo '== Pi kit imported outside the adapter'; "$work/r/bin/jg-ports-check.sh" --base "$base"; echo "exit $?"
  g mv ext/new.ts core/ports/pi-engine/adapter.ts -f; g commit -qm 'pi kit inside the adapter'
  echo '== Pi kit imported inside the adapter'; "$work/r/bin/jg-ports-check.sh" --base "$base"; echo "exit $?"
} >"$out" 2>&1
cat "$out"
grep -q 'ext/new.ts uses pi-engine-kit outside its adapter' "$out" && grep -q 'exit 1' "$out" && [ "$(grep -c '^exit 0' "$out")" -ge 1 ]
rc=$?
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a clone of this checkout with defaults/ports-adapters and the real bin/jg-ports-check.sh",
 "steps": ["run --all over the real tree", "commit a file outside the adapter that imports @earendil-works/pi-coding-agent and run --base", "move the same import into core/ports/pi-engine/adapter.ts and run --base"],
 "result": "the import outside the adapter is refused naming ext/new.ts with exit 1; the same import inside the adapter and the real tree pass with exit 0"}
JSON
exit "$rc"
