#!/usr/bin/env bash
# A config push must never hide another home's rows. config/backlog-backend is inherited, and it decides where a home
# reads its rows, so a push that moved it across the Beads boundary left the rows where they were and made the lead
# list none, with exit 0. Each case here is a real push (and the remote receiver) into a real lead home, and judges the
# lead's own view: the same row ids it listed before, the same count, the config untouched, and a non-zero exit that
# names the reason. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; without them the run skips plainly.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  printf 'skip: JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT are unset\n'
  exit 0
fi

T=$(jg_test_tmproot jg-config-push-beads-rows)
unset BEADS_DB BEADS_DIR BEADS_DOLT_SHARED_SERVER BEADS_ACTOR JG_BACKLOG_LANE JG_BACKLOG_AGENT JG_BACKLOG_LANE_HANDOVER
export TZ=UTC TMPDIR=$T JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
CLI=$ROOT/bin/jg-tasks-axi.sh PUSH=$ROOT/bin/jg-config-push.sh
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# A primary home and one lead home; <lead>'s meta names it live. Prints nothing.
make_world() {  # <name>
  local w=$T/$1
  mkdir -p "$w/primary/config" "$w/primary/state" "$w/primary/data" "$w/lead/config" "$w/lead/data" "$w/lead/state" "$w/lead/bin"
  : > "$w/primary/data/squad_leads.md"
  printf 'lead1\n' > "$w/lead/.jg-squad-lead-home"
  printf '# lead\n' > "$w/lead/AGENTS.md"
  printf 'kind=squad_lead\nhome=%s\nwindow=jg-lead1\n' "$w/lead" > "$w/primary/state/lead1.meta"
}
push() {  # <name>: the primary pushes; its output lands in $OUT, its exit status in $PUSH_RC.
  local w=$T/$1
  PUSH_RC=0
  OUT=$(JG_HOME=$w/primary JG_ROOT_OVERRIDE=$ROOT "$PUSH" 2>&1) || PUSH_RC=$?
}
lead_ids() { JG_HOME=$T/$1/lead "$CLI" list 2>&1 | grep -o 'row-[a-z0-9]*' | sort -u | tr '\n' ' '; }
store_rows() {  # <name>
  BEADS_DIR=$T/$1/store/.beads "$ROOT/bin/jg-beads.sh" list --all --limit 0 --json 2>/dev/null | jq -r '[.[].id] | sort | join(" ")'
}
seed_beads_lead() {  # <name>: a lead whose rows live in a Beads store.
  local w=$T/$1
  mkdir -p "$w/store"
  BEADS_DIR=$w/store/.beads "$ROOT/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 || fail "init the lead's store"
  printf 'beads\n' > "$w/lead/config/backlog-backend"
  printf '%s\n' "$w/store/.beads" > "$w/lead/config/beads-dir"
  for id in row-a row-b; do JG_HOME=$w/lead "$CLI" add "$id" "[feature] Row $id" --priority 2 --body why >/dev/null || fail "seed $id"; done
}

# 1. The reproduced loss: a primary with no Beads setting, a lead whose rows are in Beads.
make_world one
seed_beads_lead one
printf 'sonnet\n' > "$T/one/primary/config/crew-harness"
[ "$(lead_ids one)" = "row-a row-b " ] || fail "the lead must list its two rows before the push: [$(lead_ids one)]"
store_before=$(store_rows one)
[ "$(printf '%s' "$store_before" | wc -w)" -eq 2 ] || fail "the store must hold two rows before the push: [$store_before]"
push one; out=$OUT
[ "$PUSH_RC" -ne 0 ] || fail "a push that would hide rows must not exit 0: $out"
case $out in *"backlog-backend: error - refused, left unchanged: its Beads store holds 2 row(s)"*) ;; *) fail "the refusal must name the item and the rows: $out" ;; esac
[ "$(cat "$T/one/lead/config/backlog-backend")" = beads ] || fail "the lead's backend must be untouched"
[ "$(cat "$T/one/lead/config/beads-dir")" = "$T/one/store/.beads" ] || fail "the lead's store pointer must be untouched"
[ "$(lead_ids one)" = "row-a row-b " ] || fail "the lead must still list both rows by id: [$(lead_ids one)]"
[ "$(store_rows one)" = "$store_before" ] || fail "the store must hold the same two rows: [$(store_rows one)] vs [$store_before]"
[ "$(cat "$T/one/lead/config/crew-harness")" = sonnet ] || fail "an unrelated item must still be carried past the refusal"
printf 'ok - a push into a Beads lead is refused with the reason, and the lead still lists its two rows\n'

