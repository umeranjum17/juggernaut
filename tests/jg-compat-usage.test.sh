#!/usr/bin/env bash
# Integration test for bin/jg-compat-usage.sh: the report of pre-rename names a home or the host still uses
# (opp-g1-compat-usage, slice G1). Real fixture homes, a throwaway HOME and XDG folders, and a lab `systemctl`.
#
# T1 A clean home prints `in use: 0` and exits 0; a home with one old setting prints that one line and exits 1,
#    naming the setting and never its value.
# T2 Each old home name is reported only where the code would still fall back to it: a marker or record file whose
#    new name is absent, an old schema line or field, an unhandled FIRSTMATE_OP message and an old slot claim.
# T3 The host report lists old-name unit files with their state, install folders, the old script and FM_ names a
#    service or the user manager carries, and the old claims root; a clean host prints 0.
# T4 What cannot be read is never a clean 0: a failing systemctl exits 2 and names its cause; a directory that is
#    not a home is refused.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-compat-usage)
USAGE="$ROOT/bin/jg-compat-usage.sh"

new_home() {  # <dir>: a home in today's spelling
  mkdir -p "$1/config" "$1/state/operational-inbox/handled" "$1/data"
  printf 'lead1\n' > "$1/.jg-squad-lead-home"
  printf 'claude\n' > "$1/config/crew-harness"
  printf 'jg-custom-check-v1\n%064d\n' 0 > "$1/state/c.check-trust"
  printf 'window=w\nkind=squad_lead\n' > "$1/state/lead1.meta"
}

run() {  # <args...>: sets OUT and RC
  RC=0
  OUT=$("$USAGE" "$@" 2>&1) || RC=$?
}

test_one_old_setting_prints_one() {
  local h="$TMP_ROOT/t1"
  new_home "$h/clean"
  run --home "$h/clean"
  expect_code 0 "$RC" "a clean home"
  assert_equals "in use: 0" "$OUT" "a clean home prints 0"

  new_home "$h/old"
  printf 'JG_EFFORT=high\nFM_MODEL=secret-value-7\n' > "$h/old/config/crew"
  run --home "$h/old"
  expect_code 1 "$RC" "a home with one old setting"
  assert_equals "$(cd "$h/old" && pwd -P): setting FM_MODEL -> JG_MODEL (config/crew:2)"$'\n'"in use: 1 (setting 1)" \
    "$OUT" "one old setting is one line and a count of 1"
  assert_not_contains "$OUT" "secret-value-7" "the value of a setting is never printed"
  pass 'a clean home prints 0; a home with one old setting prints 1 and names it without its value'
}

