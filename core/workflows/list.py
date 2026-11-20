"""list: one line per workflow name, `<name>\t<canonical spec>\t<shipped|home>`, then the files read.
A name is read as a building block: `blitz` has no plan to start alone but is fine inside a spec.
A name whose spec is refused prints `<name>\trefused: <rule>\t<source>` and the exit is 2, so every broken line shows at once."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wflib  # noqa: E402


def main():
    c = wflib.load()
    bad = 0
    for name, (_, source, _) in c.names.items():
        try:
            spec = wflib.canonical(wflib.parse(name, "main", c, block=True)[1])
        except wflib.Refused as e:
            spec, bad = f"refused: {e}", 1
        print(f"{name}\t{spec}\t{source}")
    for path in c.files:
        print(f"# read {path}")
    return 2 if bad else 0


wflib.run(main)
