#!/usr/bin/env python3
"""Bound Main's context at wake time without losing the record (docs/context-bound.md).

  turns <transcript>      one JSON line per turn (the token audit's counter), then a summary line
  rates [--since EPOCH] [--until EPOCH] <transcript>...   wakes per hour of one home, from its session records
  emit [--state DIR]      SessionStart(compact) payload on stdin: history path + captain's words verbatim
  settings [--window N]   a lab --settings file with the shipped bound;  find <session-id>: its transcript
  cap <role> [--config DIR]   the cap a role gets (tokens, or off);  env <role> [--pairs]: its settings env
  apply <role> --home DIR     merge the role's cap into the home's local Claude settings   (docs/configuration.md "Supervisor context cap")
"""
import argparse
import json
import os
import sys
import time

WAKE = "needs a handling turn now"
# The shipped cap per supervisor role, in tokens; config/supervisor-context-cap overrides it. Main stays off until the lead pilot passes.
DEFAULT_CAP = {"lead": 150000, "main": None}
MARGIN = 33000  # Claude Code compacts at window - 33000, so the window is the cap plus this
KEYS = ("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE")
# Text that reaches the model as a user turn but is not the captain.
NOT_CAPTAIN = (WAKE, "Juggernaut operational input", "Juggernaut instruction", "SUPERVISION WAKE",
               "<system-reminder>", "<task-notification>", "[SYSTEM NOTIFICATION", "<command-",
               "<local-command", "JUGGERNAUT_OP:", "Stop hook", "This session is being continued")
