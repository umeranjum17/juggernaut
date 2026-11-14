#!/usr/bin/env bash
# Integration test for the verify grace (H39, core/trunk-verify/grace.sh) through the real caller bin/jg-trunk.sh verify.
# The home's verify gate ends in the grace over the eight shard results. Key unset (default 0): any failing script is a red.
# Key 2: one failed script in one shard passes and the verdict names the script and its one fix ticket; a shard that failed for
# no test (exit 1, nothing counted), a missing shard result and three failed scripts are each a red, and a red files no ticket.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

# shellcheck disable=SC2016 # the gate body is written out verbatim and expands when the gate runs it
test_the_grace_is_off_by_default_and_passes_only_a_fully_explained_red_when_a_home_turns_it_on() {
  local c out rc T
  world grace; rig
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -s "$ROOT/policy" "$HOME_D/policy"
  # The grace and its one filer run from a fixture root whose backlog is a stand-in that keeps tickets as files.
  T="$W/tickets"; mkdir -p "$T" "$HOME_D/core/trunk-verify" "$HOME_D/core/trunk-landing"
  cp "$ROOT/core/trunk-verify/grace.sh" "$HOME_D/core/trunk-verify/"; cp "$ROOT/core/trunk-landing/quarantine.sh" "$HOME_D/core/trunk-landing/"
  cat > "$HOME_D/bin/jg-backlog.sh" <<'STUB'
#!/usr/bin/env bash
t=TICKETS
case $1 in
  add) [ ! -e "$t/$2" ] || exit 1; printf '%s\n' "$3" > "$t/$2" ;;
  show) [ -e "$t/$2" ] || exit 1; echo '  closed: "-"' ;;
esac
STUB
  sed -i "s|^t=TICKETS|t=$T|" "$HOME_D/bin/jg-backlog.sh"
  chmod +x "$HOME_D/bin/jg-backlog.sh"
  # The lab runner leaves the eight shard results a case describes ("<shard>:<exit>:<failed script>..."), then the gate ends in the grace.
  cat > "$W/shards.sh" <<'SH'
#!/usr/bin/env bash
d=$1; shift; rm -rf "$d"; mkdir -p "$d"; rc=0
for k in 1 2 3 4 5 6 7 8; do
  spec=''; for a in "$@"; do case $a in "$k":*) spec=$a ;; esac; done
  [ "$spec" != "$k:missing" ] || { rc=1; continue; }
  code=0; scripts=''; failed=0
  if [ -n "$spec" ]; then IFS=: read -r _ code rest <<< "$spec"; for s in ${rest//,/ }; do scripts="$scripts{\"path\":\"$s\",\"exit\":1},"; failed=$((failed + 1)); done; fi
  [ "$code" = 0 ] || rc=1
  printf '{"scripts":[%s],"summary":{"exit":%s,"failed":%s,"total":1}}\n' "${scripts%,}" "$code" "$failed" > "$d/shard-$k.json"
done
exit "$rc"
SH
  printf 'gate-verify=bash %s/shards.sh %s/proof $(cat %s/case); rc=$?; bash %s/core/trunk-verify/grace.sh judge %s/proof $rc --project proj\n' "$W" "$W" "$W" "$HOME_D" "$W" >> "$HOME_D/config/trunk-policy"
  tip > "$HOME_D/state/trunk-green-proj"
  lane g1 "true" t/g.test.sh
  trunk land g1 >/dev/null 2>&1 || fail "g1 must land: $(trunk land g1 2>&1)"
  c=$(tip)
  verify() { rc=0; out=$(trunk verify "$PROJ" "$c" 2>&1) || rc=$?; }
  # The key unset: one failed script is a red, and nothing is ticketed.
  echo "3:1:tests/a.test.sh" > "$W/case"; verify
  [ "$rc" -ne 0 ] || fail "with the key unset a failed script must be red: $out"
  assert_contains "$out" "verify grace is off" "the red says the grace is off"
  [ -z "$(ls "$T")" ] || fail "a red must file no ticket: $(ls "$T")"
  # The key on: all eight results, the one non-zero shard explained by its own counted failure, within the grace.
  echo 'verify-grace=2' >> "$HOME_D/config/trunk-policy"
  verify
  [ "$rc" -eq 0 ] || fail "one explained failure within the grace must pass: $out"
  assert_contains "$(cat "$HOME_D"/data/trunk/gate-proj-"${c:0:12}"*.log)" "tests/a.test.sh (ticket flaky-proj-a)" "the verdict names the graced script with its ticket"
  [ "$(find "$T" -type f | grep -c .)" = 1 ] || fail "one ticket for the graced script: $(ls "$T")"
  # Reds the grace must not pass. Each one leaves the pin where the green case put it and files nothing new.
  echo "3:1:tests/a.test.sh 5:1" > "$W/case"; verify
  [ "$rc" -ne 0 ] || fail "a failure plus a shard that exited non-zero with no counted failure must be red: $out"
  assert_contains "$out" "shard 5of8 exited 1 but counted 0" "the red names the unexplained shard"
  echo "3:1:tests/a.test.sh 7:missing" > "$W/case"; verify
  [ "$rc" -ne 0 ] || fail "a dead shard must be red: $out"
  assert_contains "$out" "shard 7of8 has no readable result" "the red names the dead shard"
  echo "1:1:tests/a.test.sh,tests/b.test.sh 2:1:tests/c.test.sh" > "$W/case"; verify
  [ "$rc" -ne 0 ] || fail "three failures with a grace of two must be red: $out"
  assert_contains "$out" "3 failing test scripts, at most 2 allowed" "the red says the count and the grace"
  [ "$(find "$T" -type f | grep -c .)" = 1 ] || fail "a red files no further ticket: $(ls "$T")"
  pass 'the grace is off by default; on, it passes one explained failure and names the script and its ticket; a dead shard, an unexplained shard and too many failures are red'
}

test_the_grace_is_off_by_default_and_passes_only_a_fully_explained_red_when_a_home_turns_it_on
printf 'jg-trunk-verify-grace: ok\n'
