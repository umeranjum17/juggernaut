"""Render the scripted participant's drafts using the pack examples and the recorded Decisions."""
import shutil
import sys
from pathlib import Path

repo, project, decisions = map(Path, sys.argv[1:4])
variant = sys.argv[4]
source = repo / "tests/fixtures/muster/example" / variant
templates = repo / ".agents/skills/muster/templates"
if variant == "skeleton":
    shutil.copytree(source, project, dirs_exist_ok=True)
else:
    if not decisions.is_file():
        raise SystemExit("the drafter needs the recorded owner answers")
    actual_decisions = decisions.read_text().split("## Decisions\n", 1)[1].strip()
    if not actual_decisions or "<his words>" in actual_decisions:
        raise SystemExit("the owner has not finished the Decisions")
    vision = project / "docs/vision.md"
    if variant == "rated":
        earlier = vision.read_text().split("## Decisions\n", 1)[1].strip()
        feature_answer = actual_decisions.replace(" R1Q1:", " R1Q1 (rating muster):", 1)
        actual_decisions = f"{earlier}\n{feature_answer}"
    for name in ("docs", "journeys"):
        shutil.copytree(source / name, project / name, dirs_exist_ok=True)
    for name in ("CHANGELOG.md", "GLOSSARY.md", ".done-done.yaml"):
        shutil.copyfile(source / name, project / name)
    example_sections, _ = vision.read_text().split("## Decisions\n", 1)
    heading = next(line for line in (templates / "vision.md").read_text().splitlines() if line == "## Decisions")
    vision.write_text(f"{example_sections}{heading}\n{actual_decisions}\n")
