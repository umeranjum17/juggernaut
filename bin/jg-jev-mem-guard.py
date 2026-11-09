#!/usr/bin/env python3
"""
jg-jev-mem-guard.py - host memory guard: measure, admit, and alert before an oomd kill.

On Herdr, fleet agents share one agent-runtime service, and systemd-oomd kills
that service as a unit under the host's configured oomd pressure policy.
Classify by the pressure of the user app.slice, the cgroup systemd-oomd watches
and agents run in, plus host available memory.
Host-wide pressure aggregates capped heavy-job slices by design, so it is summary
context only and never gates admission or alerts.
Pressure is sustained "some" pressure, the lower of the 10 s and 60 s averages,
so a short spike does not hold launches while pressure held for about a minute does;
a 10 s average at or above alert_pressure holds at once as WAIT, never ALERT.
Unreadable app.slice pressure is not judged: pressure then holds nothing, while available memory still applies.
Admission refusal and sampler interrupts cannot guarantee avoidance of an oomd kill.

Usage (bin/jg-jev-mem-guard.sh runs this with python3):
  jg-jev-mem-guard.sh [--config FILE] [--state-dir HOME DIR]...
      Print "<verdict>\t<summary>" for the host, naming the largest consumers.
  jg-jev-mem-guard.sh [--config FILE] --admit TASK --state DIR
      Admission for one agent launch (bin/jg-spawn.sh, bin/jg-control.sh relaunch).
      Exit 0 admits and removes DIR/admission-refused. Exit 1 refuses: prints the
      reason and writes DIR/admission-refused as "<epoch>\t<task>\t<reason>".
  jg-jev-mem-guard.sh [--config FILE] --record FILE [--state-dir HOME DIR]...
      One independent sampler sample (bin/jg-host-memory-sampler.sh): appends
      "<epoch>\t<MemAvailable kB>\t<swap used kB>\t<sustained pressure>\t<verdict>"
      to FILE, trimming to the newest 8640 rows once it exceeds 8760, and prints
      "<verdict>\t<summary>"; an ALERT summary names the largest consumers.

  --owned-top-task DIR appends a tab and the top consumer's task ID only when
      that consumer is a task recorded in DIR (for the sampler's interrupt).

Verdicts: OK; WAIT (new agents wait); ALERT (sampler attempts one owned-task interrupt);
UNKNOWN (not measurable, for example no pressure file).
--admit refuses WAIT and ALERT and admits OK and UNKNOWN; UNKNOWN records no sample.
Pass --config FILE to read thresholds; without it the defaults apply.
Settings are owned by docs/configuration.md "Host memory guard".
The former diagnostic --check, --json, and percentage-threshold flags are unsupported.
Consumers are summed RSS plus swap per owner, using the longest matching recorded
worktree or explicit home path for the process's working directory.
A matching JG_TASK_ID must also qualify against that task's recorded worktree or
explicit home; an ID alone never establishes ownership, and unmatched processes
are named by command and PID rather than interrupted.
Home identity comes from each --state-dir HOME DIR pair, never DIR's parent, and
each local squad_lead record read there adds its recorded home and HOME/state in
turn, so one pair covers the whole local tree below it. Records are read only
when consumers are named: plain mode, or an ALERT under --record.
Explicit homes aggregate lead processes even without ordinary task records; a
local squad_lead's home remains owned by its parent-recorded squad_lead task.
RSS includes shared pages per process, so these totals rank consumers rather than
accounting for unique physical memory.
Remote records (remote_host set) never contribute local task or home owners.
The proc root is JG_HOST_MEMORY_PROC (default /proc). Exit 2: usage or an invalid
config file, with the reason on stderr.
"""

import argparse
import math
import os
import sys
import tempfile
import time

PROC = os.environ.get("JG_HOST_MEMORY_PROC") or "/proc"
DEFAULTS = {"wait_pressure": 20.0, "wait_available_gb": 12.0, "alert_pressure": 35.0, "alert_available_gb": 6.0}
KEEP_ROWS = 8640
CGROUP_ROOT = os.environ.get("JG_HOST_MEMORY_CGROUP_ROOT") or "/sys/fs/cgroup"
GIB_KB = 1048576
LEAD_KINDS = ("squad_lead", "secondmate")  # secondmate: a record written before the rename (bin/jg-compat.sh)


def die(msg):
    print(f"jg-jev-mem-guard: {msg}", file=sys.stderr)
    sys.exit(2)


def load_config(path):
    cfg = dict(DEFAULTS)
    if not path or not os.path.exists(path):
        return cfg
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, val = (p.strip() for p in line.partition("="))
        try:
            if not sep or key not in DEFAULTS or not math.isfinite(float(val)) or float(val) < 0:
                raise ValueError
            cfg[key] = float(val)
        except ValueError:
            die(f"invalid {path} line {n}: {raw!r} (expected KEY=number, keys: {', '.join(DEFAULTS)})")
    return cfg


