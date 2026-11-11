#!/usr/bin/env bash
# tests/jg-records-reaper.test.sh - a finished task leaves no status file, inbox folder, landing output or merged lane
# branch behind, and a live task, an open ticket, an unmerged branch and data/<task>/ stay
# (core/tmp-reaper/records.sh, core/tmp-reaper/wiring.sh, core/trunk-landing/trunk-landing.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-records-reaper)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
RECORDS="$ROOT/core/tmp-reaper/records.sh"
H=$TMP_ROOT/home
MEM=$H/data/jg-trunk-landing
mkdir -p "$H/state" "$H/config" "$MEM" "$H/data/gone-task" "$H/projects"
# The home's own bin: the real scripts, except a backlog that lists a fixed set of open tickets.
mkdir -p "$H/bin"
for f in "$ROOT"/bin/*; do ln -s "$f" "$H/bin/${f##*/}"; done
rm -f "$H/bin/jg-backlog.sh"
cat > "$H/bin/jg-backlog.sh" <<'EOF'
#!/usr/bin/env bash
[ -e "$JG_HOME/state/.backlog-down" ] && exit 1
printf 'count: 1\ntasks[1]{id,state,kind,repo,title}:\n  open-ticket,queued,task,p,"[feature] x"\n'
EOF
chmod +x "$H/bin/jg-backlog.sh"

HEAD=$(printf 'a%.0s' $(seq 1 40))
OLD='10 days ago'
age() { touch -d "$OLD" "$@"; }
mk() { : > "$1"; age "$1"; }

# --- state files ---------------------------------------------------------------------------
mk "$H/state/gone.status"; mk "$H/state/gone.exit"; mk "$H/state/gone.turn-ended"; mk "$H/state/gone.busy-state"
mkdir "$H/state/gone.inbox"; mk "$H/state/gone.inbox/1.msg"; age "$H/state/gone.inbox"
mk "$H/state/live.status"; mkdir "$H/state/live.inbox"; mk "$H/state/live.inbox/1.msg"; : > "$H/state/live.meta"
mk "$H/state/open-ticket.status"                       # no record, but the ticket is still open
: > "$H/state/young.status"                            # no record, but written just now
mkdir "$H/state/youngbox.inbox"; mk "$H/state/youngbox.inbox/1.msg"; : > "$H/state/youngbox.inbox/2.msg"  # a fresh message inside
mk "$H/state/gone.run-receipt.json"; mk "$H/state/gone.models"   # not a named volatile pattern
mk "$H/data/gone-task/evidence.txt"
mk "$H/state/ghost.status"

# --- landing output ------------------------------------------------------------------------
L=$MEM
for s in state log reported refusal tip; do mk "$L/gone.$HEAD.$s"; mk "$L/live.$HEAD.$s"; done
mk "$L/gone.$HEAD.request-Ab12Cd.log"; mk "$L/gone.$HEAD.launch-Ab12Cd.log"; mk "$L/batch.launch-Zz99Yy.log"
mk "$L/live.$HEAD.request-Ab12Cd.log"
: > "$L/gone2.$HEAD.request-Qq11Ww.log"; touch -d '3 hours ago' "$L/gone2.$HEAD.request-Qq11Ww.log"  # young output of a finished task
mk "$L/outbox"; mkdir -p "$L/retired"

# --- a local-trunk project with a merged lane branch, an unmerged one and a live one ---------
P=$H/projects/p
git init -q -b trunk-v1 "$P"
jg_test_git_identity "$P" 2>/dev/null || { git -C "$P" config user.email t@example.invalid; git -C "$P" config user.name t; }
cmt() { git -C "$P" -c commit.gpgsign=false commit -q --allow-empty -m "$1" --date="$OLD"; }
GIT_COMMITTER_DATE="$(date -d "$OLD" -R)" cmt base
git -C "$P" branch feature/merged-old
git -C "$P" branch fm/merged-old2
git -C "$P" branch feature/live-lane
git -C "$P" branch feature/by-record
git -C "$P" branch release/keep-me
git -C "$P" checkout -q -b feature/unmerged
GIT_COMMITTER_DATE="$(date -d "$OLD" -R)" cmt work
git -C "$P" checkout -q trunk-v1
printf 'trunk-v1\n' > "$H/state/trunk-branch-p"
: > "$H/state/live-lane.meta"
printf 'branch=feature/by-record\n' > "$H/state/other.meta"
# A branch cut just now from the trunk tip is "merged" too; it must not be taken.
git -C "$P" branch feature/just-cut

has_branch() { git -C "$P" rev-parse --verify --quiet "refs/heads/$1" >/dev/null; }

# --- through the wiring-installed watcher check (the real caller) ------------------------------
env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/wiring.sh" "$H" >/dev/null 2>&1 || fail "wiring did not arm the records check"
[ -x "$H/state/records-reaper.check.sh" ] || fail "wiring left no state/records-reaper.check.sh"
# Age the lane refs: git writes a reflog entry at branch creation, so rewrite it as 10 days old.
for b in feature/merged-old fm/merged-old2 feature/live-lane feature/by-record feature/unmerged; do
  if [ -f "$P/.git/logs/refs/heads/$b" ]; then
    old=$(date -d "$OLD" +%s)
    sed -i -E "s/ [0-9]{10} ([+-][0-9]{4})\t/ $old \1\t/" "$P/.git/logs/refs/heads/$b"
  fi
