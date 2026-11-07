#!/usr/bin/env bash
# A public follow-up kept as a native Beads row by bin/jg-beads-followup.py, driven through bin/jg-tasks-axi.sh on both providers, in a throwaway
# folder outside any git tree. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds; it skips plainly without them.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ] || ! command -v tasks-axi >/dev/null; then
  printf 'skip: real store: JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT or tasks-axi is missing\n'; exit 0; fi
T=$(jg_test_tmproot jg-beads-followup) CLI="$ROOT/bin/jg-tasks-axi.sh" jail=()
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
export TZ=UTC JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
command -v bwrap >/dev/null && jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
for h in ta bd; do
  mkdir -p "$T/$h/data" "$T/$h/state" "$T/$h/config" "$T/$h/s"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$T/$h/data/backlog.md"
done
printf 'beads\n' > "$T/bd/config/backlog-backend"
printf '%s\n' "$T/bd/s/.beads" > "$T/bd/config/beads-dir"
BEADS_DIR=$T/bd/s/.beads "${jail[@]}" "$ROOT/bin/jg-beads.sh" init --prefix jg >/dev/null 2>&1 || fail "a store"
ask() { JG_HOME="$T/$1" "${jail[@]}" "$CLI" "${@:2}"; }
same() {  # <args...>: both providers answer alike, apart from the random delivery key and the row's stamps.
  local a b ra=0 rb=0 clean='del(.. | .delivery_key?, .created?, .closed?)'
  a=$(ask ta "$@" 2>/dev/null) || ra=$?
  b=$(ask bd "$@" 2>/dev/null) || rb=$?
  case " $* " in *" --json "*) a=$(jq -S "$clean" <<<"$a") b=$(jq -S "$clean" <<<"$b") ;; esac
  [ "$a$ra" = "$b$rb" ] || fail "$* differs, rc $ra/$rb: $(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"
}
jq -n '{request_id:"req-1", platform:"discord", context_binding:{version:"ctx1", value:"ctx1_one"},
  public_safe_summary:"Umer asked for the fix", received_at:"2026-07-30T10:00:00Z",
  followup_expires_at:"2026-08-06T10:00:00Z", reservation_expires_at:"2026-08-06T10:00:00Z"}' > "$T/req.json"
jq -n '{type:"pr-merged", project:"juggernaut", required_deliverables:["pr_url"], completion_policy:"all-required"}' > "$T/final.json"
jq '.public_safe_summary = "another summary"' "$T/req.json" > "$T/other.json"
jq '.required_deliverables = ["report_path"]' "$T/final.json" > "$T/wrong.json"
# <runner> <id> <request> [flags...]: the runner is one or two words, so it splits here on purpose.
promise() { $1 public-followup add "$2" --request-context-file "$T/$3.json" --purpose promised-final --expected-final-file "$T/final.json" --expires-at 2026-10-01T00:00:00Z "${@:4}"; }
same public-followup list
promise same pf-one req --json
promise same pf-one req --json
promise same pf-one req
promise same pf-one other
for edit in 'received_at = "2026-02-30T10:00:00Z"' 'platform = "mail"' 'extra = 1'; do
  jq ".$edit" "$T/req.json" > "$T/bad.json"
  promise same pf-bad bad
done
same public-followup add pf-bad --request-context-file "$T/req.json" --purpose promised-final --expected-final-file "$T/wrong.json" --expires-at 2026-10-01T00:00:00Z
same public-followup list --json
same public-followup list
same public-followup list --delivery-state intent --json
same public-followup list --delivery-state nonsense
same public-followup nonsense
same ready
ask bd add jg-plain "[feature] Plain row" --body why >/dev/null || fail "a plain row"
assert_contains "$(promise 'ask bd' jg-plain req)" "already exists" "a promise must not take over a plain row"
# Only the typed verbs move a promise, and a backlog file cannot carry one.
refused() { local out; out=$(ask bd "$@" pf-one 2>&1) && fail "$1 must refuse a promise"; assert_contains "$out" "cannot change through generic" "$1 must name the typed path"; }
refused 'done'; refused start; refused reopen; refused hold --reason why; refused update --title moved
assert_contains "$(. "$ROOT/bin/jg-tasks-axi-lib.sh"; jg_backlog_beads_write "$T/bd/config" stage pf-one 2>&1)" "cannot cross to a backlog file" "a backlog file must refuse a promise"
assert_contains "$(. "$ROOT/bin/jg-public-followup-lib.sh"; jg_pf_obligation_json "$T/bd" pf-one 2>&1)" '"public_safe_summary"' "the shell reader must see the payload"
# Work bound to a promise: both backlogs agree on every relation answer, refusal and the delivery state it leaves.
relation() { jq -n --arg id "$1" --arg task "$2" --arg role "${3:-fulfills}" --argjson generation "${4:-1}" \
  '{relation_id:$id, work_ref:{home_id:"main", task_id:$task}, role:$role, required:true, generation:$generation}' > "$T/$1.json"; }
