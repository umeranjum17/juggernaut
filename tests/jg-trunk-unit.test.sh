#!/usr/bin/env bash
# Integration test for the landing check's detached jobs (core/trunk-landing/unit.sh) through the real tick (tests/jg-trunk-fixture.sh).
#
# The tick starts its verify in its own systemd user unit (KillMode=process, absolute log paths, the unit named jg-verify-<project>-<epoch>
# and recorded); a tick that finds that unit active starts nothing, so one verify runs at a time and the same tip is not started twice;
# with no systemd-run the tick keeps setsid nohup and the verify itself runs.
# The done-done journey journeys/trunk-landing.sh runs this file and seals its output.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# tip_after_land <id>: lands the lane and prints the new trunk tip.
tip_after_land() { trunk land "$1" >/dev/null 2>&1 || fail "$1 must land"; tip; }

# The tick starts the verify in its own systemd user unit when systemd-run exists (core/trunk-landing/unit.sh): the unit survives the
# cleanup of the tick's cgroup. A stand-in systemd-run records its arguments and runs nothing; a stand-in systemctl reports the recorded unit
# active while $W/unit-active exists. With no systemd-run the tick keeps setsid nohup and the verify really runs.
test_the_tick_starts_its_verify_in_its_own_unit_once_and_falls_back_to_setsid() {
  local base home calls n unit
  world unit
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  printf 'gate-full=true\ngate-verify=true\n' >> "$HOME_D/config/trunk-policy"
  base=$(tip); printf '%s\n' "$base" > "$HOME_D/state/trunk-green-proj"
  lane ua one a.txt; tip_after_land ua >/dev/null
  home=$(cd "$HOME_D" && pwd -P); calls=$W/sdrun-calls
  # shellcheck disable=SC2016 # the stand-ins expand their own arguments
  { printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$calls"
  } > "$W/fakebin/fake-systemd-run"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "--user is-active" ] && [ -e "%s/unit-active" ]\n' "$W" > "$W/fakebin/fake-systemctl"
  chmod +x "$W/fakebin/fake-systemd-run" "$W/fakebin/fake-systemctl"
  export JG_TRUNK_SYSTEMD_RUN=$W/fakebin/fake-systemd-run JG_TRUNK_SYSTEMCTL=$W/fakebin/fake-systemctl
  sweep >/dev/null
  n=$(grep -c . "$calls" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "one tick above the pin starts one unit and no other job: $(cat "$calls" 2>&1)"
  for want in '--user' '--collect' '--property=KillMode=process' "--working-directory=$home" \
      "--property=StandardOutput=append:$home/data/jg-trunk-landing/unit-verify-proj.log" \
      "--property=StandardError=append:$home/data/jg-trunk-landing/unit-verify-proj.log" \
      "/core/trunk-landing/trunk-landing.sh verify $home proj"; do
    assert_contains "$(cat "$calls")" "$want" "the unit's command line must carry $want"
  done
  unit=$(sed -n 's/.*--unit=\(jg-verify-proj-[0-9]*\) .*/\1/p' "$calls")
  [ -n "$unit" ] || fail "the unit is named jg-verify-<project>-<epoch>: $(cat "$calls")"
  [ "$(cat "$home/data/jg-trunk-landing/unit-verify-proj")" = "$unit" ] || fail "the unit name is recorded"
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$base" ] || fail "the stand-in unit ran nothing, so the pin stays"
  # While the unit is active, a tick starts nothing: one verify at a time, and the same tip is not started twice.
  : > "$W/unit-active"; sweep >/dev/null; sweep >/dev/null
  [ "$(grep -c . "$calls")" = 1 ] || fail "a tick that finds the unit active starts nothing: $(cat "$calls")"
  # Once the unit has ended, the next tick above the pin starts one again.
  rm -f "$W/unit-active"; sleep 1.1; sweep >/dev/null
  [ "$(grep -c . "$calls")" = 2 ] || fail "a tick with no active unit starts a unit: $(cat "$calls")"
  # With no systemd-run the job keeps setsid nohup: the verify itself runs and moves the pin.
  unset JG_TRUNK_SYSTEMD_RUN JG_TRUNK_SYSTEMCTL
  sweep >/dev/null
  for _ in $(seq 1 150); do [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] && break; sleep 0.2; done
  [ "$(cat "$HOME_D/state/trunk-green-proj")" = "$(tip)" ] || fail "with no systemd-run the tick's setsid verify must move the pin: $(cat "$HOME_D/data/jg-trunk-landing/verify-proj.log" 2>&1)"
  [ "$(grep -c . "$calls")" = 2 ] || fail "no systemd-run means no unit start"
  pass 'the tick starts its verify in its own unit once (KillMode=process, absolute paths, recorded name, nothing while it is active) and falls back to setsid with no systemd-run'
}

test_the_tick_starts_its_verify_in_its_own_unit_once_and_falls_back_to_setsid
printf 'jg-trunk-unit: ok\n'