done

out=$(bash "$H/state/records-reaper.check.sh" 2>&1)
[ -z "$out" ] || fail "the records check printed: $out"

for f in gone.status gone.exit gone.turn-ended gone.busy-state gone.inbox ghost.status; do
  assert_absent "$H/state/$f" "state/$f of a task with no record was kept"
done
for f in live.status live.inbox live.meta open-ticket.status young.status youngbox.inbox gone.run-receipt.json gone.models; do
  assert_present "$H/state/$f" "state/$f was removed"
done
assert_present "$H/data/gone-task/evidence.txt" "data/<task>/ was touched"
pass "files of a finished task are removed; a live task, an open ticket, young files and other names stay"

for s in state log reported refusal tip; do
  assert_absent "$L/gone.$HEAD.$s" "landing record gone.$s was kept"
  assert_present "$L/live.$HEAD.$s" "landing record live.$s was removed"
done
assert_absent "$L/gone.$HEAD.request-Ab12Cd.log" "a finished task's request log was kept"
assert_absent "$L/gone.$HEAD.launch-Ab12Cd.log" "a finished task's launch log was kept"
assert_absent "$L/batch.launch-Zz99Yy.log" "an old stack launch log was kept"
assert_present "$L/live.$HEAD.request-Ab12Cd.log" "a live task's request log was removed"
assert_present "$L/gone2.$HEAD.request-Qq11Ww.log" "a request log younger than a day was removed"
assert_present "$L/outbox" "the landing outbox was removed"
assert_present "$L/retired" "the landing retired folder was removed"
pass "a finished task's landing records and temporary output are removed; a live task's stay"

assert_absent_branch() { has_branch "$1" && fail "$2"; return 0; }
assert_absent_branch feature/merged-old "a merged lane branch with no record was kept"
assert_absent_branch fm/merged-old2 "a merged fm/ lane branch with no record was kept"
has_branch feature/unmerged || fail "an unmerged branch was deleted"
has_branch feature/live-lane || fail "the branch of a live task was deleted"
has_branch feature/by-record || fail "a branch a task record names was deleted"
has_branch feature/just-cut || fail "a branch cut just now was deleted"
has_branch release/keep-me || fail "a branch outside feature/ and fm/ was deleted"
has_branch trunk-v1 || fail "the trunk was deleted"
pass "a merged lane branch with no record is deleted; unmerged, live, recorded, fresh and other branches stay"

assert_grep "removed $H/state/gone.status" "$H/state/records-reaper.log" "the removal was not logged"
assert_grep "deleted-branch p:feature/merged-old" "$H/state/records-reaper.log" "the branch removal was not logged"

# --- the ticket list cannot be read: nothing that depends on it is removed -----------------------
mk "$H/state/later.status"; mk "$L/later.$HEAD.state"; : > "$H/state/.backlog-down"
bash "$H/state/records-reaper.check.sh" >/dev/null 2>&1
assert_present "$H/state/later.status" "a status file was removed while the ticket list was unreadable"
assert_present "$L/later.$HEAD.state" "a landing record was removed while the ticket list was unreadable"
rm -f "$H/state/.backlog-down"
pass "an unreadable ticket list removes nothing"

# --- the landing check removes its own output (trunk-landing.sh check) ----------------------------
rm -f "$L/.records-reaped"
mk "$L/later.$HEAD.request-Aa00Bb.log"
bash "$ROOT/core/trunk-landing/trunk-landing.sh" check "$H" >/dev/null 2>&1
assert_absent "$L/later.$HEAD.request-Aa00Bb.log" "trunk-landing.sh check left a finished task's request log"
assert_absent "$L/later.$HEAD.state" "trunk-landing.sh check left a finished task's landing record"
assert_present "$L/live.$HEAD.state" "trunk-landing.sh check removed a live task's landing record"
pass "trunk-landing.sh check clears the landing output of finished tasks"

# --- a second run changes nothing; the dry run removes nothing ---------------------------------
mk "$H/state/again.status"
bash "$RECORDS" --dry-run check "$H" | grep -q "would remove $H/state/again.status" || fail "dry run did not name the file"
assert_present "$H/state/again.status" "dry run removed a file"
bash "$RECORDS" check "$H" >/dev/null 2>&1
assert_absent "$H/state/again.status" "a second run missed a new leftover"
pass "dry run removes nothing; a later run takes new leftovers"

env -u JG_STATE_OVERRIDE bash "$ROOT/core/tmp-reaper/unwiring.sh" "$H" >/dev/null 2>&1 || fail "unwiring failed"
[ ! -e "$H/state/records-reaper.check.sh" ] || fail "unwiring left the records check"
pass "unwiring removes the records check"
