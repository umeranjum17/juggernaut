#!/usr/bin/env bash
# Behavior tests for core/machines/tables/markers.tsv: every per-pane marker kind the watcher keeps has a
# writer and a remover, and a marker whose pane no task record names is an orphan.
# The state directory and the watcher source are generated here by seed_*; no fleet record is copied.
# There is no engine `sweep` yet, so sweep and audit below are read-only loops over `jg-machine.sh show`
# and over the table; the real watcher is audited report-only (it prints, it never fails the test).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
TBL="$ROOT/core/machines/tables/markers.tsv"
T=$(jg_test_tmproot jg-machine-markers); mkdir -p "$T/state" "$T/src"
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }

seed_state() {  # <dir>: two live panes (task records) and markers for live, vanished and unrelated panes
  local w
  for w in p1 p2; do printf 'window=default:wAAA:%s\nterminal=default:wAAA:%s\n' "$w" "$w" > "$1/t$w.meta"; done
  for w in hash:p1 silent-seen:p1 tracked:p2 silent-seen:p9 silent-working:p9 hash:p8 stale-since:p7 stale-cleanup:p7; do
    : > "$1/.${w%%:*}-default_wAAA_${w##*:}"
  done
  : > "$1/.unrelated-default_wAAA_p9"; : > "$1/.hash-notes.txt"
}

seed_src() {  # <dir>: a watcher whose prune removes .hash- itself and .stale- through a helper, nothing else
  mkdir -p "$1/bin"; cat > "$1/bin/w.sh" <<'EOF2'
reset() {  # <key>
  rm -f "$STATE/.stale-$1"
}
prune() {
  rm -f "$STATE/.hash-$key"; reset "$key"
}
other() { echo "$STATE/.silent-seen-$key $STATE/.stale-cleanup-$key"; }
EOF2
  printf 'marker\t%s\tbin/w.sh\tpane\t%s\n' hash bin/w.sh:prune stale bin/w.sh:prune silent-seen bin/w.sh:prune \
    stale-cleanup - ghost bin/w.sh:prune > "$1/m.tsv"
}

sweep() {  # <state dir>: every registered marker whose observer says orphan
  local re n; re=$(awk -F'\t' '$1=="marker"{printf "%s%s", s, $2; s="|"}' "$TBL")
  find "$1" -maxdepth 1 -type f -printf '%f\n' | grep -E "^\.($re)-[A-Za-z0-9_]+$" | while read -r n; do
    JG_STATE_OVERRIDE=$1 bash "$JM" show markers "$n" | awk -F'\t' -v n="$n" '$1=="state"&&$2=="orphan"{print n}'
  done | sort
}

fn_scope() {  # <file> <fn>: the text of the function and of every function of the file it calls
  local file=$1 todo=$2 seen=" " acc="" fn body c
  while [ -n "$todo" ]; do
    fn=${todo%% *}; todo=${todo#"$fn"}; todo=${todo# }
    case "$seen" in *" $fn "*) continue ;; esac
    seen="$seen$fn "
    body=$(awk -v f="$fn" '$0 ~ "^" f "\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$file"); acc="$acc$body"
    for c in $(grep -oE '^[a-z_]+\(\)' "$file" | tr -d '()'); do
      printf '%s' "$body" | grep -qw -- "$c" && todo="$todo $c"
    done
  done
  printf '%s' "$acc"
}

audit() {  # <table> <src root>: one line per kind its writer does not write, nobody removes, or its remover skips
  awk -F'\t' '$1=="marker"{print $2 "\t" $3 "\t" $5}' "$1" | while IFS=$'\t' read -r k w r; do
    grep -qE -- '\.'"$k"'-[$*]' "$2/$w" || echo "drift $k: $w does not write it"
    if [ "$r" = - ]; then echo "no-remover $k"
    elif ! fn_scope "$2/${r%%:*}" "${r#*:}" | grep -qE -- '\.'"$k"'-[$*]'; then echo "leak $k: ${r#*:} does not remove it"; fi
  done
}

# Red first: before the table exists this fails with "no table for machine 'markers'".
jm check markers; expect_code 0 "$RC" "the markers table lints clean"
assert_contains "$OUT" "ok markers:" "check names the machine"
pass "the markers table lints clean"

seed_state "$T/state"; export JG_STATE_OVERRIDE=$T/state
jm show markers .silent-seen-default_wAAA_p1; assert_contains "$OUT" "state	owned" "a marker of a live pane is owned"
jm show markers .silent-seen-default_wAAA_p9; assert_contains "$OUT" "state	orphan" "a marker of a vanished pane is an orphan"
before=$(cd "$T/state" && ls -lA --time-style=full-iso)
assert_equals "$(printf '.hash-default_wAAA_p8\n.silent-seen-default_wAAA_p9\n.silent-working-default_wAAA_p9\n.stale-cleanup-default_wAAA_p7\n.stale-since-default_wAAA_p7')" "$(sweep "$T/state")" "sweep lists exactly the orphans"
assert_equals "$before" "$(cd "$T/state" && ls -lA --time-style=full-iso)" "sweep changes no file"
pass "sweep markers lists exactly the seeded orphans and writes nothing"

jm next markers .hash-default_wAAA_p8; assert_contains "$OUT" "bin/jg-watch.sh:phantom_pane_prune" "next names the orphan's remover"
pass "next names who removes an orphan"

seed_src "$T/src"
assert_equals "$(printf 'leak silent-seen: prune does not remove it\nno-remover stale-cleanup\ndrift ghost: bin/w.sh does not write it\nleak ghost: prune does not remove it')" "$(audit "$T/src/m.tsv" "$T/src")" "audit names each kind that leaks"
pass "audit names a skipped kind, a kind with no remover and a kind its writer does not write"

echo "report-only audit of the real watcher:"; audit "$TBL" "$ROOT" | sed 's/^/  /'
pass "the real watcher was audited (report only)"
