#!/usr/bin/env python3
"""Write, check and show a captain-facing status report.

Usage:
  report-writer.py write <sitrep|spotrep|return> --facts <file|-> [--model <gemini-4-neon-*>] [--out <file>]
  report-writer.py lint  <sitrep|spotrep|return> <report.md|->
  report-writer.py render <report.md|-> [--title <text>] [--out <file>]

README.md owns the contract: Gemini 4 Neon through agy writes the words, this file builds
what it reads (facts with local paths scrubbed), refuses a text wall or a raw local path,
and renders a page that reads on a 390 px phone.
"""

import argparse
import html
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = Path(__file__).resolve().parents[1] / "prompts"
DEFAULT_MODEL = "gemini-4-neon-medium"
MODEL_PATTERN = re.compile(r"^gemini-4-neon-(low|medium|high|xhigh)$")
KINDS = ("sitrep", "spotrep", "return")
MAX_FACTS = 100_000
AGY_TIMEOUT = 300
ATTEMPTS = 2

# Limits that keep a report a phone read. The model is told them; lint enforces them.
MAX_LINES = {"sitrep": 40, "spotrep": 15, "return": 45}
MAX_LINE = 150
MAX_LINKS = 8
# The four sections of the sitrep chat digest; the sitrep skill's chat-response contract owns them.
SITREP_SECTIONS = ("Captain's Call", "Recently Landed", "Underway", "Charted Next")

URL = re.compile(r"https?://[^\s)\]>\"'`]+|file://\S+")
ABS_PATH = re.compile(r"(?<![\w:/.-])(?:/(?:home|Users|tmp|var|etc|root|opt|usr|mnt|srv)/[^\s)\]>\"'`,;]*|~/[^\s)\]>\"'`,;]*)")
REL_PATH = re.compile(r"(?<![\w/.-])(?:\.?(?:data|state|config|projects|bin|core|docs|tests|agents|sign-off)/[\w./@-]+)")
FILE_NAME = re.compile(r"(?<![\w/.-])[\w-]+\.(?:md|json|jsonl|tsv|log|sh|py|status|meta|inbox)\b")
REPORT_PATH = re.compile(r"(?:/[^\s)\]>\"'`,;]*)?/?data/([\w.-]+)/report\.md")


def die(message, code=1):
    print(f"report-writer: {message}", file=sys.stderr)
    sys.exit(code)


def read_text(source):
    if source == "-":
        return sys.stdin.read()
    try:
        return Path(source).read_text()
    except OSError as err:
        die(f"cannot read {source}: {err.strerror}", 2)


def scrub(text):
    """Replace every local path in the facts with a plain label, so the model never sees one."""
    text = REPORT_PATH.sub(lambda m: f"the report of {m.group(1)}", text)
    text = ABS_PATH.sub("(local file)", text)
    return REL_PATH.sub("(local file)", text)


def strip_urls(text):
    return URL.sub(" ", text)


def lint(kind, text):
    """Return the findings that make a report a text wall or leak a local path."""
    found = []
    lines = [line for line in text.splitlines() if line.strip()]
    if not lines:
        return ["the report is empty"]
    if len(lines) > MAX_LINES[kind]:
        found.append(f"{len(lines)} lines; a {kind} holds at most {MAX_LINES[kind]}")
    for number, line in enumerate(lines, 1):
        if len(line) > MAX_LINE:
            found.append(f"line {number} has {len(line)} characters; a line holds at most {MAX_LINE}")
        bare = strip_urls(line)
        for pattern in (ABS_PATH, REL_PATH, FILE_NAME):
            hit = pattern.search(bare)
            if hit:
                found.append(f"line {number} shows a local file or path: {hit.group(0)}")
                break
        if line.count("http") > 1:
            found.append(f"line {number} holds more than one link")
        if line.lstrip().startswith("|") or line.lstrip().startswith("```"):
            found.append(f"line {number} is a table or a code block; neither reads on a phone")
    links = URL.findall(text)
    if len(links) > MAX_LINKS:
        found.append(f"{len(links)} links; a report holds at most {MAX_LINKS}")
    found += [f"link is not an https link: {link}" for link in links if not link.startswith("https://")]
    if not re.search(r"\bcaptain\b", text, re.I):
        found.append("the report never says 'captain'")
    headings = [re.sub(r"[*_`]", "", line.lstrip("# ").strip()).rstrip(":") for line in lines if line.startswith("#") or line.startswith("**")]
    if kind == "sitrep":
        got = [h for h in headings if h in SITREP_SECTIONS]
        if got != list(SITREP_SECTIONS):
            found.append("the four sections are missing or out of order: " + ", ".join(SITREP_SECTIONS))
    elif not headings:
        found.append("the report has no heading")
    return found