def pressure_at(path):
    """Sustained "some" pressure (the lower of the 10 s and 60 s averages) and the 10 s average.

    A spike raises avg10 alone and passes the sustained reading; pressure held for
    about a minute raises both, and the sustained reading falls as soon as avg10 does.
    """
    some = next(l for l in open(path) if l.startswith("some "))
    fields = dict(f.split("=", 1) for f in some.split()[1:])
    fast, slow = float(fields["avg10"]), float(fields["avg60"])
    if not all(math.isfinite(v) and v >= 0 for v in (fast, slow)):
        raise ValueError
    return min(fast, slow), fast


def app_slice_pressure():
    """(sustained, 10 s) pressure of the user app.slice, or None when unreadable."""
    uid = os.getuid()
    path = os.path.join(CGROUP_ROOT, f"user.slice/user-{uid}.slice/user@{uid}.service/app.slice/memory.pressure")
    try:
        return pressure_at(path)
    except (OSError, StopIteration, KeyError, ValueError):
        return None


def sample():
    """{available_kb, swap_used_kb, pressure, fast, host_pressure}, or None when not measurable.

    pressure and fast are None when app.slice pressure is unreadable.
    """
    try:
        mem = {}
        for line in open(f"{PROC}/meminfo"):
            key, _, val = line.partition(":")
            if val.split() and val.split()[0].isdigit():
                mem[key.strip()] = int(val.split()[0])
        host, _ = pressure_at(f"{PROC}/pressure/memory")
        app = app_slice_pressure()
        return {"available_kb": mem["MemAvailable"],
                "swap_used_kb": max(0, mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)),
                "pressure": app[0] if app else None, "fast": app[1] if app else None,
                "host_pressure": host}
    except (OSError, StopIteration, KeyError, ValueError):
        return None


def verdict(s, cfg):
    if s is None:
        return "UNKNOWN", []
    gb = s["available_kb"] / GIB_KB
    for level in ("alert", "wait"):
        threshold = cfg[f"{level}_pressure"]
        why = []
        if s["pressure"] is not None and s["pressure"] >= threshold:
            why.append(f"pressure at or above {threshold:g}%")
        if gb < cfg[f"{level}_available_gb"]:
            why.append(f"available memory below {cfg[f'{level}_available_gb']:g} GB")
        if why:
            return level.upper(), why
    if s["pressure"] is not None and s["fast"] >= cfg["alert_pressure"]:
        return "WAIT", [f"10 s pressure at or above {cfg['alert_pressure']:g}%"]
    return "OK", []


def summary(s):
    head = f"{s['available_kb'] / GIB_KB:.1f} GB available, {s['swap_used_kb'] / GIB_KB:.1f} GB swap used; host {s['host_pressure']:.0f}%"
    if s["pressure"] is None:
        return f"app.slice pressure unreadable, not judged; {head}"
    return (f"pressure {s['pressure']:.0f}% (lower of 10 s and 60 s averages), {head}, app.slice {s['pressure']:.0f}%")


def read_meta(path):
    meta = {}
    try:
        for line in open(path, errors="replace"):
            key, sep, val = line.rstrip("\n").partition("=")
            if sep:
                meta[key] = val
    except OSError:
        pass
    return meta


def records(state_dirs):
    """The local task records of the listed homes and of every local squad_lead home they record.

    Walks each squad_lead record's home and that home's state directory in turn, so the
    whole local tree below a listed home is read once, and only when consumers are named.
    Returns ([(state dir, task ID, record)], {state dir: home}), paths resolved.
    """
    homes, metas, queue = {}, [], list(state_dirs)
    while queue:
        home, d = queue.pop(0)
        d = os.path.realpath(d)
        if d in homes:
            continue
        homes[d] = os.path.realpath(home)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".meta"):
                continue
            m = read_meta(os.path.join(d, f))
            if m.get("remote_host"):
                continue
            metas.append((d, f[:-5], m))
            if m.get("kind") in LEAD_KINDS and m.get("home"):
                queue.append((m["home"], os.path.join(m["home"], "state")))
    return metas, homes


def owners(state_dirs):
    """Home-qualified owners, indexed by recorded paths and task IDs."""
    metas, homes = records(state_dirs)
    lead_of = {os.path.realpath(m["home"]): tid for _, tid, m in metas if m.get("kind") in LEAD_KINDS and m.get("home")}
    paths, tasks = [], {}
    for d, tid, m in metas:
        if m.get("kind") in LEAD_KINDS:
            if m.get("home"):
                owner = (os.path.realpath(d), tid, f"lead {tid}")
                tasks.setdefault(tid, []).append(owner)
                paths.append((os.path.realpath(m["home"]), owner))
            continue
        home = lead_of.get(homes[os.path.realpath(d)], "main")
        owner = (os.path.realpath(d), tid, f"task {tid} ({home})")
        tasks.setdefault(tid, []).append(owner)
        if m.get("worktree"):
            paths.append((os.path.realpath(m["worktree"]), owner))
    for d, home in homes.items():
        paths.append((home, (d, "", f"lead {lead_of.get(home, 'main')}")))
    paths.sort(key=lambda p: -len(p[0]))
    return paths, tasks, homes


