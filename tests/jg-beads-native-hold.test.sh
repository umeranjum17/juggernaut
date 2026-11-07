#!/usr/bin/env bash
# Behavior tests for bin/jg-captain-hold.sh on a Beads home: the script never starts bd itself, and an old id reaches
# its row through the provider. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds for the real case,
# which skips plainly without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTAIN="$ROOT/bin/jg-captain-hold.sh" WRAPPER="$ROOT/bin/jg-beads.sh" T=$(jg_test_tmproot jg-beads-native-hold)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER BEADS_DIR

# A bd on the path that only records it was started, because nothing here may start one.
trap_bd() {  # <fakebin>
  cat > "$1/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/bd-started"
exit 0
SH
  chmod +x "$1/bd"
}

scout() {  # <home> <id> <attested keys>
  mkdir -p "$1/data/$2"
  jg_write_meta "$1/state/$2.meta" "window=juggernaut:jg-$2" "worktree=$1/projects/missing-$2" "project=$1/projects/sample" \
    harness=codex kind=scout "spawn_gen=fixture-$2" decisions_reviewed=1 "decision_keys=$3"
  printf 'done: report complete\n' > "$1/state/$2.status"
  printf '# Report\n\nThe investigation finished.\n' > "$1/data/$2/report.md"
}

captain() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" JG_DATA_OVERRIDE="$home/data" JG_CONFIG_OVERRIDE="$home/config" \
    "${jail[@]}" "$CAPTAIN" "$@" 2>&1
}

jail=()

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: real store: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
else
  home=$T/home
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$T/store"
  fb=$(jg_fakebin "$home")
  trap_bd "$fb"
  jg_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$T/store/.beads" > "$home/config/beads-dir"
  export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT TMPDIR=$T  # The jail's /tmp is gone with each call.
  command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
  store() { BEADS_DIR="$T/store/.beads" "${jail[@]}" "$WRAPPER" "$@"; }
  store init --prefix jg >/dev/null 2>&1 || fail "real init"
  out=$(captain "$home" hold jg-call --title "[captain-ask] Pick the route" --reason "the owner picks" --repo sample --priority 1) \
    || fail "hold on the store: $out"
  store update jg-call --set-metadata legacy_item=old-call >/dev/null 2>&1 || fail "name the row"
  scout "$home" store-scout old-call
  out=$(captain "$home" verify store-scout) || fail "verify must reach the row by its old name: $out"
  out=$(captain "$home" complete store-scout old-call) || fail "complete must attest the old name: $out"
  assert_contains "$(cat "$home/state/store-scout.meta")" "decision_keys=old-call" "the attested id must stay recorded"
  out=$(captain "$home" verify store-scout) || fail "verify must hold after completion: $out"
  scout "$home" ghost-scout never-named
  rc=0
  out=$(captain "$home" verify ghost-scout) || rc=$?
  [ "$rc" = 1 ] || fail "a store must refuse an id no row answers to, exit $rc: $out"
  assert_contains "$out" never-named "the store refusal must name the id"
  [ ! -e "$T/bd-started" ] || fail "the hold script started bd: $(cat "$T/bd-started")"
  pass "an attested old id reaches its row on a real store, through the wrapper alone"
fi
pass "jg-beads-native-hold"
