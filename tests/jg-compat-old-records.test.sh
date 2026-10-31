#!/usr/bin/env bash
# A home that has not renamed its records yet still works: each record the
# rename moved is read under its old name when the new name is absent, a task
# record naming the old nested-supervisor kind reads as the current kind, and a
# library reached through its old path answers to its old function names.
# These are read fallbacks only; nothing here writes a record.
set -u
# shellcheck disable=SC1090
# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

h=$(mktemp -d)
trap 'rm -rf -- "$h"' EXIT
mkdir -p "$h"/config "$h"/data "$h"/state
legacy_lead=second
legacy_lead+=mate

# role file and inheritance receipt
printf 'maintainer github.com/o/r\n' > "$h/config/firstmate-role"
(
  . "$ROOT/bin/jg-role-lib.sh"
  jg_role_resolve "$h" "$h/config" >/dev/null 2>&1
  [ "${JG_ROLE:-}" = maintainer ]
) || fail "an old config/firstmate-role no longer grants the maintainer role"
pass "old role file still grants maintainer"
(
  # shellcheck disable=SC1090
  . "$ROOT/bin/fm-role-lib.sh"
  fm_role_resolve "$h" "$h/config" >/dev/null 2>&1
  [ "${FM_ROLE:-}" = maintainer ]
) || fail "the old role resolver does not answer in its old variables"
pass "the old role resolver answers in its old variables"
touch "$h/config/.fm-inherit-firstmate-role.generation"
[ "$(. "$ROOT/bin/jg-role-lib.sh"; jg_role_inherit_receipt "$h/config")" = "$h/config/.fm-inherit-firstmate-role.generation" ] \
  || fail "an old inheritance receipt is not found"
pass "old inheritance receipt is found"
mv "$h/config/firstmate-role" "$h/config/juggernaut-role"
[ "$(. "$ROOT/bin/jg-role-lib.sh"; jg_role_file "$h/config")" = "$h/config/juggernaut-role" ] \
  || fail "the new role file must win once it exists"
pass "the new role file wins over the old one"

# backlog transition lib: an old caller reads its output variable under set -u
printf 'spawn_gen=g1\n' > "$h/state/t.meta"
(
  set -u
  # shellcheck disable=SC1090
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_meta_spawn_gen "$h/state/t.meta" "$h/state" >/dev/null 2>&1
  [ "$FM_BACKLOG_META_SPAWN_GEN" = g1 ]
) || fail "an old caller cannot read FM_BACKLOG_META_SPAWN_GEN after the old transition function"
pass "the old transition lib answers in its old variables"

# squad lead registry
printf -- '- lead - desc (home: %s; scope: s; projects: p; added 2026-10-14)\n' "$h" > "$h/data/${legacy_lead}s.md"
reg=$(. "$ROOT/bin/jg-compat.sh"; jg_compat_pick "$h/data/squad_leads.md")
[ "$reg" = "$h/data/${legacy_lead}s.md" ] || fail "old registry file not picked: $reg"
[ "$(. "$ROOT/bin/jg-squad-lead-registry-lib.sh"; squad_lead_registry_field "$reg" lead home)" = "$h" ] \
  || fail "the old registry did not resolve the lead's home"
pass "old squad lead registry resolves"
mv "$h/data/${legacy_lead}s.md" "$h/data/squad_leads.md"
(
  # shellcheck disable=SC1090
  . "$ROOT/bin/fm-${legacy_lead}-registry-lib.sh"
  [ "$("${legacy_lead}_registry_field" "$h/data/${legacy_lead}s.md" lead home)" = "$h" ]
) || fail "an old caller naming the renamed-away registry file got nothing"
pass "an old caller naming the old registry file still resolves after the file is renamed"

# harness file
printf 'claude claude-haiku-5-5 low\n' > "$h/config/${legacy_lead}-harness"
[ "$(JG_HOME=$h JG_CONFIG_OVERRIDE=$h/config "$ROOT/bin/jg-harness.sh" squad-lead-model 2>/dev/null)" = claude-haiku-5-5 ] \
  || fail "an old squad lead harness file is not read"
pass "old squad lead harness file is read"

# task record kind
printf 'kind=%s\nharness=claude\n' "$legacy_lead" > "$h/state/lead.meta"
[ "$(. "$ROOT/bin/jg-backend.sh"; jg_meta_get "$h/state/lead.meta" kind)" = squad_lead ] \
  || fail "an old task record kind does not read as squad_lead"
(. "$ROOT/bin/jg-compat.sh"; jg_compat_meta_is_squad_lead "$h/state/lead.meta") \
  || fail "an old task record is not recognised as a squad lead"
pass "old task record kind reads as squad_lead"

