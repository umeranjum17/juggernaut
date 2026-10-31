#!/usr/bin/env bash
# Real tasks-axi -> installed watcher check -> real sign-off-axi, in isolated homes.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${JG_TICKETS_TEST_ROOT:-${TMPDIR:-/tmp}}/tickets-sync.XXXXXX")
trap 'echo "retained fixture and normalized archives: $work"' EXIT
# The fixture home's bin, and the feature's own installer's bin checks, come from the checkout this test lives in:
# $HOME/juggernaut need not exist on a machine that only cloned this repository, and a fork that is not a Juggernaut
# checkout leaves $JG_HOME/bin a dangling link that fails the install with an env 127 instead of a verdict.
fork=${JG_TEST_FORK:-$(cd "$root/.." && pwd -P)}
[ -f "$fork/bin/jg-tasks-axi.sh" ] || { echo "FAIL: $fork is not a Juggernaut checkout (no bin/jg-tasks-axi.sh); set JG_TEST_FORK"; exit 1; }
export HOME=$work/user XDG_DATA_HOME=$work/xdg SIGN_OFF_HOME=$work/signoff
export JG_HOME=$work/main
mkdir -p "$HOME" "$JG_HOME"/{data,config,state} "$work/parked/data"
ln -s "$fork/bin" "$JG_HOME/bin"
printf '{"schema":2,"items":[]}\n' > "$work/board.json"
printf '%s\n' "$work/board.json" > "$JG_HOME/config/fleet-board"
printf '%s\n' "- parked - Umer project (home: $work/parked; scope: demo)" > "$JG_HOME/data/squad_leads.md"
printf 'parked\n' > "$JG_HOME/config/parked-homes"
printf '[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$JG_HOME/.tasks.toml"
cp "$JG_HOME/.tasks.toml" "$work/parked/.tasks.toml"
(cd "$JG_HOME"; tasks-axi add parent '[captain-ask] P1 Parent: Umer release' --repo alpha --priority 1 --body 'type: captain-ask: "Umer telescope focus should be simple"' >/dev/null
 tasks-axi 'done' parent --no-prune >/dev/null
 tasks-axi add long "Umer 🚢 $(printf 'long title %.0s' {1..30})" --repo alpha --priority 1 --body $'release: v1\nhttps://github.com/example/alpha/pull/123\nhttps://github.com/example/alpha/pull/456' >/dev/null
 tasks-axi start long >/dev/null
 tasks-axi add upkeep 'Umer maintenance' --repo alpha --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add held 'Umer paused item' --repo alpha --priority 1 --body 'parent: missing' >/dev/null
 tasks-axi hold held --reason 'Umer parked this item' --kind parked >/dev/null
 tasks-axi add voice 'Umer voice practice' --repo ownvoice --priority 2 --body 'release: soon' >/dev/null
 tasks-axi add take 'Umer takes' --repo takeone --priority 2 >/dev/null
 tasks-axi add gone 'Umer queued item whose worker has gone' --repo alpha --priority 2 >/dev/null
 tasks-axi add inferred 'Umer telescope focus regression' --repo alpha --priority 1 >/dev/null
 tasks-axi add internal 'Umer internal maintenance' --repo herdr --priority 2 --body 'parent: upkeep' >/dev/null
 tasks-axi add child '[captain-ask] P0 Umer settings' --repo alpha --priority 0 --body "$(printf 'Umer notes %.0s' {1..80})"$'\nrelease: v1\nparent: parent' >/dev/null)
