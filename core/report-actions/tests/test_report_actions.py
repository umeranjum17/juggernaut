#!/usr/bin/env python3
"""Replay approve, refine and reject end to end on the real recorded report; every outside command is a stub in a throwaway directory."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
SCRIPT, RECORDED = ROOT / "bin/jg-report-actions.py", ROOT / "tests/fixtures/recorded-report.md"
SCHEMA = """

## Plan
- Add the status, ticket and message reads
- Add the decisions read and the guarded answer write
## Actions
- **Approve** (recommended): build starts. Owner: axi-lead. First PR due: 2026-02-01.
- **Refine**: your note goes to axi-lead and a new version of this report appears with a diff.
- **Reject**: pick a reason and add a note. This report closes, no build starts, and the reason is saved as an owner rule.
If you do nothing: nothing starts and this report stays open.
"""
fails = []
def check(ok, why):
    if not ok:
        fails.append(why)
        print(f"FAIL: {why}", file=sys.stderr)
def main():
    with tempfile.TemporaryDirectory() as tmp:
        work, data = Path(tmp), Path(tmp) / "data"
        def stub(name, extra=""):
            path = work / name
            path.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{work}/{name}.args"\n{extra}')
            path.chmod(0o755)
        for name in ("send", "handoff", "owner-rules"):
            stub(name)
        stub("tasks-axi", f'printf "ok: added minted-%s (ship) -> Queued\\n" "$(grep -c "" "{work}/tasks-axi.args")"\n')
        env = dict(os.environ, TASKS_AXI=str(work / "tasks-axi"), JG_SEND=str(work / "send"), JG_HANDOFF=str(work / "handoff"),
                   JG_OWNER_RULES=str(work / "owner-rules"), JG_HOME=str(work / "home"), JG_DATA_OVERRIDE=str(data))
        def run(*args):
            return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env)
        def report(name, body=None):
            (data / name).mkdir(parents=True, exist_ok=True)
            (data / name / "report.md").write_text(RECORDED.read_text() + SCHEMA if body is None else body)
            return str(data / name / "report.md")
        def read(path):
            return Path(path).read_text() if Path(path).exists() else ""
        done = run("lint", report("design", RECORDED.read_text()))
        check(done.returncode == 1 and "has no Actions block" in done.stderr, "a report with no Actions block must fail lint")
        design, routed = report("design"), report("route")
        check(run("lint", design).returncode == 0, "the canonical block must pass lint")
        done = run("approve", design, "--by", "yes please")
        check(done.returncode == 1 and "do not name this report" in done.stderr, "a bare yes must not approve")
        done = run("approve", design, "--by", "Juggernaut AXI: one-page design - yes, do it")
        check("started: owner axi-lead" in done.stdout, f"agreement quoting the title must approve: {done.stderr}")
        # approve mints one ticket per plan item and prints the started line
        done = run("approve", report("approve"), "--by", "I agree with approve, go ahead")
        check(done.stdout.startswith("started: owner axi-lead; first PR due 2026-02-01; tickets minted-"), f"the started line: {done.stdout}{done.stderr}")
        minted = read(work / "tasks-axi.args").splitlines()
        check(len(minted) == 4, f"one ticket per plan item on each approve, got {len(minted)}")
        check("Add the decisions read and the guarded answer write" in minted[-1], "every plan item becomes a ticket")
        check("From report: data/approve/report.md" in minted[-1], "each ticket names its report")
        check(run("approve", report("approve")).returncode == 1, "an answered version cannot be approved twice")
        (data / "squad_leads.md").write_text("- axi-lead - the AXI domain (home: /tmp/axi; scope: AXI reads; projects: juggernaut-axi; added 2026-10-31)\n")
        done = run("approve", routed)
        check(done.returncode == 0, f"approve with a registered lead: {done.stderr}")
        check(read(work / "handoff.args").startswith("axi-lead minted-"), f"the tickets must reach the lead: {read(work / 'handoff.args')}")
        (data / "squad_leads.md").unlink()
        refined = report("refine")
        done = run("refine", refined, "--note", "Keep the first release to reads only.")
        check(Path(refined).with_name("report.v1.md").exists(), "refine must keep version 1 beside the new one")
        check("Keep the first release to reads only." in read(refined), "the new version carries his note")
        check("+## Refined to version 2" in done.stdout, f"refine must print the diff: {done.stdout}{done.stderr}")
        check("refined: version 2 is open for approval; his note is with axi-lead" in done.stdout, "refine must say what happened")
        check("Keep the first release to reads only." in read(work / "send.args"), "his note must reach the owner")
        # reject the refined version: it closes, nothing is built, the reason becomes an owner rule
        done = run("reject", refined, "--reason", "too-risky", "--note", "the token path is unproven")
        check("closed: rejected (too-risky); no build; the reason is saved as an owner rule" in done.stdout, f"reject must say what happened: {done.stdout}{done.stderr}")
        check("Closed: rejected on " in read(refined), "reject must close the report")
        check("--words report rejected (too-risky): the token path is unproven" in read(work / "owner-rules.args"), f"the reason must be saved as an owner rule: {read(work / 'owner-rules.args')}")
        check(len(read(work / "tasks-axi.args").splitlines()) == 6, "reject must mint nothing")
        check(run("reject", routed, "--reason", "because").returncode == 1, "an unknown reason chip must be refused")
    if fails:
        return 1
    print("report-actions: all checks passed")
    return 0

if __name__ == "__main__":
    sys.exit(main())