# 2. The same refusal on the remote receiver, with the generation record left unwritten.
for form in absent put; do
  if [ "$form" = absent ]; then
    JG_HOME=$T/one/lead "$ROOT/bin/jg-remote-inherit.sh" absent config/backlog-backend 0 "$EMPTY_SHA" 7 </dev/null >"$T/recv.out" 2>&1 && rc=0 || rc=$?
  else
    sha=$(printf 'manual\n' | sha256sum | cut -d' ' -f1)
    printf 'manual\n' | JG_HOME=$T/one/lead "$ROOT/bin/jg-remote-inherit.sh" put config/backlog-backend 7 "$sha" 7 >"$T/recv.out" 2>&1 && rc=0 || rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "the receiver must refuse a $form that would hide rows: $(cat "$T/recv.out")"
  grep -q 'refused, left unchanged: its Beads store holds 2 row(s)' "$T/recv.out" || fail "the receiver must name the reason for $form: $(cat "$T/recv.out")"
  [ "$(cat "$T/one/lead/config/backlog-backend")" = beads ] || fail "the receiver changed the backend on $form"
  [ ! -e "$T/one/lead/config/.jg-inherit-backlog-backend.generation" ] || fail "a refused $form must not publish a generation"
done
[ "$(lead_ids one)" = "row-a row-b " ] || fail "the lead must still list both rows after the receiver refusals"
printf 'ok - the remote receiver refuses an absent and a put alike, and publishes no generation\n'

# 3. The other direction: a Beads primary, a lead whose rows are in its markdown backlog.
make_world two
printf 'beads\n' > "$T/two/primary/config/backlog-backend"
printf '# Backlog\n\n## Queued\n- [ ] row-m1 - [feature] Markdown one (repo: x) (kind: fix) (priority: 1) (since 2026-11-01)\n- [ ] row-m2 - [feature] Markdown two (repo: x) (kind: fix) (priority: 1) (since 2026-11-01)\n' > "$T/two/lead/data/backlog.md"
before=$(sha256sum "$T/two/lead/data/backlog.md")
push two; out=$OUT
[ "$PUSH_RC" -ne 0 ] || fail "a push that would hide markdown rows must not exit 0: $out"
case $out in *"its backlog files hold 2 row(s) that a switch to beads would hide"*) ;; *) fail "the refusal must count the markdown rows: $out" ;; esac
[ ! -e "$T/two/lead/config/backlog-backend" ] || fail "the lead must not be switched to beads"
[ "$(sha256sum "$T/two/lead/data/backlog.md")" = "$before" ] || fail "the lead's backlog must be byte-identical"
[ "$(grep -c '^- \[' "$T/two/lead/data/backlog.md")" -eq 2 ] || fail "the lead must still hold its two markdown rows"
printf 'ok - a push of beads into a markdown lead with rows is refused and leaves its backlog byte-identical\n'

# 4. A Beads primary never pushes beads to a home with no store of its own: it would leave that home unable to read.
make_world three
printf 'beads\n' > "$T/three/primary/config/backlog-backend"
push three; out=$OUT
[ "$PUSH_RC" -ne 0 ] || fail "a push of beads to a home with no store must not exit 0: $out"
case $out in *"it has no Beads store named in config/beads-dir"*) ;; *) fail "the refusal must name the missing store: $out" ;; esac
[ ! -e "$T/three/lead/config/backlog-backend" ] || fail "the lead must not be switched to a backend it cannot read"
printf 'ok - a push of beads to a home with no store of its own is refused\n'

# 5. A push that hides nothing still lands: a lead with its own empty store and no rows follows a Beads primary.
make_world four
printf 'beads\n' > "$T/four/primary/config/backlog-backend"
mkdir -p "$T/four/store"
BEADS_DIR=$T/four/store/.beads "$ROOT/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 || fail "init the empty store"
printf '%s\n' "$T/four/store/.beads" > "$T/four/lead/config/beads-dir"
push four; out=$OUT
[ "$PUSH_RC" -eq 0 ] || fail "a push with no row to hide and a store to read must still succeed: $out"
[ "$(cat "$T/four/lead/config/backlog-backend")" = beads ] || fail "the lead must inherit the backend"
[ -z "$(lead_ids four)" ] || fail "the lead must list no row: [$(lead_ids four)]"
printf 'ok - a lead with its own empty store still inherits the backend\n'

pass "jg-config-push beads rows"