def section(path, title):
    """The text of one `## title` section of a skill file, which stays the owner of its contract."""
    body = (ROOT / path).read_text()
    match = re.search(rf"^## {re.escape(title)}\n(.*?)(?=^## |\Z)", body, re.S | re.M)
    if not match:
        die(f"{path} has no '## {title}' section", 2)
    return match.group(1).strip()


CONTRACT = {
    "sitrep": (".agents/skills/sitrep/SKILL.md", "Chat-response contract"),
    "spotrep": (".agents/skills/spotrep/SKILL.md", "Reply"),
}


def build_prompt(kind, facts, findings=None):
    parts = [(PROMPTS / "common.md").read_text().strip(), (PROMPTS / f"{kind}.md").read_text().strip()]
    if kind in CONTRACT:
        parts.append("The format contract for this report:\n\n" + section(*CONTRACT[kind]))
    parts.append(f"Hard limits: at most {MAX_LINES[kind]} lines, at most {MAX_LINE} characters per line, at most {MAX_LINKS} links.")
    if findings:
        parts.append("Your last draft was refused for these reasons. Fix every one and write the whole report again:\n- " + "\n- ".join(findings))
    parts.append("FACTS (the only source you may use):\n" + facts)
    return "\n\n".join(parts)


def run_agy(prompt, model):
    agy = os.environ.get("JG_AGY") or "agy"
    with tempfile.TemporaryDirectory(prefix="report-writer-") as empty:
        try:
            done = subprocess.run([agy, "--model", model, "--print", prompt], cwd=empty, text=True,
                                  capture_output=True, timeout=AGY_TIMEOUT)
        except FileNotFoundError:
            die(f"'{agy}' is not installed; the report is written by Gemini 4 Neon through agy and has no other writer", 3)
        except subprocess.TimeoutExpired:
            die(f"agy gave no answer in {AGY_TIMEOUT} seconds with model {model}", 3)
    if done.returncode != 0 or not done.stdout.strip():
        die(f"agy failed with model {model} (exit {done.returncode}): {(done.stderr or done.stdout).strip()[:400]}", 3)
    out = done.stdout.strip()
    fenced = re.fullmatch(r"```(?:markdown|md)?\n(.*)\n```", out, re.S)
    return (fenced.group(1) if fenced else out).strip() + "\n"


def cmd_write(args):
    model = args.model or os.environ.get("JG_REPORT_MODEL") or DEFAULT_MODEL
    if not MODEL_PATTERN.match(model):
        die(f"model '{model}' is refused: captain-facing reports are written by gemini-4-neon-low|medium|high|xhigh", 2)
    facts = scrub(read_text(args.facts))
    if len(facts) > MAX_FACTS:
        die(f"the facts hold {len(facts)} characters; the limit is {MAX_FACTS}", 2)
    findings = None
    for _ in range(ATTEMPTS):
        text = run_agy(build_prompt(args.kind, facts, findings), model)
        findings = lint(args.kind, text)
        if not findings:
            if args.out:
                Path(args.out).write_text(text)
            else:
                sys.stdout.write(text)
            return 0
    die(f"Gemini 4 Neon ({model}) wrote a report that was refused twice:\n- " + "\n- ".join(findings))