USAGE = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def records(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def turn_text(rec):
    """The typed text that opens a turn, or None for tool results, meta and summaries."""
    if rec.get("type") != "user" or rec.get("isMeta") or rec.get("isCompactSummary") or rec.get("isSidechain"):
        return None
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        content = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return content if isinstance(content, str) and content.strip() else None


def kind(text):
    if WAKE in text:
        return "wake"
    return "other" if any(text.lstrip().startswith(p) or p in text[:200] for p in NOT_CAPTAIN) else "captain"


def turns(path):
    out = []
    for rec in records(path):
        text = turn_text(rec)
        if text is not None:
            out.append({"turn": len(out) + 1, "kind": kind(text), "calls": {}, "compacted": 0})
        elif out and rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
            out[-1]["compacted"] += 1
        msg = rec.get("message") or {}
        if out and rec.get("type") == "assistant" and msg.get("id") and msg.get("usage"):
            call = out[-1]["calls"].setdefault(msg["id"], {})
            for k in USAGE:
                call[k] = max(call.get(k, 0), msg["usage"].get(k) or 0)
    rows = []
    for t in out:
        calls = list(t["calls"].values())
        ctx = [c["input_tokens"] + c["cache_creation_input_tokens"] + c["cache_read_input_tokens"] for c in calls if "input_tokens" in c]
        if ctx:
            rows.append({"turn": t["turn"], "kind": t["kind"], "calls": len(ctx), "ctx_first": ctx[0], "ctx_max": max(ctx),
                         "input_total": sum(ctx), "output": sum(c["output_tokens"] for c in calls), "compacted": t["compacted"]})
    return rows


def captain_words(path):
    return [t.strip() for t in map(turn_text, records(path)) if t and kind(t) == "captain"]


def cmd_turns(args):
    rows = turns(args.transcript)
    wakes = [r for r in rows if r["kind"] == "wake"]
    for row in rows:
        print(json.dumps(row))
    print(json.dumps({"turns": len(rows), "wakes": len(wakes), "wake_ctx_first_max": max((r["ctx_first"] for r in wakes), default=0),
                      "wake_input_total_mean": round(sum(r["input_total"] for r in wakes) / len(wakes)) if wakes else 0,
                      "compactions": sum(r["compacted"] for r in rows)}))


def stamp(rec):
    """The record's time as epoch seconds, or None."""
    value = rec.get("timestamp")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return time.mktime(time.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
        except ValueError:
            return None
    return None


def cmd_rates(args):
    """Wake turns per hour, counted with the same marker as `turns`. The hours are the span in
    which the home was running (first to last record in the window), minus idle gaps over an hour,
    so a session that sat closed overnight does not dilute the rate."""
    wakes, times = 0, []
    for path in args.transcripts:
        for rec in records(path):
            at = stamp(rec)
            if at is None or (args.since and at < args.since) or (args.until and at > args.until):
                continue
            times.append(at)
            text = turn_text(rec)
            if text is not None and kind(text) == "wake":
                wakes += 1
    times.sort()
    active = sum(min(b - a, 3600) for a, b in zip(times, times[1:]))
    hours = active / 3600
    print(json.dumps({"files": len(args.transcripts), "wakes": wakes, "active_hours": round(hours, 2),
                      "wakes_per_hour": round(wakes / hours, 2) if hours else 0}))


def cmd_emit(args):
    try:
        path = json.loads(sys.stdin.read() or "{}").get("transcript_path") or ""
    except ValueError:
        return
    if not os.path.isfile(path):
        return
    b = {}
    for rec in records(path):
        if rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
            b = rec.get("compactMetadata") or {}
    trigger, pre, post = b.get("trigger", "unknown"), b.get("preTokens", "?"), b.get("postTokens", "?")
    print("CONTEXT BOUND: the conversation was compacted to stay under the wake-time ceiling (%s: %s tokens before, %s after)." % (trigger, pre, post))
    print("The full history before the compaction is still on disk and readable at: %s" % path)
    print("The captain's own words below are verbatim; the summary above may paraphrase them.")
    used, keep = 0, []
    for word in reversed(captain_words(path)[-20:]):  # newest first, so a full budget drops the oldest
        word = word if len(word) <= args.max_chars else word[:args.max_chars] + " [cut here; the rest is in the history file]"
        used += len(word)
        if used > 20000:
            keep.append("[older captain words omitted here; they are in the history file]")
            break
        keep.append("--- captain ---\n" + word)
    print("\n".join(reversed(keep)))
    if args.state and os.path.isdir(args.state):
        with open(os.path.join(args.state, "context-bound.log"), "a", encoding="utf-8") as log:
            log.write("%d\t%s\t%s\t%s\t%s\n" % (time.time(), trigger, pre, post, path))


def resolve_cap(role, config):
    """Tokens for the role, or None for off. A malformed line is an error, never a silent default or a silent off."""
    cap = DEFAULT_CAP[role]
    path = os.path.join(config, "supervisor-context-cap") if config else ""
    if path and os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                line = raw.split("#")[0].split()
                if not line:
                    continue
                if len(line) != 2 or line[0] not in DEFAULT_CAP or not (line[1] == "off" or (line[1].isdigit() and int(line[1]) >= 50000)):
                    sys.exit("error: config/supervisor-context-cap line %d must be '<lead|main> <tokens, 50000 or more|off>'" % n)
                if line[0] == role:
                    cap = None if line[1] == "off" else int(line[1])
    return cap


def cap_env(cap):
    return {} if cap is None else {KEYS[0]: str(cap + MARGIN), KEYS[1]: "100"}


def cmd_cap(args):
    cap = resolve_cap(args.role, args.config)
    if args.what == "cap":
        print("off" if cap is None else cap)
    elif args.pairs:
        print(",".join('"%s":"%s"' % kv for kv in cap_env(cap).items()))
    else:
        print(json.dumps(cap_env(cap)))


def cmd_apply(args):
    """Merge the role's cap into the home's local settings; every other key stays, and off removes only the cap keys."""
    path = os.path.join(args.home, "." + "claude", "settings.local.json")
    doc = {}
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
        except ValueError:
            sys.exit("error: %s is not valid JSON; left untouched" % path)
    env = {k: v for k, v in (doc.get("env") or {}).items() if k not in KEYS}
    env.update(cap_env(resolve_cap(args.role, args.config or os.path.join(args.home, "config"))))
    if env:
        doc["env"] = env
    else:
        doc.pop("env", None)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    print("%s: %s" % (path, json.dumps(env)))


def cmd_settings(args):
    env = cap_env(DEFAULT_CAP["lead"])
    if args.window:
        env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = args.window
    print(json.dumps({"env": env}))


def cmd_find(args):
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    for root, _dirs, files in os.walk(os.path.join(base, "projects")):
        if args.session + ".jsonl" in files:
            print(os.path.join(root, args.session + ".jsonl"))
            return
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("turns")
    p.add_argument("transcript")
    p.set_defaults(fn=cmd_turns)
    p = sub.add_parser("rates")
    p.add_argument("--since", type=float)
    p.add_argument("--until", type=float)
    p.add_argument("transcripts", nargs="+")
    p.set_defaults(fn=cmd_rates)
    p = sub.add_parser("emit")
    p.add_argument("--state")
    p.add_argument("--max-chars", type=int, default=4000)
    p.set_defaults(fn=cmd_emit)
    p = sub.add_parser("settings")
    p.add_argument("--window")
    p.set_defaults(fn=cmd_settings)
    for name in ("cap", "env"):
        p = sub.add_parser(name)
        p.add_argument("role", choices=sorted(DEFAULT_CAP))
        p.add_argument("--config")
        p.add_argument("--pairs", action="store_true")
        p.set_defaults(fn=cmd_cap, what=name)
    p = sub.add_parser("apply")
    p.add_argument("role", choices=sorted(DEFAULT_CAP))
    p.add_argument("--home", required=True)
    p.add_argument("--config")
    p.set_defaults(fn=cmd_apply)
    p = sub.add_parser("find")
    p.add_argument("session")
    p.set_defaults(fn=cmd_find)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
