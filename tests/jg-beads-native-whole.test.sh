#!/usr/bin/env bash
# Beads stays whole behind bin/jg-beads.sh: each refusal fires with its rule, and every other verb reaches a stand-in
# bd unchanged. JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT name the pinned builds for the real case, which skips plainly
# without them: it walks bd's help against these lists, runs every served verb with no network, and proves events prune.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/jg-beads.sh" T=$(jg_test_tmproot jg-beads-native-whole)
unset BEADS_DB BEADS_DOLT_SHARED_SERVER
sha_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

# Every command in the pinned bd's help, split by whether a bare call reaches bd.
SERVED=(admin admin\ {cleanup,compact,reset} ado ado\ status assign audit audit\ {label,record} backup backup\ {init,remove,restore,status,sync} batch blocked branch children close comment
  comments comments\ {add,list} compact completion completion\ {bash,fish,powershell,zsh} config config\ {drift,get,list,set,set-many,show,unset,validate} conflicts
  conflicts\ {list,resolve,show} context cook count create create-form defer delete dep dep\ {add,cycles,list,relate,remove,tree,unrelate} diff doctor dolt dolt\ {commit,remote,show,status}
  dolt\ remote\ {list,remove} duplicate duplicates edit epic epic\ {status,close-eligible} events events\ {export,prune,tail} export federation federation\ {list-peers,remove-peer,status}
  find-duplicates flatten forget formula formula\ {convert,list,schema,show} gate gate\ {add-waiter,create,list,resolve,show} gc github github\ status gitlab gitlab\ status graph
  graph\ check heartbeat history hooks hooks\ list human human\ {dismiss,list,respond,stats} import info init-safety jira jira\ status kv kv\ {clear,get,list,set} label
  label\ {add,list,list-all,propagate,remove} linear linear\ status link lint list mail memories merge-slot merge-slot\ {acquire,check,create,release} metrics metrics\ {example,off} migrate
  migrate\ {hooks,issues,legacy-sqlite,schema} migrate-personal mol mol\ {bond,burn,current,distill,last-activity,pour,progress,ready,seed,show,squash,stale,wisp}
  mol\ wisp\ {create,gc,list} note notion onboard orphans ping preflight prime priority promote provenance provenance\ {by-ref,log,record} prune purge q query quickstart ready recall
  recompute-blocked reclaim remember rename rename-prefix reopen repo repo\ {add,list,remove,sync} restore rules rules\ {audit,compact} schema search set-state setup ship show sql stale
  state state\ list status statuses supersede swarm swarm\ {create,list,status,validate} tag todo todo\ {add,done,list} types unclaim undefer update upgrade upgrade\ {ack,review,status} vc
  vc\ {commit,merge,status} version where worktree worktree\ {info,list})
SERVER=(serve dolt\ {start,stop,killall,test,set,clean-databases}
  migrate\ from-{proxied-server-to-server,server-to-proxied-server,shared-server-to-proxied-server,proxied-server-to-shared-server})
REMOTE=(sync bootstrap dolt\ {push,pull} dolt\ remote\ {add,reset-data} federation\ {add-peer,sync})
NETWORK=(ado\ {projects,pull,push,sync} github\ {pull,push,repos,sync} gitlab\ {projects,pull,push,sync} jira\ {pull,push,sync}
  linear\ {pull,push,sync,teams} notion\ {connect,init,pull,push,status,sync} gate\ {discover,check})
TREE=(hooks\ {install,uninstall,run} worktree\ {create,remove} migrate\ sync config\ apply)