sed -i "/^- \[x\] parent /s/$(date +%F)/2000-01-01/g" "$JG_HOME/data/backlog.md"
(cd "$work/parked"; tasks-axi add parent 'Umer paused project' --repo beta --priority 2 >/dev/null)
printf '\n## Done\n- [x] recent - Umer shipped feature (repo: alpha) (done %s)\n- [x] old - Umer historical work (repo: alpha) (done 2000-01-01)\n' "$(date +%F)" >> "$JG_HOME/data/backlog.md"
git init -q "$JG_HOME/projects/alpha"
git -C "$JG_HOME/projects/alpha" remote add origin https://github.com/example/alpha-app.git
printf 'window=default:w9:p1\nendpoint_task_id=long\nharness=pi\nmodel=ollama-cloud/deepseek-v4.1-flash\neffort=high\naccount=found-claude\n' > "$JG_HOME/state/long.meta"
printf 'working [at=1700000000]: building Umer release\n' > "$JG_HOME/state/long.status"
printf 'harness=pi\nmodel=ollama-cloud/deepseek-v4.1-flash\neffort=high\naccount=found-claude\n' > "$JG_HOME/state/gone.meta"
printf 'paused [at=1700000010]: ran once and stopped\n' > "$JG_HOME/state/gone.status"
sign-off-axi ticket "$work/board.json" --id jg-legacy-fixture --title 'Needs a parent · alpha' --progress 17 --asked yes >/dev/null
sign-off-axi ticket "$work/board.json" --id jg-history-fixture --title 'Umer historical maintenance' --project main --progress 100 --asked no >/dev/null
source_before=$(sha256sum "$JG_HOME/data/backlog.md" "$work/parked/data/backlog.md")
bash "$root/tickets-sync/wiring.sh" --dry-run
test ! -d "$XDG_DATA_HOME/jg-tickets-sync"
bash "$root/tickets-sync/wiring.sh"
printf 'not an image' > "$XDG_DATA_HOME/jg-tickets-sync/tickets-sync/icons/takeone.png"
env -u JG_HOME "$JG_HOME/state/tickets-sync.check.sh" | tee "$work/first.out"
# Missing/broken icons are recorded quietly; check stdout would wake Main.
jq -e '.["alpha-app"] == "no local image" and .takeone == "not a readable png image"' "$JG_HOME/state/tickets-sync/icons-skipped.json"
grep -q 'icon skipped' "$work/first.out" && { echo 'FAIL: icon skip must not print to check stdout'; exit 1; }
# Finished backfill wakes once with a summary; mid-pass continue does not.
grep -qE '^tickets-sync: [0-9]+ homes read; [0-9]+ tickets changed$' "$work/first.out"
grep -q continuing "$work/first.out" && { echo 'FAIL: backfill continue must not print to check stdout'; exit 1; }
rm -f "$JG_HOME/state/tickets-sync/cursor.json" "$JG_HOME/state/tickets-sync/progress.log"
JG_TICKETS_SYNC_BUDGET_SECS=0 JG_HOME="$JG_HOME" python3 "$XDG_DATA_HOME/jg-tickets-sync/tickets-sync/sync.py" > "$work/continue.out"
grep -q continuing "$work/continue.out" && { echo 'FAIL: backfill continue must stay off stdout'; exit 1; }
grep -q continuing "$JG_HOME/state/tickets-sync/progress.log"
test -s "$JG_HOME/state/tickets-sync/cursor.json"
printf 'working [at=1700000050]: still building Umer release\n' >> "$JG_HOME/state/long.status"
"$JG_HOME/state/tickets-sync.check.sh" > "$work/resume.out"
grep -q continuing "$work/resume.out" && { echo 'FAIL: resumed backfill continue must stay off stdout'; exit 1; }
grep -qE '^tickets-sync: [0-9]+ homes read; [0-9]+ tickets changed$' "$work/resume.out"
echo 'PASS: backfill continue is quiet; finished pass wakes once with a summary'
ticket_id() { printf 'jg-%s\n' "$(printf '%s' "$1" | sha256sum | cut -c1-32)"; }
child=$(ticket_id main/child) parent=$(ticket_id main/parent) parked=$(ticket_id parked/parent)
sign-off-axi ticket "$work/board.json" --json > "$work/first.json" || { cat "$work/first.json"; exit 1; }
jq -e '.tickets | all(.[]; (.title | length) <= 160) and all(.[]; (.title | startswith("Needs a parent")) | not)'  "$work/first.json"
jq -e --arg id "$child" --arg parent "$parent" '.tickets[] | select(.id == $id) | .parent == $parent and .priority == "P0" and .asked == false and .title == "Umer settings" and .release == "v1"' "$work/first.json"
jq -e --arg id "$parked" '.tickets[] | select(.id == $id) | .hold == true' "$work/first.json"
jq -e --arg id "$(ticket_id main/held)" '[.tickets[] | select(.id == $id and .hold == true)] | length == 1' "$work/first.json"
upkeep=$(ticket_id fleet/:upkeep)
jq -e --arg root "$parent" --arg upkeep "$upkeep" '.tickets as $ts | all($ts[]; ((.parent // "") != "") or .id == $root or .id == $upkeep) and any($ts[]; .id == $root and .title == "Umer telescope focus should be simple") and any($ts[]; .id == $upkeep and .asked == false and .title == "Not from your asks (fleet upkeep)")' "$work/first.json"
jq -e --arg upkeep "$upkeep" '.tickets[] | select(.id == "jg-legacy-fixture") | .parent == $upkeep and .asked == false and .progress == 0' "$work/first.json"
jq -e --arg upkeep "$upkeep" '.tickets[] | select(.id == "jg-history-fixture") | .parent == $upkeep and (.project // "") == ""' "$work/first.json"
jq -e --arg inferred "$(ticket_id main/inferred)" --arg parent "$parent" '.tickets[] | select(.id == $inferred) | .parent == $parent' "$work/first.json"
# herdr is an internal home: no ticket project label and no icon wake line.
jq -e --arg internal "$(ticket_id main/internal)" '.tickets[] | select(.id == $internal) | (.project // "") == ""' "$work/first.json"
# The feed record carries the assignee the board shows, and it is never blank: the owning lead with the live
# worker's harness, model, effort and account, the last values a queued item's gone worker left, a plain
# "no worker yet" for work no worker has run, and the home that publishes a fleet-wide row as its owner.
feed_assignee() { jq -s --arg id "$1" 'map(select(.id == $id)) | last | .assignee' "$work/board.tickets.jsonl"; }
feed_assignee "$(ticket_id main/long)" | jq -e '.lead == "main" and .live == true and .model == "ollama-cloud/deepseek-v4.1-flash" and .tool == "pi" and .effort == "high" and .account == "found-claude" and .worker == "found-claude" and .worker_id == "long"'
feed_assignee "$(ticket_id main/gone)" | jq -e '.lead == "main" and .live == false and .model == "ollama-cloud/deepseek-v4.1-flash" and .tool == "pi" and .effort == "high" and .account == "found-claude"'
feed_assignee "$(ticket_id main/voice)" | jq -e '.lead == "main" and .live == false and .model == "no worker yet" and .tool == "no worker yet" and .effort == "no worker yet" and .worker == "no worker yet" and (has("account") | not)'
# A fleet-wide row matches no lead in the registry, so the home that publishes it owns it: never "unassigned".
feed_assignee "$upkeep" | jq -e '.lead == "main" and .live == false and (.lead != "unassigned")'
# The added field takes nothing away: the feed's newest line for the live ticket reads back as the same record.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e \
  --slurpfile feed <(jq -s --arg id "$(ticket_id main/long)" 'map(select(.id == $id)) | last' "$work/board.tickets.jsonl") \
  '.ticket.title == $feed[0].title and .ticket.progress == $feed[0].progress and .ticket.stage == $feed[0].stage and .ticket.state == $feed[0].state and .ticket.last_event_at == $feed[0].last_event_at'