bind() { same public-followup bind-work "$1" --relation-file "$T/$2.json" "${@:3}"; }
relation rel-a jg-work; relation rel-next jg-next fulfills 2; relation rel-far jg-next fulfills 3; relation rel-late jg-work fulfills 2
jq '.role = "contributes"' "$T/rel-a.json" > "$T/rel-clash.json"
jq '.relation_id = "rel-a"' "$T/rel-clash.json" > "$T/rel-clash.tmp" && mv "$T/rel-clash.tmp" "$T/rel-clash.json"
jq '.relation_id = "nope"' "$T/rel-a.json" > "$T/rel-odd.json"
jq '.work_ref.home_id = "nowhere"' "$T/rel-a.json" > "$T/rel-home.json"
jq '.required = "yes"' "$T/rel-a.json" > "$T/rel-req.json"
ask ta add jg-plain "[feature] Plain row" --body why >/dev/null 2>&1 || fail "a plain row on the old backlog"
for h in ta bd; do ask "$h" add jg-work "[feature] Bound work" --body why >/dev/null 2>&1 || fail "work to bind on $h"; done
promise same pf-two req --json
promise same pf-three req --json
bind pf-two rel-a --json
bind pf-two rel-a --json
bind pf-three rel-a
bind pf-three rel-a
for file in rel-clash rel-odd rel-home rel-req rel-late; do bind pf-two "$file"; done
bind pf-none rel-a
bind jg-plain rel-a
same public-followup bind-work --relation-file "$T/rel-a.json"
same public-followup bind-work pf-two extra --relation-file "$T/rel-a.json"
same public-followup bind-work pf-two --relation-file "$T/absent.json"
same public-followup list --work-ref main/jg-work --json
same public-followup list --work-ref main/jg-work
same public-followup list --work-ref main/absent
same public-followup list --work-ref nowhere
same public-followup list --delivery-state pending-work --json
same public-followup supersede-work pf-three --relation rel-a --successor-file "$T/rel-next.json" --json
same public-followup supersede-work pf-three --relation rel-a --successor-file "$T/rel-next.json" --json
same public-followup supersede-work pf-three --relation rel-a --successor-file "$T/rel-far.json"
same public-followup supersede-work pf-three --relation rel-next --successor-file "$T/rel-next.json"
same public-followup supersede-work pf-three --relation rel-gone --successor-file "$T/rel-next.json"
same public-followup supersede-work pf-three --successor-file "$T/rel-next.json"
same public-followup list --work-ref main/jg-next --json
# Native shape: one tracks edge that never blocks the work it names.
[ "$(BEADS_DIR=$T/bd/s/.beads "${jail[@]}" "$ROOT/bin/jg-beads.sh" list --all --limit 0 --json | jq '[.[] | select(.id == "pf-two") | .dependencies[]? | select(.type == "tracks")] | length')" = 1 ] || fail "one tracks edge from the promise to its work"
assert_contains "$(ask bd ready)" "jg-work" "bound work must stay ready"
# Writers of one id race to one row with one delivery key.
for n in 1 2 3 4; do promise 'ask bd' pf-race req --json > "$T/race.$n" 2>/dev/null & done; wait
[ "$(ask bd public-followup list --json | jq '[.public_followups[] | select(.id == "pf-race")] | length')" = 1 ] || fail "one promise from four writers"
[ "$(jq -r '.task.public_followup.delivery.delivery_key' "$T"/race.* | sort -u | wc -l)" = 1 ] || fail "one delivery key from four writers"
[ "$(jq -s 'map(select(.ok)) | length' "$T"/race.*)" = 4 ] || fail "each of four writers gets an answer, not a refusal"
# Writers of one promise each keep their relation, so a lost update cannot drop bound work.
for n in 1 2 3 4; do relation "rel-race$n" "jg-race$n"; ask bd public-followup bind-work pf-race --relation-file "$T/rel-race$n.json" >/dev/null 2>&1 & done; wait
[ "$(ask bd public-followup list --work-ref main/jg-race1 --json | jq '[.public_followups[].public_followup.work_relations[]] | length')" = 4 ] || fail "four writers must bind four relations"
pass "a public follow-up keeps one contract on both backlogs"