mkdir -p "$T/bin" "$T/store" "$T/repo/.git" "$T/repo/a" "$T/plain"
ln -s "$T/repo/o" "$T/plain/link"
cat > "$T/bin/bd" <<'SH'
#!/usr/bin/env bash
{ printf 'pwd=%s args=%s\n' "$PWD" "$*"; env; } >> "$LOG"
[ "$1" = init ] || exit 0
printf '{"dolt_mode": "embedded", "dolt_database": "jg"}\n' > "$BEADS_DIR/metadata.json"
printf 'no-git-ops: true\n' > "$BEADS_DIR/config.yaml"
mkdir -p "$BEADS_DIR/embeddeddolt/jg"
SH
{ cat "$T/bin/bd"; printf '# dolt\n'; } > "$T/bin/dolt"
chmod +x "$T"/bin/*
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
printf 'bd 1.3.4\ndolt 2.6.0\nbd-sha256-%s-%s %s\ndolt-sha256-%s-%s %s\n' \
  "$os" "$arch" "$(sha_of "$T/bin/bd")" "$os" "$arch" "$(sha_of "$T/bin/dolt")" > "$T/pins"
export JG_PIN_FILE_OVERRIDE=$T/pins LOG=$T/call.log BEADS_DIR=$T/store/.beads JG_BEADS_BD=$T/bin/bd JG_BEADS_DOLT=$T/bin/dolt
"$WRAPPER" init --prefix jg >/dev/null 2>&1 || fail "stand-in init"

refused() {  # <rule> <bd args...>; bd must not start.
  local rule=$1 out
  shift
  rm -f "$LOG"
  out=$("$WRAPPER" "$@" 2>&1)
  expect_code 2 "$?" "$*"
  assert_contains "$out" "refused ($rule): " "$*"
  assert_absent "$LOG" "$*: bd ran"
}
reaches() {  # <bd args...>; bd must get them unchanged.
  rm -f "$LOG"
  "$WRAPPER" "$@" >/dev/null 2>&1 || fail "$* must reach bd"
  grep -qxF "pwd=$T/store args=$*" "$LOG" || fail "$* must reach bd unchanged"
}
each() { local rule=$1 call; shift; for call in "$@"; do read -ra args <<<"$call"; refused "$rule" "${args[@]}"; done; }

each server "${SERVER[@]}" "--actor=x init" "--actor x serve" "config set dolt.host x" "config set-many a=b dolt.port=1"
each remote "${REMOTE[@]}" "--actor x sync" "--dolt-auto-commit off sync" "config set sync.remote x" "config set backup.url x" "sql CALL DOLT_PUSH('origin','main')" \
  "backup init https://x/y" "backup add git@x:y" "backup restore s3://x"
each network "${NETWORK[@]}" "gate check --type=gh" "gate check -t gh:pr" "gate check --type timer --type all" "find-duplicates --method ai" "find-dups --method=ai" \
  "admin compact --auto"
each metrics "metrics on" "config set metrics.enabled true" "config set telemetry.x 1"
each "git tree" "${TREE[@]}" "migrate hooks --apply" "config set no-git-ops false" "config unset no-git-ops" "create x --repo $T/repo" "create x --repo=$T/repo/a" "export -o $T/repo/o" \
  "export -o=$T/repo/o" "export -o$T/repo/o" "export -qo $T/repo/o" "export --output=$T/repo/new/o" "export -o $T/plain/none/../../repo/o" "mol distill x -o $T/repo/o" \
  "repo add $T/repo" "backup init $T/repo" "setup x -o $T/repo/o" "rules compact --path $T/repo/o" "migrate issues --to $T/repo" "config set export.path $T/repo/o" \
  "config set routing.default $T/repo" "export -o $T/plain/link"
each secret "config get jira.api_token" "config set github.token x" "config set-many a=b linear.API_KEY=x" "config set x.pat y"

for call in "${SERVED[@]/%/ --extra}" "gate check --type=timer" "gate check -t bead" "find-duplicates --method mechanical" \
  "export -o $T/plain/o" "export -o=$T/plain/Co" "config set events-journal true" "help serve"; do read -ra args <<<"$call"; reaches "${args[@]}"; done
env GITHUB_TOKEN=tok1 ANTHROPIC_API_KEY=tok2 JIRA_PAT=tok3 X_SECRET=tok4 "$WRAPPER" list || fail "list"
assert_no_grep 'tok[1-4]' "$LOG" "no secret may reach bd"

{ [ -n "${JG_BEADS_TEST_BD:-}" ] && [ -n "${JG_BEADS_TEST_DOLT:-}" ] && command -v bwrap >/dev/null; } || {
  printf 'skip: real bd: JG_BEADS_TEST_BD, JG_BEADS_TEST_DOLT or bwrap is missing\n'; pass "jg-beads native whole"; exit 0; }
unset JG_PIN_FILE_OVERRIDE
mkdir -p "$T/real" "$T/user/.beads/eventsData" "$T/user/.dolt/eventsData"
printf 'queued\n' | tee "$T/user/.beads/eventsData/keep" > "$T/user/.dolt/eventsData/keep"
export HOME=$T/user BEADS_DIR=$T/real/.beads JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
jail=(bwrap --ro-bind / / --tmpfs /tmp --bind "$T" "$T" --ro-bind "$ROOT" "$ROOT" --dev /dev --proc /proc --unshare-net --unshare-pid --die-with-parent)
bd_() { timeout 30 "${jail[@]}" "$WRAPPER" "$@" </dev/null 2>&1; }
bd_ init --prefix jg >/dev/null || fail "real init"

# The lists above are the pinned bd's whole help: a new command must be surveyed before it passes here.
walk() {
  local sub
  [ "$#" -eq 0 ] || printf '%s\n' "$*"
  while read -r sub; do
    case " $* help " in *" $sub "*) ;; *) walk "$@" "$sub" ;; esac
  done < <(bd_ help "$@" | awk '/^Usage:/ { on = 1 } on && /^[A-Z][A-Za-z &]+:[ ]*$/ { list = $0 !~ /^(Flags|Global Flags|Usage|Aliases|Examples):/; next }
    on && list && /^  [a-z][a-z0-9-]* +[^ ]/ { print $1 }')
}
known=$(printf '%s\n' "${SERVED[@]}" "${SERVER[@]}" "${REMOTE[@]}" "${NETWORK[@]}" "${TREE[@]}" init 'metrics on' | sort -u)
assert_contains "$(diff <(walk | sort -u) <(printf '%s\n' "$known") && echo same)" same "the lists must match the pinned bd's help"

# events prune cuts this store's journal and nothing beyond its parent folder.
outside() { find "$T" -path "$T/real" -prune -o -type f -exec sha256sum {} + | sort; }
bd_ config set-many events-journal=true events-journal-retain-days=0 events-journal-retain-rows=0 >/dev/null || fail "real config"
for row in 1 2 3 4; do bd_ create "row $row" >/dev/null || fail "real create"; done
before=$(outside)
assert_contains "$(bd_ events tail --since 0 | grep -c '"seq":')" 4 "the journal must hold every row"
bd_ events prune --before 3 >/dev/null || fail "real events prune"
assert_contains "$(bd_ dolt sql -q 'select count(*) as n from bd_events_journal')" "| 2 " "prune must cut this store's journal"
[ "$before" = "$(outside)" ] || fail "events prune touched a file outside the store's folder, the eventsData canaries included"

# No served verb calls out or writes outside the store's folder. config drift tries 127.0.0.1:0, which never answers.
for call in "${SERVED[@]}"; do
  read -ra args <<<"$call"
  ! bd_ "${args[@]}" | grep -E 'network is unreachable|dial tcp( [^1]|:)' || fail "$call called out"
done
[ "$before" = "$(outside)" ] || fail "a served verb touched a file outside the store's folder"
pass "jg-beads native whole"
