#!/usr/bin/env bash
# The Recon depth gate: one shell check on a Recon's files, never a model call.
#
# Usage: jg-recon-gate.sh <task-id> [--depth <quick|standard|deep>]
#
# bin/jg-brief.sh --scout writes `Recon depth: <level>` into a standard or deep
# Recon's brief, and .agents/skills/deep-recon/SKILL.md owns the method. Before
# such a Recon may report `done`, this gate reads data/<task-id>/ and refuses when:
#   - report.md lacks one of the 13 template sections (`## <n>. <name>`, in order,
#     with a body), or a deep report writes "Not applicable" under section 8 or 11;
#   - a load-bearing claim in claims.jsonl is neither `verified` in checks.jsonl
#     nor named by its C-n id in the report's "Not checked" section, or a refuted
#     claim is still cited in the report body;
#   - a deep claim is `verified` on one source with no hands-on run;
#   - critic.md is missing, names no `Critic:`, has no `Round n: new gaps k` line,
#     or its last round found new gaps with no `Closure check: <k> closed by
#     <critic>` line after it (the same critic as `Critic:`, never `self` or the
#     researcher's own task id, closing all k gaps); a deep critic may not be
#     `self` or the researcher's own task id, and a deep Recon allows 3 rounds
#     that found new gaps;
#   - sources.jsonl is under the level's budget: standard 8 sources over 3 kinds,
#     deep 20 over 5.
# Quick is exempt, and so is a brief with no depth line (a brief made before the
# flag existed). The depth is read from data/<task-id>/brief.md unless --depth is
# given. The data directory is JG_DATA_OVERRIDE, else <JG_HOME>/data.
#
# A critic task is judged on its critic.md alone. Its data directory holds a
# critic.md whose `Critic:` line names the task itself and no report.md; the
# researcher's report is not its product. It passes with that `Critic:` line and
# one `Round <n>: new gaps <k>` line, at any depth. `--is-critic` only asks
# whether the task is one: exit 0 when it is, 1 when it is not, nothing printed.
#
# A waiver by Main is a file the gate reads: <state>/recon-gate-waiver/<task-id>
# (the state directory is JG_STATE_OVERRIDE, else <JG_HOME>/state), written by
# Main with a `waived-by: Main` line and a non-empty `reason: <why>` line. With
# a whole waiver the depth checks are skipped and the gate prints the reason;
# a waiver missing either line is refused, so a half-written file never passes.
# It waives this depth gate only, never the owner-call completion gate.
#
# It prints one line and exits 0 on success, one line per refusal and exits 1
# otherwise, and exits 2 on a usage error. A "board link missing" refusal waits
# for the board report surface and is not built here.
set -u
die() { echo "jg-recon-gate: $*" >&2; exit 2; }

task=
depth=
is_critic=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --depth) [ "$#" -ge 2 ] || die "usage: jg-recon-gate.sh <task-id> [--depth <quick|standard|deep>]"; depth=$2; shift 2 ;;
    --depth=*) depth=${1#--depth=}; shift ;;
    --is-critic) is_critic=1; shift ;;
    -*) die "usage: jg-recon-gate.sh <task-id> [--depth <quick|standard|deep>]" ;;
    *) [ -z "$task" ] || die "usage: jg-recon-gate.sh <task-id> [--depth <quick|standard|deep>]"; task=$1; shift ;;
  esac
done
[ -n "$task" ] || die "usage: jg-recon-gate.sh <task-id> [--depth <quick|standard|deep>]"
case "$task" in */*|.*) die "task id '$task' is not a plain id" ;; esac

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
data=${JG_DATA_OVERRIDE:-${JG_HOME:-$root}/data}
dir=$data/$task
[ -d "$dir" ] || die "no task directory at $dir"

# A critic task: critic.md names this task as its critic and there is no report.
critic_task=
if [ ! -f "$dir/report.md" ] && [ -f "$dir/critic.md" ]; then
  critic_who=$(sed -n 's/^Critic:[[:space:]]*//p' "$dir/critic.md" | head -1 | tr -d '[:space:]')
  [ "$(printf '%s' "$critic_who" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')" ] || critic_task=1