test_each_old_home_name_where_the_code_falls_back() {
  local h="$TMP_ROOT/t2/home" pool="$TMP_ROOT/t2/pool" mark=$'\xE2\x81\xA3'
  new_home "$h"
  # Old names whose new name is absent: still read through the fallback.
  rm "$h/.jg-squad-lead-home"; printf 'lead1\n' > "$h/.fm-secondmate-home"
  printf '| id |\n' > "$h/data/secondmates.md"
  mkdir -p "$h/config/secondmates/lead1"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$h/config/x-mode.env"
  # An old name beside its new name is not read, so it is not in use.
  printf 'claude\n' > "$h/config/secondmate-harness"; printf 'claude\n' > "$h/config/squad-lead-harness"
  # Old records.
  printf 'fm-custom-check-v1\n%064d\n' 0 > "$h/state/old.check-trust"
  printf 'fm-mail-check-v1\n' > "$h/state/.mail-check"
  mkdir -p "$h/state/decision-bindings" "$h/state/reconcile-requests"
  printf 'schema=fm-decision-binding.v1\norigin=*\n' > "$h/state/decision-bindings/s.origin"
  printf 'schema=fm-reconcile-request.v1\n' > "$h/state/reconcile-requests/r.request"
  printf 'kind=secondmate\n' > "$h/state/lead2.meta"
  printf 'task_label=fm-t1\n' > "$h/state/t1.herdr-presentation"
  printf '%sFIRSTMATE_OP: v1 watcher: wake\n' "$mark" > "$h/state/operational-inbox/1.msg"
  printf '%sFIRSTMATE_OP: v1 watcher: wake\n' "$mark" > "$h/state/operational-inbox/handled/0.msg"
  printf '%sJUGGERNAUT_OP: v1 watcher: wake\n' "$mark" > "$h/state/operational-inbox/2.msg"
  # A pool slot claimed under the old name, and one claimed under both.
  mkdir -p "$pool/1/repo" "$pool/2/repo"
  printf 'task=t1\n' > "$pool/1/.fm-slot-owner"
  printf 'task=t2\n' > "$pool/2/.fm-slot-owner"; printf 'task=t2\n' > "$pool/2/.jg-slot-owner"
  printf 'worktree=%s\n' "$pool/1/repo" > "$h/state/t1.meta"
  printf 'worktree=%s\n' "$pool/2/repo" > "$h/state/t2.meta"

  run --home "$h"
  expect_code 1 "$RC" "a home with old names"
  assert_contains "$OUT" "marker .fm-secondmate-home -> .jg-squad-lead-home" "the old lead marker"
  assert_contains "$OUT" "file data/secondmates.md -> data/squad_leads.md" "the old registry"
  assert_contains "$OUT" "file config/secondmates -> config/squad_leads" "the old pin folder"
  assert_not_contains "$OUT" "secondmate-harness" "an old name beside its new name"
  assert_contains "$OUT" "setting FM_CHECK_INTERVAL -> JG_CHECK_INTERVAL (config/x-mode.env:1)" "an exported old setting"
  assert_contains "$OUT" "record fm-custom-check-v1 -> jg-custom-check-v1 (state/old.check-trust)" "an old check trust"
  assert_not_contains "$OUT" "state/c.check-trust" "a current check trust"
  assert_contains "$OUT" "record fm-mail-check-v1 -> jg-mail-check-v1 (state/.mail-check)" "an old mail record"
  assert_contains "$OUT" "(state/decision-bindings/s.origin)" "an old decision binding"
  assert_contains "$OUT" "(state/reconcile-requests/r.request)" "an old reconcile request"
  assert_contains "$OUT" "record kind=secondmate -> kind=squad_lead (state/lead2.meta)" "an old task kind"
  assert_contains "$OUT" "record task_label=fm- -> task_label=jg- (state/t1.herdr-presentation)" "an old pane label"
  assert_contains "$OUT" "record FIRSTMATE_OP -> JUGGERNAUT_OP (state/operational-inbox/1.msg)" "an unhandled old message"
  assert_not_contains "$OUT" "handled/0.msg" "a handled message"
  assert_not_contains "$OUT" "2.msg" "a current message"
  assert_contains "$OUT" "slot .fm-slot-owner -> .jg-slot-owner ($(cd "$pool/1" && pwd -P))" "an old slot claim"
  assert_not_contains "$OUT" "$pool/2" "a slot that also has the new claim"
  assert_equals "in use: 12 (marker 1, file 2, setting 1, record 7, slot 1)" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "the count by kind"
  pass 'each old home name is reported only where the code still falls back to it'
}

# lab_systemctl <dir>: a `systemctl --user` that answers from files under <dir>/lab.
lab_systemctl() {
  local fakebin
  fakebin=$(jg_fakebin "$1")
  mkdir -p "$1/lab/show"
  cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --user ] || { echo "lab systemctl: only --user" >&2; exit 1; }
[ ! -e "$JG_LAB/fail" ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
case "${2:-}" in
  list-unit-files) cat "$JG_LAB/units" ;;
  show-environment) cat "$JG_LAB/env" ;;
  show)
    shift 2
    while [ "$1" != -- ]; do shift; done; shift
    for u in "$@"; do printf 'Id=%s\n' "$u"; cat "$JG_LAB/show/$u" 2>/dev/null; printf '\n'; done ;;
  *) echo "lab systemctl: unsupported: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/systemctl"
  printf '%s\n' "$fakebin"
}

host() {  # <dir> <args...>: run --host against the lab in <dir>
  local d=$1; shift
  RC=0
  OUT=$(env HOME="$d/home" XDG_DATA_HOME="$d/share" XDG_STATE_HOME="$d/xstate" JG_LAB="$d/lab" \
    PATH="$d/fakebin:$PATH" "$USAGE" --host "$@" 2>&1) || RC=$?
}