def consumers(state_dirs, top=3):
    # ponytail: summed RSS counts shared pages once per process; fine for ranking owners, not for accounting.
    paths, tasks, homes = owners(state_dirs)
    groups = {}
    try:
        pids = [p for p in os.listdir(PROC) if p.isdigit()]
    except OSError:
        return []
    for pid in pids:
        base = f"{PROC}/{pid}"
        try:
            status = dict(l.split(":", 1) for l in open(f"{base}/status", errors="replace") if ":" in l)
            kb = sum(int(status[k].split()[0]) for k in ("VmRSS", "VmSwap") if k in status)
        except (OSError, ValueError, IndexError):
            continue
        if kb < 10240:
            continue
        owner = None
        tid = ""
        matches = []
        try:
            tid = next((e[11:].decode(errors="replace") for e in open(f"{base}/environ", "rb").read().split(b"\0")
                        if e.startswith(b"JG_TASK_ID=")), "")
            matches = tasks.get(tid, [])
        except OSError:
            pass
        try:
            cwd = os.path.realpath(os.readlink(f"{base}/cwd"))
            owner = next((o for p, o in paths if cwd == p or cwd.startswith(p + "/")), None)
            if matches and owner not in matches:
                qualified = [o for o in matches if cwd == homes[o[0]] or
                             cwd.startswith(homes[o[0]] + "/")]
                owner = max(qualified, key=lambda o: len(homes[o[0]])) if qualified else None
        except OSError:
            pass
        owner = owner or ("", "", f"{status.get('Name', '?').strip()} pid {pid}")
        group = groups.setdefault(owner, [0, 0])
        group[0] += kb
        group[1] += 1
    ranked = sorted(groups.items(), key=lambda g: -g[1][0])[:top]
    return [(owner, f"{owner[2]} {kb / GIB_KB:.1f} GB" + (f" in {n} processes" if n > 1 else ""))
            for owner, (kb, n) in ranked]


def line(s, v, why, cons):
    if v == "UNKNOWN":
        return f"UNKNOWN\thost memory is not measurable here (no readable {PROC}/meminfo and {PROC}/pressure/memory)"
    text = summary(s) + "".join(f"; {w}" for w in why)
    return f"{v}\t{text}" + (f"; largest: {', '.join(cons)}" if cons else "")


def replace_text(path, text):
    fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def record(path, s, v):
    with open(path, "a") as f:
        pressure = "" if s["pressure"] is None else f"{s['pressure']:.2f}"
        f.write(f"{int(time.time())}\t{s['available_kb']}\t{s['swap_used_kb']}\t{pressure}\t{v}\n")
    with open(path) as f:
        rows = f.readlines()
    if len(rows) > KEEP_ROWS + 120:
        replace_text(path, "".join(rows[-KEEP_ROWS:]))


def admit(task, state, s, v, why):
    rec = os.path.join(state, "admission-refused")
    if v in ("OK", "UNKNOWN"):
        try:
            os.remove(rec)
        except FileNotFoundError:
            pass
        return 0
    reason = f"host memory under pressure: {'; '.join(why)} ({summary(s)})"
    os.makedirs(state, exist_ok=True)
    replace_text(rec, f"{int(time.time())}\t{task}\t{reason}\n")
    print(reason)
    return 1


def main():
    parser = argparse.ArgumentParser(description="Host memory guard: measure, admit, and alert before an oomd kill.")
    parser.add_argument("--config", help="thresholds file (config/host-memory); absent means the defaults")
    parser.add_argument("--admit", metavar="TASK", help="admission for one agent launch; needs --state")
    parser.add_argument("--state", metavar="DIR", help="the launching home's state directory")
    parser.add_argument("--record", metavar="FILE", help="append one sample to FILE")
    parser.add_argument("--owned-top-task", metavar="DIR", help="append the top task ID if owned by DIR")
    parser.add_argument("--state-dir", nargs=2, metavar=("HOME", "DIR"), action="append", default=[],
                        help="explicit home and its state directory whose task records map consumers")
    args = parser.parse_args()
    if args.admit and not args.state:
        die("--admit needs --state")
    cfg = load_config(args.config)
    s = sample()
    v, why = verdict(s, cfg)
    if args.admit:
        sys.exit(admit(args.admit, args.state, s, v, why))
    if args.record and s is not None:
        record(args.record, s, v)
    cons = consumers(args.state_dir) if v == "ALERT" or (not args.record and v != "UNKNOWN") else []
    output = line(s, v, why, [text for _, text in cons])
    if args.owned_top_task:
        task = cons[0][0][1] if cons and cons[0][0][0] == os.path.realpath(args.owned_top_task) else ""
        output += "\t" + task
    print(output)


if __name__ == "__main__":
    main()
