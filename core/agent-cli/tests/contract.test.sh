#!/usr/bin/env bash
# E2E: the command contract (core/agent-cli/contract/*.json) and its one dispatcher, run through both names,
# `jg` and `juggernaut-axi`, on throwaway homes and throwaway projects. No live home is read.
# Usage: core/agent-cli/tests/contract.test.sh
# Covers: every fragment's shape; unique paths and aliases; the owner of an operations.tsv row; the help page;
# the old names unchanged; the exit codes; the acknowledgement reference and its repeat; the explicit home of a
# send; the repeat key of a send; the envelope; and that a read entry changes no file.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=tests/wake-helpers.sh
. "$here/../../../tests/wake-helpers.sh"
JG=$ROOT/bin/jg
AXI=$ROOT/bin/juggernaut-axi
DISPATCH=$ROOT/core/agent-cli/dispatch.sh
TMP_ROOT=$(jg_test_tmproot contract)
T=$TMP_ROOT
has() { case $2 in *"$3"*) ;; *) fail "$1: want [$3] in [$2]" ;; esac; }
hasnt() { case $2 in *"$3"*) fail "$1: did not want [$3] in [$2]" ;; esac; }
rc_is() { [ "$2" = "$3" ] || fail "$1: exit $2, want $3"; }

# --- 1. the contract: shape, unique names, owners ---------------------------------------------------------
bash "$DISPATCH" check || fail "the contract in the tree does not pass its own check"
ls "$ROOT"/core/agent-cli/contract/core.json >/dev/null || fail "core.json is missing"

mk_tree() {  # <name> -> a tree with the dispatcher, no fragments and stub scripts
  local t=$T/$1
  mkdir -p "$t/core/agent-cli/contract" "$t/bin"
  cp "$DISPATCH" "$t/core/agent-cli/dispatch.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/s.sh"; chmod +x "$t/bin/s.sh"
  printf '%s\n' "$t"
}
frag() {  # <file> <area> <owner> <path json> <script> <operation> <aliases json> [<extra json fields>]
  printf '{"area":"%s","owner":"%s","entries":[{"path":%s,"meaning":"m","roles":[],"args":[],"changes":false,"method":"GET","form":"%s","repeat_key":null,"exits":{"0":0},"schema":"x.v1","script":"%s","operation":"%s","aliases":%s}]}\n' \
    "$2" "$3" "$4" "$5" "$5" "$6" "$7" > "$1"
}
expect_refused() {  # <name> <want text> -- the tree must fail its check naming <want>
  local out rc
  out=$(bash "$T/$1/core/agent-cli/dispatch.sh" check 2>&1); rc=$?
  rc_is "$1" "$rc" 1
  has "$1" "$out" "$2"
}
t=$(mk_tree ok); frag "$t/core/agent-cli/contract/a.json" x a '["a","b"]' bin/s.sh - '[]'
bash "$t/core/agent-cli/dispatch.sh" check || fail "a valid fragment was refused"
t=$(mk_tree shape); frag "$t/core/agent-cli/contract/a.json" x a '["a"]' bin/s.sh - '[]'
sed -i 's/"meaning":"m"/"meaning":""/' "$t/core/agent-cli/contract/a.json"; expect_refused shape "a.json does not have the fragment shape"
t=$(mk_tree method); frag "$t/core/agent-cli/contract/a.json" x a '["a"]' bin/s.sh - '[]'
sed -i 's/"changes":false/"changes":true/' "$t/core/agent-cli/contract/a.json"; expect_refused method "a.json does not have the fragment shape"
t=$(mk_tree duppath); frag "$t/core/agent-cli/contract/a.json" x a '["a","b"]' bin/s.sh one '[]'; frag "$t/core/agent-cli/contract/b.json" y b '["a","b"]' bin/s.sh two '[]'
expect_refused duppath "path a b is in two entries"
t=$(mk_tree dupalias); frag "$t/core/agent-cli/contract/a.json" x a '["a"]' bin/s.sh one '["old name"]'; frag "$t/core/agent-cli/contract/b.json" y b '["b"]' bin/s.sh two '["old name"]'
expect_refused dupalias "alias old name is in two entries"
t=$(mk_tree aliaspath); frag "$t/core/agent-cli/contract/a.json" x a '["a","b"]' bin/s.sh one '[]'; frag "$t/core/agent-cli/contract/b.json" y b '["c"]' bin/s.sh two '["a b"]'
expect_refused aliaspath "alias a b is also a path"
t=$(mk_tree duppair); frag "$t/core/agent-cli/contract/a.json" x a '["a"]' bin/s.sh one '[]'; frag "$t/core/agent-cli/contract/b.json" y b '["b"]' bin/s.sh one '[]'
expect_refused duppair "(script, operation) bin/s.sh one is in two entries"
t=$(mk_tree noscript); frag "$t/core/agent-cli/contract/a.json" x a '["a"]' bin/nothere.sh - '[]'
expect_refused noscript "bin/nothere.sh names a script that is not there"
t=$(mk_tree owner); frag "$t/core/agent-cli/contract/a.json" x e9 '["a"]' bin/s.sh go '[]'
printf 'script\toperation\tform\tpath\tmethod\tchanges\towner\n' > "$t/core/agent-cli/operations.tsv"
printf 's.sh\tgo\tbin/s.sh go\ta\tGET\tno\te1\n' >> "$t/core/agent-cli/operations.tsv"
expect_refused owner "is owned by e1 in operations.tsv, not e9"
sed -i 's/"owner":"e9"/"owner":"e1"/' "$t/core/agent-cli/contract/a.json"; bash "$t/core/agent-cli/dispatch.sh" check || fail "the named owner was refused"