echo 'PASS: the feed record carries a never-blank owner with the live or last worker, and no worker yet'
# A backlog record carries a date and no time, so a ticket with no lane event is stamped with the start of that day:
# a later hour would sit in the future and hold off the board's six-hour stall line, which is how a queued item came
# to show nothing but 0% for fifteen hours. A ticket that never gets this field can never show as stalled at all.
day=$(date -u -d "$(date -u +%F)" +%s)
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/voice)" --json | jq -e --argjson day "$day" '.ticket.last_event_at == $day and .ticket.stage == "queued"'
echo 'PASS: a queued ticket with no lane event is stamped at the start of its day, so the stall line can fire'
# Board wins over a drifted ledger that already recorded project cleared.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/internal)" --project herdr >/dev/null
python3 - <<PY
import json, hashlib
from pathlib import Path
state = Path("$JG_HOME/state/tickets-sync")
ledger_path = next(state.glob("published-*.json"))
ledger = json.loads(ledger_path.read_text())
tid = "$(ticket_id main/internal)"
desired = {"project": "", "parent": "$upkeep"}
ledger[tid] = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
ledger_path.write_text(json.dumps(ledger))
PY
"$JG_HOME/state/tickets-sync.check.sh" >/dev/null
jq -e --arg internal "$(ticket_id main/internal)" '.tickets[] | select(.id == $internal) | (.project // "") == ""' <(sign-off-axi ticket "$work/board.json" --json)
grep -qiE 'herdr( |$)' "$work/first.out" && { echo 'FAIL: herdr must not appear on check stdout'; exit 1; }
sign-off-axi project "$work/board.json" --json | jq -e '[.projects[] | .name | ascii_downcase] | (index("herdr") == null) and (index("herdr-runtime") == null)'
sign-off-axi project "$work/board.json" --json | jq -e '[.projects[] | .name] == ["ownvoice"] and .projects[0].icon.sha256 == "'"$(sha256sum "$root/tickets-sync/icons/ownvoice.png" | cut -d" " -f1)"'"'
cmp "$root/tickets-sync/icons/ownvoice.png" "$work/icons/ownvoice.png"
test ! -e "$work/icons/takeone.png"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 30 and .ticket.state == "in progress" and .ticket.stage == "building" and .ticket.last_event_at == 1700000050'
printf 'working [key=nm-umer-ci] [at=1700000100]: checking CI\n' >> "$JG_HOME/state/long.status"
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 65 and .ticket.stage == "review" and .ticket.last_event_at == 1700000100'
printf 'done [at=1700000200]: ready to merge\n' >> "$JG_HOME/state/long.status"
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 90 and .ticket.stage == "merging" and .ticket.last_event_at == 1700000200'
# A timing word in the release field is no release: the board keeps none.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/voice)" --json | jq -e '(.ticket.release // "") == ""'
printf 'cancelled [at=1700000300]: Umer cancelled this task\n' >> "$JG_HOME/state/long.status"
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/long)" --json | jq -e '.ticket.progress == 100 and .ticket.state == "done" and .ticket.stage == "done" and .ticket.last_event_at == 1700000300'
JG_HOME="$JG_HOME" python3 "$XDG_DATA_HOME/jg-tickets-sync/tickets-sync/sync.py" --close main/held --reason superseded --reconcile
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/held)" --json | jq -e '.ticket.progress == 100 and .ticket.hold == false'
before=$(sha256sum "$work/board.tickets.jsonl" "$work/board.projects.jsonl")
rm "$JG_HOME/state/tickets-sync/closures.json"
mv "$JG_HOME/state/tickets-sync"/published-*.json "$JG_HOME/state/tickets-sync/ledger-before-restart"
"$JG_HOME/state/tickets-sync.check.sh"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl" "$work/board.projects.jsonl")"
test "$source_before" = "$(sha256sum "$JG_HOME/data/backlog.md" "$work/parked/data/backlog.md")"
(cd "$JG_HOME"; tasks-axi 'done' child --pr https://github.com/example/alpha/pull/1 >/dev/null; tasks-axi 'done' inferred >/dev/null)
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$child" --json > "$work/closed.json"
jq -e '.ticket | .progress == 100 and .hold == false and (.prs | index("https://github.com/example/alpha/pull/1") != null)' "$work/closed.json"
before=$(sha256sum "$work/board.tickets.jsonl")
"$JG_HOME/state/tickets-sync.check.sh" > "$work/steady.out"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
# sign-off reports an absent field as null and a grouping row's progress as its children's
# roll-up, so a settled board must publish nothing: a republish every check is the defect.
grep -q 'tickets changed' "$work/steady.out" && { echo "FAIL: settled board republished rows: $(cat "$work/steady.out")"; exit 1; }
sign-off-axi ticket "$work/board.json" --id "$parent" --json | jq -e '.ticket.progress == 100'
echo 'PASS: completed sync stays idempotent; epic progress rolls up from its child'

if command -v gh-axi >/dev/null && [ -n "${JG_TEST_MERGED_PR:-}" ]; then
  (cd "$JG_HOME"; tasks-axi add merged 'Umer shipped PR' --repo alpha --priority 1 --body "pr: $JG_TEST_MERGED_PR" >/dev/null; tasks-axi start merged >/dev/null)
  "$JG_HOME/state/tickets-sync.check.sh"
  sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/merged)" --json | jq -e '.ticket.progress == 100 and .ticket.state == "done"'
  echo 'PASS: merged GitHub PR closes an in-flight backlog item'
