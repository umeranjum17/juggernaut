#!/usr/bin/env bash
# tests/jg-browser-sweep.test.sh - bin/jg-browser-sweep.sh selection and its apply path.
#
# Selection runs through the real command line on a fake process table: an old bridge and an old
# puppeteer browser are named, while a young one, the user's real Chrome, a renderer child, and a
# process that only mentions the profile path are left out. The apply path then runs on real
# throwaway processes under a private profile prefix, so no process of the host is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP=$ROOT/bin/jg-browser-sweep.sh
T=$(jg_test_tmproot jg-browser-sweep)
trap jg_test_cleanup EXIT
P=/tmp/puppeteer_dev_chrome_profile-

cat >"$T/ps.txt" <<EOF
 100 1 90000 /usr/bin/node /home/u/.local/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js
 101 100 90000 chrome-devtools-mcp
 102 101 90000 /opt/google/chrome/chrome --headless=new --remote-debugging-pipe --user-data-dir=${P}OLDaaa
 103 102 90000 /opt/google/chrome/chrome --type=renderer --user-data-dir=${P}OLDaaa
 200 1 600 /usr/bin/node /home/u/.local/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js
 201 200 600 /opt/google/chrome/chrome --headless=new --user-data-dir=${P}NEWbbb
 300 1 90000 /opt/google/chrome/chrome --user-data-dir=/home/u/.config/google-chrome
 400 1 90000 /home/u/pi/pi --model x -e /tmp/puppeteer_dev_chrome_profile-OLDccc --user-data-dir=${P}OLDccc
 500 1 90000 /opt/google/chrome/chrome --headless=new --user-data-dir=${P}OLDddd
 600 1 90000 vim chrome-devtools-axi-bridge.js
EOF
printf '100 old-session\n' >"$T/sessions.txt"

out=$(JG_BROWSER_SWEEP_PS_FILE=$T/ps.txt JG_BROWSER_SWEEP_SESSIONS_FILE=$T/sessions.txt bash "$SWEEP" --dry-run 2>&1)
want=$'would stop bridge pid=100 session=old-session age=25h\nwould kill browser pid=102 profile='"${P}"$'OLDaaa age=25h\nwould kill browser pid=500 profile='"${P}"$'OLDddd age=25h'
got=$(printf '%s\n' "$out" | grep '^would')
if [ "$got" = "$want" ]; then pass "dry run names exactly the old bridge and old browsers"; else fail "selection differs: $got"; fi
if printf '%s\n' "$out" | grep -q 'nothing stopped'; then pass "dry run stops nothing"; else fail "dry run summary missing"; fi

out=$(JG_BROWSER_SWEEP_PS_FILE=$T/ps.txt JG_BROWSER_SWEEP_SESSIONS_FILE=$T/sessions.txt bash "$SWEEP" --dry-run --hours 0 --no-bridges 2>&1)
got=$(printf '%s\n' "$out" | grep -c '^would kill browser')
if [ "$got" = 3 ] && ! printf '%s\n' "$out" | grep -q 'would stop bridge'; then pass "--hours 0 and --no-bridges widen browsers only"; else fail "flags: $out"; fi

bash "$SWEEP" --hours x >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "bad --hours is a usage error"; else fail "bad --hours accepted"; fi

# Apply on real processes: a fake chrome with its own profile prefix and a child.
PFX=$T/prof-
mkdir -p "${PFX}Live1" "${PFX}Orph1"
# argv0 chrome, a child sleep under it, and the profile argument: what a real browser tree looks like to ps.
(exec -a "$T/chrome" bash -c 'sleep 300; :' --headless=new "--user-data-dir=${PFX}Live1") & pid=$!
trap 'kill "$pid" 2>/dev/null; jg_test_cleanup' EXIT
sleep 0.3
touch -d '3 days ago' "${PFX}Orph1"
out=$(JG_BROWSER_SWEEP_PROFILE_PREFIX=$PFX bash "$SWEEP" --apply --hours 0 --no-bridges 2>&1); rc=$?
if [ "$rc" = 0 ] && ! kill -0 "$pid" 2>/dev/null; then pass "apply stops the old browser"; else fail "browser alive after apply (rc=$rc): $out"; fi
if printf '%s\n' "$out" | grep -q 'browsers before=1 after=0'; then pass "apply reports the count before and after"; else fail "counts: $out"; fi
if [ ! -e "${PFX}Live1" ] && [ ! -e "${PFX}Orph1" ]; then pass "apply removes the stopped and the orphan profile folders"; else fail "profile folders remain"; fi
