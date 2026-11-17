# shellcheck shell=bash disable=SC2016,SC2034,SC2154 # sourced integration case
# Actor routing: in a Squad Lead home the lead rung stays in its own queue and Main's rung goes up the real parent channel, once per
# episode, and closes there on resolve; a home with no usable parent binding refuses Main's rung instead of waking itself.
(
  P=$T/route-parent; L=$T/route-lead; R=$T/route-remote; B=$T/route-broken
  for d in "$P" "$L" "$R" "$B"; do mkdir -p "$d/state" "$d/config" "$d/data"; done
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$L/.jg-squad-lead-parent"; echo mate1 > "$L/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=remote\nparent_host=box\n' > "$R/.jg-squad-lead-parent"; echo mate2 > "$R/.jg-squad-lead-home"
  echo mate3 > "$B/.jg-squad-lead-home"   # identity with no parent binding
  in_home() { local h=$1; shift; JG_HOME=$h JG_STATE_OVERRIDE=$h/state JG_CONFIG_OVERRIDE=$h/config JG_DATA_OVERRIDE=$h/data "$@"; }
  hal() { local h=$1; shift; OUT=$(in_home "$h" bash "$AL" "$@" 2>&1); RC=$?; }
  hrec() { in_home "$1" bash "$AL" show "$2" | sed -n "s/^$3=//p"; }
  opened() { bash -c '. "$1/bin/jg-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$1" | cut -f1; }
  CH=$P/state/mate1.status
  # Main's rung (host is rung 3) reaches the parent, keyed by the alert and its episode; the lead home's own queue stays empty.
  hal "$L" raise host mem --machine m1 --deliver; expect_code 0 "$RC" "Main's rung routes up"
  ep=$(hrec "$L" host--mem episode); rk=alert-host--mem-g$ep
  assert_equals 1 "$(grep -c "key=$rk\]" "$CH")" "one parent line carries the alert and its generation"
  assert_contains "$(cat "$CH")" "(P3) at rung 3 for main: mem" "the parent line names the action and its actor"
  assert_equals "$rk" "$(hrec "$L" host--mem route_key)" "the record keeps the routed key"
  ! grep -q "alert-host--mem" "$L/state/.wake-queue" 2>/dev/null || fail "Main's rung woke the lead home"
  assert_equals "$rk" "$(opened "$CH")" "the parent holds one open action for the lead"
  # A retried ring of the same episode is idempotent.
  printf 'ring\thost--mem\t3\tmain\n' | in_home "$L" bash "$AL" deliver; expect_code 0 $? "a retried ring delivers"
  assert_equals 1 "$(grep -c "key=$rk\]" "$CH")" "a retried ring adds no second parent line"
  # The lead rung stays with the lead (line-red starts at rung 2).
  hal "$L" raise line-red tip --deliver; expect_code 0 "$RC" "the lead rung delivers"
  assert_contains "$(cat "$L/state/.wake-queue")" "alert-line-red--tip" "the lead rung is the lead home's own wake"
  ! grep -q "line-red" "$CH" || fail "the lead rung reached the parent"
  # A producer that names an older wake kind keeps its local consumer (jg_wake_host's check: readers).
  in_home "$L" bash "$AL" raise host disk --wake check --text "disk full" | in_home "$L" bash "$AL" deliver; expect_code 0 $? "a named wake delivers"
  assert_contains "$(cat "$L/state/.wake-queue")" "disk full" "the named wake stays with its local consumer"
  ! grep -q "host--disk" "$CH" || fail "a named local wake reached the parent"
  # Resolve closes the exact parent action; a new episode is a new action.
  hal "$L" resolve host--mem; expect_code 0 "$RC" "resolve"
  assert_equals "" "$(opened "$CH")" "resolve closes the parent action"
  hal "$L" raise host mem --machine m1 --deliver; expect_code 0 "$RC" "a new episode"
  rk2=$(hrec "$L" host--mem route_key); assert_not_equals "$rk" "$rk2" "a new episode has a new key"
  assert_equals "$rk2" "$(opened "$CH")" "only the new episode is open"
  hal "$L" resolve host--mem
  # A stuck alert's Main recovery card is routed as its own action and closes with its source.
  hal "$L" raise host slow --deliver
  for i in 1 2 3 4; do hal "$L" climb host--slow --now $(( $(hrec "$L" host--slow rung_at) + 3600 )); done
  printf '%s\n' "$OUT" | in_home "$L" bash "$AL" deliver; expect_code 0 $? "the stuck card delivers"
  assert_equals 2 "$(opened "$CH" | wc -l | tr -d ' ')" "the source and its recovery card are open at the parent"
  assert_contains "$(opened "$CH")" "alert-escalation-stuck--host--slow-g" "the card is its own routed action"
  hal "$L" resolve host--slow; expect_code 0 "$RC" "resolve the stuck source"
  assert_equals "" "$(opened "$CH")" "resolving the source closes both parent actions"
  # A capacity event that supersedes a routed one closes it at the parent.
  hal "$L" capacity acct "account down" --rung 3 --deliver; expect_code 0 "$RC" "capacity at Main"
  hal "$L" capacity acct "account down again" --rung 3 --deliver
  assert_equals 1 "$(opened "$CH" | wc -l | tr -d ' ')" "the superseded capacity action is closed"
  # A remote Squad Lead uses its own outbound channel.
  hal "$R" raise host far --deliver; expect_code 0 "$RC" "remote route"
  assert_contains "$(cat "$R/state/parent-replies.status")" "alert-host--far-g" "the remote route uses the outbound channel"
  ! grep -q "alert-host--far" "$R/state/.wake-queue" 2>/dev/null || fail "the remote lead woke itself"
  # An unknown destination is refused with a recovery wake, never delivered to the lead's own queue.
  hal "$B" raise host lost --deliver; expect_code 1 "$RC" "an unknown destination is refused"
  assert_contains "$OUT" "parent binding is missing" "the refusal names the cause"
  assert_contains "$(cat "$B/state/.wake-queue")" "alert-route-host--lost" "the refusal leaves a recovery wake"
  ! grep -q "alert-host--lost" "$B/state/.wake-queue" || fail "a refused Main rung became an ordinary wake"
  assert_equals "the parent binding is missing or unreadable" "$(hrec "$B" host--lost route_refused)" "the refusal is recorded"
  [ ! -e "$P/state/mate3.status" ] || fail "a refused action reached a guessed parent"
  pass "alert actions route to the real lead or Main once per episode and refuse an unknown destination"
)