fi

(cd "$JG_HOME"; tasks-axi add other '[captain-ask] P1 Umer telescope focus second request' --repo alpha --priority 1 >/dev/null
 tasks-axi add ambiguous 'Umer telescope focus diagnostic' --repo alpha --priority 1 >/dev/null)
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/ambiguous)" --json | jq -e --arg upkeep "$upkeep" '.ticket.parent == $upkeep'
echo 'PASS: confirmed tagged children, specific orphan match, ambiguous upkeep, plain/quoted asks and internal-project clearing'

sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/other)" --json | jq -e '.ticket.title == "Umer telescope focus second request"'
(cd "$JG_HOME"; tasks-axi add refresh 'Umer active refresh check' --repo alpha --priority 2 --body "$(printf 'Umer notes %.0s' {1..80})"$'\nparent: parent')
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e --arg parent "$parent" '.ticket.parent == $parent'
(cd "$JG_HOME"; tasks-axi update refresh --body "$(printf 'Umer notes %.0s' {1..80})"$'\nparent: other')
"$JG_HOME/state/tickets-sync.check.sh"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e --arg parent "$(ticket_id main/other)" '.ticket.parent == $parent'
echo 'PASS: full-body parent beyond list truncation and source revision refresh'

# The lifecycle writer records what a merge, a dispatch or a cleanup knows at the
# moment it happens; a repeated step appends nothing, and an unknown ticket is a no-op.
WRITER="$XDG_DATA_HOME/jg-tickets-sync/tickets-sync/ticket.py"
JG_HOME="$JG_HOME" python3 "$WRITER" refresh --stage merging --pr https://github.com/example/alpha/pull/999 --release v9
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e '.ticket.stage == "merging" and .ticket.prs == ["https://github.com/example/alpha/pull/999"] and .ticket.release == "v9"'
before=$(sha256sum "$work/board.tickets.jsonl")
JG_HOME="$JG_HOME" python3 "$WRITER" refresh --stage merging --pr https://github.com/example/alpha/pull/999 --release v9
JG_HOME="$JG_HOME" python3 "$WRITER" never-published --stage building
JG_HOME="$work/no-board" python3 "$WRITER" refresh --stage building
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
JG_HOME="$JG_HOME" python3 "$WRITER" refresh --state "done"
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/refresh)" --json | jq -e '.ticket.state == "done" and .ticket.progress == 100'
echo 'PASS: the lifecycle writer corrects an existing ticket only where it differs'