fi
if [ -n "$is_critic" ]; then [ -n "$critic_task" ]; exit; fi

state=${JG_STATE_OVERRIDE:-${JG_HOME:-$root}/state}
waiver=$state/recon-gate-waiver/$task
if [ -f "$waiver" ]; then
  waiver_reason=$(sed -n 's/^reason:[[:space:]]*//p' "$waiver" | head -1)
  if grep -Eqi '^waived-by:[[:space:]]*Main[[:space:]]*$' "$waiver" && [ -n "$waiver_reason" ]; then
    echo "recon gate: WAIVED by Main - $task: $waiver_reason"
    exit 0
  fi
  echo "jg-recon-gate: refused: the waiver $waiver needs a 'waived-by: Main' line and a 'reason: <why>' line" >&2
  exit 1
fi

if [ -n "$critic_task" ]; then
  if grep -Eq '^Round[[:space:]]+[0-9]+:[[:space:]]*new gaps[[:space:]]+[0-9]+' "$dir/critic.md"; then
    echo "recon gate: PASS - critic task $task: critic.md names its critic and its rounds"
    exit 0
  fi
  echo "jg-recon-gate: refused: critic.md has no 'Round <n>: new gaps <k>' line" >&2
  exit 1
fi

if [ -z "$depth" ] && [ -f "$dir/brief.md" ]; then
  depth=$(sed -n 's/^Recon depth:[[:space:]]*//p' "$dir/brief.md" | head -1 | tr -d '[:space:]')
fi
case "$depth" in
  ''|quick) echo "recon gate: exempt - ${depth:-no depth line} Recon"; exit 0 ;;
  standard|deep) ;;
  *) die "unknown depth '$depth'" ;;
esac

python3 -I - "$dir" "$task" "$depth" <<'PY'
import json, os, re, sys

d, task, depth = sys.argv[1:4]
refusals = []


def refuse(msg):
    refusals.append(msg)


def rows(name):
    path = os.path.join(d, name)
    if not os.path.isfile(path):
        refuse(f"{name} is missing")
        return []
    out = []
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            refuse(f"{name} line {n} is not JSON")
            continue
        if isinstance(row, dict):
            out.append(row)
        else:
            refuse(f"{name} line {n} is not an object")
    return out


SECTIONS = [
    "Answer", "What was asked", "Method and depth record", "Prior art and options",
    "Findings", "Design", "Not checked", "Implementation plan",
    "Risks and mitigations", "Open decisions", "Acceptance test",
    "Sources and evidence", "Revision log",
]

# --- report sections ---------------------------------------------------------
body = {}
report = ""
rpath = os.path.join(d, "report.md")
if not os.path.isfile(rpath):
    refuse("report.md is missing")
else:
    report = open(rpath, encoding="utf-8").read()
    heads = [(m.start(), int(m.group(1)), m.group(2).strip())
             for m in re.finditer(r"^## (\d+)\.\s+(.*)$", report, re.M)]
    for i, (pos, num, title) in enumerate(heads):
        end = heads[i + 1][0] if i + 1 < len(heads) else len(report)
        text = report[pos:end].split("\n", 1)[1] if "\n" in report[pos:end] else ""
        body.setdefault(num, (title, text))
    for num, name in enumerate(SECTIONS, 1):
        got = body.get(num)
        if got is None or not got[0].lower().startswith(name.lower()):
            refuse(f"report.md has no section '## {num}. {name}'")
        elif not got[1].strip():
            refuse(f"report.md section {num} '{name}' is empty")
    if depth == "deep":
        for num in (8, 11):
            got = body.get(num)
            if got and re.match(r"\s*not applicable", got[1], re.I):
                refuse(f"a deep report may not write 'Not applicable' under section {num} '{SECTIONS[num - 1]}'")

# --- sources budget ----------------------------------------------------------
sources = rows("sources.jsonl")
need_n, need_k = (8, 3) if depth == "standard" else (20, 5)
ids = {str(s.get("id")) for s in sources if s.get("id")}
kinds = {str(s.get("kind")) for s in sources if s.get("kind")}
if os.path.isfile(os.path.join(d, "sources.jsonl")) and (len(ids) < need_n or len(kinds) < need_k):
    refuse(f"source budget not met for {depth}: {len(ids)} sources over {len(kinds)} kinds, need {need_n} over {need_k}")