# A passthrough preserves arguments, streams and the child exit code.
t=$(mk_tree passthrough); frag "$t/core/agent-cli/contract/a.json" x a '["raw"]' bin/s.sh - '[]'
sed -i 's/"aliases":\[\]/"aliases":[],"passthrough":true/' "$t/core/agent-cli/contract/a.json"
printf '#!/usr/bin/env bash\nprintf "<%%s>\\n" "$@"\nprintf "problem\\n" >&2\nexit 7\n' > "$t/bin/s.sh"
out=$(bash "$t/core/agent-cli/dispatch.sh" run raw --flag 'two words' 2>"$t/error"); rc=$?
rc_is passthrough "$rc" 7
[ "$out" = "$(printf '<%s>\n' --flag 'two words')" ] || fail "passthrough changed arguments or stdout"
[ "$(cat "$t/error")" = problem ] || fail "passthrough changed stderr"
t=$(mk_tree invalidraw); frag "$t/core/agent-cli/contract/a.json" x a '["raw"]' bin/s.sh - '[]'
sed -i 's/"aliases":\[\]/"aliases":[],"passthrough":"yes"/' "$t/core/agent-cli/contract/a.json"
expect_refused invalidraw "a.json does not have the fragment shape"

# core.json holds the juggernaut-axi names and e1's own operations, and no worker verb
core=$ROOT/core/agent-cli/contract/core.json
[ "$(jq -r '.owner' "$core")" = e1 ] || fail "core.json is not owned by e1"
bad=$(jq -r '.entries[] | select(.script | IN("bin/juggernaut-axi", "bin/jg-wake-drain.sh", "bin/jg-send.sh") | not) | .script' "$core")
[ -z "$bad" ] || fail "core.json holds a script that is not e1's: $bad"
for v in status 'done' wait progress inbox alert ask proof land; do
  [ "$(jq --arg v "$v" '[.entries[] | select(.path[0] == $v or (.aliases | index("jg " + $v)))] | length' "$core")" = 0 ] || fail "core.json holds the worker verb $v"
done
for v in status lanes wakes tasks holds pr tickets board decisions messages answer message ticket; do
  [ "$(jq --arg v "juggernaut-axi $v" '[.entries[] | select(.aliases | index($v))] | length' "$core")" = 1 ] || fail "core.json has no alias entry for juggernaut-axi $v"
done

