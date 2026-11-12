# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 8. The report-only observer reads the older readers and prints a state of the ticket.
mkdir -p "$H"/{bin,crew,rows}
printf '#!/usr/bin/env bash\nprintf "state: %%s · source: none · fixture\\n" "$(cat "$JG_HOME/crew/$1" 2>/dev/null || echo unknown)"\n' > "$H/bin/jg-crew-state.sh"
printf '#!/usr/bin/env bash\n[ -r "$JG_HOME/rows/$2" ] || exit 1\nprintf "task:\\n  id: %%s\\n  state: %%s\\n" "$2" "$(cat "$JG_HOME/rows/$2")"\n' > "$H/bin/jg-backlog.sh"
chmod +x "$H"/bin/*.sh; printf working > "$H/crew/w-1"; printf in_flight > "$H/rows/w-1"; printf 'kind=ship\n' > "$H/state/w-1.meta"
OUT=$(JG_HOME=$H bash "$JM" show ticket w-1 2>&1); RC=$?; expect_code 0 "$RC" "show ticket"; assert_contains "$OUT" "state	building" "a working task is building"
OUT=$(JG_HOME=$H bash "$JM" show delivering w-1 2>&1); RC=$?; expect_code 1 "$RC" "a building ticket is in no sub-state of delivering"
pass "the observer maps the older readers' words"
