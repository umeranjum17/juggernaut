# shellcheck shell=bash disable=SC2016,SC2034,SC2154 # sourced integration case
# Recipient authority is checked at creation, derivation and the final delivery boundary.
(
  A=$T/authority; mkdir -p "$A/state" "$A/config" "$A/data"
  export JG_HOME=$A JG_STATE_OVERRIDE=$A/state JG_CONFIG_OVERRIDE=$A/config JG_DATA_OVERRIDE=$A/data
  export JG_CAPTAIN_CHANNEL=$A/config/captain-channel JG_ALERT_NOW=2000000000
  printf 'set mode shadow\nset dapr-http-url http://127.0.0.1:1\n' > "$JG_CAPTAIN_CHANNEL"
  pages() { jq -s 'map(select(.kind == "alert")) | length' "$A/state/captain-channel.jsonl"; }
  al raise stuck-wait direct --fact wait=main --rung 4
  expect_code 1 "$RC" "direct team owner rung refused"
  al raise security absent; expect_code 1 "$RC" "security needs a typed producer"
  al raise security unknown --security-source arbitrary; expect_code 1 "$RC" "unknown security producer refused"
  al raise host wrong --security-source key-in-env; expect_code 1 "$RC" "team alert cannot claim a security producer"
  for why in engineering review; do
    al raise stuck-wait "$why" --fact wait=main --fact owner-answer --deliver
    expect_code 0 "$RC" "team action rings Main"
    k=stuck-wait--$why
    assert_equals 3 "$(rec "$k" top)" "owner-answer fact is not authority"
    for i in 1 2 3 4; do
      al climb "$k" --now $((2000000000 + i * 600)); expect_code 0 "$RC" "exhaust team action"
    done
    assert_contains "$OUT" "$(printf 'ring\tescalation-stuck--%s\t3\tmain' "$k")" "derived recovery stays at Main"
    printf '%s\n' "$OUT" | bash "$AL" deliver || fail "deliver Main recovery"
    assert_equals team-action "$(rec "escalation-stuck--$k" authority_class)" "derived class preserved"
    assert_equals 2000000000 "$(rec "$k" since)" "exhaustion keeps original age"
    assert_equals stuck "$(rec "$k" state)" "source action retained"
    assert_contains "$(cat "$A/state/.wake-queue")" "Main recovery required" "recovery has an explicit next actor"
    al climb "$k" --now 2000005000; expect_code 1 "$RC" "exhaustion is idempotent"
  done
  [ ! -e "$A/state/captain-channel.jsonl" ] || fail "team causes published an owner event"
  printf 'ring\tstuck-wait--review\t4\towner\n' | bash "$AL" deliver >/dev/null 2>&1
  expect_code 1 "$?" "forged owner ring refused"
  # Permitted producers reach the real bus's isolated event journal, never a live transport.
  for producer in key-in-env delete-guard owner-details-scan unauthenticated-state-checks; do
    al raise security "$producer" --security-source "$producer" --deliver
    expect_code 0 "$RC" "allowed security awareness publishes"
  done
  assert_equals 4 "$(pages)" "all security producers publish an event"
  al raise security fresh --security-source key-in-env
  for i in 1 2 3 4; do al climb security--fresh --now $((2000000000 + i * 600)); expect_code 0 "$RC" "security exhaustion"; done
  cp "$A/state/alerts/escalation-stuck--security--fresh.rec" "$A/retained.rec"
  al resolve security--fresh --proof source:condition-ended
  al raise security fresh --security-source key-in-env
  cp "$A/retained.rec" "$A/state/alerts/escalation-stuck--security--fresh.rec"
  printf 'ring\tescalation-stuck--security--fresh\t4\towner\n' | bash "$AL" deliver >/dev/null 2>&1
  expect_code 1 "$?" "old derived episode cannot borrow new source authority"
  assert_equals 4 "$(pages)" "stale generation publishes nothing"
  # Real gates, through the existing backlog owner, rather than a fake verifier.
  if [ -n "${JG_BEADS_TEST_BD:-}" ] && [ -n "${JG_BEADS_TEST_DOLT:-}" ]; then
    jg_test_beads_home "$A"
    jg_test_add "$A" jg-call '[feature] Umer chooses the route' --repo sample >/dev/null || fail "file fixture ticket"
    gate_write() { bash -c '. "$1/bin/jg-backlog-lib.sh"; shift; jg_backlog_beads_write "$@"' _ "$ROOT" "$A/config" "$@"; }
    g=$(gate_write gate jg-call --title 'Which route?' --reason 'Choose A or B?' --must design-pick --origin jg-source) || fail "create real gate"
    badg=$(gate_write gate jg-call --title 'Engineering?' --reason 'Team action?' --must engineering --origin jg-source) || fail "create invalid category control"
    al raise stuck-wait bad-must --fact wait=main --rung 4 --owner-gate "$badg" --ticket jg-call --origin jg-source
    expect_code 1 "$RC" "engineering category cannot grant owner authority"
    for bad in missing wrong-origin wrong-ticket; do
      opts=(--owner-gate "$g" --ticket jg-call --origin jg-source)
      case $bad in missing) opts=(--owner-gate no-gate --ticket jg-call --origin jg-source) ;; wrong-origin) opts[5]=other ;; wrong-ticket) opts[3]=jg-other ;; esac
      al raise stuck-wait "$bad" --fact wait=main --rung 4 "${opts[@]}"
      expect_code 1 "$RC" "reject $bad authority"
    done
    al raise stuck-wait call --fact wait=main --rung 4 --owner-gate "$g" --ticket jg-call --origin jg-source --deliver
    expect_code 0 "$RC" "valid gate publishes owner event"
    assert_equals 5 "$(pages)" "gate-backed owner call published"
    for i in 1 2 3 4; do al climb stuck-wait--call --now $((2000000000 + i * 600)); expect_code 0 "$RC" "owner call exhaustion"; done
    assert_equals owner-call "$(rec escalation-stuck--stuck-wait--call authority_class)" "derived gate class preserved"
    printf '%s\n' "$OUT" | bash "$AL" deliver || fail "derived gate delivery"
    assert_equals 6 "$(pages)" "derived valid gate publishes"
    printf 'Use route A.\n' > "$A/answer"
    gate_write resolve "$g" --words-file "$A/answer" --resolution answered >/dev/null || fail "close real gate"
    printf 'ring\tescalation-stuck--stuck-wait--call\t4\towner\n' | bash "$AL" deliver >/dev/null 2>&1
    expect_code 1 "$?" "closed gate cannot publish on replay"
    assert_equals 6 "$(pages)" "revoked authority publishes nothing"
    assert_equals main "$(rec escalation-stuck--stuck-wait--call recovery_owner)" "refusal retains Main recovery"
    al raise stuck-wait closed --fact wait=main --rung 4 --owner-gate "$g" --ticket jg-call --origin jg-source
    expect_code 1 "$RC" "closed gate cannot create owner authority"
  else
    printf 'skip: real owner-gate controls need pinned Beads and Dolt\n'
  fi
  pass "team exhaustion never owner-pages; typed security and current gates retain authority"
) || fail "alert authority journey"
