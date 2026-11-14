#!/usr/bin/env bash
# run-proof.sh: the recon-ready proof for done-done. Runs the real check over a fixture home holding one finished quick Recon,
# keeps the wake line it prints and the quiet rerun as plain transcript, then runs the journey test.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
mkdir -p "$evidence"
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT
mkdir -p "$d/state" "$d/data/demo-recon" "$d/bin"
cp "$repo/bin/jg-recon-gate.sh" "$d/bin/"
printf 'kind=scout\n' > "$d/state/demo-recon.meta"
printf 'done [at=1]: report ready\n' > "$d/state/demo-recon.status"
printf 'Recon depth: quick\n' > "$d/data/demo-recon/brief.md"
printf '## 1. Answer\n\nOne queue serves every alert.\n\n## 8. Implementation plan\n\n| Slice | Outcome |\n|---|---|\n| Queue table | one table |\n| Alert wiring | alerts read it |\n\n## 10. Open decisions\n\n| Question | Options |\n|---|---|\n| Keep the old queue? | yes, no |\n' > "$d/data/demo-recon/report.md"
{
  echo "== first sweep: the wake line the owner reads"
  bash "$repo/core/recon-ready/ready.sh" check "$d"
  echo "== second sweep: nothing is printed"
  bash "$repo/core/recon-ready/ready.sh" check "$d"
  echo "== record: $(cut -c1-12 "$d/state/recon-ready/demo-recon")..."
} 2>&1 | tee "$evidence/wake.txt"
bash "$repo/tests/jg-recon-ready.test.sh" > "$evidence/recon-ready.log" 2>&1
printf '{"target":{"version":"juggernaut@%s"},"start":"a Recon passes its gate and its owner waits on the report","steps":["run the recon-ready check over the home","run it again","revise the report and run it again","ask the wait-timer library whether the Recon rings"],"result":"one wake line names the report and the next items, a rerun prints nothing, and the Recon arms no owner timer"}\n' "$(git -C "$repo" rev-parse --short HEAD)" > "$evidence/steps.json"
