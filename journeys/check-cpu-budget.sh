#!/usr/bin/env bash
# The watcher's slow checks stay under their 5 CPU-second budget (JG_WATCH_CHECK_CPU_BUDGET) on lab homes shaped like a busy home:
#   - board-answers: one `bin/jg-board-answers.sh check` pass at steady state over a 4.5 MB board of 2144 cards with 93 answers,
#     19 of them on cards with no options, read through the real sign-off-axi;
#   - delivery-tick's landing check: one `core/trunk-landing/trunk-landing.sh check` pass over 3 local-trunk projects (and 3 backup
#     trunk-tip files), 10 lanes (2 reported done) and 1113 landing state files, with detached jobs stubbed;
#   - the landing check's running_lanes loop, taken from the script, over the same 1113 state files with 2 landings running.
# Each figure is the median of 5 passes. CHECK_CPU_BEFORE_REF=<git ref> (default HEAD^) measures that ref the same way, for comparison.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ev=${DONE_DONE_EVIDENCE_ROOT:?}
out=$ev/${DONE_DONE_RUN_ID:-${RUN_ID:-run}}.log
budget=${JG_WATCH_CHECK_CPU_BUDGET:-5}
d=$(mktemp -d)
trap 'rm -rf -- "$d"' EXIT

cpu_of() {  # <command...>: the CPU seconds (user + system) the command and every process it waited on used
  local TIMEFORMAT='%U %S' t
  t=$( { time "$@" > "$d/cmd.out" 2>&1; } 2>&1 )
  awk -v t="$t" 'BEGIN { split(t, f, " "); printf "%.2f\n", f[1] + f[2] }'
}
median() { sort -n | sed -n 3p; }  # of 5 lines

board_home() {  # <dir>: a home and a board shaped like the shared one on 2026-11-21
  mkdir -p "$1/home/state" "$1/home/data" "$1/home/config" "$1/so/.sign-off"
  python3 - "$1/so/.sign-off" <<'PY'
import json, sys
out = sys.argv[1]
items, answers, n_opt, n_none = [], [], 0, 0
for i in range(2144):
    item = {"filed": "2026-11-01T00:00:00Z", "key": f"umer-card-{i}", "title": f"Umer lab card {i}?", "why": "Umer lab reason. " * 120}
    if i % 5:
        item["options"] = [{"value": "yes", "label": "Yes", "outcome": "Yes."}, {"value": "no", "label": "No", "outcome": "No."}]
    else:
        item.update(kind="report", purpose="research", about="a lab report", sections=[])
    items.append(item)
    if i % 5 and n_opt < 74: n_opt += 1
    elif not i % 5 and n_none < 19: n_none += 1
    else: continue
    answers.append({"key": item["key"], "answer": "yes" if i % 5 else "seen", "label": "Answered in chat", "close": "done",
                    "at": f"2026-11-10T02:{i % 60:02d}:{i % 59:02d}Z"})
json.dump({"schema": 2, "items": items}, open(f"{out}/decisions.json", "w"))
with open(f"{out}/decisions.answers.jsonl", "w") as f:
    f.writelines(json.dumps(a) + "\n" for a in answers)
PY
}

board_answers() {  # <tree> <label>
  local w=$d/board-$2 i
  board_home "$w"
  run() { env JG_HOME="$w/home" JG_STATE_OVERRIDE="$w/home/state" JG_DATA_OVERRIDE="$w/home/data" JG_CONFIG_OVERRIDE="$w/home/config" \
    SIGN_OFF_HOME="$w/so" bash "$1/bin/jg-board-answers.sh" check; }
  cpu_of run "$1" >/dev/null; cpu_of run "$1" >/dev/null  # the first pass routes every answer; the steady state starts after it
  printf '%s board-answers check: %s cpu-seconds per pass\n' "$2" "$(for i in 1 2 3 4 5; do cpu_of run "$1"; done | median)"
}

landing_home() {  # <home dir> <fakebin dir>
  local h=$1 p tip i
  mkdir -p "$h/state" "$h/data/jg-trunk-landing" "$h/config" "$h/projects" "$2"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$2/systemd-run"; chmod +x "$2/systemd-run"
  : > "$h/data/projects.md"
  for p in umer-app umer-api umer-web; do
    git init -q -b main "$h/projects/$p"
    git -C "$h/projects/$p" -c user.email=umer@example.com -c user.name=Umer commit -q --allow-empty -m init
    git -C "$h/projects/$p" branch trunk
    tip=$(git -C "$h/projects/$p" rev-parse HEAD)
    printf '%s\n' "$tip" | tee "$h/state/trunk-tip-$p" "$h/state/trunk-green-$p" "$h/state/trunk-tip-$p.bak-1794075222" >/dev/null
    printf 'trunk\n' > "$h/state/trunk-branch-$p"
    printf -- '- %s [local-trunk +yolo] - Umer lab project (added 2026-11-01)\n' "$p" >> "$h/data/projects.md"
  done
  for i in $(seq 1 10); do
    p=umer-app; [ $((i % 3)) -ne 1 ] || p=umer-api; [ $((i % 3)) -ne 2 ] || p=umer-web
    git -C "$h/projects/$p" branch "fixlab-$i" trunk
    printf 'kind=ship\nmode=local-trunk\nyolo=on\nproject=%s\nbranch=fixlab-%s\nticket=lab-%s\n' "$h/projects/$p" "$i" "$i" > "$h/state/lab-$i.meta"
    if [ "$i" -le 2 ]; then printf 'done [at=1795230000]: ready in branch fixlab-%s (local-trunk)\n' "$i"
    else printf 'working [at=1795230000]: Umer lab lane\n'; fi > "$h/state/lab-$i.status"
  done
  for i in $(seq 1 1113); do
    case $((i % 3)) in 0) p='landed 1795000000' ;; 1) p='final conflict' ;; *) p='wait proof' ;; esac
    printf '%s\n' "$p" > "$h/data/jg-trunk-landing/old-$i.$(printf '%040x' "$i").state"
  done
}