# The stale check names the ticket its own work contradicts and the board row no
# home's work accounts for, writes nothing, and falls silent on a settled board.
# The board can lag the work: this ticket still says in progress after its item closed.
sign-off-axi ticket "$work/board.json" --id "$(ticket_id main/inferred)" --state "in progress" >/dev/null
before=$(sha256sum "$work/board.tickets.jsonl")
out=$("$JG_HOME/state/tickets-stale.check.sh")
# ...and the fixture still holds the surplus row its earlier grouping history left behind.
grep -q 'Umer telescope focus regression' <<<"$out"
grep -q "no home's work accounts for it" <<<"$out"
test "$before" = "$(sha256sum "$work/board.tickets.jsonl")"
# The fixture's leftover row from its earlier grouping history is the surplus row the
# check is for; closing it and settling the rest leaves the board true and silent.
sign-off-axi ticket "$work/board.json" --id jg-history-fixture --state "done" >/dev/null
"$JG_HOME/state/tickets-sync.check.sh" >/dev/null
test -z "$("$JG_HOME/state/tickets-stale.check.sh")"
echo 'PASS: the stale check flags a contradicting and an orphaned ticket, writes nothing, and silences a settled board'

# The daily clean-up flags what needs a keep/remove call, back-fills a captain quote's
# date and source from the steer record, raises one card and prints one line a day.
(cd "$JG_HOME"; tasks-axi add ask3 '[captain-ask] P2 Umer ask three' --repo alpha --priority 2 --body 'type: captain-ask: "Umer wants the board to show quotes always"' >/dev/null
 tasks-axi add dupa 'Umer duplicate thing' --repo alpha --priority 2 >/dev/null
 tasks-axi add dupb 'Umer duplicate thing.' --repo alpha --priority 2 >/dev/null
 tasks-axi add old 'Umer quiet urgent work' --repo alpha --priority 1 >/dev/null
 tasks-axi start old >/dev/null)
