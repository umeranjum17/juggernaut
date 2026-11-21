"""define <name> <spec|off> --by owner|main|lead: write one line into this home's config/workflows.
The spec is parsed with the names it will have after the change, so a refusal changes nothing. `--by main|lead` may
only add a name the file does not hold; changing or removing one is `--by owner` (the owner's own words, through Main)."""
import argparse
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wflib  # noqa: E402

HEADER = ("# Workflows of this home: one `<name>: <spec>` line each; a line here wins over the same name in the shipped file.\n"
          "# defaults/workflows holds the shipped names and the line format; `<name>: off` removes a shipped name here.\n")


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".workflows.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def main():
    p = argparse.ArgumentParser(prog="jg-workflow.sh define")
    p.add_argument("name")
    p.add_argument("spec", help="a spec, or off to remove the name")
    p.add_argument("--by", required=True, choices=wflib.BY)
    a = p.parse_args()
    name, spec = a.name, " ".join(a.spec.split())
    if not wflib.NAME.match(name) or name in wflib.RESERVED:
        wflib.refuse(f"'{name}' is not a name you may define: a kind is not a name, and a name is lowercase letters, digits and dashes")
    if "#" in spec or not spec:
        wflib.refuse("a spec is one non-empty line with no '#' (it would start a comment)")
    c = wflib.load()
    path = wflib.home_path()
    raw = open(path).read().splitlines() if os.path.exists(path) else HEADER.splitlines()
    held = [i for i, key in keyed_lines(raw) if key == name]  # raw line indexes of this name in the home file
    if a.by != "owner" and (held or spec == "off"):
        wflib.refuse(f"changing or removing '{name}' is the owner's: his own words through Main, with --by owner")
    if spec == "off":
        if name not in c.names:
            wflib.refuse(f"'{name}' is not a workflow name here")
        # a shipped name stays shipped, so only a line saying off removes it; a name this home added just loses its line
        line = f"{name}: off" if name in c.shipped else None
        message = f"removed {name}"
    else:
        c.names[name] = (spec, "home", "")
        line = f"{name}: {spec}"
        message = f"defined {name}: {wflib.canonical(wflib.parse(name, a.by, c)[1])}"
    if held:
        raw[held[-1]:held[-1] + 1] = [line] if line else []
    elif line:
        raw.append(line)
    write(path, "\n".join(raw) + "\n")
    print(message)


def keyed_lines(raw):
    """(index, key) of every `<key>: <value>` line, comments skipped."""
    for i, text in enumerate(raw):
        text = text.split("#", 1)[0].strip()
        key, sep, _ = text.partition(":")
        if text and sep:
            yield i, key.strip()


wflib.run(main)
