#!/usr/bin/env bash
# Integration test for the dispatch kick at a landing (slice kk1, core/trunk-landing/trunk-landing.sh), through the real
# `run` and `runbatch` over real lanes (tests/jg-trunk-fixture.sh). The lander (bin/jg-trunk.sh) is a stand-in in the fixture home,
# and the home's state/auto-dispatch.check.sh, the shim the watcher runs, is a stand-in that appends one line to a marker file.
#
# T1 One lane lands: the dispatch check is started, and its marker has one line within 5 seconds.
# T2 A stack of three lanes lands in one run: the dispatch check is started once, after the last lane.
# T3 JG_LANDING_DISPATCH_KICK=0: it is not started.
# T4 A home with no shim: the landing still succeeds and prints what it printed before.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"
# shellcheck disable=SC2034 # read by the fixture
JG_TRUNK_FIXTURE_CACHE=1

# A home whose lander lands every lane it is given; with a shim, the dispatch check appends one line per start to $W/kicks.
# shellcheck disable=SC2016 # the stand-in bodies are written out verbatim and expand when they run
stub_world() {  # <name> [noshim]
  world "$1"
  cp -r "$W/root/bin" "$HOME_D/bin"; ln -sn "$ROOT/core" "$HOME_D/core"; ln -sn "$ROOT/policy" "$HOME_D/policy"
  cat > "$HOME_D/bin/jg-trunk.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  land) echo "landed $2 on trunk (stand-in)" ;;
  land-batch) shift; for a in "$@"; do echo "landed ${a%%@*} on trunk (stand-in)"; sleep 0.3; done ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$HOME_D/bin/jg-trunk.sh"
  [ "${2-}" = noshim ] && return 0
  printf '#!/usr/bin/env bash\ndate +%%s >> "%s/kicks"\n' "$W" > "$HOME_D/state/auto-dispatch.check.sh"
  chmod +x "$HOME_D/state/auto-dispatch.check.sh"
}
land_one() {  # <id>: the landing check's single run
  JG_TEST_SEAM=1 JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" run "$HOME_D" "$1" "$(git -C "$PROJ" rev-parse "fm/$1")" >"$W/run.out" 2>&1 \
    || fail "the run must not fail: $(tail -5 "$W/run.out")"
}
land_stack() {  # <id>...: the landing check's stack run
  local args=() id
  for id in "$@"; do args+=("$id@$(git -C "$PROJ" rev-parse "fm/$id")"); done
  JG_TEST_SEAM=1 JG_HOME="$HOME_D" PATH="$W/fakebin:$PATH" bash "$ROOT/core/trunk-landing/trunk-landing.sh" runbatch "$HOME_D" "${args[@]}" >"$W/run.out" 2>&1 \
    || fail "the stack run must not fail: $(tail -5 "$W/run.out")"
}
kicks() { grep -c . "$W/kicks" 2>/dev/null || echo 0; }
wait_kicks() {  # <n>: the marker reaches <n> lines within 5 seconds
  for _ in $(seq 1 50); do [ "$(kicks)" -ge "$1" ] && return 0; sleep 0.1; done
  fail "the marker has $(kicks) lines, wanted $1"
}

test_one_landing_starts_one_dispatch() {
  stub_world one
  lane a1 one a1.txt
  land_one a1
  wait_kicks 1; sleep 0.5
  [ "$(kicks)" = 1 ] || fail "one landing starts one dispatch: $(kicks)"
  pass 'a landed lane starts the home'"'"'s dispatch check, once'
}

test_a_stack_starts_one_dispatch() {
  stub_world stack
  lane s1 one s1.txt; lane s2 two s2.txt; lane s3 three s3.txt
  land_stack s1 s2 s3
  wait_kicks 1; sleep 0.5
  [ "$(kicks)" = 1 ] || fail "a stack of three starts one dispatch: $(kicks)"
  [ "$(grep -c '^trunk-landing: landed s' "$HOME_D/data/jg-trunk-landing/outbox")" = 3 ] || fail "all three lanes landed"
  pass 'a stack of three lanes landing in one run starts the dispatch check once'
}

test_the_kick_can_be_turned_off() {
  stub_world off
  lane o1 one o1.txt
  JG_LANDING_DISPATCH_KICK=0 land_one o1
  sleep 1
  [ "$(kicks)" = 0 ] || fail "JG_LANDING_DISPATCH_KICK=0 starts nothing: $(kicks)"
  grep -q '^trunk-landing: landed o1 ' "$HOME_D/data/jg-trunk-landing/outbox" || fail "the lane still lands"
  pass 'JG_LANDING_DISPATCH_KICK=0 starts no dispatch check'
}

test_a_home_without_the_shim_lands_as_before() {
  stub_world bare noshim
  lane n1 one n1.txt
  land_one n1
  [ ! -e "$W/kicks" ] || fail "no shim, no kick"
  grep -q '^trunk-landing: landed n1 ' "$HOME_D/data/jg-trunk-landing/outbox" || fail "the lane still lands"
  [ ! -s "$W/run.out" ] || fail "the run prints what it printed before: $(cat "$W/run.out")"
  pass 'a home with no dispatch shim lands the lane and prints what it printed before'
}

test_one_landing_starts_one_dispatch
test_a_stack_starts_one_dispatch
test_the_kick_can_be_turned_off
test_a_home_without_the_shim_lands_as_before
printf 'jg-trunk-landing-kick: ok\n'