# --- 2. the help page, and a word that is neither a verb nor a noun -------------------------------------------
help=$("$JG" help); has "jg help" "$help" "jg status "   # the worker verbs stay on the page
total=$(jq -s '[.[] | .entries[]] | length' "$ROOT"/core/agent-cli/contract/*.json)
n=0
while IFS=$'\t' read -r path meaning; do
  has "jg help" "$help" "jg $path - $meaning"
  n=$((n + 1))
done < <(jq -rs '.[] | .entries[] | [(.path | join(" ")), .meaning] | @tsv' "$ROOT"/core/agent-cli/contract/*.json)
[ "$n" = "$total" ] && [ "$n" -gt 0 ] || fail "help listed $n of $total entries"
[ "$("$JG")" = "$(sed -n '/^## Verbs/,$p' "$ROOT/core/agent-cli/README.md" | sed '1d')" ] || fail "jg alone no longer prints the worker help page"
has "axi help all" "$("$AXI" help all)" "juggernaut-axi radio send - "
[ "$("$AXI" help)" = "$("$AXI" --help)" ] || fail "juggernaut-axi help and --help differ"
has "axi help" "$("$AXI" help)" "usage: juggernaut-axi <command> [--json]"
for w in frob "radio frob" "sitrep frob" "muster"; do
  # shellcheck disable=SC2086
  out=$("$JG" $w 2>&1); rc=$?; rc_is "jg $w" "$rc" 2
done
out=$("$AXI" frob 2>&1); rc=$?; rc_is "axi frob" "$rc" 2; has "axi frob" "$out" "unknown command: frob"
out=$(cd "$T" && env -u JG_HOME -u JG_TASK "$JG" status 2>&1); rc=$?; rc_is "jg status as Overwatch" "$rc" 2; has "jg status as Overwatch" "$out" "jg sitrep"

# --- 3. a throwaway home: the old names, the new paths, and the envelope --------------------------------------
H=$T/fixture/home          # the last two path words are fixed, so "home" fields read the same on every run
OTHER=$T/fixture/other
mkdir -p "$H/state" "$H/config" "$H/data" "$H/projects" "$OTHER/state" "$OTHER/config" "$OTHER/data" "$T/bin"
: > "$H/config/backlog-intake-loose"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/tmux"; cp "$T/bin/tmux" "$T/bin/sleep"; chmod +x "$T/bin/tmux" "$T/bin/sleep"
export PATH="$T/bin:$PATH" JG_ROOT_OVERRIDE=$T/fixture/root JG_SEND_SETTLE=0
mkdir -p "$JG_ROOT_OVERRIDE"
(cd "$H" && JG_HOME=$H JG_CONFIG_OVERRIDE=$H/config "$ROOT/bin/jg-backlog.sh" add q-1 "[feature] Ready work" --priority 1 --kind ship --repo alpha --body Fixture >/dev/null) || fail "fixture ticket"
for h in "$H" "$OTHER"; do
  jg_write_meta "$h/state/t1.meta" window=sess:jg-t1 kind=ship harness=claude
  jg_write_meta "$h/state/w1.meta" harness=claude kind=ship mode=direct-PR branch=fm/w1 backend=herdr window=default:w:p project="$h/projects/alpha"
  echo "working [at=1795000000]: going" > "$h/state/w1.status"
done
export JG_HOME=$H

# each old name keeps working: its own output, and the exit codes it had
for c in status lanes wakes "tasks" "tasks ready" "tasks show q-1" holds tickets decisions "messages w1" board; do
  # shellcheck disable=SC2086
  out=$("$AXI" $c 2>&1); rc=$?; rc_is "juggernaut-axi $c" "$rc" 0; has "juggernaut-axi $c" "$out" "schema: juggernaut-axi.v1"
done
out=$("$AXI" answer w1 x 2>&1); rc=$?; rc_is "juggernaut-axi answer (no open decision)" "$rc" 2
out=$("$AXI" message w1 "old name text" 2>&1); rc=$?; rc_is "juggernaut-axi message" "$rc" 0
[ "$(jq -r .view <<<"$("$AXI" ticket "[feature] Old name" --why because --json)")" = write ] || fail "juggernaut-axi ticket"
[ -f "$H/state/w1.inbox/001.msg" ] || fail "juggernaut-axi message wrote no steering record"
# --json and the new path give the same data (the clock fields aside), through both names
clockless() { jq -S 'del(.generated, .read_model_age_seconds)'; }
for pair in "status:sitrep" "lanes:sitrep lanes" "wakes:sitrep wakes" "tasks:sitrep tasks" "tasks ready:sitrep tasks ready" "tasks show q-1:sitrep tasks show q-1" \
            "holds:sitrep holds" "tickets:sitrep tickets" "decisions:sitrep decisions" "messages w1:sitrep messages w1"; do
  old=${pair%%:*}; new=${pair#*:}
  # shellcheck disable=SC2086
  want=$("$AXI" $old --json | clockless)
  for cmd in "$JG" "$AXI"; do
    # shellcheck disable=SC2086
    env=$("$cmd" $new); rc=$?; rc_is "$(basename "$cmd") $new" "$rc" 0
    [ "$(jq -r .schema <<<"$env")" = "jg.v1 juggernaut-axi.v1" ] && [ "$(jq -r .ok <<<"$env")" = true ] || fail "$new: not a jg.v1 envelope: $env"
    [ "$(jq '.data' <<<"$env" | clockless)" = "$want" ] || fail "$(basename "$cmd") $new: data differs from juggernaut-axi $old --json"
  done
done
# a read entry changes no file of the home
digest() { (cd "$H" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum); }
before=$(digest)
ask="Fix a bug in the login sync"
want=$("$ROOT/bin/jg-muster-depth.sh" --project mature --projects-dir "$H/projects" "$ask")
out=$("$JG" muster depth --project mature --projects-dir "$H/projects" "$ask") || fail "muster depth refused supported project options"
[ "$(jq -r '.data.stdout' <<<"$out")" = "$want" ] || fail "muster depth differs from the direct script: $out"
[ "$(digest)" = "$before" ] || fail "muster depth changed a file of the home"
for cmd in "sitrep" "sitrep lanes" "sitrep wakes" "sitrep tasks" "sitrep tasks ready" "sitrep tasks show q-1" "sitrep holds" "sitrep tickets" "sitrep decisions" \
           "sitrep messages w1" "sitrep board" "radio decisions"; do
  # shellcheck disable=SC2086
  "$JG" $cmd >/dev/null 2>&1 || fail "jg $cmd failed on the fixture home"
  [ "$(digest)" = "$before" ] || fail "jg $cmd (a GET entry) changed a file of the home"
done

# --- 4. the notification queue: drain gives a reference, ack takes it, a repeat is processed once --------------
append_wake "$H/state" signal t1.status "signal: t1.status" >/dev/null || fail "could not queue a wake"
echo "working [at=1795000000]: going" > "$H/state/t1.status"
env=$("$JG" radio drain 2>/dev/null); rc=$?; rc_is "radio drain" "$rc" 0
ref=$(jq -r '.data.ack_ref' <<<"$env")
case $ref in [0-9]*:[A-Za-z0-9._-]*) ;; *) fail "drain returned no reference: $env" ;; esac
has "radio drain next" "$(jq -r .next <<<"$env")" "jg radio ack $ref"
out=$("$JG" radio ack "${ref%%:*}:no.such.generation" 2>&1); rc=$?
rc_is "ack under a stale generation" "$rc" 1; has "stale ack" "$out" "jg radio drain"
append_wake "$H/state" signal t1.status "signal: t1.status again" >/dev/null || fail "could not queue a second wake"
ref=$("$JG" radio drain 2>/dev/null | jq -r '.data.ack_ref')
out=$("$JG" radio ack "$ref" 2>&1); rc=$?; rc_is "radio ack" "$rc" 0; [ "$(jq -r .ok <<<"$out")" = true ] || fail "ack was not ok: $out"
out=$("$JG" radio ack "$ref" 2>&1); rc=$?; rc_is "a repeated ack" "$rc" 0; has "repeat" "$out" "already processed"
out=$("$JG" radio ack not-a-reference 2>&1); rc=$?; rc_is "a malformed reference" "$rc" 2
out=$("$JG" radio ack 2>&1); rc=$?; rc_is "ack with no reference" "$rc" 2

# the pages sequence rides in the reference, both ways (a stand-in drain; the real one needs the item store)
t=$(mk_tree pages)
cp "$ROOT/core/agent-cli/contract/core.json" "$t/core/agent-cli/contract/"
for s in juggernaut-axi jg-send.sh; do cp "$t/bin/s.sh" "$t/bin/$s"; done
cat > "$t/bin/jg-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then echo 'rows' ; echo 'WAKE_ACK_REQUIRED: after handling completes run bin/jg-wake-drain.sh --ack-through 7 --recovery-generation g1.2 --pages-ack 3' >&2
else printf '%s\n' "$*" > "$DRAIN_ARGS"; fi
SH
chmod +x "$t/bin/jg-wake-drain.sh"
out=$(bash "$t/core/agent-cli/dispatch.sh" run radio drain 2>/dev/null); [ "$(jq -r .data.ack_ref <<<"$out")" = "7:g1.2:3" ] || fail "pages reference: $out"
DRAIN_ARGS=$t/args bash "$t/core/agent-cli/dispatch.sh" run radio ack 7:g1.2:3 >/dev/null; export -n DRAIN_ARGS
[ "$(cat "$t/args")" = "--ack-through 7 --recovery-generation g1.2 --pages-ack 3" ] || fail "ack arguments: $(cat "$t/args")"
DRAIN_ARGS=$t/args2 bash "$t/core/agent-cli/dispatch.sh" run radio ack 8:g1.2 >/dev/null
[ "$(cat "$t/args2")" = "--ack-through 8 --recovery-generation g1.2" ] || fail "ack arguments without pages: $(cat "$t/args2")"

# --- 5. a steering send: an explicit home, and one arrival per message ----------------------------------------
want_err=$(env -u JG_HOME "$ROOT/bin/jg-send.sh" t1 "no home" 2>&1 >/dev/null); want_rc=$?
out=$(env -u JG_HOME "$JG" radio send t1 "no home" 2>&1 >/dev/null); rc=$?
[ "$rc" = "$want_rc" ] && [ "$out" = "$want_err" ] || fail "send with no home is refused differently from bin/jg-send.sh: [$out] rc=$rc, want [$want_err] rc=$want_rc"
has "no home" "$out" "JG_HOME is not set"
inbox() { find "$1/state/t1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
"$JG" radio send t1 "first message" >/dev/null 2>&1 || fail "send to home A"
[ "$(inbox "$H")" = 1 ] && [ "$(inbox "$OTHER")" = 0 ] || fail "a send to home A wrote $(inbox "$H") record(s) there and $(inbox "$OTHER") into home B"
"$JG" radio send t1 "second message" >/dev/null 2>&1 || fail "second message"
[ "$(inbox "$H")" = 2 ] || fail "two different messages to one ticket did not both arrive"
out=$("$JG" radio send t1 "first message" 2>/dev/null); rc=$?; rc_is "the same message again" "$rc" 0
has "repeat send" "$out" "already processed"; [ "$(inbox "$H")" = 2 ] || fail "the same message twice arrived twice"
"$JG" radio send t1 "first message" --again >/dev/null 2>&1 || fail "--again"
[ "$(inbox "$H")" = 3 ] || fail "--again did not send it again"
"$JG" radio send t1 "keyed one" --key k1 >/dev/null 2>&1 && out=$("$JG" radio send t1 "keyed two" --key k1 2>/dev/null)
has "same --key" "$out" "already processed"; [ "$(inbox "$H")" = 4 ] || fail "a message with a used --key arrived again"
[ "$(inbox "$OTHER")" = 0 ] || fail "home B received a message"
export JG_HOME=$OTHER; "$JG" radio send t1 "first message" >/dev/null 2>&1 || fail "the same text to home B"
[ "$(inbox "$OTHER")" = 1 ] || fail "home B's own record of a repeat key was shared with home A"; export JG_HOME=$H

# --- 6. both public names pass stdin and replay identity to the real inbox ------------------------------------
body=$'First line for Umer\nSecond line for Umer'
out=$(printf '%s' "$body" | "$JG" radio inbox note --request-id tg-test-101 --json -)
rc_is 'jg radio inbox note' "$?" 0
note=$(jq -er 'select(.ok and .data.saved and .data.outcome == "created") | .data.id' <<<"$out") || fail "note was not saved: $out"
out=$(printf '%s' "$body" | "$AXI" radio inbox note --request-id tg-test-101 --json -)
rc_is 'juggernaut-axi radio inbox note' "$?" 0
jq -e --arg id "$note" '.ok and .data.outcome == "replay" and .data.id == $id' <<<"$out" >/dev/null || fail "note replay: $out"
has "stdin reached the saved note" "$(cat "$H/state/inbox/$note.note")" "$body"

# --- 7. wave-2 forms keep the script argv exact without running any lifecycle action --------------------------
t=$(mk_tree wave-2)
cp "$JG" "$t/bin/jg"
cp "$ROOT/core/agent-cli/operations.tsv" "$t/core/agent-cli/"
awk -F'\t' '$2 == "check" && $1 == "jg-tmp-sweep.sh" || $2 == "squad_lead" || $1 == "jg-claude-trust.sh" ||
  $4 ~ /^(radio (afk-contract enter|beat append|machine-guard fact)|alert alert raise|hold (owner-rules audit|board-gate route)|crew remote-squad-lead-control capture|relay (procevent register|procevent-when arm)|proof proof-bypass grant|plan blitz start|report fleet-ledger (pr_ready|cleaned_up)|ticket goal declare)$/' \
  "$t/core/agent-cli/operations.tsv" |
  while IFS=$'\t' read -r script operation form path _ _ owner aliases _; do
    cat > "$t/bin/$script" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]'
SH
    chmod +x "$t/bin/$script"
    jq -nc --arg owner "$owner" --arg script "bin/$script" --arg op "$operation" --arg form "$form" \
      --arg path "$path" --arg aliases "$aliases" '{area:"fixture",owner:$owner,entries:[{
        path:($path|split(" ")),meaning:"Record the argv",roles:[],args:[],changes:true,method:"POST",
        repeat_key:"fixture",script:$script,operation:$op,form:$form,exits:{"0":0},schema:"fixture.v1",
        aliases:(if $aliases == "-" then [] else [$aliases] end)}]}' > "$t/core/agent-cli/contract/$script-$operation.json"
  done
argv_is() {
  local expected=$1 output
  shift
  output=$("$t/bin/jg" "$@") || fail "jg $* did not dispatch"
  [ "$(jq -c .data <<<"$output")" = "$expected" ] || fail "jg $* passed the wrong argv: $output"
}
argv_is '["check"]' crew tmp-sweep check
argv_is '["check","--root","/tmp"]' crew tmp-sweep check --root /tmp
argv_is '["squad_lead","lead"]' crew harness squad_lead lead
argv_is '["/tmp/copy","demo"]' crew claude-trust /tmp/copy demo
argv_is '["--lab-home","/tmp/lab"]' crew claude-trust lab-home /tmp/lab
argv_is '["--squad-lead-home","/tmp/lead","lead"]' crew claude-trust squad-lead-home /tmp/lead lead
argv_is '["enter","--words","example"]' radio afk-contract enter --words example
argv_is '["enter","--words-file","/tmp/words"]' radio afk-contract enter --words-file /tmp/words
argv_is '["register","file","source","--","/bin/true","--flag","two words"]' relay procevent register file source -- /bin/true --flag 'two words'
argv_is '["grant","--ticket","ticket-id","--word","word-id"]' proof proof-bypass grant --ticket ticket-id --word word-id
argv_is '["grant","--home","--word","word-id","--hours","2"]' proof proof-bypass grant --home --word word-id --hours 2
argv_is '["start","plan.json","--harness","codex","--model","model","--effort","high"]' plan swarm start plan.json --harness codex --model model --effort high
argv_is '["pr_ready","t1","url"]' report fleet-ledger pr_ready t1 url
argv_is '["cleaned_up","t1"]' report fleet-ledger cleaned_up t1
argv_is '["declare","--ask","hello","--repo","demo","--","/bin/true","--flag"]' ticket goal declare --ask hello --repo demo -- /bin/true --flag
argv_is '["raise","fixture","two words","--fact","x=one","--fact","y=two words","--print"]' alert alert raise fixture 'two words' --fact x=one --fact 'y=two words' --print
out=$("$t/bin/jg" alert alert raise fixture demo --fact x=one --fact 2>&1); rc=$?
rc_is 'raise with an incomplete repeated option' "$rc" 2
has 'raise with an incomplete repeated option' "$out" 'option --fact is missing its value'
argv_is '["audit","--source","/tmp/one file","--source","/tmp/two"]' hold owner-rules audit --source '/tmp/one file' --source /tmp/two
argv_is '["append","/tmp/state","t1","event"]' radio beat append /tmp/state t1 event
argv_is '["append","/tmp/state","t1","event","timeout"]' radio beat append /tmp/state t1 event timeout
argv_is '["fact","reuse"]' radio machine-guard fact reuse
argv_is '["capture","lead"]' crew remote-squad-lead-control capture lead
argv_is '["capture","lead","12"]' crew remote-squad-lead-control capture lead 12
argv_is '["arm","fixture","--interval","2","--condition","/bin/false","--flag","two words","--action","/bin/true","--interval"]' \
  relay procevent-when arm fixture --interval 2 --condition /bin/false --flag 'two words' --action /bin/true --interval

# Both entry points use the same board clock and produce the same durable record.
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$ROOT/bin/jg-board-gate.sh" > "$t/bin/jg-board-gate.sh"
route_args=(--title 'Send the planned update' --filer jg-t1 --ref jg-t2)
JG_BOARD_GATE_NOW=1795000000 JG_DATA_OVERRIDE=$H/route-direct "$ROOT/bin/jg-board-gate.sh" route "${route_args[@]}" >/dev/null \
  || fail "direct board route"
JG_BOARD_GATE_NOW=1795000000 JG_DATA_OVERRIDE=$H/route-bound "$t/bin/jg" hold board-gate route "${route_args[@]}" >/dev/null \
  || fail "dispatched board route"
diff -r "$H/route-direct" "$H/route-bound" || fail "board route wrote different records through the dispatcher"

pass "contract: fragments, names, envelope, acknowledgement reference, repeats and explicit home"