printf 'working [at=1700000000]: started\n' > "$JG_HOME/state/old.status"
mkdir -p "$JG_HOME/state/lane.inbox"
printf 'schema=jg-task-inbox.v1\nat=2026-10-28T10:00:00Z\n--\nCaptain: Umer wants the board to show quotes always\n' > "$JG_HOME/state/lane.inbox/001.msg"
"$JG_HOME/state/tickets-sync.check.sh" >/dev/null
printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec python3 %q --cleanup 2>&1\n' "$JG_HOME" "$XDG_DATA_HOME/jg-tickets-sync/tickets-sync/sync.py" > "$work/cleanup.sh"
sign-off-axi raise "$work/board.json" --ticket "$(ticket_id main/ask3)" --ask-ref ask3 --key ask3 --title "Show quotes always?" --why "Captain ask on record." --outcome yes=Done --outcome no=Not --recommend yes --recommend-reason ok --default yes >/dev/null
out=$(bash "$work/cleanup.sh")
grep -q '^tickets-cleanup: flagged .*duplicate.*no-ask-card.*no-quote.*stale' <<<"$out"
grep -q '1 quotes back-filled' <<<"$out"
grep -q "quoted-at: 2026-10-28" <(cd "$JG_HOME"; tasks-axi show ask3 --full)
grep -q "source: $JG_HOME/state/lane.inbox/001.msg" <(cd "$JG_HOME"; tasks-axi show ask3 --full)
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
grep -q "ticket-cleanup-$(date -u +%F)" "$work/cards.json"
jq -e '[.decisions[].detail // ""] | any(contains("no-ask-card: main/other")) and (any(contains("no-ask-card: main/ask3")) | not)' "$work/cards.json"
test -z "$(bash "$work/cleanup.sh")"
echo 'PASS: the daily clean-up flags, back-fills a quote from the steer record, raises one card and runs once a day'

# The card reconcile (same daily pass) archives a waiting card whose ticket is done, keeps one whose
# ticket is open, and lists a card with no source to check for Main.
rm -f "$JG_HOME/state/tickets-sync/cleanup.day"
raise_card() { sign-off-axi raise "$work/board.json" --key "$1" --ask-ref "$1" --title "$2" --why "Fixture card." --outcome yes=Done --outcome no=Not --recommend yes --recommend-reason ok --default yes "${@:3}" >/dev/null; }
raise_card closed-source "Is the old history still wanted?" --ticket jg-history-fixture
raise_card open-source "Is the open ask still wanted?" --ticket "$(ticket_id main/ask3)"
raise_card no-source "Does the unlinked thing matter?"
out=$(bash "$work/cleanup.sh")
grep -q '^cards: 1 archived, [0-9]* kept (source open), 1 for Main' <<<"$out"
grep -q 'no-source - Does the unlinked thing matter?' <<<"$out"
sign-off-axi list "$work/board.json" --json > "$work/cards.json"
jq -e '.decisions | (map(select(.key == "closed-source" and .dismissed)) | length == 1) and (map(select(.key == "open-source" and (.dismissed | not))) | length == 1) and (map(select(.key == "no-source" and (.dismissed | not))) | length == 1)' "$work/cards.json"
grep -q 'dismissed closed-source (done-elsewhere): ticket .* is done' "$JG_HOME/state/tickets-sync/card-reconcile.log"
echo 'PASS: the card reconcile archives a closed-source card, keeps an open-source one and lists an unjudged one'

# A board that still shows the row the poll published before it re-keyed its ids (fm-<hash> beside jg-<hash>) is the
# same work, so that row names the same owner: only the assignee moves, and its own fields stay as they were.
(cd "$JG_HOME"; tasks-axi add legacy 'Umer legacy row item' --repo alpha --priority 2 >/dev/null)
legacy="fm-$(ticket_id main/legacy | cut -c4-)"
sign-off-axi ticket "$work/board.json" --id "$legacy" --title 'Umer legacy row item' --state queued >/dev/null
"$JG_HOME/state/tickets-sync.check.sh" >/dev/null
feed_assignee "$legacy" | jq -e '.lead == "main" and .live == false and .model == "no worker yet"'
sign-off-axi ticket "$work/board.json" --id "$legacy" --json | jq -e '.ticket.title == "Umer legacy row item" and .ticket.state == "queued" and .ticket.progress == 0 and ((.ticket.last_event_at // "") == "") and ((.ticket.stage // "") == "")'
echo 'PASS: the row from before the re-keyed ids names the same owner, and only that field moves'
