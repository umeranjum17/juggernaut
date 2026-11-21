#!/usr/bin/env bash
# E2E: a worker's question is answered with no Main turn. The worker asks with the real `jg ask` from its worktree; the real
# core/decision-handler/decision-handler.sh tick reads the open decision through the real status classifier. Only the two edges
# are recorders: the advisor (a script that counts its calls) and the steer endpoint, which keeps bin/jg-send.sh's documented
# --resolve-key contract (it records the steer and appends the `resolved [key=...]` line).
# Usage: core/decision-handler/tests/decision-handler.test.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$here/../../.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/decision-handler.XXXXXX") || exit 1
trap 'rm -rf -- "$d"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: want [$3] got [$2]"; }

H=$d/home; mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$d/bin"
git -C "$H/projects/proj" init -q .
git -C "$H/projects/proj" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
mk_worker() {  # <task>
  git -C "$H/projects/proj" worktree add -q -b "feature/$1" "$d/wt-$1" || fail "worktree $1"
  printf 'worktree=%s\nkind=ship\nmode=local-trunk\nbranch=feature/%s\n' "$(cd "$d/wt-$1" && pwd -P)" "$1" > "$H/state/$1.meta"
  mkdir -p "$H/data/$1"; printf "## Captain's intent\nKeep the parser fast.\n## Juggernaut spec\nBuild it.\n" > "$H/data/$1/brief.md"
}
ask() { (cd "$d/wt-$1" && env -u JG_HOME -u JG_TASK -u JG_STATE_OVERRIDE "$ROOT/bin/jg" ask "${@:2}" >/dev/null 2>&1) || fail "jg ask $*"; }

# The steer endpoint: fails while $d/send-down exists, so a lost delivery can be replayed.
cat > "$d/bin/send" <<SH
#!/usr/bin/env bash
[ ! -e "$d/send-down" ] || exit 1
t=\$1; shift
printf '%s\t%s\n' "\$t" "\$*" >> "$d/steers"
[ "\${1:-}" = --resolve-key ] && printf 'resolved [at=%s] [key=%s]: answered: %s\n' "\$(date +%s)" "\$2" "\${3:0:60}" >> "$H/state/\$t.status"
exit 0
SH
# The advisor: counts calls; answers with the file $d/advice (its last line), as a plan-only model would.
cat > "$d/bin/advisor" <<SH
#!/usr/bin/env bash
cat >> "$d/prompts"; echo x >> "$d/advisor-calls"; cat "$d/advice"
SH
chmod +x "$d/bin/send" "$d/bin/advisor"
tick() { JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config \
  JG_DECISION_SEND=$d/bin/send JG_DECISION_ADVISOR_CMD=$d/bin/advisor "$ROOT/core/decision-handler/decision-handler.sh" tick; }
calls() { wc -l < "$d/advisor-calls" 2>/dev/null || echo 0; }
steers() { grep -c "^$1	" "$d/steers" 2>/dev/null || true; }
open_n() { JG_HOME=$H bash -c ". '$ROOT/bin/jg-classify-lib.sh'; status_own_open_decisions '$H/state/$1.status' | grep -c ."; }

# 1. An in-scope fork: one advisor call, one steer to that worker carrying the pick, the wait closed, and replays change nothing.
mk_worker t1; ask t1 "Use a hash map or a sorted list for the token index?" --option hashmap --option sortedlist --recommend hashmap
eq open-before "$(open_n t1)" 1
echo '{"pick":"hashmap","reason":"the intent is a fast parser","proof":"the benchmark journey stays under budget"}' > "$d/advice"
out=$(tick); case $out in "delivered t1 default: hashmap"*|"delivered t1 "*": hashmap") ;; *) fail "tick1: $out" ;; esac
eq advisor-calls "$(calls)" 1; eq steers "$(steers t1)" 1; eq open-after "$(open_n t1)" 0
grep -q 'Keep the parser fast' "$d/prompts" || fail "the advisor was not given the accepted intent"
grep -q 'hashmap.*Reason: the intent is a fast parser.*Proof: the benchmark' "$d/steers" || fail "the steer lacks pick, reason and proof"
tick >/dev/null; tick >/dev/null
eq advisor-calls-replay "$(calls)" 1; eq steers-replay "$(steers t1)" 1

# 2. A lost delivery stays pending: the send fails, the same pick is kept, and it is sent once when the endpoint is back.
mk_worker t2; ask t2 "Tabs or spaces in the fixture files?" --option tabs --option spaces --recommend spaces
echo '{"pick":"spaces","reason":"matches the repo","proof":"the lint passes"}' > "$d/advice"; : > "$d/send-down"
out=$(tick); case $out in *"pending t2 "*) ;; *) fail "lost send: $out" ;; esac
eq open-while-down "$(open_n t2)" 1; eq advisor-after-down "$(calls)" 2
rm -f "$d/send-down"; echo '{"pick":"tabs","reason":"changed my mind","proof":"x"}' > "$d/advice"
tick >/dev/null; eq steers-t2 "$(steers t2)" 1; eq advisor-not-asked-again "$(calls)" 2; eq open-t2 "$(open_n t2)" 0
grep -q "^t2.*spaces" "$d/steers" || fail "the kept pick was not the one sent"

# 3. A boundary question reaches no advisor and no steer; the wait stays open for the existing authority.
mk_worker t3; ask t3 "Discard the worker's uncommitted files and restart?" --option discard --option keep
before=$(calls); out=$(tick); case $out in "escalated t3 "*) ;; *) fail "boundary: $out" ;; esac
eq boundary-advisor "$(calls)" "$before"; eq boundary-steer "$(steers t3)" 0; eq boundary-open "$(open_n t3)" 1
tick >/dev/null; eq boundary-quiet "$(calls)" "$before"

# 4. The captain's own question and a validation finding are not taken.
mk_worker t4
printf 'needs-decision [at=%s]: captain call, hold t4: Pick the logo? Options: a | b.\n' "$(date +%s)" > "$H/state/t4.status"
printf 'needs-decision [at=%s] [key=nm-run1-review]: Fix or ignore? Options: fix | ignore.\n' "$(date +%s)" >> "$H/state/t4.status"
before=$(calls); tick >/dev/null; eq owner-advisor "$(calls)" "$before"; eq owner-steer "$(steers t4)" 0

# 5. Advice that names no option is refused three times, then the question is left to the ladder with no steer.
mk_worker t5; ask t5 "Name the column ts or created?" --option ts --option created
echo '{"pick":"timestamp","reason":"x","proof":"y"}' > "$d/advice"; before=$(calls)
tick >/dev/null; tick >/dev/null; out=$(tick); case $out in "escalated t5 "*) ;; *) fail "bad advice: $out" ;; esac
eq bad-advice-calls "$(( $(calls) - before ))" 3; eq bad-advice-steer "$(steers t5)" 0; eq bad-advice-open "$(open_n t5)" 1

# 6. The advisor can say the question is the owner's; nothing is sent and the question stays open.
mk_worker t6; ask t6 "Ship under the old name or the new brand?" --option old --option new
echo '{"escalate":true,"reason":"a brand choice is the owner'"'"'s"}' > "$d/advice"; before=$(calls)
out=$(tick); case $out in "escalated t6 "*) ;; *) fail "owner call: $out" ;; esac
eq owner-call-steer "$(steers t6)" 0; eq owner-call-open "$(open_n t6)" 1

echo "decision-handler: ok"