# old function names through the old library path
for pair in "bin/fm-backend.sh:fm_meta_get" "bin/fm-backend.sh:fm_backend_of_meta" "bin/fm-timeout-lib.sh:fm_run_timed" "bin/fm-${legacy_lead}-registry-lib.sh:${legacy_lead}_registry_field"; do
  lib=${pair%%:*}; fn=${pair##*:}
  # shellcheck disable=SC1090
  (. "$ROOT/$lib" >/dev/null 2>&1; declare -F "$fn" >/dev/null) || fail "$fn is not defined after sourcing $lib"
done
pass "old function names answer through the old library paths"
# every old library path answers to the old name of each function its renamed
# library defines, including a library that does not load the compatibility
# layer itself (an OpenCode plugin loaded before the rename calls
# fm_supervision_needed through bin/fm-supervision-lib.sh)
for shim in "$ROOT"/bin/fm-*-lib.sh; do
  missing=$(
    before=$(compgen -A function)
    # shellcheck disable=SC1090
    . "${shim%/*}/jg-${shim##*/fm-}" >/dev/null 2>&1
    new=$(compgen -A function | grep -vxF "$before" | grep '^jg_' | grep -v '^jg_compat_')
    # shellcheck disable=SC1090
    . "$shim" >/dev/null 2>&1
    for fn in $new; do declare -F "fm_${fn#jg_}" >/dev/null || printf '%s ' "fm_${fn#jg_}"; done
  )
  [ -z "$missing" ] || fail "sourcing ${shim##*/} leaves old names undefined: $missing"
done
(. "$ROOT/bin/fm-supervision-lib.sh"; declare -F fm_supervision_needed >/dev/null) \
  || fail "fm_supervision_needed is not defined after sourcing bin/fm-supervision-lib.sh"
pass "every old library path answers to its library's old function names"
# an old caller that runs a library as `bash <old path>` reaches the renamed
# library even though that library is not executable
[ ! -x "$ROOT/bin/jg-supervision-engine-lib.sh" ] \
  || fail "bin/jg-supervision-engine-lib.sh is executable, so this case no longer proves anything"
mkdir -p "$h/host-config"
bash "$ROOT/bin/fm-supervision-engine-lib.sh" enabled "$h/host-config" opencode 2>/dev/null
rc=$?
[ "$rc" -eq 1 ] || fail "the old engine path answered $rc, not 1, for a home without a supervision host"
printf 'claude claude-haiku-5-5\n' > "$h/host-config/supervision-host"
bash "$ROOT/bin/fm-supervision-engine-lib.sh" enabled "$h/host-config" opencode 2>/dev/null \
  || fail "the old engine path did not see the home's supervision host"
pass "an old caller running a library through bash reaches the renamed library"
# the handover those shims each carried is one library now: no shim keeps its
# own copy, and every shim still resolves to the file its old form named
# shellcheck source=bin/jg-alias-lib.sh
. "$ROOT/bin/jg-alias-lib.sh"
for shim in "$ROOT"/bin/fm-*.sh; do
  [ "$(wc -l < "$shim")" -le 8 ] \
    || fail "${shim##*/} carries its own copy of the alias handover again"
  ! grep -q 'exec bash' "$shim" \
    || fail "${shim##*/} hands over by itself instead of calling bin/jg-alias-lib.sh"
  target=$(jg_alias_target "${shim##*/}")
  [ -f "$ROOT/bin/$target" ] \
    || fail "${shim##*/} hands over to $target, which does not exist"
done
# an executed shim still hands its own arguments through, one argument at a time
argdir=$h/aliasargs
mkdir -p "$argdir"
cp "$ROOT/bin/jg-alias-lib.sh" "$argdir/"
cp "$ROOT/bin/fm-role-lib.sh" "$argdir/fm-args.sh"
printf '#!/usr/bin/env bash\nprintf "%%s|" "$@"\n' > "$argdir/jg-args.sh"
chmod +x "$argdir/jg-args.sh"
[ "$(bash "$argdir/fm-args.sh" a 'b c')" = 'a|b c|' ] \
  || fail "an executed shim no longer hands its own arguments through"
pass "every old path hands over from one library, and keeps its arguments"
# a per-lead pin left under the old directory name
mkdir -p "$h/config/${legacy_lead}s/lead1"
printf 'claude claude-haiku-5-5 low\n' > "$h/config/${legacy_lead}s/lead1/harness"
[ "$(JG_HOME="$h" JG_CONFIG_OVERRIDE="$h/config" bash "$ROOT/bin/jg-harness.sh" squad-lead-model lead1 2>&1)" = claude-haiku-5-5 ] \
  || fail "an old config/${legacy_lead}s/<id>/harness pin is not read"
pass "an old per-lead pin directory is still read"
# a saved contribution record under the old schema name
rec='{"schema":"fm-contributions.v1","task":"t","records":[]}'
prog=$(cat "$ROOT/bin/jg-contributions.jq"; printf '\nvalid_record\n')
printf '%s' "$rec" | jq -e "$prog" >/dev/null \
  || fail "a record saved under fm-contributions.v1 is treated as unreadable"
pass "an old contribution record is still readable"
# the migrator renames a lead home's markers, header wording and pin directory, and rolls back exactly
lh=$h/leadhome
mkdir -p "$lh"/config/"${legacy_lead}"s/l1 "$lh"/state "$lh"/data
printf 'claude claude-haiku-5-5 low\n' > "$lh/config/${legacy_lead}s/l1/harness"
printf 'l1\n' > "$lh/.fm-${legacy_lead}-home"
printf 'schema=fm-%s-parent.v1\nroute=remote\n' "$legacy_lead" > "$lh/.fm-${legacy_lead}-parent"
printf '# main-authoritative. read-only in %s homes, must not be edited there. Ask the main first%s.\n' "$legacy_lead" mate > "$lh/data/captain-shared.md"
cp -a "$lh" "$h/leadhome-before"
bash "$ROOT/bin/jg-migrate.sh" --home "$lh" --apply >/dev/null 2>&1 || fail "migrator apply failed on an old lead home"
bash "$ROOT/bin/jg-migrate.sh" --home "$lh" --verify >/dev/null 2>&1 || fail "migrator verify failed on an old lead home"
grep -q '^l1$' "$lh/.jg-squad-lead-home" && grep -q '^schema=jg-squad-lead-parent.v1$' "$lh/.jg-squad-lead-parent" \
  && grep -q 'read-only in squad_lead homes' "$lh/data/captain-shared.md" \
  && grep -q 'claude-haiku-5-5' "$lh/config/squad_leads/l1/harness" \
  && [ ! -e "$lh/.fm-${legacy_lead}-home" ] && [ ! -e "$lh/.fm-${legacy_lead}-parent" ] && [ ! -e "$lh/config/${legacy_lead}s" ] \
  || fail "the migrator left an old marker, header wording or pin directory"
bash "$ROOT/bin/jg-migrate.sh" --home "$lh" --rollback >/dev/null 2>&1 || fail "migrator rollback failed"
diff -r "$h/leadhome-before" "$lh" >/dev/null || fail "rollback did not restore the old lead home"
pass "the migrator renames old lead records and rolls back exactly"
# a pool-slot claim written under the old name still names the task that holds the slot
slot=$h/pool/1
mkdir -p "$slot/repo"
printf 'task=other-task\nhome=/x\n' > "$h/pool/1/.fm-slot-owner"
(
  . "$ROOT/bin/jg-wake-lib.sh"
  jg_treehouse_slot_owner_state "$slot/repo" mine-task
  [ "$JG_TREEHOUSE_SLOT_OWNER" = other ] && [ "$JG_TREEHOUSE_SLOT_OWNER_ID" = other-task ]
) || fail "an old .fm-slot-owner claim is ignored, so a reassigned slot reads as unclaimed"
(
  . "$ROOT/bin/jg-wake-lib.sh"
  jg_treehouse_slot_owner_claim "$slot/repo" mine-task /y
  jg_treehouse_slot_owner_state "$slot/repo" mine-task
  [ "$JG_TREEHOUSE_SLOT_OWNER" = mine ] && [ ! -e "$h/pool/1/.fm-slot-owner" ]
  jg_treehouse_slot_owner_release "$slot/repo" mine-task
  jg_treehouse_slot_owner_state "$slot/repo" mine-task
  [ "$JG_TREEHOUSE_SLOT_OWNER" = absent ]
) || fail "a new claim must replace the old one and a release must leave the slot unclaimed"
pass "an old pool-slot claim is read, replaced and released"
# a squad lead launched before the rename keeps its Stop pointer under the old name
bh=$h/busyhome
mkdir -p "$bh/bin" "$bh/state"
cat > "$bh/writer.sh" <<'W'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/writer.log"
W
chmod +x "$bh/writer.sh"
printf 'writer=%s/writer.sh\nstate=%s/state\nid=lead\ngen=g1\n' "$bh" "$bh" > "$bh/.fm-busy-stop"
printf '{}' | JG_ROOT_OVERRIDE="$bh" bash "$ROOT/bin/jg-turnend-guard.sh" --claude >/dev/null 2>&1 || true
grep -q 'apply .*lead idle --gen g1' "$bh/writer.log" 2>/dev/null \
  || fail "the Stop guard ignores a pointer saved under .fm-busy-stop, so the lead's busy record is never closed"
pass "the Stop guard honours an old Stop pointer"
printf 'jg-compat-old-records passed\n'