landing_check() {  # <tree> <label>
  local h=$d/landing-$2/home fb=$d/landing-$2/fakebin i
  landing_home "$h" "$fb"
  for i in bin core policy defaults; do ln -s "$1/$i" "$h/$i"; done
  run() { env PATH="$fb:$PATH" JG_TEST_SEAM=1 JG_TRUNK_SYSTEMD_RUN="$fb/systemd-run" JG_LANDING_DISPATCH_KICK=0 \
    bash "$1/core/trunk-landing/trunk-landing.sh" check "$h"; }
  cpu_of run "$1" >/dev/null
  printf '%s landing check: %s cpu-seconds per pass\n' "$2" "$(for i in 1 2 3 4 5; do cpu_of run "$1"; done | median)"
}

running_lanes_loop() {  # <tree> <label>
  local MEM=$d/lanes-$2 STATE=$d/lanes-$2/state i w
  mkdir -p "$STATE"
  for i in $(seq 1 1113); do
    w='landed 1795000000'; [ "$i" -gt 2 ] || w="running $(date +%s) $$"
    printf '%s\n' "$w" > "$MEM/lab-$i.$(printf '%040x' "$i").state"
  done
  # shellcheck disable=SC2034 # read by the loop taken from the tree
  (
    jg_pid_alive() { kill -0 "$1" 2>/dev/null; }
    mval() { :; }; partition_queue_of() { :; }; partition_scripts() { :; }
    eval "$(sed -n '/^run_alive() {/,/^}/p; /^running_lanes() {/,/^}/p' "$1/core/trunk-landing/trunk-landing.sh")"
    [ "$(running_lanes | wc -l)" = 2 ] || { echo "$2 running_lanes did not list the 2 running landings"; exit 1; }
    printf '%s running_lanes loop: %s cpu-seconds per pass\n' "$2" "$(for i in 1 2 3 4 5; do cpu_of running_lanes; done | median)"
  )
}

run_all() {
  local rc=0 before=${CHECK_CPU_BEFORE_REF:-HEAD^} tree label
  command -v sign-off-axi >/dev/null || { echo "FAIL: sign-off-axi is not on PATH, so the board-answers pass cannot be measured"; return 1; }
  echo "=== check CPU on lab homes, budget $budget s, load $(cut -d' ' -f1-3 /proc/loadavg) ==="
  if git -C "$root" rev-parse --verify --quiet "$before^{commit}" >/dev/null; then
    mkdir -p "$d/before-tree"
    git -C "$root" archive "$before" bin core policy defaults | tar -x -C "$d/before-tree"
    label="before $(git -C "$root" rev-parse --short "$before")"
    { board_answers "$d/before-tree" "$label"; landing_check "$d/before-tree" "$label"; running_lanes_loop "$d/before-tree" "$label"; } \
      | tee "$ev/check-cpu-before.txt"
  fi
  tree=$root label="after $(git -C "$root" rev-parse --short HEAD)"
  { board_answers "$tree" "$label"; landing_check "$tree" "$label"; running_lanes_loop "$tree" "$label"; } | tee "$ev/check-cpu-after.txt"
  [ "$(grep -c 'cpu-seconds per pass' "$ev/check-cpu-after.txt")" = 3 ] || { echo "FAIL: a measurement did not finish"; rc=1; }
  awk -v b="$budget" '/cpu-seconds per pass/ { if ($(NF-3) + 0 >= b) { print "FAIL: over budget: " $0; bad = 1 } } END { exit bad }' \
    "$ev/check-cpu-after.txt" || rc=1
  [ "$rc" -ne 0 ] || echo "PASS every measured check is under its $budget CPU-second budget"
  return "$rc"
}

run_all > "$out" 2>&1
rc=$?
cat "$out"
cat > "$ev/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "throwaway lab homes: a 4.5 MB board of 2144 cards with 93 answers (19 on cards with no options), and a landing home with 3 local-trunk projects, 10 lanes and 1113 landing state files",
 "steps": ["run the board-answers check twice, then time 5 steady passes", "time 5 landing check passes", "time 5 passes of the running_lanes loop with 2 landings running", "do the same for the before ref"],
 "result": "each measured check uses under ${budget} CPU seconds per pass at this head"}
JSON
exit "$rc"