def cmd_lint(args):
    findings = lint(args.kind, read_text(args.report))
    for finding in findings:
        print(finding)
    return 1 if findings else 0


INLINE = re.compile(r"\[([^\]]+)\]\((https://[^)\s]+)\)|(https://[^\s<)]+)|\*\*([^*]+)\*\*")


def inline(text):
    out, last = [], 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[last:m.start()]))
        if m.group(2):
            out.append(f'<a href="{html.escape(m.group(2), quote=True)}">{html.escape(m.group(1))}</a>')
        elif m.group(3):
            out.append(f'<a href="{html.escape(m.group(3), quote=True)}">{html.escape(m.group(3))}</a>')
        else:
            out.append(f"<strong>{html.escape(m.group(4))}</strong>")
        last = m.end()
    out.append(html.escape(text[last:]))
    return "".join(out)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root{{color-scheme:light dark;--bg:#fff;--fg:#1b1d21;--mute:#5b616b;--line:#e3e5e9;--accent:#0b5fff}}
@media(prefers-color-scheme:dark){{:root{{--bg:#14161a;--fg:#eceef1;--mute:#9aa1ab;--line:#2a2e35;--accent:#7aa7ff}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:17px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-text-size-adjust:100%}}
main{{max-width:40rem;margin:0 auto;padding:20px 18px 48px}}
h1{{font-size:1.35rem;line-height:1.25;margin:0 0 6px}}
h2{{font-size:1.05rem;margin:26px 0 8px;padding-top:14px;border-top:1px solid var(--line);letter-spacing:.01em}}
p{{margin:8px 0}}
ul{{margin:6px 0;padding-left:1.15rem}}
li{{margin:7px 0}}
a{{color:var(--accent);overflow-wrap:anywhere}}
.sub{{color:var(--mute);font-size:.9rem;margin:0 0 4px}}
</style></head><body><main>
{body}
</main></body></html>
"""


def render(text, title):
    body, in_list = [], False
    if not re.search(r"^# ", text, re.M):
        body.append(f"<h1>{html.escape(title)}</h1>")
    for raw in text.splitlines():
        line = raw.rstrip()
        bullet = re.match(r"\s*[-*] (.*)", line)
        if in_list and not bullet:
            body.append("</ul>")
            in_list = False
        if not line.strip():
            continue
        heading = re.match(r"(#{1,3}) (.*)", line)
        if heading:
            tag = "h1" if len(heading.group(1)) == 1 else "h2"
            body.append(f"<{tag}>{inline(heading.group(2))}</{tag}>")
        elif bullet:
            if not in_list:
                body.append("<ul>")
                in_list = True
            body.append(f"<li>{inline(bullet.group(1))}</li>")
        elif re.fullmatch(r"\*\*[^*]+\*\*:?", line.strip()):
            body.append(f"<h2>{inline(line.strip().rstrip(':'))}</h2>")
        else:
            body.append(f"<p>{inline(line)}</p>")
    if in_list:
        body.append("</ul>")
    return PAGE.format(title=html.escape(title), body="\n".join(body))


def cmd_render(args):
    page = render(read_text(args.report), args.title)
    if args.out:
        Path(args.out).write_text(page)
    else:
        sys.stdout.write(page)
    return 0


def main():
    parser = argparse.ArgumentParser(prog="report-writer.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    write = sub.add_parser("write")
    write.add_argument("kind", choices=KINDS)
    write.add_argument("--facts", required=True)
    write.add_argument("--model")
    write.add_argument("--out")
    check = sub.add_parser("lint")
    check.add_argument("kind", choices=KINDS)
    check.add_argument("report")
    show = sub.add_parser("render")
    show.add_argument("report")
    show.add_argument("--title", default="Status report")
    show.add_argument("--out")
    args = parser.parse_args()
    return {"write": cmd_write, "lint": cmd_lint, "render": cmd_render}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