# --- claims and checks -------------------------------------------------------
claims = {str(c.get("id")): c for c in rows("claims.jsonl") if c.get("id")}
status, method = {}, {}
for c in rows("checks.jsonl"):
    cid = str(c.get("claim"))
    status[cid] = str(c.get("status"))
    method[cid] = str(c.get("method"))
not_checked = body.get(7, ("", ""))[1]
others = report
if 7 in body:
    others = report.replace(not_checked, "", 1)
for cid, c in sorted(claims.items()):
    st = status.get(cid, "unverified")
    if st == "refuted" and re.search(r"\[%s\]" % re.escape(cid), others):
        refuse(f"refuted claim {cid} is still cited in the report")
    if not c.get("load_bearing"):
        continue
    if st == "verified":
        if depth == "deep" and len(c.get("sources") or []) < 2 and method.get(cid) != "run":
            refuse(f"deep claim {cid} is verified on one source with no hands-on run")
    elif not re.search(r"\b%s\b" % re.escape(cid), not_checked):
        refuse(f"load-bearing claim {cid} is {st}, and section 7 'Not checked' does not list it")

# --- critic ------------------------------------------------------------------
cpath = os.path.join(d, "critic.md")
if not os.path.isfile(cpath):
    refuse("critic.md is missing")
else:
    critic = open(cpath, encoding="utf-8").read()
    who = re.search(r"^Critic:[ \t]*(\S.*)$", critic, re.M)
    rounds = re.findall(r"^Round[ \t]+(\d+):[ \t]*new gaps[ \t]+(\d+)", critic, re.M)
    if not who:
        refuse("critic.md has no 'Critic: <who>' line")
    elif depth == "deep" and who.group(1).strip().lower() in ("self", task.lower()):
        refuse("a deep Recon needs a separate critic worker; critic.md names the researcher")
    if not rounds:
        refuse("critic.md has no 'Round <n>: new gaps <k>' line")
    else:
        last_n, last_k = rounds[-1][0], int(rounds[-1][1])
        if last_k > 0:
            # A fixed last-round gap cannot get another round once the cap is
            # spent, so a closure line by the same separate critic, written after
            # that round, stands in for it. Never the researcher's own word.
            last_pos = [m.start() for m in re.finditer(r"^Round[ \t]+\d+:[ \t]*new gaps[ \t]+\d+", critic, re.M)][-1]
            closure = re.search(r"^Closure check:[ \t]*(\d+)[ \t]+closed by[ \t]+(\S+)[ \t]*$", critic[last_pos:], re.M)
            fix = f"critic.md round {last_n} found {last_k} new gaps; close them and run another round, or end with 'Closure check: {last_k} closed by <the critic>'"
            if not closure:
                refuse(fix)
            else:
                by = closure.group(2).lower()
                if by in ("self", task.lower()):
                    refuse(f"critic.md closure check is certified by '{closure.group(2)}'; only the separate critic may close a gap. {fix}")
                elif not who or by != who.group(1).strip().lower():
                    refuse(f"critic.md closure check names '{closure.group(2)}', not the critic '{who.group(1).strip() if who else ''}'. {fix}")
                elif int(closure.group(1)) != last_k:
                    refuse(f"critic.md closure check closes {closure.group(1)} of {last_k} gaps in round {last_n}. {fix}")
        # The cap counts rounds that found new gaps: the clean round that ends
        # a critic file, or the closure line, is not one of them.
        gap_rounds = sum(1 for _, k in rounds if int(k) > 0)
        if depth == "deep" and gap_rounds > 3:
            refuse(f"critic.md has {gap_rounds} rounds with new gaps; a deep Recon allows 3")

if refusals:
    for r in refusals:
        print(f"jg-recon-gate: refused: {r}", file=sys.stderr)
    sys.exit(1)
print(f"recon gate: PASS - {depth} Recon {task}: {len(ids)} sources over {len(kinds)} kinds, {len(claims)} claims")
PY