test_the_host_report() {
  local d="$TMP_ROOT/t3"
  mkdir -p "$d/home" "$d/share/jg-sentinel" "$d/xstate"
  lab_systemctl "$d" >/dev/null
  printf 'jg-sentinel.service enabled enabled\njg-sentinel.timer enabled enabled\n' > "$d/lab/units"
  printf 'ExecStart={ path=/x/jg-sentinel.sh ; argv[]=/x/jg-sentinel.sh loop ; }\nEnvironment=JG_HOME=/h\n' \
    > "$d/lab/show/jg-sentinel.service"
  printf 'PATH=/usr/bin\nLFM_HOME=/l\n' > "$d/lab/env"
  host "$d"
  expect_code 0 "$RC" "a clean host"
  assert_equals "in use: 0" "$OUT" "a clean host prints 0"

  mkdir -p "$d/share/fm-sentinel" "$d/share/fm-glm-queue" "$d/xstate/firstmate/procevent-claims"
  touch "$d/share/fm-not-a-folder"
  cat >> "$d/lab/units" <<'EOF'
fm-sentinel.service disabled enabled
fm-heavy.slice static -
fm-pair@.service static -
fm-pairpage.service transient -
other.service static -
EOF
  printf 'ExecStart={ path=/s/bin/fm-sentinel.sh ; argv[]=/s/bin/fm-sentinel.sh loop ; }\nEnvironment=FM_HOME=/h PATH=/b\n' \
    > "$d/lab/show/fm-sentinel.service"
  printf 'ExecStartPre={ path=/bin/sh ; argv[]=/bin/sh -c /o/fm-prep.sh ; }\nEnvironment=FM_TOKEN=secret-token-9\n' \
    > "$d/lab/show/other.service"
  printf 'PATH=/usr/bin\nFM_BIN=/b\n' > "$d/lab/env"
  host "$d"
  expect_code 1 "$RC" "a host with old names"
  assert_contains "$OUT" "host: unit fm-sentinel.service (disabled)" "an old-name service with its state"
  assert_contains "$OUT" "host: unit fm-heavy.slice (static)" "an old-name slice"
  assert_contains "$OUT" "host: unit fm-pair@.service (static)" "an old-name template unit"
  assert_contains "$OUT" "host: command fm-sentinel.sh -> jg-sentinel.sh (fm-sentinel.service)" "an old script, once per unit"
  assert_contains "$OUT" "host: environment FM_HOME -> JG_HOME (fm-sentinel.service)" "an old name a service sets"
  assert_contains "$OUT" "host: command fm-prep.sh -> jg-prep.sh (other.service)" "an old script a new-name unit runs"
  assert_contains "$OUT" "host: environment FM_TOKEN -> JG_TOKEN (other.service)" "an old name a new-name unit sets"
  assert_not_contains "$OUT" "secret-token-9" "an environment value is never printed"
  assert_contains "$OUT" "host: environment FM_BIN -> JG_BIN (user manager)" "an old name in the user manager"
  assert_contains "$OUT" "host: folder fm-sentinel -> jg-sentinel" "an old install folder"
  assert_not_contains "$OUT" "fm-not-a-folder" "a plain file is not an install folder"
  assert_contains "$OUT" "host: claims firstmate/procevent-claims -> juggernaut/procevent-claims" "the old claims root"
  assert_equals "in use: 12 (unit 4, folder 2, command 2, environment 3, claims 1)" \
    "$(printf '%s\n' "$OUT" | tail -n 1)" "the count by kind"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c 'command fm-sentinel.sh')" "one line per old name per unit"

  mkdir -p "$d/xstate/juggernaut/procevent-claims"
  host "$d"
  assert_not_contains "$OUT" "claims" "the old claims root beside the new one is not read"
  pass 'the host report lists old unit files, folders, scripts, environment names and the old claims root'
}

test_what_cannot_be_read_is_never_clean() {
  local d="$TMP_ROOT/t4"
  mkdir -p "$d/home" "$d/share" "$d/xstate"
  lab_systemctl "$d" >/dev/null
  touch "$d/lab/fail"
  host "$d"
  expect_code 2 "$RC" "a host whose units cannot be read"
  assert_contains "$OUT" "host units not read: systemctl --user list-unit-files: Failed to connect to bus" \
    "the real cause is named"

  mkdir -p "$d/not-a-home"
  run --home "$d/not-a-home"
  expect_code 2 "$RC" "a directory that is not a home"
  assert_contains "$OUT" "is not a Juggernaut home" "the refusal names why"
  run --home "$d/missing"
  expect_code 2 "$RC" "a missing home"
  run
  expect_code 2 "$RC" "no scope"
  pass 'a failing systemctl exits 2 with its cause, and a directory that is not a home is refused'
}

test_one_old_setting_prints_one
test_each_old_home_name_where_the_code_falls_back
test_the_host_report
test_what_cannot_be_read_is_never_clean
