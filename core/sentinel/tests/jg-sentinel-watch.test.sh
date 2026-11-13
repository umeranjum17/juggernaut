#!/usr/bin/env bash
# core/sentinel/tests/jg-sentinel-watch.test.sh - the sentinel watches the home's supervision from outside (slice H16).
#
# Hermetic: a throwaway home whose bin/ and core/ are this checkout's, a stub watcher start, no Herdr, no systemd.
# Everything runs through the real caller, `jg-sentinel.sh watch`, which is what jg-sentinel-watch.service runs:
#   - a home with work and no watcher beat: the first run starts the watcher again (inside 2 runs) and the next run finds it fresh;
#   - a start that does not hold: it is tried twice, then supervision-down--watcher-dead is open; a beat that returns resolves it;
#   - a stopped session with a wake unacknowledged past the limit: supervision-down--escalation-stuck is open, and resolves when the queue empties;
#   - a home with no work starts nothing; every run leaves exactly one health row.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SENTINEL=$REPO/bin/jg-sentinel.sh
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
eq() { [ "$1" = "$2" ] || fail "$3: wanted [$2], got [$1]"; pass "$3"; }

H=$d/home S=$H/state
mkdir -p "$S" "$H/data" "$H/config"
ln -s "$REPO/bin" "$H/bin"; ln -s "$REPO/core" "$H/core"
# The stub watcher start: records the call, and beats only when the lab says it holds.
cat > "$d/start" <<SH
#!/usr/bin/env bash
echo started >> "$d/starts"
[ ! -e "$d/holds" ] || touch "$S/.last-watcher-beat"
SH
chmod +x "$d/start"
export HOME=$d/home-dir; mkdir -p "$HOME"
unset JG_BIN
watch() { JG_HOME=$H JG_SENTINEL_WATCHER_START=$d/start JG_SENTINEL_STUCK_SECS=${STUCK:-1200} bash "$SENTINEL" watch; }
starts() { [ -e "$d/starts" ] && wc -l <"$d/starts" | tr -d ' ' || echo 0; }
alert_state() { sed -n 's/^state=//p' "$S/alerts/supervision-down--$1.rec" 2>/dev/null; }
rows() { [ -e "$S/.sentinel-health.tsv" ] && wc -l <"$S/.sentinel-health.tsv" | tr -d ' ' || echo 0; }
settle() { for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; [ "$(starts)" -ge "$1" ] && return 0; done; }

# 1. No work under way: nothing is started.
watch; settle 1
eq "$(starts)" 0 "a home with no work starts no watcher"
eq "$(rows)" 1 "the run wrote one health row"

# 2. Work under way, no beat, a live session: the watcher is started again inside 2 runs.
printf 'kind=ship\n' > "$S/lane-a.meta"
sleep 300 & live=$!; trap 'kill $live 2>/dev/null; rm -rf -- "$d"' EXIT
printf '%s\n' "$live" > "$S/.lock"
: > "$d/holds"
watch; settle 1
eq "$(starts)" 1 "run 1 starts the dead watcher"
watch; settle 1
eq "$(starts)" 1 "run 2 finds the beat back and starts nothing"
eq "$(alert_state watcher-dead)" "" "no page while the start held"
eq "$(awk -F'\t' 'END {print $4}' "$S/.sentinel-health.tsv")" fresh "the health row reads the watcher fresh"

# 3. A start that does not hold: tried twice, then one page; the beat's return resolves it.
rm -f "$S/.last-watcher-beat" "$d/holds" "$d/starts"
watch; watch; settle 2
eq "$(starts)" 2 "a watcher that stays dead is started twice"
eq "$(alert_state watcher-dead)" "" "no page inside the tries"
watch
eq "$(starts)" 2 "past the tries it is not started a third time"
eq "$(alert_state watcher-dead)" open "past the tries supervision-down--watcher-dead is open"
touch "$S/.last-watcher-beat"; watch
eq "$(alert_state watcher-dead)" resolved "the beat's return resolves it"

# 4. The session is stopped and a wake waits past the limit: escalation-stuck.
kill "$live"; wait "$live" 2>/dev/null; printf '%s\n' 999999999 > "$S/.lock"
JG_HOME=$H JG_STATE_OVERRIDE=$S bash -c ". '$REPO/bin/jg-wake-lib.sh'; jg_wake_append check lab-wake 'check: lab'" >/dev/null
touch "$S/.last-watcher-beat"
STUCK=3600 watch
eq "$(alert_state escalation-stuck)" "" "a young wake with a stopped session raises nothing"
sleep 2; STUCK=1 watch
eq "$(alert_state escalation-stuck)" open "an old wake with a stopped session raises supervision-down--escalation-stuck"
: > "$S/.wake-queue"; STUCK=1 watch
eq "$(alert_state escalation-stuck)" resolved "an empty queue resolves it"
eq "$(rows)" 10 "every run left exactly one health row"
echo "PASS jg-sentinel-watch"
